// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Client} from "../vendor/ccip-2.0.0/libraries/Client.sol";
import {IRouterClient} from "../vendor/ccip-2.0.0/interfaces/IRouterClient.sol";
import {IRouter} from "../vendor/ccip-2.0.0/interfaces/IRouter.sol";
import {IAny2EVMMessageReceiverV2} from "../vendor/ccip-2.0.0/interfaces/IAny2EVMMessageReceiverV2.sol";
import {StarknetOwnerProxy} from "../src/StarknetOwnerProxy.sol";
import {CCIPGovernancePayload} from "../src/CCIPGovernancePayload.sol";
import {CCIPGovernanceSender} from "../src/CCIPGovernanceSender.sol";
import {CCIPOwnerExecutor} from "../src/CCIPOwnerExecutor.sol";
import {MockCanceller} from "./CCIPMocks.sol";

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external payable;
    function ownershipHandoverExpiresAt(address pendingOwner) external view returns (uint256);
}

interface IStarknetCore {
    function l2ToL1Messages(bytes32 msgHash) external view returns (uint256);
}

/// @notice T1 read-only fork simulation of the A'-CCIP owner route. Nothing here touches a live network: every
///         transaction runs on local forks of public RPC state.
///
///         Evidence classes:
///         - Ethereum leg is REAL CODE on a fork: unchanged StarknetOwnerProxy 0x1E0E..., real StarknetCore message
///           consumption (the L2->L1 message is injected into Core storage with vm.store, i.e. SIMULATED Starknet
///           settlement), real CCIP Router 1.2.0 + OnRamp 2.0.0 fee quote and ccipSend.
///         - Destination legs are IMPERSONATED: the registered OffRamp (2.0.0, and a legacy one) is pranked to call the
///           real destination Router.routeMessage. No DON, committee verifier or RMN signature is involved. This is
///           NOT real end-to-end CCIP delivery.
/// @dev Foundry instantiates one EVM family per run, so Monad runs separately (`--network monad`) and consumes the
///      exact Monad payloads emitted by the Ethereum run. `script/ccip-fork-t1.sh` chains the two runs.
abstract contract CCIPForkBase is Test {
    // Ethereum
    address constant L1_PROXY = 0x1E0EF4162e42C9bF820c307218c4E41cCcA6E9CC;
    address constant STARKNET_CORE = 0xc662c410C0ECf747543f5bA90660f6ABeBD9C8c4;
    address constant ETH_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    address constant ETH_ONRAMP = 0xc3423F3FB30857D9C14717b119884b1B63d250b7;
    uint64 constant ETH_SELECTOR = 5009297550715157269;
    // BNB Chain
    address constant BNB_ROUTER = 0x34B03Cb9086d7D758AC55af71584F81A598759FE;
    address constant BNB_OFFRAMP = 0x4914044f8d787bd5DC7528f00775D850dC54477e; // OffRamp 2.0.0
    address constant BNB_LEGACY_OFFRAMP = 0xF616733641D420207b8F30db9C4cE39684768991; // EVM2EVMOffRamp 1.5.0
    uint64 constant BNB_SELECTOR = 11344663589394136015;
    // Monad
    address constant MONAD_ROUTER = 0x33566fE5976AAa420F3d5C64996641Fc3858CaDB;
    address constant MONAD_OFFRAMP = 0xa315658c5E11b0Ca99dE255F07F10E6C584E4e01; // OffRamp 2.0.0
    address constant MONAD_LEGACY_OFFRAMP = 0xdCc981e12Fd132d9172eb03E8373BE68032588e8; // OffRamp 1.6.0
    uint64 constant MONAD_SELECTOR = 8481857512324358265;
    // Targets
    address constant COMPANY_KEY = 0x00000C771F6176268D5A9846E0956C3eF58597A1;
    address constant POSITIONS_192 = 0xA2971E0C37cFdb13aE8440A0C94Ef1A1af39e326;
    address constant ORDERS_192 = 0x9bB520B6192F71ec3D015C8a74F914f9c94bF794;
    address constant POSITIONS_V311 = 0x02D9876A21AF7545f8632C3af76eC90b5ad4b66D;
    address constant ORDERS_V311 = 0x3325428adB409c239E88ca472F50b0efe00E98B4;

    uint64 constant DELAY = 72 hours;
    uint64 constant WINDOW = 14 days;
    uint64 constant TTL = 30 days;
    uint16 constant GAS_FOR_CALL_EXACT_CHECK = 5_000;
    uint32 constant GAS_LIMIT = 500_000;
    bytes4 constant OWNER_SELECTOR = 0x8da5cb5b;

    // Test-only identities. Executors on both destinations come from the same fresh deployer at nonce 0.
    address senderDeployer = makeAddr("eku1199-test-sender-deployer");
    address executorDeployer = makeAddr("eku1199-test-executor-deployer");
    address bootstrap = makeAddr("eku1199-test-bootstrap");

    function _fork(string memory url, string memory blockVar) internal returns (uint256) {
        uint256 b = vm.envOr(blockVar, uint256(0));
        return b == 0 ? vm.createFork(url) : vm.createFork(url, b);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _deployExecutor(address router, address senderAddr, address[] memory ts)
        internal
        returns (CCIPOwnerExecutor e, address canceller)
    {
        canceller = address(new MockCanceller()); // test-only stand-in for the canceller Safe
        assertEq(vm.getNonce(executorDeployer), 0, "fresh executor deployer");
        vm.prank(executorDeployer);
        e = new CCIPOwnerExecutor(router, ETH_SELECTOR, senderAddr, DELAY, WINDOW, TTL, canceller, ts);
        assertEq(address(e), vm.computeCreateAddress(executorDeployer, 0));
        _verifyExecutor(e);
    }

    function _verifyExecutor(CCIPOwnerExecutor e) internal view {
        assertTrue(address(e).code.length > 0);
        assertTrue(e.supportsInterface(0x85572ffb), "legacy receiver");
        assertFalse(e.supportsInterface(type(IAny2EVMMessageReceiverV2).interfaceId), "not V2");
        assertGe(e.delay(), 72 hours, "C3 delay");
        assertLe(e.maxTtl(), 30 days);
        assertTrue(e.canceller().code.length > 0, "canceller is a contract");
        assertEq(e.owner(), address(0));
    }

    function _route(
        address router,
        address offRamp,
        address receiver,
        address senderAddr,
        bytes32 messageId,
        bytes memory data
    ) internal returns (bool success, bytes memory ret, Vm.Log[] memory logs) {
        assertTrue(IRouter(router).isOffRamp(ETH_SELECTOR, offRamp), "registered OffRamp");
        Client.Any2EVMMessage memory m = Client.Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: ETH_SELECTOR,
            sender: abi.encode(senderAddr),
            data: data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        vm.recordLogs();
        vm.prank(offRamp);
        uint256 gasUsed;
        (success, ret, gasUsed) = IRouter(router).routeMessage(m, GAS_FOR_CALL_EXACT_CHECK, GAS_LIMIT, receiver);
        logs = vm.getRecordedLogs();
        emit log_named_uint("dest: ccipReceive gas used", gasUsed);
    }

    function _hasLog(Vm.Log[] memory logs, address emitter, bytes32 topic0, bytes32 topic1)
        internal
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic0 && logs[i].topics[1] == topic1) {
                return true;
            }
        }
        return false;
    }

    function _ownerBatch(address[] memory ts) internal pure returns (CCIPGovernancePayload.Call[] memory c) {
        c = new CCIPGovernancePayload.Call[](ts.length);
        for (uint256 i = 0; i < ts.length; i++) {
            c[i] = CCIPGovernancePayload.Call(ts[i], abi.encodeWithSelector(OWNER_SELECTOR));
        }
    }

    function _deliverPing(
        address router,
        address offRamp,
        CCIPOwnerExecutor e,
        address senderAddr,
        bytes32 mid,
        bytes memory p
    ) internal {
        (bool ok,, Vm.Log[] memory logs) = _route(router, offRamp, address(e), senderAddr, mid, p);
        assertTrue(ok);
        assertTrue(_hasLog(logs, address(e), CCIPOwnerExecutor.Pinged.selector, keccak256(p)), "Pinged");
        assertEq(e.lastExecutedOpId(), 0);
    }

    function _deliverQueueExecute(
        address router,
        address offRamp,
        CCIPOwnerExecutor e,
        address senderAddr,
        bytes32 messageId,
        bytes memory payload
    ) internal {
        bytes32 payloadHash = keccak256(payload);
        (bool ok, bytes memory ret, Vm.Log[] memory logs) =
            _route(router, offRamp, address(e), senderAddr, messageId, payload);
        assertTrue(ok, string(ret));
        assertTrue(_hasLog(logs, address(e), CCIPOwnerExecutor.Queued.selector, payloadHash), "Queued");
        (,, uint64 eta) = e.ops(payloadHash);
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.NotReady.selector, eta));
        e.execute(payload);
        vm.warp(eta);
        address[] memory ts = e.targets();
        for (uint256 i = 0; i < ts.length; i++) {
            vm.expectCall(ts[i], abi.encodeWithSelector(OWNER_SELECTOR));
        }
        vm.recordLogs();
        uint256 g = gasleft();
        e.execute(payload);
        emit log_named_uint("dest: execute(owner() batch) gas", g - gasleft());
        assertTrue(_hasLog(vm.getRecordedLogs(), address(e), CCIPOwnerExecutor.Executed.selector, payloadHash));
        for (uint256 i = 0; i < ts.length; i++) {
            assertEq(IOwnable(ts[i]).owner(), COMPANY_KEY, "owner() batch is harmless");
        }
    }

    /// T6, local fork only: the company key transfers each target DIRECTLY. No handover calls are used.
    function _directTransfers(CCIPOwnerExecutor e) internal {
        address[] memory ts = e.targets();
        for (uint256 i = 0; i < ts.length; i++) {
            assertEq(IOwnable(ts[i]).owner(), COMPANY_KEY);
            vm.prank(COMPANY_KEY);
            IOwnable(ts[i]).transferOwnership(address(e));
            assertEq(IOwnable(ts[i]).owner(), address(e));
            assertEq(IOwnable(ts[i]).ownershipHandoverExpiresAt(address(e)), 0, "no handover used");
        }
    }

    /// After T6: a delayed DAO op delivered through a still-registered LEGACY OffRamp (L-1: the executor cannot tell
    /// OffRamps apart) migrates one target to a successor; renounceOwnership is refused at queue time.
    function _postTransferMigration(
        uint256 chainId,
        address router,
        address offRamp,
        address legacyOffRamp,
        CCIPOwnerExecutor e,
        address senderAddr,
        address target
    ) internal {
        address successor = address(new MockCanceller());
        CCIPGovernancePayload.Call[] memory c = new CCIPGovernancePayload.Call[](1);
        c[0] = CCIPGovernancePayload.Call(target, abi.encodeCall(IOwnable.transferOwnership, (successor)));
        bytes memory p =
            CCIPGovernancePayload.encode(chainId, address(e), e.lastExecutedOpId() + 1, 2, uint64(_now() + 1 days), c);
        (bool ok,,) = _route(router, legacyOffRamp, address(e), senderAddr, keccak256("legacy"), p);
        assertTrue(ok, "legacy OffRamp accepted (L-1)");
        vm.warp(_now() + DELAY);
        e.execute(p);
        assertEq(IOwnable(target).owner(), successor);

        c[0] = CCIPGovernancePayload.Call(e.targets()[0], hex"715018a6");
        p = CCIPGovernancePayload.encode(chainId, address(e), e.lastExecutedOpId() + 1, 2, uint64(_now() + 1 days), c);
        bytes memory ret;
        (ok, ret,) = _route(router, offRamp, address(e), senderAddr, keccak256("renounce"), p);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(CCIPOwnerExecutor.SelectorDenied.selector, 0, bytes4(0x715018a6)));
    }
}

