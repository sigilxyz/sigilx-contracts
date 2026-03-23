// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ISigilXOracleHook} from "./ISigilXOracleHook.sol";

/// @title SigilXTreasuryManager
/// @notice Autonomous treasury management: revenue split, buyback+burn, protocol-owned liquidity.
///         Owned by SigilXTimelock — all config changes require 48h delay.
///
/// Revenue flow:
///   Verification fees (USDC) -> collectRevenue() -> splitRevenue()
///     |-- treasuryBps (70%) -> stays in treasury
///     |-- buybackBps (20%) -> buyback pool -> executeBuyback() -> burn SIGILX
///     +-- teamBps (10%) -> team multisig
///
/// Automation: anyone can call autoSplit() / executeBuyback() — 0.1% incentive to caller.
contract SigilXTreasuryManager is Ownable, ReentrancyGuard, Pausable, IUnlockCallback {
    using SafeERC20 for IERC20;

    // ── Immutables ───────────────────────────────────────────────────

    IERC20 public immutable usdc;
    IERC20 public immutable sigilxToken;

    // ── Revenue split (basis points, must sum to 10000) ──────────────

    uint256 public treasuryBps = 7000;  // 70%
    uint256 public buybackBps  = 2000;  // 20%
    uint256 public teamBps     = 1000;  // 10%

    // ── Addresses ────────────────────────────────────────────────────

    address public teamWallet;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ── Buyback config ───────────────────────────────────────────────

    uint256 public buybackPool;         // Accumulated USDC for buybacks
    uint256 public maxBuybackPerDay;    // Cap daily buyback amount
    uint256 public lastBuybackDay;
    uint256 public buybacksToday;
    uint256 public maxSlippageBps = 300; // 3% max slippage

    // ── V4 Oracle (TWAP) ───────────────────────────────────────────

    /// @notice SigilXOracleHook address for TWAP queries.
    ///         Set via setOracleHook() — zero means V4 buyback disabled.
    ISigilXOracleHook public oracleHook;

    /// @notice Uniswap V4 PoolManager for executing swaps.
    IPoolManager public poolManager;

    /// @notice V4 PoolKey for the SIGILX/USDC pool.
    PoolKey public poolKey;

    /// @notice V4 PoolId for the SIGILX/USDC pool.
    PoolId public poolId;

    /// @notice TWAP window in seconds (default 1 hour per expert recommendation).
    uint32 public twapWindow = 3600;

    /// @notice Maximum USDC per single buyback trade. 0 = no limit.
    uint256 public maxBuybackPerTrade;

    /// @notice Minimum oracle observations required before TWAP is trusted.
    uint16 public minObservations = 10;

    // ── Automation incentive ─────────────────────────────────────────

    uint256 public constant KEEPER_INCENTIVE_BPS = 10; // 0.1% to caller
    uint256 public minSplitAmount   = 100e6;  // $100 USDC minimum to trigger split
    uint256 public minBuybackAmount = 50e6;   // $50 USDC minimum to trigger buyback

    // ── Stats ────────────────────────────────────────────────────────

    uint256 public totalRevenue;
    uint256 public totalBuybackBurned;
    uint256 public totalTeamPaid;

    // ── Events ───────────────────────────────────────────────────────

    event RevenueSplit(
        uint256 treasury,
        uint256 buyback,
        uint256 team,
        uint256 keeperReward
    );
    event BuybackExecuted(
        uint256 usdcSpent,
        uint256 sigilxBurned,
        address indexed keeper
    );
    event ConfigUpdated(string param, uint256 oldValue, uint256 newValue);
    event TeamWalletUpdated(address oldWallet, address newWallet);
    event OracleHookUpdated(address oldHook, address newHook);
    event PoolIdUpdated(PoolId oldPoolId, PoolId newPoolId);
    event BuybackV4Executed(
        uint256 usdcSpent,
        int24   twapTick,
        uint256 sigilxBurned,
        uint256 minSigilxOut,
        address indexed keeper
    );

    // ── Errors ───────────────────────────────────────────────────────

    error InvalidSplit();
    error BuybackCapExceeded();
    error InsufficientBuybackPool();
    error SlippageExceeded();
    error BelowMinimum();
    error ZeroAddress();
    error OracleNotSet();
    error PoolIdNotSet();
    error PoolManagerNotSet();
    error TWAPWindowTooShort();
    error PerTradeLimitExceeded();
    error UnauthorizedCallback();
    error InsufficientObservations(uint16 observed, uint16 required);

    // ── Constructor ──────────────────────────────────────────────────

    /// @param _usdc              USDC token address
    /// @param _sigilxToken       SIGILX token address
    /// @param _teamWallet        Team multisig for team revenue share
    /// @param _maxBuybackPerDay  Daily buyback cap in USDC units (6 decimals)
    /// @param _owner             Should be SigilXTimelock for 48h governance delay
    constructor(
        address _usdc,
        address _sigilxToken,
        address _teamWallet,
        uint256 _maxBuybackPerDay,
        address _owner
    ) Ownable(_owner) {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_sigilxToken == address(0)) revert ZeroAddress();
        if (_teamWallet == address(0)) revert ZeroAddress();

        usdc            = IERC20(_usdc);
        sigilxToken     = IERC20(_sigilxToken);
        teamWallet      = _teamWallet;
        maxBuybackPerDay = _maxBuybackPerDay;
    }

    // ── Revenue Collection ───────────────────────────────────────────

    /// @notice Split accumulated USDC revenue per configured ratios.
    /// @dev Anyone can call — keeper gets 0.1% incentive.
    ///      Treasury share stays in the contract; buyback share is
    ///      accumulated in `buybackPool` for later executeBuyback().
    function autoSplit() external nonReentrant whenNotPaused {
        uint256 balance = usdc.balanceOf(address(this)) - buybackPool;
        if (balance < minSplitAmount) revert BelowMinimum();

        // Keeper incentive carved from total before split
        uint256 keeperReward = (balance * KEEPER_INCENTIVE_BPS) / 10000;
        uint256 remaining    = balance - keeperReward;

        uint256 toTreasury = (remaining * treasuryBps) / 10000;
        uint256 toBuyback  = (remaining * buybackBps)  / 10000;
        uint256 toTeam     = remaining - toTreasury - toBuyback; // dust -> team

        buybackPool   += toBuyback;
        totalRevenue  += balance;
        totalTeamPaid += toTeam;

        // Transfer team share
        if (toTeam > 0) {
            usdc.safeTransfer(teamWallet, toTeam);
        }
        // Transfer keeper reward
        if (keeperReward > 0) {
            usdc.safeTransfer(msg.sender, keeperReward);
        }
        // Treasury share stays in contract

        emit RevenueSplit(toTreasury, toBuyback, toTeam, keeperReward);
    }

    // ── Buyback + Burn ───────────────────────────────────────────────

    /// @notice Execute a buyback: swap USDC -> SIGILX, then burn.
    /// @param amountUSDC   Amount of USDC to spend from buyback pool
    /// @param minSigilxOut Minimum SIGILX to receive (slippage protection)
    /// @dev Anyone can call — uses buyback pool only, not treasury reserves.
    ///      The caller is responsible for ensuring the swap produces
    ///      `minSigilxOut`. In production, this will integrate with
    ///      Uniswap V4 PoolManager or V3 SwapRouter + Chainlink price
    ///      feeds for price protection.
    function executeBuyback(
        uint256 amountUSDC,
        uint256 minSigilxOut
    ) external nonReentrant whenNotPaused {
        if (amountUSDC > buybackPool)      revert InsufficientBuybackPool();
        if (amountUSDC < minBuybackAmount) revert BelowMinimum();

        // ── Per-trade limit check ──────────────────────────────────
        if (maxBuybackPerTrade > 0 && amountUSDC > maxBuybackPerTrade) {
            revert PerTradeLimitExceeded();
        }

        // ── Daily cap check ──────────────────────────────────────────
        uint256 today = block.timestamp / 1 days;
        if (today != lastBuybackDay) {
            lastBuybackDay = today;
            buybacksToday  = 0;
        }
        if (buybacksToday + amountUSDC > maxBuybackPerDay) {
            revert BuybackCapExceeded();
        }

        buybackPool   -= amountUSDC;
        buybacksToday += amountUSDC;

        // ── Swap integration point ───────────────────────────────────
        // In production: approve USDC to Uniswap V4 PoolManager or V3
        // SwapRouter, execute swap with Chainlink-validated minSigilxOut.
        // For testability, the swap is performed externally and SIGILX
        // tokens are sent to this contract before calling executeBuyback.
        // ─────────────────────────────────────────────────────────────

        // Verify we received enough SIGILX
        uint256 sigilxBalance = sigilxToken.balanceOf(address(this));
        if (sigilxBalance < minSigilxOut) revert SlippageExceeded();

        // Burn all SIGILX held by the contract
        sigilxToken.safeTransfer(BURN_ADDRESS, sigilxBalance);
        totalBuybackBurned += sigilxBalance;

        emit BuybackExecuted(amountUSDC, sigilxBalance, msg.sender);
    }

    // ── V4 TWAP Buyback ─────────────────────────────────────────────

    /// @dev Compute TWAP tick and minSigilxOut from the oracle hook.
    function _computeTwap(uint256 amountUSDC) internal view returns (int24 twapTick, uint256 minSigilxOut) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = oracleHook.observe(secondsAgos, poolId);
        twapTick = int24((tickCumulatives[1] - tickCumulatives[0]) / int56(int32(twapWindow)));

        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(twapTick);
        uint256 numerator    = uint256(amountUSDC) * (1 << 96);
        uint256 intermediate = numerator / uint256(sqrtPriceX96);
        uint256 expectedOut  = (intermediate * (1 << 96) * 1e12) / uint256(sqrtPriceX96);
        minSigilxOut = (expectedOut * (10000 - maxSlippageBps)) / 10000;
    }

    /// @dev Execute the V4 swap via poolManager.unlock and burn the output.
    function _executeV4Swap(uint256 amountUSDC, uint256 minSigilxOut) internal returns (uint256 sigilxReceived) {
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(usdc);
        uint160 sqrtPriceLimitX96 = zeroForOne
            ? TickMath.MIN_SQRT_PRICE + 1
            : TickMath.MAX_SQRT_PRICE - 1;

        bytes memory callbackData = abi.encode(amountUSDC, minSigilxOut, zeroForOne, sqrtPriceLimitX96);
        bytes memory result = poolManager.unlock(callbackData);
        sigilxReceived = abi.decode(result, (uint256));

        sigilxToken.safeTransfer(BURN_ADDRESS, sigilxReceived);
        totalBuybackBurned += sigilxReceived;
    }

    /// @notice Execute a TWAP-protected buyback via Uniswap V4.
    ///         Queries the oracle hook for the TWAP tick over `twapWindow`,
    ///         calculates a minimum output using maxSlippageBps, then executes
    ///         the swap via poolManager.unlock() -> swap() -> settle/take.
    ///         Received SIGILX is burned to 0xdead.
    /// @param amountUSDC Amount of USDC to spend from buyback pool.
    /// @return twapTick  The time-weighted average tick over the TWAP window.
    /// @return minSigilxOut The minimum SIGILX output after slippage tolerance.
    function executeBuybackV4(
        uint256 amountUSDC
    ) external nonReentrant whenNotPaused returns (int24 twapTick, uint256 minSigilxOut) {
        if (address(oracleHook) == address(0)) revert OracleNotSet();
        if (PoolId.unwrap(poolId) == bytes32(0)) revert PoolIdNotSet();
        if (address(poolManager) == address(0)) revert PoolManagerNotSet();
        if (amountUSDC > buybackPool)      revert InsufficientBuybackPool();
        if (amountUSDC < minBuybackAmount) revert BelowMinimum();
        if (maxBuybackPerTrade > 0 && amountUSDC > maxBuybackPerTrade) {
            revert PerTradeLimitExceeded();
        }

        // ── Oracle observation count check (Risk 7: oracle initialization spoofing) ──
        if (minObservations > 0) {
            uint16 obsCount = oracleHook.observationCount(poolId);
            if (obsCount < minObservations) {
                revert InsufficientObservations(obsCount, minObservations);
            }
        }

        // ── Daily cap check ──────────────────────────────────────────
        uint256 today = block.timestamp / 1 days;
        if (today != lastBuybackDay) {
            lastBuybackDay = today;
            buybacksToday  = 0;
        }
        if (buybacksToday + amountUSDC > maxBuybackPerDay) {
            revert BuybackCapExceeded();
        }

        // ── Compute TWAP and minOut ──────────────────────────────────
        (twapTick, minSigilxOut) = _computeTwap(amountUSDC);

        // ── Deduct from pool ─────────────────────────────────────────
        buybackPool   -= amountUSDC;
        buybacksToday += amountUSDC;

        // ── Execute swap and burn ────────────────────────────────────
        uint256 sigilxReceived = _executeV4Swap(amountUSDC, minSigilxOut);

        emit BuybackV4Executed(amountUSDC, twapTick, sigilxReceived, minSigilxOut, msg.sender);
    }

    /// @notice Callback from PoolManager.unlock(). Executes the swap,
    ///         settles USDC into the pool, and takes SIGILX out.
    /// @dev Only callable by the PoolManager during an active unlock.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();

        (
            uint256 amountUSDC,
            uint256 minSigilxOut,
            bool zeroForOne,
            uint160 sqrtPriceLimitX96
        ) = abi.decode(data, (uint256, uint256, bool, uint160));

        // Execute the swap — exact input (negative amountSpecified in V4)
        BalanceDelta delta = poolManager.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountUSDC),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );

        // Determine SIGILX received based on swap direction
        uint256 sigilxReceived;
        if (zeroForOne) {
            // currency0=USDC (we pay), currency1=SIGILX (we receive)
            sigilxReceived = uint256(uint128(int128(delta.amount1())));

            // Settle USDC: transfer to pool manager then call settle
            usdc.safeTransfer(address(poolManager), amountUSDC);
            poolManager.settle();

            // Take SIGILX from pool manager
            poolManager.take(poolKey.currency1, address(this), sigilxReceived);
        } else {
            // currency1=USDC (we pay), currency0=SIGILX (we receive)
            sigilxReceived = uint256(uint128(int128(delta.amount0())));

            // Settle USDC
            usdc.safeTransfer(address(poolManager), amountUSDC);
            poolManager.settle();

            // Take SIGILX
            poolManager.take(poolKey.currency0, address(this), sigilxReceived);
        }

        // Enforce slippage protection inside the callback
        if (sigilxReceived < minSigilxOut) revert SlippageExceeded();

        return abi.encode(sigilxReceived);
    }

    // ── Config (Timelock-gated) ──────────────────────────────────────

    /// @notice Set the oracle hook address for V4 TWAP queries.
    function setOracleHook(address _hook) external onlyOwner {
        emit OracleHookUpdated(address(oracleHook), _hook);
        oracleHook = ISigilXOracleHook(_hook);
    }

    /// @notice Set the V4 PoolManager address.
    function setPoolManager(address _poolManager) external onlyOwner {
        if (_poolManager == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(_poolManager);
    }

    /// @notice Set the V4 pool key for the SIGILX/USDC pool.
    function setPoolKey(PoolKey calldata _poolKey) external onlyOwner {
        poolKey = _poolKey;
    }

    /// @notice Set the V4 pool ID for the SIGILX/USDC pool.
    function setPoolId(PoolId _poolId) external onlyOwner {
        emit PoolIdUpdated(poolId, _poolId);
        poolId = _poolId;
    }

    /// @notice Set the TWAP observation window. Minimum 1800 seconds (30 min).
    function setTwapWindow(uint32 _window) external onlyOwner {
        if (_window < 1800) revert TWAPWindowTooShort();
        emit ConfigUpdated("twapWindow", uint256(twapWindow), uint256(_window));
        twapWindow = _window;
    }

    /// @notice Update revenue split ratios. Must sum to 10000 bps.
    function setSplitRatios(
        uint256 _treasury,
        uint256 _buyback,
        uint256 _team
    ) external onlyOwner {
        if (_treasury + _buyback + _team != 10000) revert InvalidSplit();

        emit ConfigUpdated("treasuryBps", treasuryBps, _treasury);
        emit ConfigUpdated("buybackBps",  buybackBps,  _buyback);
        emit ConfigUpdated("teamBps",     teamBps,     _team);

        treasuryBps = _treasury;
        buybackBps  = _buyback;
        teamBps     = _team;
    }

    /// @notice Update daily buyback cap.
    function setMaxBuybackPerDay(uint256 _max) external onlyOwner {
        emit ConfigUpdated("maxBuybackPerDay", maxBuybackPerDay, _max);
        maxBuybackPerDay = _max;
    }

    /// @notice Update per-trade buyback limit. 0 = no limit.
    function setMaxBuybackPerTrade(uint256 _max) external onlyOwner {
        emit ConfigUpdated("maxBuybackPerTrade", maxBuybackPerTrade, _max);
        maxBuybackPerTrade = _max;
    }

    /// @notice Set minimum oracle observations required for TWAP trust.
    function setMinObservations(uint16 _min) external onlyOwner {
        emit ConfigUpdated("minObservations", uint256(minObservations), uint256(_min));
        minObservations = _min;
    }

    /// @notice Update max slippage for buybacks. Capped at 10%.
    function setMaxSlippageBps(uint256 _bps) external onlyOwner {
        require(_bps <= 1000, "max 10%");
        emit ConfigUpdated("maxSlippageBps", maxSlippageBps, _bps);
        maxSlippageBps = _bps;
    }

    /// @notice Update minimum USDC amount required to trigger autoSplit.
    function setMinSplitAmount(uint256 _min) external onlyOwner {
        emit ConfigUpdated("minSplitAmount", minSplitAmount, _min);
        minSplitAmount = _min;
    }

    /// @notice Update minimum USDC amount required for a buyback.
    function setMinBuybackAmount(uint256 _min) external onlyOwner {
        emit ConfigUpdated("minBuybackAmount", minBuybackAmount, _min);
        minBuybackAmount = _min;
    }

    /// @notice Update team wallet address.
    function setTeamWallet(address _wallet) external onlyOwner {
        if (_wallet == address(0)) revert ZeroAddress();
        emit TeamWalletUpdated(teamWallet, _wallet);
        teamWallet = _wallet;
    }

    /// @notice Pause all revenue splits and buybacks.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause all revenue splits and buybacks.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ── Emergency ────────────────────────────────────────────────────

    /// @notice Emergency rescue of ERC20 tokens sent to contract by mistake.
    /// @dev Cannot rescue USDC (use autoSplit for that) or SIGILX (burned).
    ///      Only owner (Timelock) can call.
    function rescueToken(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        require(
            token != address(usdc) && token != address(sigilxToken),
            "use autoSplit or executeBuyback"
        );
        IERC20(token).safeTransfer(to, amount);
    }

    // ── Views ────────────────────────────────────────────────────────

    /// @notice Returns USDC balance minus buyback pool (i.e. actual treasury).
    function treasuryBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this)) - buybackPool;
    }

    /// @notice Aggregate protocol stats.
    function stats()
        external
        view
        returns (
            uint256 _totalRevenue,
            uint256 _totalBurned,
            uint256 _totalTeamPaid,
            uint256 _buybackPool,
            uint256 _treasuryBalance
        )
    {
        return (
            totalRevenue,
            totalBuybackBurned,
            totalTeamPaid,
            buybackPool,
            usdc.balanceOf(address(this)) - buybackPool
        );
    }
}
