// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Client} from "../vendor/ccip-2.0.0/libraries/Client.sol";
import {IRouterClient} from "../vendor/ccip-2.0.0/interfaces/IRouterClient.sol";
import {CCIPGovernancePayload} from "./CCIPGovernancePayload.sol";

/// @notice Ethereum leg of the DAO's CCIP owner route: StarknetOwnerProxy -> this -> CCIP -> CCIPOwnerExecutor.
/// @dev This is not a direct Starknet CCIP route. `request` records an operation from the current authority and
///      depends only on its calldata and this contract's own storage, so it cannot revert because of the router,
///      fees, RMN or time; a revert there would jam the StarknetOwnerProxy's strict nonce. `dispatch` is a separate,
///      permissionless, fee-paying step that may be retried.
///      The authority starts as a single-purpose bootstrap key that can only request pings (no calls), and moves
///      once, irreversibly, to the immutable `finalAuthority` (the StarknetOwnerProxy). There is no owner, setter,
///      receive or withdraw function.
contract CCIPGovernanceSender is ReentrancyGuard {
    struct Destination {
        uint64 chainSelector;
        uint64 chainId;
        address executor;
    }

    enum RequestStatus {
        None,
        Pending,
        Dispatched
    }

    struct Request {
        RequestStatus status;
        uint64 destChainSelector;
        uint32 gasLimit;
    }

    uint32 public constant MIN_GAS_LIMIT = 100_000;
    uint32 public constant MAX_GAS_LIMIT_CAP = 3_000_000;
    /// @dev `GenericExtraArgsV3` tag; with finality config 0 (wait for finality) and no CCVs, executor or token args.
    bytes4 public constant GENERIC_EXTRA_ARGS_V3_TAG = 0xa69dd4aa;

    error Unauthorized();
    error AlreadyHandedOff();
    error UnknownDestination(uint64 destChainSelector);
    error InvalidGasLimit(uint32 gasLimit);
    error InvalidCallCount(uint256 count);
    error NotPending(bytes32 requestId);
    error InsufficientFee(uint256 required, uint256 provided);
    error RefundFailed();
    error InvalidConstructorArgument(uint256 index);

    event Requested(
        bytes32 indexed requestId,
        uint64 indexed destChainSelector,
        uint64 indexed opId,
        uint8 phase,
        uint32 gasLimit,
        uint64 deadline,
        bytes payload
    );
    event Dispatched(
        bytes32 indexed requestId,
        uint64 indexed destChainSelector,
        bytes32 indexed ccipMessageId,
        uint256 fee,
        address payer
    );
    event HandedOff(address indexed previousAuthority, address indexed newAuthority);

    IRouterClient public immutable router;
    address public immutable finalAuthority;
    uint32 public immutable maxGasLimit;

    uint64 internal immutable dest0ChainSelector;
    uint64 internal immutable dest0ChainId;
    address internal immutable dest0Executor;
    uint64 internal immutable dest1ChainSelector;
    uint64 internal immutable dest1ChainId;
    address internal immutable dest1Executor;

    address public authority;
    mapping(uint64 destChainSelector => uint64) public nextOpId;
    mapping(bytes32 requestId => Request) public requests;

    constructor(
        IRouterClient _router,
        address _finalAuthority,
        address bootstrapAuthority,
        Destination memory dest0,
        Destination memory dest1,
        uint32 _maxGasLimit
    ) {
        if (address(_router).code.length == 0) revert InvalidConstructorArgument(0);
        if (_finalAuthority.code.length == 0) revert InvalidConstructorArgument(1);
        if (bootstrapAuthority == address(0) || bootstrapAuthority == _finalAuthority) {
            revert InvalidConstructorArgument(2);
        }
        if (
            dest0.chainSelector == 0 || dest0.chainId == 0 || dest0.chainId == block.chainid
                || dest0.executor == address(0)
        ) {
            revert InvalidConstructorArgument(3);
        }
        if (
            dest1.chainSelector == 0 || dest1.chainId == 0 || dest1.chainId == block.chainid
                || dest1.executor == address(0) || dest1.chainSelector == dest0.chainSelector
                || dest1.chainId == dest0.chainId
        ) {
            revert InvalidConstructorArgument(4);
        }
        if (_maxGasLimit < MIN_GAS_LIMIT || _maxGasLimit > MAX_GAS_LIMIT_CAP) revert InvalidConstructorArgument(5);

        router = _router;
        finalAuthority = _finalAuthority;
        authority = bootstrapAuthority;
        maxGasLimit = _maxGasLimit;
        dest0ChainSelector = dest0.chainSelector;
        dest0ChainId = dest0.chainId;
        dest0Executor = dest0.executor;
        dest1ChainSelector = dest1.chainSelector;
        dest1ChainId = dest1.chainId;
        dest1Executor = dest1.executor;
    }

    /// @notice Records an operation for one destination. Static checks only; never touches the router.
    /// @dev Before `handoff` the phase is BOOTSTRAP and `calls` must be empty (a ping). After it the phase is
    ///      GOVERNOR and `calls` must hold 1..8 calls. `deadline` is copied into the payload unchecked; the executor
    ///      enforces it.
    function request(
        uint64 destChainSelector,
        uint32 gasLimit,
        uint64 deadline,
        CCIPGovernancePayload.Call[] calldata calls
    ) external nonReentrant returns (bytes32 requestId) {
        address currentAuthority = authority;
        if (msg.sender != currentAuthority) revert Unauthorized();
        (uint256 chainId, address executor) = _destination(destChainSelector);
        if (gasLimit < MIN_GAS_LIMIT || gasLimit > maxGasLimit) revert InvalidGasLimit(gasLimit);

        uint8 phase;
        if (currentAuthority == finalAuthority) {
            phase = CCIPGovernancePayload.PHASE_GOVERNOR;
            if (calls.length == 0 || calls.length > CCIPGovernancePayload.MAX_CALLS) {
                revert InvalidCallCount(calls.length);
            }
        } else {
            phase = CCIPGovernancePayload.PHASE_BOOTSTRAP;
            if (calls.length != 0) revert InvalidCallCount(calls.length);
        }

        uint64 opId = ++nextOpId[destChainSelector];
        bytes memory payload =
            abi.encode(CCIPGovernancePayload.VERSION, chainId, executor, opId, phase, deadline, calls);
        requestId = keccak256(payload);
        requests[requestId] =
            Request({status: RequestStatus.Pending, destChainSelector: destChainSelector, gasLimit: gasLimit});

        emit Requested(requestId, destChainSelector, opId, phase, gasLimit, deadline, payload);
    }

    /// @notice Sends a pending request over CCIP, paying the exact native fee and refunding the rest to the caller.
    /// @param payload The exact `payload` bytes from the request's `Requested` event.
    function dispatch(bytes calldata payload) external payable nonReentrant returns (bytes32 ccipMessageId) {
        bytes32 requestId = keccak256(payload);
        Request storage r = requests[requestId];
        if (r.status != RequestStatus.Pending) revert NotPending(requestId);
        uint64 destChainSelector = r.destChainSelector;
        (, address executor) = _destination(destChainSelector);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(executor),
            data: payload,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: extraArgs(r.gasLimit)
        });

        uint256 fee = router.getFee(destChainSelector, message);
        if (msg.value < fee) revert InsufficientFee(fee, msg.value);

        r.status = RequestStatus.Dispatched;
        ccipMessageId = router.ccipSend{value: fee}(destChainSelector, message);
        emit Dispatched(requestId, destChainSelector, ccipMessageId, fee, msg.sender);

        uint256 refund = msg.value - fee;
        if (refund != 0) {
            (bool success,) = msg.sender.call{value: refund}("");
            if (!success) revert RefundFailed();
        }
    }

    /// @notice Irreversibly moves the authority from the bootstrap key to `finalAuthority`.
    function handoff() external nonReentrant {
        address currentAuthority = authority;
        if (currentAuthority == finalAuthority) revert AlreadyHandedOff();
        if (msg.sender != currentAuthority) revert Unauthorized();
        authority = finalAuthority;
        emit HandedOff(currentAuthority, finalAuthority);
    }

    /// @notice `GenericExtraArgsV3` with the given gas limit, wait-for-finality and no CCVs, executor or token args.
    function extraArgs(uint32 gasLimit) public pure returns (bytes memory) {
        return abi.encodePacked(GENERIC_EXTRA_ARGS_V3_TAG, gasLimit, bytes4(0), bytes7(0));
    }

    function destinations() external view returns (Destination memory dest0, Destination memory dest1) {
        dest0 = Destination(dest0ChainSelector, dest0ChainId, dest0Executor);
        dest1 = Destination(dest1ChainSelector, dest1ChainId, dest1Executor);
    }

    function _destination(uint64 destChainSelector) internal view returns (uint256 chainId, address executor) {
        if (destChainSelector == dest0ChainSelector) return (dest0ChainId, dest0Executor);
        if (destChainSelector == dest1ChainSelector) return (dest1ChainId, dest1Executor);
        revert UnknownDestination(destChainSelector);
    }
}
