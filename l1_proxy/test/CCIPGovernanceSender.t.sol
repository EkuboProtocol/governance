// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IRouterClient} from "../vendor/ccip-2.0.0/interfaces/IRouterClient.sol";
import {StarknetOwnerProxy} from "../src/StarknetOwnerProxy.sol";
import {CCIPGovernancePayload} from "../src/CCIPGovernancePayload.sol";
import {CCIPGovernanceSender} from "../src/CCIPGovernanceSender.sol";
import {MockStarknetMessaging} from "./StarknetOwnerProxy.t.sol";
import {MockCCIPRouter, PayloadLib} from "./CCIPMocks.sol";

/// @dev Refund recipient that tries to re-enter the sender during the refund.
contract ReentrantPayer {
    CCIPGovernanceSender public s;
    bytes public reenterData;
    bool public reverted;
    bytes public err;
    bool public rejectRefund;

    constructor(CCIPGovernanceSender _s) {
        s = _s;
    }

    function arm(bytes calldata d) external {
        reenterData = d;
    }

    function setRejectRefund(bool v) external {
        rejectRefund = v;
    }

    function pay(bytes calldata payload) external payable returns (bytes32) {
        return s.dispatch{value: msg.value}(payload);
    }

    receive() external payable {
        if (rejectRefund) revert("no");
        if (reenterData.length != 0) {
            (bool ok, bytes memory r) = address(s).call(reenterData);
            reverted = !ok;
            err = r;
        }
    }
}