/// @notice Ethereum + BNB Chain (EVM family `ethereum`). Emits the exact Monad payloads for `CCIPMonadForkTest`.
/// @dev Needs ETH_RPC_URL and BNB_RPC_URL; skipped otherwise. Optional ETH_FORK_BLOCK / BNB_FORK_BLOCK pins.
contract CCIPOwnerRouteForkTest is CCIPForkBase {
    /// @dev Receives dispatch refunds.
    receive() external payable {}

    uint256 ethFork;
    uint256 bnbFork;

    CCIPGovernanceSender sender;
    CCIPOwnerExecutor bnbExec;
    address bnbCanceller;
    address monadExecPredicted;

    function setUp() public {
        string memory eth = vm.envOr("ETH_RPC_URL", string(""));
        string memory bnb = vm.envOr("BNB_RPC_URL", string(""));
        if (bytes(eth).length == 0 || bytes(bnb).length == 0) {
            vm.skip(true);
            return;
        }
        ethFork = _fork(eth, "ETH_FORK_BLOCK");
        bnbFork = _fork(bnb, "BNB_FORK_BLOCK");

        // Deployment order (M-1): predict the sender, deploy and verify the executors, then deploy the sender.
        vm.selectFork(ethFork);
        address predictedSender = vm.computeCreateAddress(senderDeployer, vm.getNonce(senderDeployer));

        vm.selectFork(bnbFork);
        address[] memory bnbTargets = new address[](2);
        bnbTargets[0] = POSITIONS_192;
        bnbTargets[1] = ORDERS_192;
        (bnbExec, bnbCanceller) = _deployExecutor(BNB_ROUTER, predictedSender, bnbTargets);
        // Monad runs in its own process; its executor is the same deployer's nonce-0 address (checked there).
        monadExecPredicted = vm.computeCreateAddress(executorDeployer, 0);

        vm.selectFork(ethFork);
        vm.prank(senderDeployer);
        sender = new CCIPGovernanceSender(
            IRouterClient(ETH_ROUTER),
            L1_PROXY,
            bootstrap,
            CCIPGovernanceSender.Destination(BNB_SELECTOR, 56, address(bnbExec)),
            CCIPGovernanceSender.Destination(MONAD_SELECTOR, 143, monadExecPredicted),
            1_000_000
        );
        assertEq(address(sender), predictedSender, "sender address prediction");
        vm.deal(address(this), 1 ether);
    }

    // ---------------------------------------------------------------- Ethereum leg

    function _requestedPayload(Vm.Log[] memory logs) internal view returns (bytes32 id, bytes memory payload) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(sender) && logs[i].topics[0] == CCIPGovernanceSender.Requested.selector) {
                id = logs[i].topics[1];
                (,,, payload) = abi.decode(logs[i].data, (uint8, uint32, uint64, bytes));
                return (id, payload);
            }
        }
        revert("no Requested");
    }

    /// Dispatches through the real Router 1.2.0 / OnRamp 2.0.0 and checks the OnRamp event carries our message id
    /// and sender, and that the encoded message contains the exact payload bytes.
    function _dispatch(bytes memory payload) internal returns (bytes32 messageId) {
        vm.selectFork(ethFork);
        uint256 balBefore = address(this).balance;
        vm.recordLogs();
        uint256 g = gasleft();
        messageId = sender.dispatch{value: 0.01 ether}(payload);
        emit log_named_uint("eth: dispatch gas", g - gasleft());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fee;
        bool onRampSeen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(sender) && logs[i].topics[0] == CCIPGovernanceSender.Dispatched.selector) {
                assertEq(logs[i].topics[3], messageId);
                (fee,) = abi.decode(logs[i].data, (uint256, address));
            }
            if (logs[i].emitter == ETH_ONRAMP && logs[i].topics.length == 4 && logs[i].topics[3] == messageId) {
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(sender), "OnRamp sender");
                assertTrue(_contains(logs[i].data, payload), "payload in CCIPMessageSent");
                onRampSeen = true;
            }
        }
        assertTrue(onRampSeen, "CCIPMessageSent from OnRamp 2.0.0");
        assertGt(fee, 0);
        assertEq(balBefore - address(this).balance, fee, "exact fee, rest refunded");
        assertEq(address(sender).balance, 0);
        emit log_named_uint("eth: CCIP fee (wei)", fee);
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        bytes32 h = keccak256(needle);
        for (uint256 i = 0; i + needle.length <= hay.length; i++) {
            bytes32 x;
            assembly ("memory-safe") {
                x := keccak256(add(add(hay, 32), i), mload(needle))
            }
            if (x == h) return true;
        }
        return false;
    }

    /// Injects the Governor's L2->L1 message into StarknetCore's l2ToL1Messages mapping (SIMULATED settlement).
    function _injectStarknetMessage(uint256[] memory payload) internal {
        uint256 l2Owner = StarknetOwnerProxy(payable(L1_PROXY)).l2Owner();
        bytes32 msgHash = keccak256(abi.encodePacked(l2Owner, uint256(uint160(L1_PROXY)), payload.length, payload));
        bytes32 base = keccak256(abi.encodePacked("STARKNET_1.0_MSGING_L2TOL1_MAPPPING"));
        bytes32 slot = keccak256(abi.encode(msgHash, base));
        vm.store(STARKNET_CORE, slot, bytes32(uint256(1)));
        assertEq(IStarknetCore(STARKNET_CORE).l2ToL1Messages(msgHash), 1, "message injected");
    }

    function _governorRequest(uint64 dest, uint64 deadline, CCIPGovernancePayload.Call[] memory calls)
        internal
        returns (bytes32 id, bytes memory payload)
    {
        vm.selectFork(ethFork);
        StarknetOwnerProxy l1 = StarknetOwnerProxy(payable(L1_PROXY));
        bytes memory data = abi.encodeCall(CCIPGovernanceSender.request, (dest, GAS_LIMIT, deadline, calls));
        uint64 n = l1.currentNonce();
        _injectStarknetMessage(l1.getPayload(address(sender), 0, n, data));

        // Out-of-gas on the L1 proxy is retryable: nothing is consumed, the nonce does not move.
        (bool ok,) =
            L1_PROXY.call{gas: 80_000}(abi.encodeCall(StarknetOwnerProxy.execute, (address(sender), 0, n, data)));
        assertFalse(ok, "low-gas execute must fail");
        assertEq(l1.currentNonce(), n, "nonce unchanged after OOG");

        vm.recordLogs();
        uint256 g = gasleft();
        l1.execute(address(sender), 0, n, data);
        emit log_named_uint("eth: StarknetOwnerProxy.execute -> request gas", g - gasleft());
        assertEq(l1.currentNonce(), n + 1);
        (id, payload) = _requestedPayload(vm.getRecordedLogs());
        emit log_named_uint("eth: proxy nonce used", n);
        emit log_named_bytes("eth: L1 proxy calldata (target=sender)", data);
    }

    // ---------------------------------------------------------------- the full gated sequence, locally

    function test_fork_fullRoute_ping_handoff_ownerBatch_directTransfer() public {
        // T3 (simulated): bootstrap pings to both chains.
        vm.selectFork(ethFork);
        uint64 deadline = uint64(_now() + 20 days);
        vm.recordLogs();
        vm.prank(bootstrap);
        sender.request(BNB_SELECTOR, GAS_LIMIT, deadline, new CCIPGovernancePayload.Call[](0));
        (, bytes memory bnbPing) = _requestedPayload(vm.getRecordedLogs());
        vm.recordLogs();
        vm.prank(bootstrap);
        sender.request(MONAD_SELECTOR, GAS_LIMIT, deadline, new CCIPGovernancePayload.Call[](0));
        (, bytes memory monPing) = _requestedPayload(vm.getRecordedLogs());
        bytes32 bnbPingMsg = _dispatch(bnbPing);
        bytes32 monPingMsg = _dispatch(monPing);

        vm.selectFork(bnbFork);
        _deliverPing(BNB_ROUTER, BNB_OFFRAMP, bnbExec, address(sender), bnbPingMsg, bnbPing);

        // T4 (simulated): one-way handoff; the bootstrap key can no longer request.
        vm.selectFork(ethFork);
        vm.prank(bootstrap);
        sender.handoff();
        assertEq(sender.authority(), L1_PROXY);
        vm.prank(bootstrap);
        vm.expectRevert(CCIPGovernanceSender.Unauthorized.selector);
        sender.request(BNB_SELECTOR, GAS_LIMIT, deadline, new CCIPGovernancePayload.Call[](0));

        // T5 (simulated): Governor -> Starknet messaging -> real StarknetOwnerProxy -> sender, one batch per chain on
        // consecutive proxy nonces; each batch is harmless owner() calls on every target of that chain.
        vm.selectFork(bnbFork);
        address[] memory bnbTargets = bnbExec.targets();
        address[] memory monTargets = new address[](4);
        monTargets[0] = POSITIONS_V311;
        monTargets[1] = ORDERS_V311;
        monTargets[2] = POSITIONS_192;
        monTargets[3] = ORDERS_192;
        (, bytes memory bnbOp) = _governorRequest(BNB_SELECTOR, deadline, _ownerBatch(bnbTargets));
        (, bytes memory monOp) = _governorRequest(MONAD_SELECTOR, deadline, _ownerBatch(monTargets));
        assertEq(
            monOp,
            CCIPGovernancePayload.encode(143, monadExecPredicted, 2, 2, deadline, _ownerBatch(monTargets)),
            "sender encoding == shared library encoding"
        );
        bytes32 bnbOpMsg = _dispatch(bnbOp);
        bytes32 monOpMsg = _dispatch(monOp);

        vm.selectFork(bnbFork);
        _deliverQueueExecute(BNB_ROUTER, BNB_OFFRAMP, bnbExec, address(sender), bnbOpMsg, bnbOp);
        _directTransfers(bnbExec);
        _postTransferMigration(56, BNB_ROUTER, BNB_OFFRAMP, BNB_LEGACY_OFFRAMP, bnbExec, address(sender), ORDERS_192);

        // Hand the exact Monad bytes to the Monad run (script/ccip-fork-t1.sh greps these lines).
        emit log_named_address("MONAD_SENDER", address(sender));
        emit log_named_address("MONAD_EXECUTOR", monadExecPredicted);
        emit log_named_bytes32("MONAD_PING_MSG", monPingMsg);
        emit log_named_bytes("MONAD_PING_PAYLOAD", monPing);
        emit log_named_bytes32("MONAD_OP_MSG", monOpMsg);
        emit log_named_bytes("MONAD_OP_PAYLOAD", monOp);
    }

    // ---------------------------------------------------------------- forgery and recovery on the real router

    function test_fork_bnb_forgedSender_rejected_and_forgedOp_cancelled() public {
        vm.selectFork(bnbFork);
        CCIPGovernancePayload.Call[] memory c = new CCIPGovernancePayload.Call[](1);
        c[0] = CCIPGovernancePayload.Call(POSITIONS_192, abi.encodeWithSelector(OWNER_SELECTOR));
        bytes memory p =
            CCIPGovernancePayload.encode(56, address(bnbExec), type(uint64).max, 2, uint64(_now() + 1 days), c);

        // Wrong sender bytes through the real router: the receiver reverts, the router reports failure.
        (bool ok, bytes memory ret,) =
            _route(BNB_ROUTER, BNB_OFFRAMP, address(bnbExec), address(0xBAD), keccak256("s"), p);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(CCIPOwnerExecutor.InvalidSender.selector));

        // An unregistered OffRamp cannot route at all.
        Client.Any2EVMMessage memory m = Client.Any2EVMMessage(
            keccak256("forged"), ETH_SELECTOR, abi.encode(address(sender)), p, new Client.EVMTokenAmount[](0)
        );
        vm.prank(address(0xBAD));
        vm.expectRevert(IRouter.OnlyOffRamp.selector);
        IRouter(BNB_ROUTER).routeMessage(m, GAS_FOR_CALL_EXACT_CHECK, GAS_LIMIT, address(bnbExec));

        // A forgery with the right sender bytes (CCIP compromise, here via a legacy OffRamp) queues with opId max, is
        // cancelled, and does not block the next legitimate op (H-1).
        (ok,,) = _route(BNB_ROUTER, BNB_LEGACY_OFFRAMP, address(bnbExec), address(sender), keccak256("f"), p);
        assertTrue(ok);
        bytes32[] memory hs = new bytes32[](1);
        hs[0] = keccak256(p);
        MockCanceller(bnbCanceller).cancel(bnbExec, hs);
        bytes memory legit = CCIPGovernancePayload.encode(56, address(bnbExec), 1, 2, uint64(_now() + 1 days), c);
        (ok,,) = _route(BNB_ROUTER, BNB_OFFRAMP, address(bnbExec), address(sender), keccak256("l"), legit);
        assertTrue(ok);
        vm.warp(_now() + DELAY);
        bnbExec.execute(legit);
        assertEq(bnbExec.lastExecutedOpId(), 1);
    }

    /// M-1: the real Router refuses a receiver with no code (`NoContract`), so a message to an undeployed or
    /// non-receiver executor never reaches the Router: OffRamp 2.0.0 `_isTokenOnlyTransfer` (OffRamp.sol:426) skips the
    /// call first and records SUCCESS (mocked in `CCIPOwnerExecutorTest.test_silentSuccess_*`). OffRamp SUCCESS is
    /// therefore not delivery evidence; only the executor's own Pinged/Queued event is.
    function test_fork_silentSuccess_isDecidedBeforeRouter() public {
        vm.selectFork(bnbFork);
        address nowhere = vm.computeCreateAddress(executorDeployer, 7);
        assertEq(nowhere.code.length, 0);
        bytes memory p = CCIPGovernancePayload.encode(
            56, nowhere, 1, 1, uint64(_now() + 1 days), new CCIPGovernancePayload.Call[](0)
        );
        Client.Any2EVMMessage memory m = Client.Any2EVMMessage(
            keccak256("x"), ETH_SELECTOR, abi.encode(address(sender)), p, new Client.EVMTokenAmount[](0)
        );
        vm.prank(BNB_OFFRAMP);
        vm.expectRevert(bytes4(keccak256("NoContract()")));
        IRouter(BNB_ROUTER).routeMessage(m, GAS_FOR_CALL_EXACT_CHECK, GAS_LIMIT, nowhere);
    }
}

