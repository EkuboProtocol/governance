// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {BridgedOwnerProxy} from "../src/BridgedOwnerProxy.sol";
import {AMBOwnerProxy, IAMB} from "../src/AMBOwnerProxy.sol";
import {FxPortalOwnerProxy} from "../src/FxPortalOwnerProxy.sol";

contract Lockable {
    uint256 public x;
    uint256 public received;
    bool public locked;
    address public lastCaller;

    function setLocked(bool l) external {
        locked = l;
    }

    function setX(uint256 _x) external payable {
        require(!locked, "locked");
        x = _x;
        received += msg.value;
        lastCaller = msg.sender;
    }
}

contract MockAMB is IAMB {
    address public messageSender;
    bytes32 public messageSourceChainId;
    bytes32 public messageId;

    function deliver(bytes32 id, address sender, uint256 srcChain, address to, bytes calldata data)
        external
        returns (bool ok)
    {
        messageId = id;
        messageSender = sender;
        messageSourceChainId = bytes32(srcChain);
        (ok,) = to.call(data);
        messageId = 0;
        messageSender = address(0);
        messageSourceChainId = 0;
    }
}

abstract contract Wave4Base is Test {
    address constant L1 = 0x1E0EF4162e42C9bF820c307218c4E41cCcA6E9CC;
    address constant FX_CHILD = 0x8397259c983751DAf40400790063935a11afa28a;
    Lockable t;

    function setUp() public virtual {
        t = new Lockable();
    }

    function _one(address target, uint256 value, bytes memory data)
        internal
        pure
        returns (BridgedOwnerProxy.Call[] memory calls)
    {
        calls = new BridgedOwnerProxy.Call[](1);
        calls[0] = BridgedOwnerProxy.Call(target, value, data);
    }

    function _setX(uint256 x) internal view returns (BridgedOwnerProxy.Call[] memory) {
        return _one(address(t), 0, abi.encodeCall(Lockable.setX, (x)));
    }

    function _assertOwnershipImmutable(BridgedOwnerProxy p, address caller) internal {
        vm.startPrank(caller);
        vm.expectRevert(BridgedOwnerProxy.OwnershipImmutable.selector);
        p.transferOwnership(address(0xA11CE));
        vm.expectRevert(BridgedOwnerProxy.OwnershipImmutable.selector);
        p.renounceOwnership();
        vm.expectRevert(BridgedOwnerProxy.OwnershipImmutable.selector);
        p.requestOwnershipHandover();
        vm.expectRevert(BridgedOwnerProxy.OwnershipImmutable.selector);
        p.completeOwnershipHandover(address(0xA11CE));
        vm.expectRevert(BridgedOwnerProxy.OwnershipImmutable.selector);
        p.cancelOwnershipHandover();
        vm.stopPrank();
        assertEq(p.owner(), L1);
        assertEq(p.l1Owner(), L1);
        assertEq(p.ownershipHandoverExpiresAt(caller), 0);
    }
}

