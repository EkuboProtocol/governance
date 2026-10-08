// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {L1L2OwnerProxy} from "../src/L1L2OwnerProxy.sol";
import {AMBOwnerProxy, IAMB} from "../src/AMBOwnerProxy.sol";
import {FxPortalOwnerProxy} from "../src/FxPortalOwnerProxy.sol";
import {WormholeOwnerProxy, IWormhole} from "../src/WormholeOwnerProxy.sol";

contract Target {
    uint256 public x;

    function setX(uint256 _x) external payable returns (uint256) {
        x = _x;
        return _x + 1;
    }
}

contract MockAMB is IAMB {
    address public messageSender;
    bytes32 public messageSourceChainId;

    function deliver(address sender, uint256 srcChain, address to, bytes calldata data) external {
        messageSender = sender;
        messageSourceChainId = bytes32(srcChain);
        (bool ok, bytes memory r) = to.call(data);
        messageSender = address(0);
        messageSourceChainId = 0;
        if (!ok) assembly ("memory-safe") { revert(add(r, 32), mload(r)) }
    }
}

contract MockWormhole {
    mapping(bytes32 => IWormhole.VM) internal vms;

    function store(IWormhole.VM memory vm) external returns (bytes memory encoded) {
        encoded = abi.encode(vm.hash);
        IWormhole.VM storage s = vms[vm.hash];
        s.emitterChainId = vm.emitterChainId;
        s.emitterAddress = vm.emitterAddress;
        s.sequence = vm.sequence;
        s.consistencyLevel = vm.consistencyLevel;
        s.payload = vm.payload;
        s.hash = vm.hash;
    }

    function parseAndVerifyVM(bytes calldata encoded) external view returns (IWormhole.VM memory vm, bool, string memory) {
        vm = vms[abi.decode(encoded, (bytes32))];
        return (vm, vm.hash != 0, vm.hash != 0 ? "" : "unknown");
    }
}

