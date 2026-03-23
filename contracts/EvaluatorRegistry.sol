/*
         ╔═══════════════════════════════════════════════╗
         ║                                               ║
         ║     ███████╗██╗ ██████╗ ██╗██╗     ██╗  ██╗  ║
         ║     ██╔════╝██║██╔════╝ ██║██║     ╚██╗██╔╝  ║
         ║     ███████╗██║██║  ███╗██║██║      ╚███╔╝   ║
         ║     ╚════██║██║██║   ██║██║██║      ██╔██╗   ║
         ║     ███████║██║╚██████╔╝██║███████╗██╔╝ ██╗  ║
         ║     ╚══════╝╚═╝ ╚═════╝ ╚═╝╚══════╝╚═╝  ╚═╝ ║
         ║                                               ║
         ║       BFT Evaluator Registry & Selection      ║
         ║              https://sigilx.xyz               ║
         ║                                               ║
         ╚═══════════════════════════════════════════════╝
*/
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {WorldIDSybilGuard} from "./WorldIDSybilGuard.sol";

/// @title SigilX EvaluatorRegistry
/// @notice Manages evaluator registration, quadratic staking, slashing, and VRF-based
///         committee selection for the SigilX BFT evaluator protocol. Evaluators stake
///         tokens to become eligible for random committee assignment, weighted by
///         a quadratic function of stake and reputation (Sybil-resistant).
/// @dev Committee selection uses cumulative-weight binary search with deterministic
///      rehashing to guarantee unique committee members.
///      Deployed behind an ERC1967 UUPS proxy for upgradeability.
contract EvaluatorRegistry is OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Types
    // =========================================================================

    struct EvaluatorInfo {
        uint256 stake;              // Current staked amount
        uint256 registeredAt;       // Block timestamp of registration
        bool active;                // Currently eligible
        uint256 reputationScore;    // Accumulated reputation (updated externally)
        uint256 totalEvaluations;   // Total evaluations participated in
        uint256 correctEvaluations; // Evaluations matching ground truth
        uint256 cooldownUntil;      // Timestamp until which unstake withdrawal is locked
        uint256 pendingUnstake;     // Amount requested for withdrawal
    }

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Minimum time after registration before an evaluator can be selected
    uint256 public constant MIN_REGISTRATION_AGE = 7 days;

    /// @notice Minimum stake to register (100 USDC with 6 decimals)
    uint256 public constant MIN_STAKE = 100e6;

    /// @notice Minimum allowed unstake cooldown (24 hours).
    uint256 public constant MIN_UNSTAKE_COOLDOWN = 24 hours;

    /// @notice Cooldown period after unstake request before withdrawal.
    ///         Configurable via setUnstakeCooldown(). Default 3 days.
    uint256 public unstakeCooldown = 3 days;

    // =========================================================================
    // State
    // =========================================================================

    /// @notice The ERC20 token used for staking
    IERC20 public stakingToken;

    /// @notice Evaluator address => EvaluatorInfo
    mapping(address => EvaluatorInfo) public evaluators;

    /// @notice Ordered list of active evaluator addresses
    address[] public activeEvaluatorList;

    /// @notice Total stake across all active evaluators
    uint256 public totalActiveStake;

    /// @notice Addresses authorized to record evaluation outcomes
    mapping(address => bool) public recorders;

    /// @notice Optional World ID Sybil guard (zero address = open registration)
    address public sybilGuard;

    /// @notice Addresses authorized to slash evaluators
    mapping(address => bool) public slashers;

    /// @notice Receiver of slashed funds (defaults to this contract if not set)
    address public slashReceiver;

    /// @notice Slash percentage in basis points (default 1000 = 10%)
    uint256 public slashBps;

    // =========================================================================
    // Events
    // =========================================================================

    event EvaluatorRegistered(address indexed evaluator, uint256 stake);
    event StakeIncreased(address indexed evaluator, uint256 added, uint256 newTotal);
    event UnstakeRequested(address indexed evaluator, uint256 amount, uint256 cooldownUntil);
    event StakeWithdrawn(address indexed evaluator, uint256 amount);
    event EvaluatorDeactivated(address indexed evaluator);
    event EvaluationRecorded(address indexed evaluator, bool correct);
    event RecorderUpdated(address indexed recorder, bool authorized);
    event SlasherUpdated(address indexed slasher, bool authorized);
    event EvaluatorSlashed(address indexed evaluator, uint256 amount, bytes32 reason);
    event SlashReceiverUpdated(address indexed receiver);
    event SlashBpsUpdated(uint256 bps);
    event SybilGuardUpdated(address indexed guard);
    event UnstakeCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);

    // =========================================================================
    // Errors
    // =========================================================================

    error InsufficientStake(uint256 provided, uint256 required);
    error AlreadyRegistered();
    error NotRegistered();
    error NotActive();
    error CooldownNotExpired(uint256 until);
    error NotAuthorizedRecorder();
    error ZeroAmount();
    error PendingUnstakeExists();
    error NotAuthorizedSlasher();
    error InsufficientEligibleEvaluators(uint256 available, uint256 required);
    error CooldownTooShort(uint256 requested, uint256 minimum);

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyRecorder() {
        if (!recorders[msg.sender]) revert NotAuthorizedRecorder();
        _;
    }

    modifier onlySlasher() {
        if (!slashers[msg.sender]) revert NotAuthorizedSlasher();
        _;
    }

    // =========================================================================
    // Constructor (disabled for proxy) & Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract (called once via proxy)
    /// @param _stakingToken The ERC20 token used for staking
    /// @param _owner The initial owner address
    function initialize(IERC20 _stakingToken, address _owner) external initializer {
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        // __UUPSUpgradeable_init(); // Not available in this OZ version (no-op anyway)
        stakingToken = _stakingToken;
        slashBps = 1000;
        unstakeCooldown = 3 days;
    }

    /// @notice UUPS authorization — only owner can upgrade
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // =========================================================================
    // Evaluator Lifecycle
    // =========================================================================

    /// @notice Register as an evaluator by staking at least MIN_STAKE tokens
    /// @param amount Number of tokens to stake
    function registerEvaluator(uint256 amount) external nonReentrant {
        if (evaluators[msg.sender].active) revert AlreadyRegistered();
        if (amount < MIN_STAKE) revert InsufficientStake(amount, MIN_STAKE);

        // Sybil guard check (soft gate — skipped if guard not set)
        if (sybilGuard != address(0)) {
            WorldIDSybilGuard(sybilGuard).requireHuman(msg.sender);
        }

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        evaluators[msg.sender] = EvaluatorInfo({
            stake: amount,
            registeredAt: block.timestamp,
            active: true,
            reputationScore: 0,
            totalEvaluations: 0,
            correctEvaluations: 0,
            cooldownUntil: 0,
            pendingUnstake: 0
        });

        activeEvaluatorList.push(msg.sender);
        totalActiveStake += amount;

        emit EvaluatorRegistered(msg.sender, amount);
    }

    /// @notice Increase stake (must already be registered and active)
    /// @param amount Additional tokens to stake
    function increaseStake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        EvaluatorInfo storage e = evaluators[msg.sender];
        if (!e.active) revert NotActive();

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        e.stake += amount;
        totalActiveStake += amount;

        emit StakeIncreased(msg.sender, amount, e.stake);
    }

    /// @notice Request to unstake. Begins cooldown period.
    /// @param amount Number of tokens to unstake
    function requestUnstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        EvaluatorInfo storage e = evaluators[msg.sender];
        if (!e.active) revert NotActive();
        if (e.pendingUnstake > 0) revert PendingUnstakeExists();
        if (amount > e.stake) revert InsufficientStake(e.stake, amount);

        e.cooldownUntil = block.timestamp + unstakeCooldown;
        e.pendingUnstake = amount;

        // If remaining stake < MIN_STAKE, deactivate
        if (e.stake - amount < MIN_STAKE) {
            e.active = false;
            totalActiveStake -= e.stake;
            _removeFromActiveList(msg.sender);
            emit EvaluatorDeactivated(msg.sender);
        } else {
            totalActiveStake -= amount;
        }

        emit UnstakeRequested(msg.sender, amount, e.cooldownUntil);
    }

    /// @notice Withdraw staked tokens after cooldown expires
    function withdraw() external nonReentrant {
        EvaluatorInfo storage e = evaluators[msg.sender];
        if (e.stake == 0) revert NotRegistered();
        if (e.pendingUnstake == 0) revert ZeroAmount();
        if (block.timestamp < e.cooldownUntil) revert CooldownNotExpired(e.cooldownUntil);

        uint256 amount = e.pendingUnstake;
        if (amount > e.stake) {
            amount = e.stake;
        }
        e.pendingUnstake = 0;
        e.stake -= amount;

        stakingToken.safeTransfer(msg.sender, amount);
        emit StakeWithdrawn(msg.sender, amount);
    }

    // =========================================================================
    // Evaluation Recording
    // =========================================================================

    /// @notice Record an evaluation outcome (correct or incorrect)
    /// @param evaluator Address of the evaluator
    /// @param correct Whether the evaluation matched ground truth
    function recordEvaluation(address evaluator, bool correct) external onlyRecorder {
        EvaluatorInfo storage e = evaluators[evaluator];
        if (e.stake == 0) revert NotRegistered();

        e.totalEvaluations += 1;
        if (correct) {
            e.correctEvaluations += 1;
            e.reputationScore += 1;
        }

        emit EvaluationRecorded(evaluator, correct);
    }

    // =========================================================================
    // Slashing
    // =========================================================================

    /// @notice Slash an evaluator's stake. Called by authorized slashers (e.g. SigilXEvaluatorV2).
    /// @param evaluator Address of the evaluator to slash
    /// @param reason Encoded reason for the slash
    function slash(address evaluator, bytes32 reason) external onlySlasher nonReentrant {
        EvaluatorInfo storage e = evaluators[evaluator];
        if (e.stake == 0) revert NotRegistered();

        uint256 slashAmount = (e.stake * slashBps) / 10000;
        if (slashAmount == 0) slashAmount = 1; // minimum 1 wei slash
        if (slashAmount > e.stake) slashAmount = e.stake;

        e.stake -= slashAmount;

        if (e.active) {
            // If remaining stake below minimum, deactivate and remove full remaining stake
            // from totalActiveStake. Otherwise just remove the slashed amount.
            // IMPORTANT: Only one decrement — avoid double-counting (audit F-22).
            if (e.stake < MIN_STAKE) {
                totalActiveStake -= (slashAmount + e.stake);
                e.active = false;
                _removeFromActiveList(evaluator);
                emit EvaluatorDeactivated(evaluator);
            } else {
                totalActiveStake -= slashAmount;
            }
        }

        // Transfer slashed tokens to receiver (or keep in contract if not set)
        address receiver = slashReceiver == address(0) ? address(this) : slashReceiver;
        if (receiver != address(this)) {
            stakingToken.safeTransfer(receiver, slashAmount);
        }

        emit EvaluatorSlashed(evaluator, slashAmount, reason);
    }

    // =========================================================================
    // Committee Selection (core algorithm)
    // =========================================================================

    /// @notice Select a committee of evaluators weighted by quadratic stake
    /// @param randomSeed VRF random seed for deterministic selection
    /// @param committeeSize Number of committee members to select
    /// @return committee Array of selected evaluator addresses
    function selectCommittee(
        uint256 randomSeed,
        uint8 committeeSize
    ) external view returns (address[] memory committee) {
        // Phase 1: build eligible set with cumulative weights
        (
            address[] memory eligible,
            uint256[] memory cumWeights,
            uint256 eligibleCount,
            uint256 totalEffWeight
        ) = _buildEligibleSet();

        if (eligibleCount < committeeSize) {
            revert InsufficientEligibleEvaluators(eligibleCount, committeeSize);
        }

        // Phase 2: pick unique committee members
        committee = _pickCommittee(
            randomSeed, committeeSize, eligible, cumWeights, eligibleCount, totalEffWeight
        );

        return committee;
    }

    /// @notice Determine committee size based on job value in USDC
    /// @param jobValueUSDC The value of the job in USDC (6 decimals)
    /// @return size The recommended committee size
    function committeeSizeForValue(uint256 jobValueUSDC) public pure returns (uint8 size) {
        if (jobValueUSDC >= 1000e6) return 13;
        if (jobValueUSDC >= 100e6) return 7;
        return 5;
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Compute the quadratic effective weight for an evaluator
    /// @dev Weight = sqrt(stake * (reputationScore + 1)). The +1 ensures new
    ///      evaluators with zero reputation still have nonzero weight.
    /// @param evaluator Address to compute weight for
    /// @return weight The effective weight
    function effectiveWeight(address evaluator) public view returns (uint256 weight) {
        EvaluatorInfo storage e = evaluators[evaluator];
        if (!e.active) return 0;
        return _effectiveWeight(e);
    }

    /// @notice Get the number of active evaluators
    function activeEvaluatorCount() external view returns (uint256) {
        return activeEvaluatorList.length;
    }

    /// @notice Check if an evaluator is active and meets minimum stake
    /// @param evaluator Address to check
    /// @return True if evaluator is active with sufficient stake
    function isActiveAttester(address evaluator) external view returns (bool) {
        return evaluators[evaluator].active && evaluators[evaluator].stake >= MIN_STAKE;
    }

    /// @notice Get the quadratic stake weight for an evaluator (alias for effectiveWeight)
    /// @param evaluator Address to query
    /// @return The effective weight used in committee selection
    function stakeWeight(address evaluator) external view returns (uint256) {
        return effectiveWeight(evaluator);
    }

    // =========================================================================
    // Governance
    // =========================================================================

    /// @notice Authorize or revoke an address as an evaluation recorder
    /// @param recorder Address to update
    /// @param authorized Whether the address should be authorized
    function setRecorder(address recorder, bool authorized) external onlyOwner {
        recorders[recorder] = authorized;
        emit RecorderUpdated(recorder, authorized);
    }

    /// @notice Authorize or revoke an address as a slasher
    /// @param slasher Address to update
    /// @param authorized Whether the address should be authorized
    function setSlasher(address slasher, bool authorized) external onlyOwner {
        slashers[slasher] = authorized;
        emit SlasherUpdated(slasher, authorized);
    }

    /// @notice Set the receiver of slashed funds
    /// @param receiver Address to receive slashed tokens (zero = keep in contract)
    function setSlashReceiver(address receiver) external onlyOwner {
        slashReceiver = receiver;
        emit SlashReceiverUpdated(receiver);
    }

    /// @notice Set the slash percentage in basis points
    /// @param bps Slash amount in basis points (max 5000 = 50%)
    function setSlashBps(uint256 bps) external onlyOwner {
        require(bps <= 5000, "Max 50% slash");
        slashBps = bps;
        emit SlashBpsUpdated(bps);
    }

    /// @notice Set the unstake cooldown period. Minimum 24 hours.
    /// @param _cooldown New cooldown in seconds (must be >= MIN_UNSTAKE_COOLDOWN)
    function setUnstakeCooldown(uint256 _cooldown) external onlyOwner {
        if (_cooldown < MIN_UNSTAKE_COOLDOWN) revert CooldownTooShort(_cooldown, MIN_UNSTAKE_COOLDOWN);
        emit UnstakeCooldownUpdated(unstakeCooldown, _cooldown);
        unstakeCooldown = _cooldown;
    }

    /// @notice Set the World ID Sybil guard (zero address disables the gate)
    /// @param _guard Address of the WorldIDSybilGuard contract
    function setSybilGuard(address _guard) external onlyOwner {
        sybilGuard = _guard;
        emit SybilGuardUpdated(_guard);
    }

    // =========================================================================
    // Internal
    // =========================================================================

    /// @dev Build arrays of eligible evaluators and their cumulative weights
    function _buildEligibleSet()
        internal
        view
        returns (
            address[] memory eligible,
            uint256[] memory cumWeights,
            uint256 eligibleCount,
            uint256 cumWeight
        )
    {
        uint256 listLen = activeEvaluatorList.length;
        eligible = new address[](listLen);
        cumWeights = new uint256[](listLen);

        for (uint256 i = 0; i < listLen; i++) {
            address addr = activeEvaluatorList[i];
            EvaluatorInfo storage e = evaluators[addr];

            if (!e.active) continue;
            if (block.timestamp - e.registeredAt < MIN_REGISTRATION_AGE) continue;

            uint256 w = _effectiveWeight(e);
            if (w == 0) continue;

            cumWeight += w;
            eligible[eligibleCount] = addr;
            cumWeights[eligibleCount] = cumWeight;
            eligibleCount++;
        }
    }

    /// @dev Pick unique committee members using deterministic rehashing
    function _pickCommittee(
        uint256 randomSeed,
        uint8 committeeSize,
        address[] memory eligible,
        uint256[] memory cumWeights,
        uint256 eligibleCount,
        uint256 totalEffWeight
    ) internal pure returns (address[] memory committee) {
        committee = new address[](committeeSize);
        uint256 selected = 0;

        for (uint8 i = 0; i < committeeSize; i++) {
            uint256 nonce = 0;
            while (true) {
                uint256 roll = uint256(
                    keccak256(abi.encode(randomSeed, i, nonce))
                ) % totalEffWeight;

                uint256 idx = _binarySearch(cumWeights, eligibleCount, roll);
                address candidate = eligible[idx];

                if (!_isDuplicate(committee, selected, candidate)) {
                    committee[selected] = candidate;
                    selected++;
                    break;
                }
                nonce++;
            }
        }
    }

    /// @dev Check if candidate already exists in the committee
    function _isDuplicate(
        address[] memory committee,
        uint256 count,
        address candidate
    ) internal pure returns (bool) {
        for (uint256 j = 0; j < count; j++) {
            if (committee[j] == candidate) return true;
        }
        return false;
    }

    /// @dev Compute effective weight from evaluator info struct
    function _effectiveWeight(EvaluatorInfo storage e) internal view returns (uint256) {
        return _sqrt(e.stake * (e.reputationScore + 1));
    }

    /// @dev Binary search on cumulative weight array. Returns the index where
    ///      cumWeights[idx] > roll (first element strictly greater than roll).
    function _binarySearch(
        uint256[] memory cumWeights,
        uint256 length,
        uint256 roll
    ) internal pure returns (uint256) {
        uint256 lo = 0;
        uint256 hi = length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (cumWeights[mid] <= roll) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    /// @dev Remove an address from the activeEvaluatorList (swap-and-pop)
    function _removeFromActiveList(address evaluator) internal {
        uint256 len = activeEvaluatorList.length;
        for (uint256 i = 0; i < len; i++) {
            if (activeEvaluatorList[i] == evaluator) {
                activeEvaluatorList[i] = activeEvaluatorList[len - 1];
                activeEvaluatorList.pop();
                return;
            }
        }
    }

    // =========================================================================
    // Storage Gap (H-2 audit fix: reserve slots for future upgrades)
    // =========================================================================

    uint256[50] private __gap;

    /// @dev Babylonian integer square root (floor)
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}