contract AMBOwnerProxyTest is Wave4Base {
    MockAMB amb;
    AMBOwnerProxy p;

    function setUp() public override {
        super.setUp();
        amb = new MockAMB();
        p = new AMBOwnerProxy(L1, amb, 1);
    }

    function _deliver(address sender, uint256 src, BridgedOwnerProxy.Call[] memory calls) internal returns (bool) {
        return amb.deliver(keccak256("m"), sender, src, address(p), abi.encodeCall(AMBOwnerProxy.executeBatch, (calls)));
    }

    function test_constructor() public {
        assertEq(address(p.amb()), address(amb));
        assertEq(p.sourceChainId(), bytes32(uint256(1)));
        vm.expectRevert(BridgedOwnerProxy.InvalidL1Owner.selector);
        new AMBOwnerProxy(address(0), amb, 1);
    }

    function test_executes_batch_from_l1_owner() public {
        vm.deal(address(p), 5);
        BridgedOwnerProxy.Call[] memory calls = new BridgedOwnerProxy.Call[](2);
        calls[0] = BridgedOwnerProxy.Call(address(t), 0, abi.encodeCall(Lockable.setX, (7)));
        calls[1] = BridgedOwnerProxy.Call(address(t), 5, abi.encodeCall(Lockable.setX, (8)));
        vm.expectEmit(address(p));
        emit BridgedOwnerProxy.Executed(keccak256("m"), 2);
        assertTrue(_deliver(L1, 1, calls));
        assertEq(t.x(), 8);
        assertEq(t.received(), 5);
        assertEq(t.lastCaller(), address(p));
    }

    function test_batch_is_atomic() public {
        Lockable u = new Lockable();
        u.setLocked(true);
        BridgedOwnerProxy.Call[] memory calls = new BridgedOwnerProxy.Call[](2);
        calls[0] = BridgedOwnerProxy.Call(address(t), 0, abi.encodeCall(Lockable.setX, (7)));
        calls[1] = BridgedOwnerProxy.Call(address(u), 0, abi.encodeCall(Lockable.setX, (8)));
        vm.mockCall(address(amb), abi.encodeCall(IAMB.messageSender, ()), abi.encode(L1));
        vm.mockCall(address(amb), abi.encodeCall(IAMB.messageSourceChainId, ()), abi.encode(bytes32(uint256(1))));
        vm.prank(address(amb));
        vm.expectRevert(
            abi.encodeWithSelector(
                BridgedOwnerProxy.CallFailed.selector, 1, abi.encodeWithSignature("Error(string)", "locked")
            )
        );
        p.executeBatch(calls);
        vm.clearMockedCalls();
        assertFalse(_deliver(L1, 1, calls));
        assertEq(t.x(), 0);
    }

    function test_rejects_wrong_sender_wrong_chain_and_direct_calls() public {
        assertFalse(_deliver(address(0xbad), 1, _setX(1)));
        assertFalse(_deliver(L1, 100, _setX(1)));
        assertFalse(_deliver(L1, 137, _setX(1)));
        // HomeAMB with no message context.
        vm.prank(address(amb));
        vm.expectRevert(BridgedOwnerProxy.Unauthorized.selector);
        p.executeBatch(_setX(1));
        // The L1 owner address calling directly on this chain has no power (no direct-call branch).
        vm.prank(L1);
        vm.expectRevert(BridgedOwnerProxy.Unauthorized.selector);
        p.executeBatch(_setX(1));
        assertEq(t.x(), 0);
    }

    function test_rejects_zero_and_self_target_and_insufficient_balance() public {
        vm.mockCall(address(amb), abi.encodeCall(IAMB.messageSender, ()), abi.encode(L1));
        vm.mockCall(address(amb), abi.encodeCall(IAMB.messageSourceChainId, ()), abi.encode(bytes32(uint256(1))));
        vm.startPrank(address(amb));
        vm.expectRevert(abi.encodeWithSelector(BridgedOwnerProxy.InvalidTarget.selector, 0));
        p.executeBatch(_one(address(0), 0, ""));
        vm.expectRevert(abi.encodeWithSelector(BridgedOwnerProxy.InvalidTarget.selector, 0));
        p.executeBatch(_one(address(p), 0, abi.encodeCall(BridgedOwnerProxy.transferOwnership, (address(1)))));
        vm.expectRevert(abi.encodeWithSelector(BridgedOwnerProxy.InsufficientBalance.selector, 0));
        p.executeBatch(_one(address(t), 1, abi.encodeCall(Lockable.setX, (1))));
        vm.stopPrank();
    }

    function test_ownership_mutators_revert() public {
        _assertOwnershipImmutable(p, L1);
        _assertOwnershipImmutable(p, address(amb));
    }

    // CSO EKU-1047 F2 PoC, adapted: a bridge message can no longer move the proxy's ownership, so no destination-chain
    // address can ever become the identity the bridge check accepts.
    function test_F2_bridge_message_cannot_move_proxy_ownership() public {
        address n = address(0xA11CE);
        assertFalse(_deliver(L1, 1, _one(address(p), 0, abi.encodeCall(BridgedOwnerProxy.transferOwnership, (n)))));
        assertEq(p.owner(), L1);
        assertFalse(_deliver(n, 1, _setX(9)));
        vm.prank(n);
        vm.expectRevert(BridgedOwnerProxy.Unauthorized.selector);
        p.executeBatch(_setX(10));
        assertEq(t.x(), 0);
    }

    function test_receives_native() public {
        (bool ok,) = address(p).call{value: 1}("");
        assertTrue(ok);
        assertEq(address(p).balance, 1);
    }
}

