// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract SigilXStakeDisputeV1 is UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant UNSTAKE_DELAY = 100;
    uint256 public constant MIN_BOND = 1e6;

    IERC20 public stakeToken;
    uint256 public slashBps;

    struct StakerInfo { uint256 rawStaked; uint256 pendingUnstake; uint256 unstakeRequestBlock; uint256 snapshotMultiplier; }
    struct Dispute { uint256 agentId; bytes32 certHash; address challenger; uint256 bond; bool resolved; bool upheld; }

    mapping(uint256 => mapping(address => StakerInfo)) public stakers;
    mapping(uint256 => uint256) public agentTotalRawStake;
    mapping(uint256 => uint256) public cumulativeSlashMultiplier;
    mapping(uint256 => Dispute) public disputes;
    uint256 public nextDisputeId;

    event Staked(uint256 indexed agentId, address indexed staker, uint256 amount);
    event UnstakeRequested(uint256 indexed agentId, address indexed staker, uint256 amount);
    event Withdrawn(uint256 indexed agentId, address indexed staker, uint256 amount);
    event DisputeOpened(uint256 indexed disputeId, uint256 indexed agentId, bytes32 certHash);
    event DisputeResolved(uint256 indexed disputeId, bool upheld, uint256 slashAmount);

    error ZeroAmount();
    error InsufficientStake();
    error NothingPending();
    error TooEarly();
    error BondTooSmall();
    error AlreadyResolved();
    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address _token, uint256 _slashBps, address _owner) public initializer {
        if (_token == address(0)) revert ZeroAddress();
        __Ownable_init(_owner);
        stakeToken = IERC20(_token);
        slashBps = _slashBps;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function stake(uint256 agentId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (cumulativeSlashMultiplier[agentId] == 0) cumulativeSlashMultiplier[agentId] = PRECISION;
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        StakerInfo storage info = stakers[agentId][msg.sender];
        uint256 currentMult = cumulativeSlashMultiplier[agentId];
        if (info.rawStaked > 0 && info.snapshotMultiplier != currentMult) {
            uint256 effective = Math.mulDiv(info.rawStaked, info.snapshotMultiplier, PRECISION);
            uint256 rebasedRaw = Math.mulDiv(effective, PRECISION, currentMult);
            agentTotalRawStake[agentId] = agentTotalRawStake[agentId] - info.rawStaked + rebasedRaw;
            info.rawStaked = rebasedRaw;
        }
        uint256 rawAmount = Math.mulDiv(amount, PRECISION, currentMult);
        info.rawStaked += rawAmount;
        info.snapshotMultiplier = currentMult;
        agentTotalRawStake[agentId] += rawAmount;
        emit Staked(agentId, msg.sender, amount);
    }

    function requestUnstake(uint256 agentId, uint256 amount) external nonReentrant {
        StakerInfo storage info = stakers[agentId][msg.sender];
        uint256 effectiveStaked = stakeOf(agentId, msg.sender);
        if (effectiveStaked < amount) revert InsufficientStake();
        uint256 currentMult = cumulativeSlashMultiplier[agentId];
        if (currentMult == 0) currentMult = PRECISION;
        if (info.snapshotMultiplier != currentMult && info.snapshotMultiplier != 0) {
            uint256 effective = Math.mulDiv(info.rawStaked, info.snapshotMultiplier, PRECISION);
            uint256 rebasedRaw = Math.mulDiv(effective, PRECISION, currentMult);
            agentTotalRawStake[agentId] = agentTotalRawStake[agentId] - info.rawStaked + rebasedRaw;
            info.rawStaked = rebasedRaw;
        }
        uint256 rawAmount = Math.mulDiv(amount, PRECISION, currentMult);
        info.rawStaked -= rawAmount;
        info.snapshotMultiplier = currentMult;
        info.pendingUnstake += amount;
        info.unstakeRequestBlock = block.number;
        agentTotalRawStake[agentId] -= rawAmount;
        emit UnstakeRequested(agentId, msg.sender, amount);
    }

    function withdraw(uint256 agentId) external nonReentrant {
        StakerInfo storage info = stakers[agentId][msg.sender];
        if (info.pendingUnstake == 0) revert NothingPending();
        if (block.number < info.unstakeRequestBlock + UNSTAKE_DELAY) revert TooEarly();
        uint256 amount = info.pendingUnstake;
        info.pendingUnstake = 0;
        stakeToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(agentId, msg.sender, amount);
    }

    function openDispute(uint256 agentId, bytes32 certHash, uint256 bond) external nonReentrant returns (uint256) {
        if (bond < MIN_BOND) revert BondTooSmall();
        stakeToken.safeTransferFrom(msg.sender, address(this), bond);
        uint256 id = nextDisputeId++;
        disputes[id] = Dispute({ agentId: agentId, certHash: certHash, challenger: msg.sender, bond: bond, resolved: false, upheld: false });
        emit DisputeOpened(id, agentId, certHash);
        return id;
    }

    function resolveDispute(uint256 disputeId, bool upheld) external onlyOwner nonReentrant {
        Dispute storage d = disputes[disputeId];
        if (d.resolved) revert AlreadyResolved();
        d.resolved = true;
        d.upheld = upheld;
        if (upheld) {
            uint256 agentId = d.agentId;
            if (cumulativeSlashMultiplier[agentId] == 0) cumulativeSlashMultiplier[agentId] = PRECISION;
            uint256 totalEffective = Math.mulDiv(agentTotalRawStake[agentId], cumulativeSlashMultiplier[agentId], PRECISION);
            uint256 slashAmount = Math.mulDiv(totalEffective, slashBps, BPS_DENOM);
            cumulativeSlashMultiplier[agentId] = Math.mulDiv(cumulativeSlashMultiplier[agentId], BPS_DENOM - slashBps, BPS_DENOM);
            stakeToken.safeTransfer(d.challenger, d.bond + slashAmount);
            emit DisputeResolved(disputeId, true, slashAmount);
        } else {
            emit DisputeResolved(disputeId, false, 0);
        }
    }

    function setSlashBps(uint256 _bps) external onlyOwner { slashBps = _bps; }

    function stakeOf(uint256 agentId, address staker) public view returns (uint256) {
        StakerInfo storage info = stakers[agentId][staker];
        if (info.rawStaked == 0) return 0;
        uint256 snapshot = info.snapshotMultiplier == 0 ? PRECISION : info.snapshotMultiplier;
        uint256 current = cumulativeSlashMultiplier[agentId] == 0 ? PRECISION : cumulativeSlashMultiplier[agentId];
        return Math.mulDiv(info.rawStaked, current, snapshot);
    }

    function pendingUnstakeOf(uint256 agentId, address staker) external view returns (uint256) { return stakers[agentId][staker].pendingUnstake; }

    function agentTotalStake(uint256 agentId) external view returns (uint256) {
        uint256 mult = cumulativeSlashMultiplier[agentId] == 0 ? PRECISION : cumulativeSlashMultiplier[agentId];
        return Math.mulDiv(agentTotalRawStake[agentId], mult, PRECISION);
    }
}
