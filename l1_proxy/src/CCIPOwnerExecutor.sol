// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Client} from "../vendor/ccip-2.0.0/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "../vendor/ccip-2.0.0/interfaces/IAny2EVMMessageReceiver.sol";
import {CCIPGovernancePayload} from "./CCIPGovernancePayload.sol";

/// @notice Destination leg of the DAO's CCIP owner route. Owns a fixed set of target contracts and executes
///         GOVERNOR operations from the pinned Ethereum `CCIPGovernanceSender` only after a delay, during which a
///         cancel-only canceller can veto them.
/// @dev Legacy-only CCIP receiver: it advertises `IAny2EVMMessageReceiver` and never `IAny2EVMMessageReceiverV2`, so
///      CCIP 2.0 OffRamps enforce wait-for-finality. Operations are keyed by `keccak256(payload)`; there is no
///      queue-time op id high-water mark, so a cancelled forgery blocks only its own exact bytes. Ordering is enforced
///      at execution only. There is no owner, setter, upgrade path or local recovery: changes to the targets'
///      ownership, including migration to a new executor, go through a delayed DAO operation.
contract CCIPOwnerExecutor is IAny2EVMMessageReceiver, ReentrancyGuard {
    enum OpStatus {
        None,
        Queued,
        Cancelled,
        Executed
    }

    struct Op {
        OpStatus status;
        uint64 opId;
        uint64 eta;
    }

    uint64 public constant MAX_TTL_CAP = 30 days;
    uint256 public constant MAX_TARGETS = 6;
    /// @dev `renounceOwnership()`; would permanently remove the DAO's ability to manage or migrate a target.
    bytes4 public constant DENIED_SELECTOR = 0x715018a6;

    error InvalidRouter();
    error InvalidSourceChain(uint64 sourceChainSelector);
    error InvalidSender();
    error TokensNotAccepted();
    error InvalidVersion(uint8 version);
    error InvalidChainId(uint256 chainId);
    error InvalidExecutor(address executor);
    error Expired(uint64 deadline);
    error DeadlineTooFar(uint64 deadline);
    error InvalidPhase(uint8 phase);
    error InvalidCallCount(uint256 count);
    error TargetNotAllowed(uint256 index, address target);
    error InvalidCallData(uint256 index);
    error SelectorDenied(uint256 index, bytes4 selector);
    error StaleOpId(uint64 opId, uint64 lastExecutedOpId);
    error AlreadyKnown(bytes32 payloadHash);
    error NotQueued(bytes32 payloadHash);
    error NotReady(uint64 eta);
    error WindowElapsed(uint64 lastExecutable);
    error Unauthorized();
    error CallFailed(uint256 index, bytes data);
    error OwnershipImmutable();
    error InvalidConstructorArgument(uint256 index);

    event Pinged(bytes32 indexed payloadHash, bytes32 indexed ccipMessageId, uint64 indexed opId);
    event Queued(
        bytes32 indexed payloadHash,
        bytes32 indexed ccipMessageId,
        uint64 indexed opId,
        uint64 eta,
        uint64 deadline,
        bytes payload
    );
    event Cancelled(bytes32 indexed payloadHash, uint64 indexed opId);
    event Executed(bytes32 indexed payloadHash, uint64 indexed opId);

    address public immutable router;
    uint64 public immutable sourceChainSelector;
    address public immutable sender;
    uint64 public immutable delay;
    uint64 public immutable executionWindow;
    uint64 public immutable maxTtl;
    address public immutable canceller;

    uint256 internal immutable targetCount;
    address internal immutable target0;
    address internal immutable target1;
    address internal immutable target2;
    address internal immutable target3;
    address internal immutable target4;
    address internal immutable target5;

    mapping(bytes32 payloadHash => Op) public ops;
    uint64 public lastExecutedOpId;

    constructor(
        address _router,
        uint64 _sourceChainSelector,
        address _sender,
        uint64 _delay,
        uint64 _executionWindow,
        uint64 _maxTtl,
        address _canceller,
        address[] memory _targets
    ) {
        if (_router.code.length == 0) revert InvalidConstructorArgument(0);
        if (_sourceChainSelector == 0) revert InvalidConstructorArgument(1);
        if (_sender == address(0)) revert InvalidConstructorArgument(2);
        if (_delay == 0) revert InvalidConstructorArgument(3);
        if (_executionWindow == 0) revert InvalidConstructorArgument(4);
        if (_maxTtl == 0 || _maxTtl > MAX_TTL_CAP) revert InvalidConstructorArgument(5);
        if (_canceller.code.length == 0 || _canceller == _router || _canceller == _sender) {
            revert InvalidConstructorArgument(6);
        }
        uint256 n = _targets.length;
        if (n == 0 || n > MAX_TARGETS) revert InvalidConstructorArgument(7);
        for (uint256 i = 0; i < n; i++) {
            address t = _targets[i];
            if (t.code.length == 0 || t == _router || t == _canceller) revert InvalidConstructorArgument(7);
            for (uint256 j = 0; j < i; j++) {
                if (_targets[j] == t) revert InvalidConstructorArgument(7);
            }
        }

        router = _router;
        sourceChainSelector = _sourceChainSelector;
        sender = _sender;
        delay = _delay;
        executionWindow = _executionWindow;
        maxTtl = _maxTtl;
        canceller = _canceller;
        targetCount = n;
        target0 = _targets[0];
        target1 = n > 1 ? _targets[1] : address(0);
        target2 = n > 2 ? _targets[2] : address(0);
        target3 = n > 3 ? _targets[3] : address(0);
        target4 = n > 4 ? _targets[4] : address(0);
        target5 = n > 5 ? _targets[5] : address(0);
    }

    // ---------------------------------------------------------------- CCIP

    /// @notice ERC-165. True only for ERC-165 itself and the legacy `IAny2EVMMessageReceiver`.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == type(IAny2EVMMessageReceiver).interfaceId;
    }

    /// @inheritdoc IAny2EVMMessageReceiver
    /// @dev Validates and records only; makes no external call. Any revert becomes a CCIP FAILURE that can only be
    ///      re-executed into the same checks, bounded by the payload's deadline.
    function ccipReceive(Client.Any2EVMMessage calldata message) external override {
        if (msg.sender != router) revert InvalidRouter();
        if (message.sourceChainSelector != sourceChainSelector) revert InvalidSourceChain(message.sourceChainSelector);
        if (message.sender.length != 32 || bytes32(message.sender) != bytes32(uint256(uint160(sender)))) {
            revert InvalidSender();
        }
        if (message.destTokenAmounts.length != 0) revert TokensNotAccepted();

        bytes32 payloadHash = keccak256(message.data);
        (
            uint8 version,
            uint256 chainId,
            address executor,
            uint64 opId,
            uint8 phase,
            uint64 deadline,
            CCIPGovernancePayload.Call[] memory calls
        ) = CCIPGovernancePayload.decode(message.data);

        if (version != CCIPGovernancePayload.VERSION) revert InvalidVersion(version);
        if (chainId != block.chainid) revert InvalidChainId(chainId);
        if (executor != address(this)) revert InvalidExecutor(executor);
        if (block.timestamp > deadline) revert Expired(deadline);
        if (deadline > block.timestamp + maxTtl) revert DeadlineTooFar(deadline);

        if (phase == CCIPGovernancePayload.PHASE_BOOTSTRAP) {
            if (calls.length != 0) revert InvalidCallCount(calls.length);
            emit Pinged(payloadHash, message.messageId, opId);
            return;
        }
        if (phase != CCIPGovernancePayload.PHASE_GOVERNOR) revert InvalidPhase(phase);

        if (calls.length == 0 || calls.length > CCIPGovernancePayload.MAX_CALLS) {
            revert InvalidCallCount(calls.length);
        }
        for (uint256 i = 0; i < calls.length; i++) {
            CCIPGovernancePayload.Call memory c = calls[i];
            if (!isTarget(c.target)) revert TargetNotAllowed(i, c.target);
            if (c.data.length < 4) revert InvalidCallData(i);
            if (bytes4(c.data) == DENIED_SELECTOR) revert SelectorDenied(i, DENIED_SELECTOR);
        }

        uint64 lastExecuted = lastExecutedOpId;
        if (opId <= lastExecuted) revert StaleOpId(opId, lastExecuted);
        Op storage op = ops[payloadHash];
        if (op.status != OpStatus.None) revert AlreadyKnown(payloadHash);

        uint64 eta = uint64(block.timestamp) + delay;
        op.status = OpStatus.Queued;
        op.opId = opId;
        op.eta = eta;
        emit Queued(payloadHash, message.messageId, opId, eta, deadline, message.data);
    }

    // ---------------------------------------------------------------- execution

    /// @notice Executes a queued GOVERNOR operation after its delay and within the execution window. All calls
    ///         succeed or the whole operation reverts and stays queued.
    /// @param payload The exact payload bytes from the `Queued` event.
    function execute(bytes calldata payload) external nonReentrant {
        bytes32 payloadHash = keccak256(payload);
        Op storage op = ops[payloadHash];
        if (op.status != OpStatus.Queued) revert NotQueued(payloadHash);
        uint64 eta = op.eta;
        if (block.timestamp < eta) revert NotReady(eta);
        if (block.timestamp > eta + executionWindow) revert WindowElapsed(eta + executionWindow);
        uint64 opId = op.opId;
        uint64 lastExecuted = lastExecutedOpId;
        if (opId <= lastExecuted) revert StaleOpId(opId, lastExecuted);

        op.status = OpStatus.Executed;
        lastExecutedOpId = opId;

        (,,,,,, CCIPGovernancePayload.Call[] memory calls) = CCIPGovernancePayload.decode(payload);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = calls[i].target.call(calls[i].data);
            if (!success) revert CallFailed(i, result);
        }
        emit Executed(payloadHash, opId);
    }

    /// @notice Cancels queued operations. Only the canceller; any queued operation until it has executed.
    function cancel(bytes32[] calldata payloadHashes) external {
        if (msg.sender != canceller) revert Unauthorized();
        for (uint256 i = 0; i < payloadHashes.length; i++) {
            Op storage op = ops[payloadHashes[i]];
            if (op.status != OpStatus.Queued) revert NotQueued(payloadHashes[i]);
            op.status = OpStatus.Cancelled;
            emit Cancelled(payloadHashes[i], op.opId);
        }
    }

    // ---------------------------------------------------------------- views

    function isTarget(address target) public view returns (bool) {
        return target != address(0)
            && (target == target0
                || target == target1
                || target == target2
                || target == target3
                || target == target4
                || target == target5);
    }

    function targets() external view returns (address[] memory list) {
        address[6] memory all = [target0, target1, target2, target3, target4, target5];
        list = new address[](targetCount);
        for (uint256 i = 0; i < list.length; i++) {
            list[i] = all[i];
        }
    }

    // ---------------------------------------------------------------- Ownable-compatible surface

    /// @notice There is no owner.
    function owner() external pure returns (address) {
        return address(0);
    }

    function ownershipHandoverExpiresAt(address) external pure returns (uint256) {
        return 0;
    }

    function transferOwnership(address) external payable {
        revert OwnershipImmutable();
    }

    function renounceOwnership() external payable {
        revert OwnershipImmutable();
    }

    function requestOwnershipHandover() external payable {
        revert OwnershipImmutable();
    }

    function completeOwnershipHandover(address) external payable {
        revert OwnershipImmutable();
    }

    function cancelOwnershipHandover() external payable {
        revert OwnershipImmutable();
    }
}