/// @notice T0 unit and fuzz tests for the Ethereum sender. Evidence class: MOCKED router; the StarknetOwnerProxy is the
///         unchanged repo contract with a mocked Starknet messaging core.
contract CCIPGovernanceSenderTest is Test {
    using PayloadLib for *;

    uint64 constant BNB = 11344663589394136015;
    uint64 constant MONAD = 8481857512324358265;
    address constant E_BNB = address(0xB1B);
    address constant E_MONAD = address(0x3011AD);
    address constant BOOT = address(0xB007);
    uint256 constant L2_OWNER = 0x053499f7aa2706395060fe72d00388803fb2dcc111429891ad7b2d9dcea29acd;

    MockCCIPRouter router;
    MockStarknetMessaging messaging;
    StarknetOwnerProxy l1;
    CCIPGovernanceSender s;

    function setUp() public {
        router = new MockCCIPRouter();
        messaging = new MockStarknetMessaging();
        l1 = new StarknetOwnerProxy(messaging, L2_OWNER);
        s = _deploy(BOOT);
    }

    function _deploy(address boot) internal returns (CCIPGovernanceSender) {
        return new CCIPGovernanceSender(
            IRouterClient(address(router)),
            address(l1),
            boot,
            CCIPGovernanceSender.Destination(BNB, 56, E_BNB),
            CCIPGovernanceSender.Destination(MONAD, 143, E_MONAD),
            1_000_000
        );
    }

    function _noCalls() internal pure returns (CCIPGovernancePayload.Call[] memory) {
        return new CCIPGovernancePayload.Call[](0);
    }

    function _calls() internal pure returns (CCIPGovernancePayload.Call[] memory) {
        return address(0xA2971E0C37cFdb13aE8440A0C94Ef1A1af39e326).one(hex"8da5cb5b");
    }

    function _ping(uint64 dest) internal returns (bytes32 id, bytes memory payload) {
        vm.recordLogs();
        vm.prank(BOOT);
        id = s.request(dest, 300_000, 2_000_000_000, _noCalls());
        payload = _requestedPayload();
    }

    function _requestedPayload() internal returns (bytes memory payload) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(s) && logs[i].topics[0] == CCIPGovernanceSender.Requested.selector) {
                (,,, payload) = abi.decode(logs[i].data, (uint8, uint32, uint64, bytes));
            }
        }
        require(payload.length != 0, "no Requested");
    }

    /// Simulates the Starknet Governor's L2->L1 message, then relays it through the real StarknetOwnerProxy.
    function _governorRequest(uint64 dest, uint32 gas, uint64 deadline, CCIPGovernancePayload.Call[] memory calls)
        internal
        returns (bytes32 id, bytes memory payload)
    {
        bytes memory data = abi.encodeCall(CCIPGovernanceSender.request, (dest, gas, deadline, calls));
        uint64 n = l1.currentNonce();
        messaging.setMessageCount(L2_OWNER, l1.getPayload(address(s), 0, n, data), 1);
        vm.recordLogs();
        bytes memory ret = l1.execute(address(s), 0, n, data);
        id = abi.decode(ret, (bytes32));
        payload = _requestedPayload();
    }

    // ---------------------------------------------------------------- bootstrap and handoff

    function test_bootstrap_pingOnly() public {
        (bytes32 id, bytes memory p) = _ping(BNB);
        assertEq(id, keccak256(p));
        (
            uint8 v,
            uint256 chainId,
            address ex,
            uint64 opId,
            uint8 phase,
            uint64 dl,
            CCIPGovernancePayload.Call[] memory c
        ) = CCIPGovernancePayload.decode(p);
        assertEq(v, 1);
        assertEq(chainId, 56);
        assertEq(ex, E_BNB);
        assertEq(opId, 1);
        assertEq(phase, CCIPGovernancePayload.PHASE_BOOTSTRAP);
        assertEq(dl, 2_000_000_000);
        assertEq(c.length, 0);
        (CCIPGovernanceSender.RequestStatus st, uint64 d, uint32 g) = s.requests(id);
        assertEq(uint8(st), 1);
        assertEq(d, BNB);
        assertEq(g, 300_000);

        vm.prank(BOOT);
        vm.expectRevert(abi.encodeWithSelector(CCIPGovernanceSender.InvalidCallCount.selector, 1));
        s.request(BNB, 300_000, 2_000_000_000, _calls());

        (, bytes memory p2) = _ping(MONAD);
        (,,, uint64 op2,,,) = CCIPGovernancePayload.decode(p2);
        assertEq(op2, 1, "opIds are per destination");
        (, bytes memory p3) = _ping(BNB);
        (,,, uint64 op3,,,) = CCIPGovernancePayload.decode(p3);
        assertEq(op3, 2);
    }

    function test_handoff_oneWay_and_postHandoffBootstrapRejected() public {
        vm.expectRevert(CCIPGovernanceSender.Unauthorized.selector);
        s.handoff();
        vm.expectRevert(CCIPGovernanceSender.Unauthorized.selector);
        s.request(BNB, 300_000, 1, _noCalls());

        (bytes32 pingId, bytes memory pingPayload) = _ping(BNB);

        vm.expectEmit(address(s));
        emit CCIPGovernanceSender.HandedOff(BOOT, address(l1));
        vm.prank(BOOT);
        s.handoff();
        assertEq(s.authority(), address(l1));

        vm.prank(BOOT);
        vm.expectRevert(CCIPGovernanceSender.Unauthorized.selector);
        s.request(BNB, 300_000, 1, _noCalls());
        vm.prank(BOOT);
        vm.expectRevert(CCIPGovernanceSender.AlreadyHandedOff.selector);
        s.handoff();
        vm.prank(address(l1));
        vm.expectRevert(CCIPGovernanceSender.AlreadyHandedOff.selector);
        s.handoff();

        // A ping requested before handoff can still be dispatched afterwards; it stays a ping.
        router.setFee(100);
        vm.deal(address(this), 1 ether);
        s.dispatch{value: 100}(pingPayload);
        (CCIPGovernanceSender.RequestStatus st,,) = s.requests(pingId);
        assertEq(uint8(st), 2);
        (,,,, uint8 phase,,) = CCIPGovernancePayload.decode(router.lastSent().data);
        assertEq(phase, CCIPGovernancePayload.PHASE_BOOTSTRAP);

        // Governor requests now come only through the StarknetOwnerProxy and are GOVERNOR phase.
        (, bytes memory gp) = _governorRequest(BNB, 300_000, 2_000_000_000, _calls());
        (,,, uint64 opId, uint8 gphase,, CCIPGovernancePayload.Call[] memory c) = CCIPGovernancePayload.decode(gp);
        assertEq(gphase, CCIPGovernancePayload.PHASE_GOVERNOR);
        assertEq(opId, 2);
        assertEq(c.length, 1);

        // GOVERNOR phase needs 1..8 calls.
        vm.prank(address(l1));
        vm.expectRevert(abi.encodeWithSelector(CCIPGovernanceSender.InvalidCallCount.selector, 0));
        s.request(BNB, 300_000, 1, _noCalls());
        CCIPGovernancePayload.Call[] memory nine = new CCIPGovernancePayload.Call[](9);
        vm.prank(address(l1));
        vm.expectRevert(abi.encodeWithSelector(CCIPGovernanceSender.InvalidCallCount.selector, 9));
        s.request(BNB, 300_000, 1, nine);
    }

    function test_request_staticChecks() public {
        vm.startPrank(BOOT);
        vm.expectRevert(abi.encodeWithSelector(CCIPGovernanceSender.UnknownDestination.selector, uint64(1)));
        s.request(1, 300_000, 1, _noCalls());
        vm.expectRevert(abi.encodeWithSelector(CCIPGovernanceSender.InvalidGasLimit.selector, uint32(99_999)));
        s.request(BNB, 99_999, 1, _noCalls());
        vm.expectRevert(abi.encodeWithSelector(CCIPGovernanceSender.InvalidGasLimit.selector, uint32(1_000_001)));
        s.request(BNB, 1_000_001, 1, _noCalls());
        s.request(BNB, 100_000, 0, _noCalls());
        s.request(BNB, 1_000_000, type(uint64).max, _noCalls());
        vm.stopPrank();
    }

    /// C5: `request` never reverts on valid static input, whatever the router, RMN or fee state is. The router is
    /// replaced with code that reverts on every call, and the sender's ETH balance is arbitrary.
    function testFuzz_request_ignoresRouterState(
        uint32 gas,
        uint64 deadline,
        bool monad,
        uint8 n,
        bytes calldata junk,
        uint256 bal
    ) public {
        vm.prank(BOOT);
        s.handoff();
        vm.etch(address(router), hex"60006000fd"); // revert(0,0) on any call
        vm.deal(address(s), bal);
        vm.warp(uint256(deadline) + 1); // deadline already in the past: still accepted here
        gas = uint32(bound(gas, 100_000, 1_000_000));
        n = uint8(bound(n, 1, 8));
        CCIPGovernancePayload.Call[] memory calls = new CCIPGovernancePayload.Call[](n);
        for (uint256 i = 0; i < n; i++) {
            calls[i] = CCIPGovernancePayload.Call(address(uint160(i + 1)), junk);
        }
        (bytes32 id, bytes memory p) = _governorRequest(monad ? MONAD : BNB, gas, deadline, calls);
        assertEq(id, keccak256(p));
        assertEq(l1.currentNonce(), 1);
    }

    function testFuzz_bootstrapRequest_ignoresRouterState(uint32 gas, uint64 deadline) public {
        vm.etch(address(router), hex"60006000fd");
        gas = uint32(bound(gas, 100_000, 1_000_000));
        vm.prank(BOOT);
        s.request(MONAD, gas, deadline, _noCalls());
    }

    // ---------------------------------------------------------------- out-of-gas retry on the L1 proxy (C6)

    function test_l1ProxyExecute_outOfGas_isRetryable() public {
        vm.prank(BOOT);
        s.handoff();
        bytes memory data = abi.encodeCall(CCIPGovernanceSender.request, (BNB, 300_000, 2_000_000_000, _calls()));
        messaging.setMessageCount(L2_OWNER, l1.getPayload(address(s), 0, 0, data), 1);
        (bool ok,) = address(l1).call{gas: 60_000}(abi.encodeCall(StarknetOwnerProxy.execute, (address(s), 0, 0, data)));
        assertFalse(ok, "should run out of gas");
        assertEq(l1.currentNonce(), 0, "nonce unchanged");
        assertEq(s.nextOpId(BNB), 0);
        l1.execute(address(s), 0, 0, data);
        assertEq(l1.currentNonce(), 1);
        assertEq(s.nextOpId(BNB), 1);
    }

    // ---------------------------------------------------------------- dispatch (exact fee, refund, once)

    function test_dispatch_exactFee_refund_once() public {
        (bytes32 id, bytes memory p) = _ping(BNB);
        router.setFee(1234);
        address payer = makeAddr("payer");
        vm.deal(payer, 1 ether);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(CCIPGovernanceSender.InsufficientFee.selector, 1234, 1233));
        s.dispatch{value: 1233}(p);

        vm.recordLogs();
        vm.prank(payer);
        bytes32 mid = s.dispatch{value: 1 ether}(p);
        assertEq(router.received(), 1234, "router receives exactly the fee");
        assertEq(payer.balance, 1 ether - 1234, "excess refunded");
        assertEq(address(s).balance, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[0], CCIPGovernanceSender.Dispatched.selector);
        assertEq(logs[0].topics[1], id);
        assertEq(logs[0].topics[3], mid);

        MockCCIPRouter.Sent memory sent = router.lastSent();
        assertEq(sent.dest, BNB);
        assertEq(sent.receiver, abi.encode(E_BNB));
        assertEq(sent.data, p);
        assertEq(sent.tokenCount, 0);
        assertEq(sent.feeToken, address(0));
        assertEq(sent.extraArgs, hex"a69dd4aa000493e00000000000000000000000");
        assertEq(sent.value, 1234);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(CCIPGovernanceSender.NotPending.selector, id));
        s.dispatch{value: 1234}(p);
        vm.expectRevert(abi.encodeWithSelector(CCIPGovernanceSender.NotPending.selector, keccak256("x")));
        s.dispatch("x");
    }

    function test_extraArgs_layout() public view {
        bytes memory e = s.extraArgs(500_000);
        assertEq(e.length, 19);
        assertEq(e, abi.encodePacked(bytes4(0xa69dd4aa), uint32(500_000), bytes4(0), bytes7(0)));
    }

    function test_dispatch_routerFailure_staysPending_retry() public {
        (bytes32 id, bytes memory p) = _ping(MONAD);
        router.setSendReverts(true);
        vm.expectRevert(MockCCIPRouter.Cursed.selector);
        s.dispatch(p);
        router.setSendReverts(false);
        router.setFeeReverts(true);
        vm.expectRevert(MockCCIPRouter.Cursed.selector);
        s.dispatch(p);
        (CCIPGovernanceSender.RequestStatus st,,) = s.requests(id);
        assertEq(uint8(st), 1);
        router.setFeeReverts(false);
        s.dispatch(p); // fee 0, anyone
        (st,,) = s.requests(id);
        assertEq(uint8(st), 2);
    }

    function test_dispatch_refundReentry_blocked() public {
        (, bytes memory p1) = _ping(BNB);
        (, bytes memory p2) = _ping(BNB);
        router.setFee(10);
        ReentrantPayer payer = new ReentrantPayer(s);
        vm.deal(address(payer), 1 ether);
        bytes[3] memory reentries = [
            abi.encodeCall(CCIPGovernanceSender.dispatch, (p2)),
            abi.encodeCall(CCIPGovernanceSender.request, (BNB, 300_000, 1, _noCalls())),
            abi.encodeCall(CCIPGovernanceSender.handoff, ())
        ];
        // Re-entering any entry point during the refund hits the guard; the outer dispatch still completes.
        payer.arm(reentries[0]);
        vm.deal(address(this), 1 ether);
        payer.pay{value: 100}(p1);
        assertTrue(payer.reverted());
        assertEq(payer.err(), abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector));
        for (uint256 i = 1; i < 3; i++) {
            (, bytes memory p) = _ping(BNB);
            payer.arm(reentries[i]);
            payer.pay{value: 100}(p);
            assertTrue(payer.reverted());
            assertEq(payer.err(), abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector));
        }
        assertEq(s.authority(), BOOT);
        (CCIPGovernanceSender.RequestStatus st,,) = s.requests(keccak256(p2));
        assertEq(uint8(st), 1, "p2 untouched");

        // A refund recipient that rejects ETH makes the whole dispatch revert; the request stays pending.
        payer.setRejectRefund(true);
        vm.expectRevert(CCIPGovernanceSender.RefundFailed.selector);
        payer.pay{value: 100}(p2);
        (st,,) = s.requests(keccak256(p2));
        assertEq(uint8(st), 1);
        // Exact payment needs no refund and succeeds.
        payer.pay{value: 10}(p2);
    }

    function test_noReceive_noOwner() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(s).call{value: 1}("");
        assertFalse(ok);
        (ok,) = address(s).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(s).call(abi.encodeWithSignature("transferOwnership(address)", address(this)));
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- constructor

    function test_constructor_checks() public {
        CCIPGovernanceSender.Destination memory b = CCIPGovernanceSender.Destination(BNB, 56, E_BNB);
        CCIPGovernanceSender.Destination memory m = CCIPGovernanceSender.Destination(MONAD, 143, E_MONAD);
        IRouterClient r = IRouterClient(address(router));
        _ctor(0, IRouterClient(address(0x1)), address(l1), BOOT, b, m, 1_000_000);
        _ctor(1, r, address(0x1), BOOT, b, m, 1_000_000);
        _ctor(2, r, address(l1), address(0), b, m, 1_000_000);
        _ctor(2, r, address(l1), address(l1), b, m, 1_000_000);
        _ctor(3, r, address(l1), BOOT, CCIPGovernanceSender.Destination(0, 56, E_BNB), m, 1_000_000);
        _ctor(
            3, r, address(l1), BOOT, CCIPGovernanceSender.Destination(BNB, uint64(block.chainid), E_BNB), m, 1_000_000
        );
        _ctor(3, r, address(l1), BOOT, CCIPGovernanceSender.Destination(BNB, 56, address(0)), m, 1_000_000);
        _ctor(4, r, address(l1), BOOT, b, b, 1_000_000);
        _ctor(4, r, address(l1), BOOT, b, CCIPGovernanceSender.Destination(MONAD, 56, E_MONAD), 1_000_000);
        _ctor(5, r, address(l1), BOOT, b, m, 99_999);
        _ctor(5, r, address(l1), BOOT, b, m, 3_000_001);
        (CCIPGovernanceSender.Destination memory d0, CCIPGovernanceSender.Destination memory d1) = s.destinations();
        assertEq(d0.executor, E_BNB);
        assertEq(d1.chainId, 143);
    }

    function _ctor(
        uint256 idx,
        IRouterClient r,
        address fa,
        address boot,
        CCIPGovernanceSender.Destination memory a,
        CCIPGovernanceSender.Destination memory b,
        uint32 g
    ) internal {
        vm.expectRevert(abi.encodeWithSelector(CCIPGovernanceSender.InvalidConstructorArgument.selector, idx));
        new CCIPGovernanceSender(r, fa, boot, a, b, g);
    }
}
