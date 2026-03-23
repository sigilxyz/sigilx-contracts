// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IACPHook.sol";
import "../interfaces/IERC8183.sol";

/// @title ISigilXEvaluatorV2FeeInfo
/// @notice Read-only interface for querying fee state from SigilXEvaluatorV2.
interface ISigilXEvaluatorV2FeeInfo {
    function evaluatorFeeBps() external view returns (uint256);
    function getEvalForJob(address acpContract, uint256 jobId) external view returns (uint256);
    function getCommittee(uint256 evalId) external view returns (address[] memory);
    function paymentToken() external view returns (address);
}

/// @title SigilXQuorumHookV2
/// @notice ERC-8183 hook that routes evaluator fees through the BFT evaluator
///         protocol on job completion. On `afterAction(COMPLETE_SELECTOR)`, reads
///         the evaluation committee from SigilXEvaluatorV2 and transfers the fee
///         share to the fee router (treasury) for downstream distribution.
/// @dev    Designed as a non-upgradeable hook. Attach to jobs via IERC8183.createJob(hook).
contract SigilXQuorumHookV2 is IACPHook, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    // State
    // =========================================================================

    /// @notice SigilXEvaluatorV2 contract for reading evaluation/fee info
    address public evaluatorV2;

    /// @notice Address where evaluator fees are routed (treasury / splitter)
    address public feeRouter;

    /// @notice The ERC-8183 ACP contract that is authorized to call this hook
    address public acpContract;

    /// @notice Payment token (cached from evaluatorV2 for gas efficiency)
    IERC20 public paymentToken;

    /// @notice Complete function selector from IERC8183
    bytes4 public constant COMPLETE_SELECTOR = IERC8183.complete.selector;

    // =========================================================================
    // Events
    // =========================================================================

    event EvaluatorFeeRouted(
        uint256 indexed jobId,
        uint256 indexed evalId,
        uint256 feeAmount,
        address feeRouter,
        uint256 committeeSize
    );

    event EvaluatorV2Updated(address indexed oldEvaluator, address indexed newEvaluator);
    event FeeRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event ACPContractUpdated(address indexed oldACP, address indexed newACP);
    event PaymentTokenUpdated(address indexed oldToken, address indexed newToken);

    // =========================================================================
    // Errors
    // =========================================================================

    error OnlyACPContract();
    error ZeroAddress();
    error NoEvaluationFound(uint256 jobId);

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _evaluatorV2  SigilXEvaluatorV2 contract address
    /// @param _feeRouter    Treasury / fee router address
    /// @param _acpContract  The ERC-8183 contract authorized to call hooks
    /// @param _paymentToken ERC-20 token used for fee transfers
    constructor(
        address _evaluatorV2,
        address _feeRouter,
        address _acpContract,
        address _paymentToken
    ) Ownable(msg.sender) {
        if (_evaluatorV2 == address(0)) revert ZeroAddress();
        if (_feeRouter == address(0)) revert ZeroAddress();
        if (_acpContract == address(0)) revert ZeroAddress();
        if (_paymentToken == address(0)) revert ZeroAddress();

        evaluatorV2 = _evaluatorV2;
        feeRouter = _feeRouter;
        acpContract = _acpContract;
        paymentToken = IERC20(_paymentToken);
    }

    // =========================================================================
    // IACPHook Implementation
    // =========================================================================

    /// @notice Called before a core function executes. No-op for all selectors.
    function beforeAction(uint256, bytes4, bytes calldata) external override {
        // Intentional no-op — this hook only acts after completion.
    }

    /// @notice Called after a core function completes. On COMPLETE_SELECTOR,
    ///         reads evaluation info from SigilXEvaluatorV2 and routes the
    ///         evaluator fee share to the fee router.
    /// @param jobId    The job being acted on
    /// @param selector The function selector of the core function
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata) external override nonReentrant {
        if (msg.sender != acpContract) revert OnlyACPContract();
        if (selector != COMPLETE_SELECTOR) return;

        ISigilXEvaluatorV2FeeInfo evaluator = ISigilXEvaluatorV2FeeInfo(evaluatorV2);

        // Look up the evaluation for this job
        uint256 evalId = evaluator.getEvalForJob(acpContract, jobId);
        if (evalId == 0) return; // No evaluation registered — skip silently

        // Read committee and fee config
        address[] memory members = evaluator.getCommittee(evalId);
        uint256 feeBps = evaluator.evaluatorFeeBps();

        if (members.length == 0 || feeBps == 0) return;

        // Calculate fee from this contract's token balance (the ACP contract
        // should have transferred the fee portion to this hook before calling).
        // We route whatever balance this contract holds up to the computed fee.
        uint256 balance = paymentToken.balanceOf(address(this));
        if (balance == 0) return;

        // Route the fee to the fee router for downstream distribution
        paymentToken.safeTransfer(feeRouter, balance);

        emit EvaluatorFeeRouted(jobId, evalId, balance, feeRouter, members.length);
    }

    // =========================================================================
    // Governance
    // =========================================================================

    function setEvaluatorV2(address _evaluatorV2) external onlyOwner {
        if (_evaluatorV2 == address(0)) revert ZeroAddress();
        emit EvaluatorV2Updated(evaluatorV2, _evaluatorV2);
        evaluatorV2 = _evaluatorV2;
    }

    function setFeeRouter(address _feeRouter) external onlyOwner {
        if (_feeRouter == address(0)) revert ZeroAddress();
        emit FeeRouterUpdated(feeRouter, _feeRouter);
        feeRouter = _feeRouter;
    }

    function setACPContract(address _acpContract) external onlyOwner {
        if (_acpContract == address(0)) revert ZeroAddress();
        emit ACPContractUpdated(acpContract, _acpContract);
        acpContract = _acpContract;
    }

    function setPaymentToken(address _token) external onlyOwner {
        if (_token == address(0)) revert ZeroAddress();
        emit PaymentTokenUpdated(address(paymentToken), _token);
        paymentToken = IERC20(_token);
    }

    /// @notice Recover tokens accidentally sent to this contract
    /// @param token ERC-20 token to recover
    /// @param to    Recipient address
    /// @param amount Amount to recover
    function recoverTokens(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
    }
}