contract Wave4OwnerProxiesTest is Test {
    address constant L1 = 0x1E0EF4162e42C9bF820c307218c4E41cCcA6E9CC;
    address constant FX_CHILD = 0x8397259c983751DAf40400790063935a11afa28a;
    Target target;

    function setUp() public {
        target = new Target();
    }

    // ---------------- AMB (Gnosis) ----------------
    function test_amb_executes_from_l1_owner() public {
        MockAMB amb = new MockAMB();
        AMBOwnerProxy p = new AMBOwnerProxy(L1, amb, 1);
        amb.deliver(L1, 1, address(p), abi.encodeCall(L1L2OwnerProxy.execute, (address(target), 0, abi.encodeCall(Target.setX, (7)))));
        assertEq(target.x(), 7);
    }

    function test_amb_rejects_wrong_sender_wrong_chain_and_direct_calls() public {
        MockAMB amb = new MockAMB();
        AMBOwnerProxy p = new AMBOwnerProxy(L1, amb, 1);
        bytes memory m = abi.encodeCall(L1L2OwnerProxy.execute, (address(target), 0, abi.encodeCall(Target.setX, (7))));
        vm.expectRevert(Ownable.Unauthorized.selector);
        amb.deliver(address(0xbad), 1, address(p), m);
        vm.expectRevert(Ownable.Unauthorized.selector);
        amb.deliver(L1, 137, address(p), m);
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(address(amb));
        p.execute(address(target), 0, abi.encodeCall(Target.setX, (7)));
    }

    // ---------------- FxPortal (Polygon) ----------------
    function _fx(FxPortalOwnerProxy p, address sender, address to, bytes memory data, uint64 deadline) internal {
        vm.prank(FX_CHILD);
        p.processMessageFromRoot(1, sender, abi.encode(to, uint256(0), data, deadline));
    }

    function test_fx_executes_and_transfers_ownership() public {
        FxPortalOwnerProxy p = new FxPortalOwnerProxy(L1, FX_CHILD);
        _fx(p, L1, address(target), abi.encodeCall(Target.setX, (9)), uint64(block.timestamp));
        assertEq(target.x(), 9);
        _fx(p, L1, address(p), abi.encodeCall(Ownable.transferOwnership, (address(0xbeef))), uint64(block.timestamp));
        assertEq(p.owner(), address(0xbeef));
    }

    function test_fx_rejects_wrong_caller_sender_and_expired() public {
        FxPortalOwnerProxy p = new FxPortalOwnerProxy(L1, FX_CHILD);
        bytes memory data = abi.encodeCall(Target.setX, (9));
        vm.expectRevert(Ownable.Unauthorized.selector);
        p.processMessageFromRoot(1, L1, abi.encode(address(target), uint256(0), data, uint64(block.timestamp)));
        vm.expectRevert(Ownable.Unauthorized.selector);
        _fx(p, address(0xbad), address(target), data, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(FxPortalOwnerProxy.Expired.selector, uint64(block.timestamp - 1)));
        _fx(p, L1, address(target), data, uint64(block.timestamp - 1));
        vm.expectRevert(Ownable.Unauthorized.selector);
        p.execute(address(target), 0, data);
    }

    // ---------------- Wormhole (BNB / Monad) ----------------
    function _vaa(MockWormhole w, uint16 chain, address emitter, uint64 seq, uint8 cl, uint256 dstChain, address dst, uint256 x)
        internal
        returns (bytes memory)
    {
        IWormhole.VM memory v;
        v.emitterChainId = chain;
        v.emitterAddress = bytes32(uint256(uint160(emitter)));
        v.sequence = seq;
        v.consistencyLevel = cl;
        v.payload = abi.encode(dstChain, dst, address(target), uint256(0), abi.encodeCall(Target.setX, (x)), uint64(block.timestamp));
        v.hash = keccak256(abi.encode(chain, emitter, seq, cl, dstChain, dst, x));
        return w.store(v);
    }

    function test_wormhole_executes_once_in_order() public {
        MockWormhole w = new MockWormhole();
        WormholeOwnerProxy p = new WormholeOwnerProxy(L1, IWormhole(address(w)), 2);
        bytes memory v0 = _vaa(w, 2, L1, 0, 1, block.chainid, address(p), 1);
        bytes memory v1 = _vaa(w, 2, L1, 1, 1, block.chainid, address(p), 2);
        p.receiveMessage(v0);
        assertEq(target.x(), 1);
        vm.expectRevert(abi.encodeWithSelector(WormholeOwnerProxy.StaleSequence.selector, uint64(1), uint64(0)));
        p.receiveMessage(v0);
        p.receiveMessage(v1);
        assertEq(target.x(), 2);
    }

    function test_wormhole_rejects_emitter_finality_and_destination() public {
        MockWormhole w = new MockWormhole();
        WormholeOwnerProxy p = new WormholeOwnerProxy(L1, IWormhole(address(w)), 2);
        bytes memory bad;
        bad = _vaa(w, 4, L1, 0, 1, block.chainid, address(p), 1);
        vm.expectRevert(WormholeOwnerProxy.WrongEmitter.selector);
        p.receiveMessage(bad);
        bad = _vaa(w, 2, address(0xbad), 0, 1, block.chainid, address(p), 1);
        vm.expectRevert(WormholeOwnerProxy.WrongEmitter.selector);
        p.receiveMessage(bad);
        bad = _vaa(w, 2, L1, 0, 200, block.chainid, address(p), 1);
        vm.expectRevert(WormholeOwnerProxy.NotFinalized.selector);
        p.receiveMessage(bad);
        bad = _vaa(w, 2, L1, 0, 1, 143, address(p), 1);
        vm.expectRevert(WormholeOwnerProxy.WrongDestination.selector);
        p.receiveMessage(bad);
        bad = _vaa(w, 2, L1, 0, 1, block.chainid, address(0xdead), 1);
        vm.expectRevert(WormholeOwnerProxy.WrongDestination.selector);
        p.receiveMessage(bad);
    }
}
