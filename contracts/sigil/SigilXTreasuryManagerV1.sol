// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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

contract SigilXTreasuryManagerV1 is UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    IERC20 public usdc;
    IERC20 public sigilxToken;
    uint256 public treasuryBps;
    uint256 public buybackBps;
    uint256 public teamBps;
    address public teamWallet;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 public buybackPool;
    uint256 public maxBuybackPerDay;
    uint256 public lastBuybackDay;
    uint256 public buybacksToday;
    uint256 public maxSlippageBps;
    ISigilXOracleHook public oracleHook;
    IPoolManager public poolManager;
    PoolKey public poolKey;
    PoolId public poolId;
    uint32 public twapWindow;
    uint256 public maxBuybackPerTrade;
    uint16 public minObservations;
    uint256 public constant KEEPER_INCENTIVE_BPS = 10;
    uint256 public minSplitAmount;
    uint256 public minBuybackAmount;
    uint256 public totalRevenue;
    uint256 public totalBuybackBurned;
    uint256 public totalTeamPaid;

    event RevenueSplit(uint256 treasury, uint256 buyback, uint256 team, uint256 keeperReward);
    event BuybackExecuted(uint256 usdcSpent, uint256 sigilxBurned, address indexed keeper);
    event ConfigUpdated(string param, uint256 oldValue, uint256 newValue);
    event TeamWalletUpdated(address oldWallet, address newWallet);
    event OracleHookUpdated(address oldHook, address newHook);
    event PoolIdUpdated(PoolId oldPoolId, PoolId newPoolId);
    event BuybackV4Executed(uint256 usdcSpent, int24 twapTick, uint256 sigilxBurned, uint256 minSigilxOut, address indexed keeper);
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address _usdc, address _sigilxToken, address _teamWallet, uint256 _maxBuybackPerDay, address _owner) public initializer {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_sigilxToken == address(0)) revert ZeroAddress();
        if (_teamWallet == address(0)) revert ZeroAddress();
        __Ownable_init(_owner);
        __Pausable_init();
        usdc = IERC20(_usdc); sigilxToken = IERC20(_sigilxToken); teamWallet = _teamWallet; maxBuybackPerDay = _maxBuybackPerDay;
        treasuryBps = 7000; buybackBps = 2000; teamBps = 1000; maxSlippageBps = 300; twapWindow = 3600; minSplitAmount = 100e6; minBuybackAmount = 50e6; minObservations = 10;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function autoSplit() external nonReentrant whenNotPaused {
        uint256 balance = usdc.balanceOf(address(this)) - buybackPool;
        if (balance < minSplitAmount) revert BelowMinimum();
        uint256 keeperReward = (balance * KEEPER_INCENTIVE_BPS) / 10000;
        uint256 remaining = balance - keeperReward;
        uint256 toTreasury = (remaining * treasuryBps) / 10000;
        uint256 toBuyback = (remaining * buybackBps) / 10000;
        uint256 toTeam = remaining - toTreasury - toBuyback;
        buybackPool += toBuyback; totalRevenue += balance; totalTeamPaid += toTeam;
        if (toTeam > 0) usdc.safeTransfer(teamWallet, toTeam);
        if (keeperReward > 0) usdc.safeTransfer(msg.sender, keeperReward);
        emit RevenueSplit(toTreasury, toBuyback, toTeam, keeperReward);
    }

    function executeBuyback(uint256 amountUSDC, uint256 minSigilxOut) external nonReentrant whenNotPaused {
        if (amountUSDC > buybackPool) revert InsufficientBuybackPool();
        if (amountUSDC < minBuybackAmount) revert BelowMinimum();
        if (maxBuybackPerTrade > 0 && amountUSDC > maxBuybackPerTrade) revert PerTradeLimitExceeded();
        uint256 today = block.timestamp / 1 days;
        if (today != lastBuybackDay) { lastBuybackDay = today; buybacksToday = 0; }
        if (buybacksToday + amountUSDC > maxBuybackPerDay) revert BuybackCapExceeded();
        buybackPool -= amountUSDC; buybacksToday += amountUSDC;
        uint256 sigilxBalance = sigilxToken.balanceOf(address(this));
        if (sigilxBalance < minSigilxOut) revert SlippageExceeded();
        sigilxToken.safeTransfer(BURN_ADDRESS, sigilxBalance);
        totalBuybackBurned += sigilxBalance;
        emit BuybackExecuted(amountUSDC, sigilxBalance, msg.sender);
    }

    function _computeTwapV1(uint256 amountUSDC) internal view returns (int24 twapTick, uint256 minSigilxOut) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow; secondsAgos[1] = 0;
        (int56[] memory tickCumulatives,) = oracleHook.observe(secondsAgos, poolId);
        twapTick = int24((tickCumulatives[1] - tickCumulatives[0]) / int56(int32(twapWindow)));
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(twapTick);
        uint256 numerator = uint256(amountUSDC) * (1 << 96);
        uint256 intermediate = numerator / uint256(sqrtPriceX96);
        uint256 expectedOut = (intermediate * (1 << 96) * 1e12) / uint256(sqrtPriceX96);
        minSigilxOut = (expectedOut * (10000 - maxSlippageBps)) / 10000;
    }

    function _executeV4SwapV1(uint256 amountUSDC, uint256 minSigilxOut) internal returns (uint256 sigilxReceived) {
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(usdc);
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        bytes memory callbackData = abi.encode(amountUSDC, minSigilxOut, zeroForOne, sqrtPriceLimitX96);
        bytes memory result = poolManager.unlock(callbackData);
        sigilxReceived = abi.decode(result, (uint256));
        sigilxToken.safeTransfer(BURN_ADDRESS, sigilxReceived);
        totalBuybackBurned += sigilxReceived;
    }

    function executeBuybackV4(uint256 amountUSDC) external nonReentrant whenNotPaused returns (int24 twapTick, uint256 minSigilxOut) {
        if (address(oracleHook) == address(0)) revert OracleNotSet();
        if (PoolId.unwrap(poolId) == bytes32(0)) revert PoolIdNotSet();
        if (address(poolManager) == address(0)) revert PoolManagerNotSet();
        if (amountUSDC > buybackPool) revert InsufficientBuybackPool();
        if (amountUSDC < minBuybackAmount) revert BelowMinimum();
        if (maxBuybackPerTrade > 0 && amountUSDC > maxBuybackPerTrade) revert PerTradeLimitExceeded();
        if (minObservations > 0) { uint16 obsCount = oracleHook.observationCount(poolId); if (obsCount < minObservations) revert InsufficientObservations(obsCount, minObservations); }
        uint256 today = block.timestamp / 1 days;
        if (today != lastBuybackDay) { lastBuybackDay = today; buybacksToday = 0; }
        if (buybacksToday + amountUSDC > maxBuybackPerDay) revert BuybackCapExceeded();
        (twapTick, minSigilxOut) = _computeTwapV1(amountUSDC);
        buybackPool -= amountUSDC; buybacksToday += amountUSDC;
        uint256 sigilxReceived = _executeV4SwapV1(amountUSDC, minSigilxOut);
        emit BuybackV4Executed(amountUSDC, twapTick, sigilxReceived, minSigilxOut, msg.sender);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();

        (uint256 amountUSDC, uint256 minSigilxOut, bool zeroForOne, uint160 sqrtPriceLimitX96) =
            abi.decode(data, (uint256, uint256, bool, uint160));

        BalanceDelta delta = poolManager.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountUSDC),
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );

        uint256 sigilxReceived;
        if (zeroForOne) {
            sigilxReceived = uint256(uint128(int128(delta.amount1())));
            usdc.safeTransfer(address(poolManager), amountUSDC);
            poolManager.settle();
            poolManager.take(poolKey.currency1, address(this), sigilxReceived);
        } else {
            sigilxReceived = uint256(uint128(int128(delta.amount0())));
            usdc.safeTransfer(address(poolManager), amountUSDC);
            poolManager.settle();
            poolManager.take(poolKey.currency0, address(this), sigilxReceived);
        }

        if (sigilxReceived < minSigilxOut) revert SlippageExceeded();
        return abi.encode(sigilxReceived);
    }

    function setOracleHook(address _hook) external onlyOwner { emit OracleHookUpdated(address(oracleHook), _hook); oracleHook = ISigilXOracleHook(_hook); }
    function setPoolManager(address _pm) external onlyOwner { if (_pm == address(0)) revert ZeroAddress(); poolManager = IPoolManager(_pm); }
    function setPoolKey(PoolKey calldata _poolKey) external onlyOwner { poolKey = _poolKey; }
    function setPoolId(PoolId _poolId) external onlyOwner { emit PoolIdUpdated(poolId, _poolId); poolId = _poolId; }
    function setTwapWindow(uint32 _window) external onlyOwner { if (_window < 1800) revert TWAPWindowTooShort(); emit ConfigUpdated("twapWindow", uint256(twapWindow), uint256(_window)); twapWindow = _window; }
    function setMinObservations(uint16 _min) external onlyOwner { emit ConfigUpdated("minObservations", uint256(minObservations), uint256(_min)); minObservations = _min; }
    function setSplitRatios(uint256 _treasury, uint256 _buyback, uint256 _team) external onlyOwner { if (_treasury + _buyback + _team != 10000) revert InvalidSplit(); treasuryBps = _treasury; buybackBps = _buyback; teamBps = _team; }
    function setMaxBuybackPerDay(uint256 _max) external onlyOwner { maxBuybackPerDay = _max; }
    function setMaxBuybackPerTrade(uint256 _max) external onlyOwner { emit ConfigUpdated("maxBuybackPerTrade", maxBuybackPerTrade, _max); maxBuybackPerTrade = _max; }
    function setMaxSlippageBps(uint256 _bps) external onlyOwner { require(_bps <= 1000, "max 10%"); maxSlippageBps = _bps; }
    function setMinSplitAmount(uint256 _min) external onlyOwner { minSplitAmount = _min; }
    function setMinBuybackAmount(uint256 _min) external onlyOwner { minBuybackAmount = _min; }
    function setTeamWallet(address _wallet) external onlyOwner { if (_wallet == address(0)) revert ZeroAddress(); teamWallet = _wallet; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function rescueToken(address token, address to, uint256 amount) external onlyOwner { if (to == address(0)) revert ZeroAddress(); require(token != address(usdc) && token != address(sigilxToken), "use autoSplit"); IERC20(token).safeTransfer(to, amount); }
    function treasuryBalance() external view returns (uint256) { return usdc.balanceOf(address(this)) - buybackPool; }
    function stats() external view returns (uint256, uint256, uint256, uint256, uint256) { return (totalRevenue, totalBuybackBurned, totalTeamPaid, buybackPool, usdc.balanceOf(address(this)) - buybackPool); }
}
