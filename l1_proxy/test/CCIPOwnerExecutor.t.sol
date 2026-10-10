// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Client} from "../vendor/ccip-2.0.0/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "../vendor/ccip-2.0.0/interfaces/IAny2EVMMessageReceiver.sol";
import {IAny2EVMMessageReceiverV2} from "../vendor/ccip-2.0.0/interfaces/IAny2EVMMessageReceiverV2.sol";
import {CCIPGovernancePayload} from "../src/CCIPGovernancePayload.sol";
import {CCIPOwnerExecutor} from "../src/CCIPOwnerExecutor.sol";
import {MockCCIPRouter, MockOwnedTarget, MockCanceller, NoInterface, PayloadLib} from "./CCIPMocks.sol";

/// @notice T0 unit and fuzz tests for the destination executor. Evidence class: MOCKED (MockCCIPRouter delivers).
contract CCIPOwnerExecutorTest is Test {
    using PayloadLib for *;

    uint64 constant SOURCE = 5009297550715157269;
    uint64 constant DELAY = 72 hours;
    uint64 constant WINDOW = 14 days;
    uint64 constant TTL = 30 days;
    address constant SENDER = address(0x5E4D);

    MockCCIPRouter router;
    MockCanceller canceller;
    MockOwnedTarget t0;
    MockOwnedTarget t1;
    MockOwnedTarget outsider;
    CCIPOwnerExecutor ex;
    uint256 msgNonce;

    function setUp() public {
        vm.warp(1_800_000_000);
        router = new MockCCIPRouter();
        canceller = new MockCanceller();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        t0 = new MockOwnedTarget(predicted);
        t1 = new MockOwnedTarget(predicted);
        outsider = new MockOwnedTarget(predicted);
        ex = _deploy(DELAY);
        assertEq(address(ex), predicted);
    }

    function _deploy(uint64 delay) internal returns (CCIPOwnerExecutor) {
        address[] memory ts = new address[](2);
        ts[0] = address(t0);
        ts[1] = address(t1);
        return new CCIPOwnerExecutor(address(router), SOURCE, SENDER, delay, WINDOW, TTL, address(canceller), ts);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev via-IR may reuse a cached `block.timestamp` across `vm.warp`; read the cheatcode instead.
    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _payload(uint64 opId, uint8 phase, uint64 deadline, CCIPGovernancePayload.Call[] memory calls)
        internal
        view
        returns (bytes memory)
    {
        return CCIPGovernancePayload.encode(block.chainid, address(ex), opId, phase, deadline, calls);
    }

    function _gov(uint64 opId, uint256 value) internal view returns (bytes memory) {
        return _payload(
            opId,
            CCIPGovernancePayload.PHASE_GOVERNOR,
            uint64(_now() + 7 days),
            address(t0).one(abi.encodeCall(MockOwnedTarget.setX, (value)))
        );
    }

    function _msg(bytes memory data) internal returns (Client.Any2EVMMessage memory m) {
        m.messageId = keccak256(abi.encode(++msgNonce));
        m.sourceChainSelector = SOURCE;
        m.sender = abi.encode(SENDER);
        m.data = data;
    }

    function _deliver(bytes memory data) internal returns (bool ok, bytes memory ret) {
        bool skipped;
        (ok, skipped, ret) = router.deliver(address(ex), _msg(data), 500_000);
        assertFalse(skipped);
    }

    function _deliverOk(bytes memory data) internal {
        (bool ok, bytes memory ret) = _deliver(data);
        assertTrue(ok, string(ret));
    }

    function _deliverErr(bytes memory data, bytes memory err) internal {
        (bool ok, bytes memory ret) = _deliver(data);
        assertFalse(ok);
        assertEq(ret, err);
    }

    function _receiveDirect(Client.Any2EVMMessage memory m) internal {
        vm.prank(address(router));
        ex.ccipReceive(m);
    }

    function _one(bytes32 h) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = h;
    }

    function _status(bytes32 h) internal view returns (CCIPOwnerExecutor.OpStatus s) {
        (s,,) = ex.ops(h);
    }

    // ---------------------------------------------------------------- interface (C4)

    function test_supportsInterface_legacyOnly() public view {
        assertTrue(ex.supportsInterface(0x01ffc9a7));
        assertTrue(ex.supportsInterface(0x85572ffb));
        assertEq(type(IAny2EVMMessageReceiver).interfaceId, bytes4(0x85572ffb));
        assertFalse(ex.supportsInterface(type(IAny2EVMMessageReceiverV2).interfaceId));
        assertFalse(ex.supportsInterface(0xffffffff));
        assertFalse(ex.supportsInterface(0x00000000));
    }

    function testFuzz_supportsInterface_onlyTwo(bytes4 id) public view {
        assertEq(ex.supportsInterface(id), id == 0x01ffc9a7 || id == 0x85572ffb);
    }

    // ---------------------------------------------------------------- happy path

    function test_queue_wait_execute() public {
        bytes memory p = _gov(1, 42);
        bytes32 h = keccak256(p);
        vm.recordLogs();
        _deliverOk(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], CCIPOwnerExecutor.Queued.selector);
        assertEq(logs[0].topics[1], h);
        (CCIPOwnerExecutor.OpStatus s, uint64 opId, uint64 eta) = ex.ops(h);
        assertEq(uint8(s), uint8(CCIPOwnerExecutor.OpStatus.Queued));
        assertEq(opId, 1);
        assertEq(eta, _now() + DELAY);

        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.NotReady.selector, eta));
        ex.execute(p);
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.NotReady.selector, eta));
        ex.execute(p);
        vm.warp(eta);
        vm.expectEmit(address(ex));
        emit CCIPOwnerExecutor.Executed(h, 1);
        ex.execute(p);
        assertEq(t0.x(), 42);
        assertEq(ex.lastExecutedOpId(), 1);
        assertEq(uint8(_status(h)), uint8(CCIPOwnerExecutor.OpStatus.Executed));

        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.NotQueued.selector, h));
        ex.execute(p);
    }

    function test_execute_windowBoundary() public {
        bytes memory p = _gov(1, 1);
        _deliverOk(p);
        (,, uint64 eta) = ex.ops(keccak256(p));
        vm.warp(eta + WINDOW + 1);
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.WindowElapsed.selector, eta + WINDOW));
        ex.execute(p);
        vm.warp(eta + WINDOW);
        ex.execute(p);
    }

    function test_execute_unknownPayload() public {
        bytes memory p = _gov(1, 1);
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.NotQueued.selector, keccak256(p)));
        ex.execute(p);
    }

    // ---------------------------------------------------------------- authentication negatives (C6)

    function test_reject_wrongRouter() public {
        Client.Any2EVMMessage memory m = _msg(_gov(1, 1));
        vm.expectRevert(CCIPOwnerExecutor.InvalidRouter.selector);
        ex.ccipReceive(m);
        vm.prank(address(canceller));
        vm.expectRevert(CCIPOwnerExecutor.InvalidRouter.selector);
        ex.ccipReceive(m);
    }

    function test_reject_wrongSourceChain() public {
        Client.Any2EVMMessage memory m = _msg(_gov(1, 1));
        m.sourceChainSelector = 11344663589394136015;
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.InvalidSourceChain.selector, m.sourceChainSelector));
        _receiveDirect(m);
    }

    function test_reject_senderEncodings() public {
        Client.Any2EVMMessage memory m = _msg(_gov(1, 1));
        bytes[5] memory bad = [
            abi.encode(address(0xBAD)),
            abi.encodePacked(SENDER), // 20 bytes
            abi.encodePacked(bytes32(uint256(uint160(SENDER)) | (uint256(1) << 255))), // dirty upper bytes
            abi.encodePacked(abi.encode(SENDER), bytes1(0)), // 33 bytes
            bytes("")
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            m.sender = bad[i];
            vm.expectRevert(CCIPOwnerExecutor.InvalidSender.selector);
            _receiveDirect(m);
        }
    }

    function testFuzz_reject_anyOtherSender(bytes calldata s) public {
        vm.assume(keccak256(s) != keccak256(abi.encode(SENDER)));
        Client.Any2EVMMessage memory m = _msg(_gov(1, 1));
        m.sender = s;
        vm.expectRevert(CCIPOwnerExecutor.InvalidSender.selector);
        _receiveDirect(m);
    }

    function test_reject_tokens() public {
        Client.Any2EVMMessage memory m = _msg(_gov(1, 1));
        m.destTokenAmounts = new Client.EVMTokenAmount[](1);
        vm.expectRevert(CCIPOwnerExecutor.TokensNotAccepted.selector);
        _receiveDirect(m);
    }

    // ---------------------------------------------------------------- payload negatives

    function test_reject_version_chain_executor() public {
        CCIPGovernancePayload.Call[] memory c = address(t0).one(abi.encodeCall(MockOwnedTarget.setX, (1)));
        uint64 d = uint64(_now() + 1 days);
        _deliverErr(
            abi.encode(uint8(2), block.chainid, address(ex), uint64(1), uint8(2), d, c),
            abi.encodeWithSelector(CCIPOwnerExecutor.InvalidVersion.selector, uint8(2))
        );
        _deliverErr(
            CCIPGovernancePayload.encode(56, address(ex), 1, 2, d, c),
            abi.encodeWithSelector(CCIPOwnerExecutor.InvalidChainId.selector, uint256(56))
        );
        _deliverErr(
            CCIPGovernancePayload.encode(block.chainid, address(t1), 1, 2, d, c),
            abi.encodeWithSelector(CCIPOwnerExecutor.InvalidExecutor.selector, address(t1))
        );
    }

    function test_reject_malformedPayload() public {
        (bool ok,) = _deliver(hex"deadbeef");
        assertFalse(ok);
        (ok,) = _deliver("");
        assertFalse(ok);
    }

    function test_reject_phase() public {
        CCIPGovernancePayload.Call[] memory c = address(t0).one(abi.encodeCall(MockOwnedTarget.setX, (1)));
        uint64 d = uint64(_now() + 1 days);
        _deliverErr(_payload(1, 0, d, c), abi.encodeWithSelector(CCIPOwnerExecutor.InvalidPhase.selector, uint8(0)));
        _deliverErr(_payload(1, 3, d, c), abi.encodeWithSelector(CCIPOwnerExecutor.InvalidPhase.selector, uint8(3)));
        // A BOOTSTRAP payload can never carry calls.
        _deliverErr(_payload(1, 1, d, c), abi.encodeWithSelector(CCIPOwnerExecutor.InvalidCallCount.selector, 1));
    }

    function test_reject_callCount() public {
        uint64 d = uint64(_now() + 1 days);
        _deliverErr(
            _payload(1, 2, d, new CCIPGovernancePayload.Call[](0)),
            abi.encodeWithSelector(CCIPOwnerExecutor.InvalidCallCount.selector, 0)
        );
        CCIPGovernancePayload.Call[] memory c = new CCIPGovernancePayload.Call[](9);
        for (uint256 i = 0; i < 9; i++) {
            c[i] = CCIPGovernancePayload.Call(address(t0), abi.encodeCall(MockOwnedTarget.setX, (i)));
        }
        _deliverErr(_payload(1, 2, d, c), abi.encodeWithSelector(CCIPOwnerExecutor.InvalidCallCount.selector, 9));
    }

    function test_reject_targets_selectors() public {
        uint64 d = uint64(_now() + 1 days);
        _deliverErr(
            _payload(1, 2, d, address(outsider).one(abi.encodeCall(MockOwnedTarget.setX, (1)))),
            abi.encodeWithSelector(CCIPOwnerExecutor.TargetNotAllowed.selector, 0, address(outsider))
        );
        _deliverErr(
            _payload(1, 2, d, address(ex).one(abi.encodeWithSelector(CCIPOwnerExecutor.cancel.selector))),
            abi.encodeWithSelector(CCIPOwnerExecutor.TargetNotAllowed.selector, 0, address(ex))
        );
        _deliverErr(
            _payload(1, 2, d, address(0).one(hex"12345678")),
            abi.encodeWithSelector(CCIPOwnerExecutor.TargetNotAllowed.selector, 0, address(0))
        );
        _deliverErr(
            _payload(1, 2, d, address(t0).one(hex"123456")),
            abi.encodeWithSelector(CCIPOwnerExecutor.InvalidCallData.selector, 0)
        );
        _deliverErr(
            _payload(1, 2, d, address(t1).one(hex"715018a6")),
            abi.encodeWithSelector(CCIPOwnerExecutor.SelectorDenied.selector, 0, bytes4(0x715018a6))
        );
        // renounce hidden at index 1 of a batch
        CCIPGovernancePayload.Call[] memory c = new CCIPGovernancePayload.Call[](2);
        c[0] = CCIPGovernancePayload.Call(address(t0), abi.encodeCall(MockOwnedTarget.setX, (1)));
        c[1] = CCIPGovernancePayload.Call(address(t0), abi.encodePacked(bytes4(0x715018a6), uint256(0)));
        _deliverErr(
            _payload(1, 2, d, c),
            abi.encodeWithSelector(CCIPOwnerExecutor.SelectorDenied.selector, 1, bytes4(0x715018a6))
        );
    }

    function test_reject_deadlines() public {
        CCIPGovernancePayload.Call[] memory c = address(t0).one(abi.encodeCall(MockOwnedTarget.setX, (1)));
        uint64 past = uint64(_now() - 1);
        _deliverErr(_payload(1, 2, past, c), abi.encodeWithSelector(CCIPOwnerExecutor.Expired.selector, past));
        uint64 far = uint64(_now() + TTL + 1);
        _deliverErr(_payload(1, 2, far, c), abi.encodeWithSelector(CCIPOwnerExecutor.DeadlineTooFar.selector, far));
        _deliverOk(_payload(1, 2, uint64(_now() + TTL), c));
        _deliverOk(_payload(2, 2, uint64(_now()), c));
    }

    // ---------------------------------------------------------------- bootstrap pings

    function test_ping_isHarmless() public {
        bytes memory p = _payload(7, 1, uint64(_now() + 1 days), new CCIPGovernancePayload.Call[](0));
        vm.recordLogs();
        _deliverOk(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], CCIPOwnerExecutor.Pinged.selector);
        assertEq(logs[0].topics[1], keccak256(p));
        assertEq(uint256(logs[0].topics[3]), 7);
        assertEq(uint8(_status(keccak256(p))), 0);
        assertEq(ex.lastExecutedOpId(), 0);
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.NotQueued.selector, keccak256(p)));
        ex.execute(p);
        // A ping never blocks a GOVERNOR op with the same opId.
        bytes memory g = _gov(7, 3);
        _deliverOk(g);
        vm.warp(_now() + DELAY);
        ex.execute(g);
        assertEq(t0.x(), 3);
        // Ping with a stale opId is still just a ping (no state).
        _deliverOk(_payload(1, 1, uint64(_now() + 1 days), new CCIPGovernancePayload.Call[](0)));
        assertEq(ex.lastExecutedOpId(), 7);
    }

    // ---------------------------------------------------------------- replay and order

    function test_replay_sameBytes_rejected_inAllStates() public {
        bytes memory p = _gov(1, 1);
        bytes32 h = keccak256(p);
        _deliverOk(p);
        _deliverErr(p, abi.encodeWithSelector(CCIPOwnerExecutor.AlreadyKnown.selector, h));
        vm.prank(address(canceller));
        ex.cancel(_one(h));
        _deliverErr(p, abi.encodeWithSelector(CCIPOwnerExecutor.AlreadyKnown.selector, h));

        bytes memory q = _gov(2, 2);
        _deliverOk(q);
        vm.warp(_now() + DELAY);
        ex.execute(q);
        // after execution, a replay of q is stale (opId 2 <= 2)
        _deliverErr(q, abi.encodeWithSelector(CCIPOwnerExecutor.StaleOpId.selector, uint64(2), uint64(2)));
    }

    function test_order_newerSupersedesOlder() public {
        bytes memory p1 = _gov(1, 1);
        bytes memory p2 = _gov(2, 2);
        _deliverOk(p2);
        _deliverOk(p1); // out-of-order arrival is fine at queue time
        vm.warp(_now() + DELAY);
        ex.execute(p2);
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.StaleOpId.selector, uint64(1), uint64(2)));
        ex.execute(p1);
        assertEq(t0.x(), 2);
        // stale at queue time once executed state moved
        _deliverErr(_gov(2, 9), abi.encodeWithSelector(CCIPOwnerExecutor.StaleOpId.selector, uint64(2), uint64(2)));
        _deliverErr(_gov(1, 9), abi.encodeWithSelector(CCIPOwnerExecutor.StaleOpId.selector, uint64(1), uint64(2)));
    }

    // ---------------------------------------------------------------- H-1 cancellation recovery (C1)

    function test_H1_forgedMaxOpId_cancel_thenLegitimate() public {
        bytes memory forged = _gov(type(uint64).max, 666);
        _deliverOk(forged);
        vm.prank(address(canceller));
        ex.cancel(_one(keccak256(forged)));
        bytes memory legit = _gov(1, 1);
        _deliverOk(legit);
        vm.warp(_now() + DELAY);
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.NotQueued.selector, keccak256(forged)));
        ex.execute(forged);
        ex.execute(legit);
        assertEq(t0.x(), 1);
        assertEq(ex.lastExecutedOpId(), 1);
    }

    function test_H1_forgedSameOpId_cancel_thenLegitimate() public {
        bytes memory forged = _gov(1, 666);
        bytes memory legit = _gov(1, 1);
        _deliverOk(forged);
        _deliverOk(legit); // same opId, different bytes: both queue independently
        vm.prank(address(canceller));
        ex.cancel(_one(keccak256(forged)));
        vm.warp(_now() + DELAY);
        ex.execute(legit);
        assertEq(t0.x(), 1);
    }

    function test_H1_preburnedRange_cancelMany_thenLegitimate() public {
        bytes32[] memory hs = new bytes32[](20);
        for (uint64 i = 0; i < 20; i++) {
            bytes memory f = _gov(i + 1, 1000 + i);
            _deliverOk(f);
            hs[i] = keccak256(f);
        }
        vm.prank(address(canceller));
        ex.cancel(hs);
        for (uint256 i = 0; i < 20; i++) {
            assertEq(uint8(_status(hs[i])), uint8(CCIPOwnerExecutor.OpStatus.Cancelled));
        }
        bytes memory l1 = _gov(1, 1);
        bytes memory l2 = _gov(2, 2);
        _deliverOk(l1);
        _deliverOk(l2);
        vm.warp(_now() + DELAY);
        ex.execute(l1);
        ex.execute(l2);
        assertEq(t0.x(), 2);
    }

    // ---------------------------------------------------------------- canceller

    function test_cancel_afterEta_and_beforeExecute() public {
        bytes memory p = _gov(1, 1);
        _deliverOk(p);
        vm.warp(_now() + DELAY + 1 days);
        vm.expectEmit(address(ex));
        emit CCIPOwnerExecutor.Cancelled(keccak256(p), 1);
        canceller.cancel(ex, _one(keccak256(p)));
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.NotQueued.selector, keccak256(p)));
        ex.execute(p);
        assertEq(ex.lastExecutedOpId(), 0);
    }

    function test_cancel_onlyCanceller_onlyQueued_atomic() public {
        bytes memory p = _gov(1, 1);
        bytes32 h = keccak256(p);
        _deliverOk(p);
        vm.expectRevert(CCIPOwnerExecutor.Unauthorized.selector);
        ex.cancel(_one(h));
        vm.prank(address(router));
        vm.expectRevert(CCIPOwnerExecutor.Unauthorized.selector);
        ex.cancel(_one(h));
        // unknown hash inside a batch reverts the whole batch
        bytes32[] memory hs = new bytes32[](2);
        hs[0] = h;
        hs[1] = keccak256("unknown");
        vm.prank(address(canceller));
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.NotQueued.selector, hs[1]));
        ex.cancel(hs);
        assertEq(uint8(_status(h)), 1);
        // executed ops cannot be cancelled
        vm.warp(_now() + DELAY);
        ex.execute(p);
        vm.prank(address(canceller));
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.NotQueued.selector, h));
        ex.cancel(_one(h));
    }

    function test_canceller_cannotQueueOrBypassDelay() public {
        Client.Any2EVMMessage memory m = _msg(_gov(1, 1));
        vm.prank(address(canceller));
        vm.expectRevert(CCIPOwnerExecutor.InvalidRouter.selector);
        ex.ccipReceive(m);
        bytes memory p = _gov(1, 1);
        _deliverOk(p);
        (,, uint64 eta) = ex.ops(keccak256(p));
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.NotReady.selector, eta));
        canceller.tryExecute(ex, p);
    }

    // ---------------------------------------------------------------- atomicity, retry and reentrancy (C5)

    function test_failingBatch_isAtomic_andRetryable() public {
        CCIPGovernancePayload.Call[] memory c = new CCIPGovernancePayload.Call[](2);
        c[0] = CCIPGovernancePayload.Call(address(t0), abi.encodeCall(MockOwnedTarget.setX, (5)));
        c[1] = CCIPGovernancePayload.Call(address(t1), abi.encodeCall(MockOwnedTarget.setX, (6)));
        bytes memory p = _payload(1, 2, uint64(_now() + 1 days), c);
        _deliverOk(p);
        vm.warp(_now() + DELAY);
        // t1 temporarily not owned by the executor -> second call fails -> whole batch reverts
        vm.prank(address(ex));
        t1.transferOwnership(address(0xdead));
        vm.expectRevert(
            abi.encodeWithSelector(CCIPOwnerExecutor.CallFailed.selector, 1, abi.encodeWithSelector(bytes4(0x82b42900)))
        );
        ex.execute(p);
        assertEq(t0.x(), 0);
        assertEq(uint8(_status(keccak256(p))), 1);
        assertEq(ex.lastExecutedOpId(), 0);
        vm.prank(address(0xdead));
        t1.transferOwnership(address(ex));
        ex.execute(p);
        assertEq(t0.x(), 5);
        assertEq(t1.x(), 6);
    }

    function test_reentrancy_targetCallback() public {
        bytes memory other = _gov(2, 99);
        _deliverOk(other);
        t0.armReentry(address(ex), abi.encodeCall(CCIPOwnerExecutor.execute, (other)));
        bytes memory p =
            _payload(1, 2, uint64(_now() + 1 days), address(t0).one(abi.encodeCall(MockOwnedTarget.poke, ())));
        _deliverOk(p);
        vm.warp(_now() + DELAY);
        ex.execute(p);
        assertTrue(t0.lastReentryReverted());
        assertEq(t0.lastReentryError(), abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector));
        assertEq(t0.x(), 0);
        // the re-entered op is untouched but now stale (2 > 1 so still executable)
        ex.execute(other);
        assertEq(t0.x(), 99);

        // a strict target that bubbles the reentrancy failure reverts the whole op; it stays queued
        bytes memory again = _gov(4, 7);
        _deliverOk(again);
        t1.armReentry(address(ex), abi.encodeCall(CCIPOwnerExecutor.execute, (again)));
        bytes memory q =
            _payload(3, 2, uint64(_now() + 1 days), address(t1).one(abi.encodeCall(MockOwnedTarget.pokeStrict, ())));
        _deliverOk(q);
        vm.warp(_now() + DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPOwnerExecutor.CallFailed.selector, 0, abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector)
            )
        );
        ex.execute(q);
        assertEq(uint8(_status(keccak256(q))), 1);

        // re-entering ccipReceive from a target fails on the router check
        t1.armReentry(address(ex), abi.encodeCall(CCIPOwnerExecutor.ccipReceive, (_msg(_gov(9, 9)))));
        bytes memory r =
            _payload(5, 2, uint64(_now() + 1 days), address(t1).one(abi.encodeCall(MockOwnedTarget.poke, ())));
        _deliverOk(r);
        vm.warp(_now() + DELAY);
        ex.execute(r);
        assertEq(t1.lastReentryError(), abi.encodeWithSelector(CCIPOwnerExecutor.InvalidRouter.selector));
    }

    function test_calls_carryZeroValue_noReceive() public {
        (bool ok,) = address(ex).call{value: 1}("");
        assertFalse(ok);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(CCIPOwnerExecutor.OwnershipImmutable.selector);
        ex.transferOwnership{value: 1}(address(1));
        assertEq(address(ex).balance, 0);
    }

    // ---------------------------------------------------------------- deadline revival (C6)

    function test_failureRevival_boundedByDeadline() public {
        // First delivery runs out of gas (CCIP FAILURE, re-executable by anyone).
        bytes memory p =
            _payload(1, 2, uint64(_now() + 1 days), address(t0).one(abi.encodeCall(MockOwnedTarget.setX, (1))));
        (bool ok,,) = router.deliver(address(ex), _msg(p), 5_000);
        assertFalse(ok);
        assertEq(uint8(_status(keccak256(p))), 0);
        // Revival within the deadline queues it.
        vm.warp(_now() + 12 hours);
        _deliverOk(p);
        // Revival of another failed message after its deadline is rejected.
        bytes memory q =
            _payload(2, 2, uint64(_now() + 1 days), address(t0).one(abi.encodeCall(MockOwnedTarget.setX, (2))));
        (ok,,) = router.deliver(address(ex), _msg(q), 5_000);
        assertFalse(ok);
        vm.warp(_now() + 1 days + 1);
        _deliverErr(q, abi.encodeWithSelector(CCIPOwnerExecutor.Expired.selector, uint64(_now() - 1)));
    }

    // ---------------------------------------------------------------- silent SUCCESS (M-1, documented)

    function test_silentSuccess_undeployedOrNoInterface_noPinged() public {
        bytes memory p = _payload(1, 1, uint64(_now() + 1 days), new CCIPGovernancePayload.Call[](0));
        NoInterface ni = new NoInterface();
        address[2] memory receivers = [address(0xC0FFEE), address(ni)];
        for (uint256 i = 0; i < 2; i++) {
            vm.recordLogs();
            (bool ok, bool skipped,) = router.deliver(receivers[i], _msg(p), 500_000);
            assertTrue(ok, "OffRamp would record SUCCESS");
            assertTrue(skipped, "receiver not called");
            assertEq(vm.getRecordedLogs().length, 0, "no Pinged");
        }
        assertEq(ni.touched(), 0);
    }

    // ---------------------------------------------------------------- no local admin

    function test_ownableSurface_immutable() public {
        assertEq(ex.owner(), address(0));
        assertEq(ex.ownershipHandoverExpiresAt(address(this)), 0);
        vm.expectRevert(CCIPOwnerExecutor.OwnershipImmutable.selector);
        ex.transferOwnership(address(this));
        vm.expectRevert(CCIPOwnerExecutor.OwnershipImmutable.selector);
        ex.renounceOwnership();
        vm.expectRevert(CCIPOwnerExecutor.OwnershipImmutable.selector);
        ex.requestOwnershipHandover();
        vm.expectRevert(CCIPOwnerExecutor.OwnershipImmutable.selector);
        ex.completeOwnershipHandover(address(this));
        vm.expectRevert(CCIPOwnerExecutor.OwnershipImmutable.selector);
        ex.cancelOwnershipHandover();
    }

    function test_views() public view {
        address[] memory ts = ex.targets();
        assertEq(ts.length, 2);
        assertEq(ts[0], address(t0));
        assertEq(ts[1], address(t1));
        assertTrue(ex.isTarget(address(t1)));
        assertFalse(ex.isTarget(address(0)));
        assertFalse(ex.isTarget(address(outsider)));
        assertEq(ex.delay(), DELAY);
        assertEq(ex.canceller(), address(canceller));
        assertEq(ex.sender(), SENDER);
        assertEq(ex.router(), address(router));
        assertEq(ex.sourceChainSelector(), SOURCE);
    }

    // ---------------------------------------------------------------- constructor

    function test_constructor_checks() public {
        address[] memory ts = new address[](1);
        ts[0] = address(t0);
        address r = address(router);
        address c = address(canceller);
        _expectCtor(0, address(0xabc), SOURCE, SENDER, DELAY, WINDOW, TTL, c, ts);
        _expectCtor(1, r, 0, SENDER, DELAY, WINDOW, TTL, c, ts);
        _expectCtor(2, r, SOURCE, address(0), DELAY, WINDOW, TTL, c, ts);
        _expectCtor(3, r, SOURCE, SENDER, 0, WINDOW, TTL, c, ts);
        _expectCtor(4, r, SOURCE, SENDER, DELAY, 0, TTL, c, ts);
        _expectCtor(5, r, SOURCE, SENDER, DELAY, WINDOW, 0, c, ts);
        _expectCtor(5, r, SOURCE, SENDER, DELAY, WINDOW, 30 days + 1, c, ts);
        _expectCtor(6, r, SOURCE, SENDER, DELAY, WINDOW, TTL, address(0xE0A), ts); // EOA canceller
        _expectCtor(6, r, SOURCE, SENDER, DELAY, WINDOW, TTL, r, ts);
        _expectCtor(7, r, SOURCE, SENDER, DELAY, WINDOW, TTL, c, new address[](0));
        address[] memory seven = new address[](7);
        for (uint256 i = 0; i < 7; i++) {
            seven[i] = address(new MockOwnedTarget(address(1)));
        }
        _expectCtor(7, r, SOURCE, SENDER, DELAY, WINDOW, TTL, c, seven);
        address[] memory dup = new address[](2);
        dup[0] = address(t0);
        dup[1] = address(t0);
        _expectCtor(7, r, SOURCE, SENDER, DELAY, WINDOW, TTL, c, dup);
        ts[0] = address(0x1234);
        _expectCtor(7, r, SOURCE, SENDER, DELAY, WINDOW, TTL, c, ts);
        ts[0] = c;
        _expectCtor(7, r, SOURCE, SENDER, DELAY, WINDOW, TTL, c, ts);
        address[] memory six = new address[](6);
        for (uint256 i = 0; i < 6; i++) {
            six[i] = seven[i];
        }
        CCIPOwnerExecutor e6 = new CCIPOwnerExecutor(r, SOURCE, SENDER, DELAY, WINDOW, TTL, c, six);
        assertEq(e6.targets().length, 6);
        assertTrue(e6.isTarget(six[5]));
        assertFalse(e6.isTarget(seven[6]));
    }

    function _expectCtor(
        uint256 idx,
        address r,
        uint64 s,
        address snd,
        uint64 d,
        uint64 w,
        uint64 ttl,
        address c,
        address[] memory ts
    ) internal {
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.InvalidConstructorArgument.selector, idx));
        new CCIPOwnerExecutor(r, s, snd, d, w, ttl, c, ts);
    }

    // ---------------------------------------------------------------- fuzz

    /// A cancelled payload never blocks a different payload, whatever its opId.
    function testFuzz_cancelledNeverBlocksDifferent(uint64 forgedOpId, uint256 forgedValue, uint64 legitOpId) public {
        legitOpId = uint64(bound(legitOpId, 1, type(uint64).max));
        vm.assume(forgedOpId != legitOpId || forgedValue != 1);
        bytes memory forged = _gov(forgedOpId, forgedValue);
        bytes memory legit = _gov(legitOpId, 1);
        if (forgedOpId != 0) {
            _deliverOk(forged);
            vm.prank(address(canceller));
            ex.cancel(_one(keccak256(forged)));
        }
        _deliverOk(legit);
        vm.warp(_now() + DELAY);
        ex.execute(legit);
        assertEq(t0.x(), 1);
        assertEq(ex.lastExecutedOpId(), legitOpId);
    }

    function testFuzz_deadlineRule(uint64 offsetBack, uint64 offsetFwd, bool future) public {
        CCIPGovernancePayload.Call[] memory c = address(t0).one(abi.encodeCall(MockOwnedTarget.setX, (1)));
        uint64 d;
        if (future) {
            d = uint64(_now()) + uint64(bound(offsetFwd, 0, 2 * TTL));
        } else {
            d = uint64(_now()) - uint64(bound(offsetBack, 1, _now()));
        }
        (bool ok,) = _deliver(_payload(1, 2, d, c));
        assertEq(ok, d >= _now() && d <= _now() + TTL);
    }
}