contract FxPortalOwnerProxyTest is Wave4Base {
    FxPortalOwnerProxy p;

    function setUp() public override {
        super.setUp();
        p = new FxPortalOwnerProxy(L1, FX_CHILD);
    }

    function _fx(uint256 stateId, address sender, BridgedOwnerProxy.Call[] memory calls, uint64 deadline)
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.prank(FX_CHILD);
        (ok, ret) = address(p)
            .call(
                abi.encodeCall(
                    FxPortalOwnerProxy.processMessageFromRoot, (stateId, sender, abi.encode(calls, deadline))
                )
            );
    }

    function _ok(uint256 stateId, BridgedOwnerProxy.Call[] memory calls) internal returns (bool ok) {
        (ok,) = _fx(stateId, L1, calls, uint64(block.timestamp + 7 days));
    }

    function test_constructor() public {
        assertEq(p.fxChild(), FX_CHILD);
        assertEq(p.lastStateId(), 0);
        vm.expectRevert(BridgedOwnerProxy.InvalidL1Owner.selector);
        new FxPortalOwnerProxy(address(0), FX_CHILD);
    }

    function test_executes_batch_and_records_state_id() public {
        BridgedOwnerProxy.Call[] memory calls = new BridgedOwnerProxy.Call[](2);
        calls[0] = BridgedOwnerProxy.Call(address(t), 0, abi.encodeCall(Lockable.setX, (7)));
        calls[1] = BridgedOwnerProxy.Call(address(t), 0, abi.encodeCall(Lockable.setX, (8)));
        vm.expectEmit(address(p));
        emit BridgedOwnerProxy.Executed(bytes32(uint256(42)), 2);
        assertTrue(_ok(42, calls));
        assertEq(t.x(), 8);
        assertEq(p.lastStateId(), 42);
        assertEq(t.lastCaller(), address(p));
    }

    function test_deadline_is_inclusive() public {
        (bool ok,) = _fx(1, L1, _setX(1), uint64(block.timestamp));
        assertTrue(ok);
        (, bytes memory ret) = _fx(2, L1, _setX(2), uint64(block.timestamp - 1));
        assertEq(ret, abi.encodeWithSelector(FxPortalOwnerProxy.Expired.selector, uint64(block.timestamp - 1)));
        assertEq(p.lastStateId(), 1);
    }

    function test_rejects_wrong_caller_and_sender() public {
        bytes memory m = abi.encode(_setX(9), uint64(block.timestamp));
        vm.expectRevert(BridgedOwnerProxy.Unauthorized.selector);
        p.processMessageFromRoot(1, L1, m);
        vm.prank(L1);
        vm.expectRevert(BridgedOwnerProxy.Unauthorized.selector);
        p.processMessageFromRoot(1, L1, m);
        (, bytes memory ret) = _fx(1, address(0xbad), _setX(9), uint64(block.timestamp));
        assertEq(ret, abi.encodeWithSelector(BridgedOwnerProxy.Unauthorized.selector));
        assertEq(p.lastStateId(), 0);
        assertEq(t.x(), 0);
    }

    function test_failed_batch_does_not_consume_state_id() public {
        t.setLocked(true);
        assertFalse(_ok(5, _setX(1)));
        assertEq(p.lastStateId(), 0);
    }

    // CSO EKU-1047 F1 PoC, adapted: the stale replay of stateId 100 after 101 executed is now rejected.
    function test_F1_stale_replay_cannot_override_newer_message() public {
        t.setLocked(true);
        assertFalse(_ok(100, _setX(1))); // fails, StateReceiver stores it
        t.setLocked(false);
        assertTrue(_ok(101, _setX(2))); // newer DAO message
        (bool ok, bytes memory ret) = _fx(100, L1, _setX(1), uint64(block.timestamp + 7 days)); // anyone replays 100
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(FxPortalOwnerProxy.StaleStateId.selector, 100, 101));
        assertEq(t.x(), 2);
    }

    // R3: an in-order replay before the deadline succeeds, after the deadline it does not.
    function test_in_order_replay_before_deadline_succeeds() public {
        uint64 dl = uint64(block.timestamp + 7 days);
        t.setLocked(true);
        (bool ok,) = _fx(100, L1, _setX(1), dl);
        assertFalse(ok);
        t.setLocked(false);
        vm.warp(dl);
        (ok,) = _fx(100, L1, _setX(1), dl);
        assertTrue(ok);
        assertEq(t.x(), 1);
        assertEq(p.lastStateId(), 100);
    }

    function test_replay_after_deadline_fails() public {
        uint64 dl = uint64(block.timestamp + 7 days);
        t.setLocked(true);
        (bool ok,) = _fx(100, L1, _setX(1), dl);
        assertFalse(ok);
        t.setLocked(false);
        vm.warp(uint256(dl) + 1);
        (ok,) = _fx(100, L1, _setX(1), dl);
        assertFalse(ok);
        assertEq(t.x(), 0);
    }

    // An empty batch supersedes every stored failure with a lower stateId.
    function test_empty_batch_supersedes_stored_failure() public {
        t.setLocked(true);
        assertFalse(_ok(100, _setX(1)));
        assertTrue(_ok(101, new BridgedOwnerProxy.Call[](0)));
        t.setLocked(false);
        assertFalse(_ok(100, _setX(1)));
        assertEq(t.x(), 0);
    }

    function test_ownership_mutators_revert() public {
        _assertOwnershipImmutable(p, L1);
        _assertOwnershipImmutable(p, FX_CHILD);
        _assertOwnershipImmutable(p, address(p));
    }

    // CSO EKU-1047 F2 PoC, adapted.
    function test_F2_bridge_message_cannot_move_proxy_ownership() public {
        address n = address(0xA11CE);
        assertFalse(_ok(1, _one(address(p), 0, abi.encodeCall(BridgedOwnerProxy.transferOwnership, (n)))));
        assertEq(p.owner(), L1);
        (bool ok,) = _fx(2, n, _setX(9), uint64(block.timestamp));
        assertFalse(ok);
        vm.prank(n);
        vm.expectRevert(BridgedOwnerProxy.Unauthorized.selector);
        p.processMessageFromRoot(3, n, abi.encode(_setX(10), uint64(block.timestamp)));
        assertEq(t.x(), 0);
    }

    /// Property: a delivery executes iff it is authentic, unexpired, its batch succeeds and its stateId exceeds every
    /// stateId executed before; lastStateId is always the maximum executed stateId.
    function testFuzz_state_id_ordering(uint256[8] memory ids, bool[8] memory lockedAt) public {
        uint256 maxExecuted;
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = bound(ids[i], 1, 20);
            t.setLocked(lockedAt[i]);
            bool ok = _ok(id, _setX(id));
            bool expected = id > maxExecuted && !lockedAt[i];
            assertEq(ok, expected);
            if (expected) {
                maxExecuted = id;
                assertEq(t.x(), id);
            }
            assertEq(p.lastStateId(), maxExecuted);
        }
    }
}
