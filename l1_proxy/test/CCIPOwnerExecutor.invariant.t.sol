// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Client} from "../vendor/ccip-2.0.0/libraries/Client.sol";
import {CCIPGovernancePayload} from "../src/CCIPGovernancePayload.sol";
import {CCIPOwnerExecutor} from "../src/CCIPOwnerExecutor.sol";
import {MockCCIPRouter, MockOwnedTarget, MockCanceller} from "./CCIPMocks.sol";

/// @notice Drives the executor with interleaved legitimate ops, forged ops (any op id, including max, duplicates of
///         legitimate ids and pre-burned ranges) that the monitored canceller cancels, pings, time warps and
///         executions. Evidence class: MOCKED router.
contract ExecutorHandler is Test {
    uint64 constant SOURCE = 5009297550715157269;
    address constant SENDER = address(0x5E4D);
    uint256 constant FORGED = 1e18;

    CCIPOwnerExecutor public ex;
    MockCCIPRouter public router;
    MockCanceller public canceller;
    MockOwnedTarget public t0;
    MockOwnedTarget public t1;

    uint64 public legitNext;
    bytes[] internal legit;
    bytes[] internal forged;
    uint256 public ghostTargetCalls;
    uint64 public ghostLastExecuted;
    bool public orderViolated;
    bool public earlyExecution;
    bool public legitDeliveryFailed;
    bool public forgedExecuted;
    uint256 public pings;
    uint256 public executions;
    uint256 public cancellations;
    uint256 msgNonce;

    constructor(CCIPOwnerExecutor _ex, MockCCIPRouter _r, MockCanceller _c, MockOwnedTarget _t0, MockOwnedTarget _t1) {
        ex = _ex;
        router = _r;
        canceller = _c;
        t0 = _t0;
        t1 = _t1;
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _payload(uint64 opId, uint8 phase, uint256 value, uint8 n) internal view returns (bytes memory) {
        CCIPGovernancePayload.Call[] memory c = new CCIPGovernancePayload.Call[](n);
        for (uint256 i = 0; i < n; i++) {
            address t = (value + i) % 2 == 0 ? address(t0) : address(t1);
            c[i] = CCIPGovernancePayload.Call(t, abi.encodeCall(MockOwnedTarget.setX, (value)));
        }
        return CCIPGovernancePayload.encode(block.chainid, address(ex), opId, phase, uint64(_now() + 7 days), c);
    }

    function _deliver(bytes memory data) internal returns (bool ok) {
        Client.Any2EVMMessage memory m;
        m.messageId = keccak256(abi.encode(++msgNonce));
        m.sourceChainSelector = SOURCE;
        m.sender = abi.encode(SENDER);
        m.data = data;
        (ok,,) = router.deliver(address(ex), m, 1_000_000);
    }

    function deliverLegit(uint256 value, uint8 n) external {
        n = uint8(bound(n, 1, 8));
        value = bound(value, 1, FORGED - 1);
        bytes memory p = _payload(++legitNext, 2, value, n);
        if (!_deliver(p)) legitDeliveryFailed = true;
        legit.push(p);
    }

    function deliverForged(uint64 opId, uint256 value, uint8 n, uint8 mode) external {
        n = uint8(bound(n, 1, 8));
        value = FORGED + bound(value, 0, 1e9);
        if (mode % 3 == 0) opId = type(uint64).max;
        else if (mode % 3 == 1) opId = legitNext + 1 + (opId % 5); // pre-burn upcoming ids
        bytes memory p = _payload(opId, 2, value, n);
        if (_deliver(p)) {
            forged.push(p);
            // The monitored canceller cancels every unknown Queued op (A' operating assumption).
            bytes32[] memory hs = new bytes32[](1);
            hs[0] = keccak256(p);
            canceller.cancel(ex, hs);
            cancellations++;
        }
    }

    function ping(uint64 opId) external {
        uint256 before = t0.calls() + t1.calls();
        bytes memory p = _payload(opId, 1, 0, 0);
        if (_deliver(p)) pings++;
        assertEq(t0.calls() + t1.calls(), before);
    }

    function warp(uint32 dt) external {
        vm.warp(_now() + bound(dt, 1, 5 days));
    }

    function executeLegit(uint256 idx) external {
        if (legit.length == 0) return;
        bytes memory p = legit[idx % legit.length];
        (, uint64 opId, uint64 eta) = ex.ops(keccak256(p));
        (,,,,,, CCIPGovernancePayload.Call[] memory c) = CCIPGovernancePayload.decode(p);
        try ex.execute(p) {
            executions++;
            if (opId <= ghostLastExecuted) orderViolated = true;
            if (_now() < eta) earlyExecution = true;
            ghostLastExecuted = opId;
            ghostTargetCalls += c.length;
        } catch {}
    }

    function executeForged(uint256 idx) external {
        if (forged.length == 0) return;
        try ex.execute(forged[idx % forged.length]) {
            forgedExecuted = true;
        } catch {}
    }
}

contract CCIPOwnerExecutorInvariantTest is Test {
    ExecutorHandler h;
    CCIPOwnerExecutor ex;
    MockOwnedTarget t0;
    MockOwnedTarget t1;

    function setUp() public {
        vm.warp(1_800_000_000);
        MockCCIPRouter router = new MockCCIPRouter();
        MockCanceller canceller = new MockCanceller();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        t0 = new MockOwnedTarget(predicted);
        t1 = new MockOwnedTarget(predicted);
        address[] memory ts = new address[](2);
        ts[0] = address(t0);
        ts[1] = address(t1);
        ex = new CCIPOwnerExecutor(
            address(router), 5009297550715157269, address(0x5E4D), 72 hours, 14 days, 30 days, address(canceller), ts
        );
        assertEq(address(ex), predicted);
        h = new ExecutorHandler(ex, router, canceller, t0, t1);
        targetContract(address(h));
    }

    function invariant_noForgedEffect() public view {
        assertFalse(h.forgedExecuted());
        assertLt(t0.x(), 1e18);
        assertLt(t1.x(), 1e18);
    }

    function invariant_targetCallsOnlyFromDelayedGovernorOps() public view {
        assertEq(t0.calls() + t1.calls(), h.ghostTargetCalls());
        assertFalse(h.earlyExecution());
    }

    function invariant_executedOpIdsStrictlyIncrease() public view {
        assertFalse(h.orderViolated());
        assertEq(ex.lastExecutedOpId(), h.ghostLastExecuted());
    }

    function invariant_cancelledNeverBlocksDifferentPayload() public view {
        assertFalse(h.legitDeliveryFailed());
    }

    function invariant_holdsNoEth() public view {
        assertEq(address(ex).balance, 0);
    }

    function afterInvariant() external view {
        console.log("legit", h.legitNext(), "executed", h.executions());
        console.log("forged cancelled", h.cancellations(), "pings", h.pings());
    }
}
