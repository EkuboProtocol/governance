// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {StarknetOwnerProxy, IStarknetMessaging} from "../src/StarknetOwnerProxy.sol";
import {CCIPGovernancePayload} from "../src/CCIPGovernancePayload.sol";
import {CCIPGovernanceSender} from "../src/CCIPGovernanceSender.sol";
import {T2Route} from "../script/t2/T2Route.s.sol";
import {T2DummyTarget} from "../script/t2/T2DummyTarget.sol";

/// @notice EKU-1232 unit tests of the T2 configuration helpers (local EVM only, no fork, no key).
contract T2ConfigTest is Test {
    T2Route r;
    StarknetOwnerProxy proxy;

    /// @dev Fixed vector shared with the Cairo test `governance::t2_l1_message_test` (Starknet hop).
    uint64 constant VECTOR_DEADLINE = 1_792_000_000;
    uint256 constant VECTOR_GOVERNOR = 0x0123200000000000000000000000000000000000000000000000000000001232;

    function setUp() public {
        r = new T2Route();
        proxy = new StarknetOwnerProxy(IStarknetMessaging(address(0x5701)), 1);
    }

    function testFuzz_t2Felts_matchesStarknetOwnerProxy(
        address target,
        uint256 value,
        uint64 nonce,
        bytes calldata data
    ) public view {
        assertEq(
            keccak256(abi.encode(r.t2Felts(target, value, nonce, data))),
            keccak256(abi.encode(proxy.getPayload(target, value, nonce, data)))
        );
    }

    function test_sendMessageToL1Selector() public view {
        // starknet_keccak("send_message_to_l1"), also asserted by the Cairo test against selector!(...).
        assertEq(r.SEND_MESSAGE_TO_L1_SELECTOR(), 0x028148d19de27882118e9b0533def6b88b428328cdcc0b063d75fdc29c907007);
    }

    function test_productionChainsRefused() public {
        uint256[3] memory prod = [uint256(1), 56, 143];
        for (uint256 i = 0; i < 3; i++) {
            vm.chainId(prod[i]);
            vm.expectRevert(abi.encodeWithSignature("NotT2Chain(uint256)", prod[i]));
            r.requireT2Chain();
        }
        vm.chainId(11155111);
        r.requireT2Chain();
        vm.chainId(97);
        r.requireT2Chain();
        vm.chainId(10143);
        r.requireT2Chain();
    }

    function test_placeholdersAndFixturesRefused() public {
        assertTrue(r.isT2Placeholder(0x1232000000000000000000000000000000000d01));
        assertTrue(r.isT2Placeholder(0x00000C771F6176268D5A9846E0956C3eF58597A1), "company key");
        assertTrue(r.isT2Placeholder(0x1E0EF4162e42C9bF820c307218c4E41cCcA6E9CC), "production L1 proxy");
        assertTrue(r.isT2Placeholder(0x29fcB43b46531BcA003ddC8FCB67FFE91900C762), "Safe singleton");
        for (uint256 i = 0; i < 8; i++) {
            assertTrue(r.isT2Placeholder(vm.addr(r.fixtureKey(i))), "fixture");
        }
        assertFalse(r.isT2Placeholder(makeAddr("a-real-looking-test-key")));
    }

    function test_addressPlan_isNoncePlan() public {
        address d = makeAddr("t2-deployer");
        assertEq(r.t2Proxy(d), vm.computeCreateAddress(d, 0));
        assertEq(r.t2Sender(d), vm.computeCreateAddress(d, 1));
        assertEq(r.t2Targets(d, 97).length, 2);
        assertEq(r.t2Targets(d, 10143).length, 4);
        assertEq(r.t2Executor(d, 97), vm.computeCreateAddress(d, 3));
        assertEq(r.t2Executor(d, 10143), vm.computeCreateAddress(d, 5));
    }

    function test_callKinds() public view {
        address[] memory ts = new address[](2);
        ts[0] = address(0xA);
        ts[1] = address(0xB);
        CCIPGovernancePayload.Call[] memory c = r.t2Calls(ts, 0, 0);
        assertEq(c.length, 2);
        assertEq(c[1].data, abi.encodeWithSignature("owner()"));
        c = r.t2Calls(ts, 1, 42);
        assertEq(c[0].data, abi.encodeCall(T2DummyTarget.setValue, (42)));
        c = r.t2Calls(ts, 2, 0);
        assertEq(c.length, 1);
        assertEq(bytes4(c[0].data), T2DummyTarget.note.selector);
        assertEq(c[0].data.length, 4 + 32 + 32 + 14_016); // 14000 bytes padded to 32
    }

    /// The exact L1 message (BNB testnet owner() proof, proxy nonce 0) for the fixture deployer, printed for the
    /// Cairo Starknet-hop test which must emit exactly these felts from the Governor.
    function test_l1MessageVector() public {
        address d = vm.addr(r.fixtureKey(0));
        bytes memory data = abi.encodeCall(
            CCIPGovernanceSender.request,
            (13264668187771770619, 300_000, VECTOR_DEADLINE, r.t2Calls(r.t2Targets(d, 97), 0, 0))
        );
        uint256[] memory felts = r.t2Felts(r.t2Sender(d), 0, 0, data);
        assertEq(felts.length, 20);
        emit log_named_address("VECTOR_PROXY", r.t2Proxy(d));
        emit log_named_uint("VECTOR_FELT_COUNT", felts.length);
        for (uint256 i = 0; i < felts.length; i++) {
            emit log_named_bytes32("VECTOR_FELT", bytes32(felts[i]));
        }
        uint256[] memory call = r.t2StarknetCall(VECTOR_GOVERNOR, r.t2Proxy(d), felts);
        assertEq(call.length, 25);
        assertEq(call[2], 22);
        emit log_named_bytes32("VECTOR_MESSAGE_HASH", r.t2MessageHash(VECTOR_GOVERNOR, r.t2Proxy(d), felts));
    }
}