/// @notice Monad leg (run with `--network monad`). Deploys the executor from the same fresh deployer and delivers the
///         exact payloads the Ethereum run's real sender emitted, through an IMPERSONATED OffRamp 2.0.0.
/// @dev Needs MONAD_RPC_URL and the MONAD_* values printed by `CCIPOwnerRouteForkTest`; skipped otherwise.
contract CCIPMonadForkTest is CCIPForkBase {
    function test_fork_monad_ping_ownerBatch_directTransfer() public {
        string memory mon = vm.envOr("MONAD_RPC_URL", string(""));
        bytes memory opPayload = vm.envOr("MONAD_OP_PAYLOAD", bytes(""));
        if (bytes(mon).length == 0 || opPayload.length == 0) {
            vm.skip(true);
            return;
        }
        vm.selectFork(_fork(mon, "MONAD_FORK_BLOCK"));
        address senderAddr = vm.envAddress("MONAD_SENDER");
        address[] memory ts = new address[](4);
        ts[0] = POSITIONS_V311;
        ts[1] = ORDERS_V311;
        ts[2] = POSITIONS_192;
        ts[3] = ORDERS_192;
        (CCIPOwnerExecutor e,) = _deployExecutor(MONAD_ROUTER, senderAddr, ts);
        assertEq(address(e), vm.envAddress("MONAD_EXECUTOR"), "executor address matches the sender's pin");

        _deliverPing(
            MONAD_ROUTER,
            MONAD_OFFRAMP,
            e,
            senderAddr,
            vm.envBytes32("MONAD_PING_MSG"),
            vm.envBytes("MONAD_PING_PAYLOAD")
        );
        _deliverQueueExecute(MONAD_ROUTER, MONAD_OFFRAMP, e, senderAddr, vm.envBytes32("MONAD_OP_MSG"), opPayload);
        _directTransfers(e);
        _postTransferMigration(143, MONAD_ROUTER, MONAD_OFFRAMP, MONAD_LEGACY_OFFRAMP, e, senderAddr, ORDERS_V311);
    }
}
