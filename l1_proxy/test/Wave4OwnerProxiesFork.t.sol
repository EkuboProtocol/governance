// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {BridgedOwnerProxy} from "../src/BridgedOwnerProxy.sol";
import {AMBOwnerProxy, IAMB} from "../src/AMBOwnerProxy.sol";
import {FxPortalOwnerProxy} from "../src/FxPortalOwnerProxy.sol";

interface IOwnable {
    function owner() external view returns (address);
    function requestOwnershipHandover() external payable;
    function completeOwnershipHandover(address pendingOwner) external payable;
    function transferOwnership(address newOwner) external payable;
    function ownershipHandoverExpiresAt(address pendingOwner) external view returns (uint256);
}

interface IForeignAMB {
    function requireToPassMessage(address contract_, bytes calldata data, uint256 gas) external returns (bytes32);
}

interface IHomeAMB {
    function executeAffirmation(bytes calldata message) external;
    function messageCallStatus(bytes32 messageId) external view returns (bool);
    function validatorContract() external view returns (address);
    function requiredSignatures() external view returns (uint256);
}

interface IValidatorSet {
    function validatorList() external view returns (address[] memory);
}

interface IFxRoot {
    function sendMessageToChild(address receiver, bytes calldata data) external;
}

interface IStateReceiver {
    function lastStateId() external view returns (uint256);
    function commitState(uint256 syncTime, bytes calldata recordBytes) external returns (bool);
    function replayFailedStateSync(uint256 stateId) external;
    function failedStateSyncs(uint256 stateId) external view returns (bytes memory);
}

/// @notice End-to-end fork tests: the Ethereum leg runs from the live L1 proxy through the live ForeignAMB / FxRoot,
///         and the emitted bridge payload is delivered on Gnosis / Polygon through the live HomeAMB (affirmed by the
///         live validator set, impersonated) / StateReceiver -> FxChild (system call, impersonated).
/// @dev Needs ETH_RPC_URL, GNOSIS_RPC_URL and POLYGON_RPC_URL; skipped otherwise. Optional *_FORK_BLOCK pins.
contract Wave4OwnerProxiesForkTest is Test {
    address constant L1_PROXY = 0x1E0EF4162e42C9bF820c307218c4E41cCcA6E9CC;
    address constant COMPANY_KEY = 0x00000C771F6176268D5A9846E0956C3eF58597A1;
    // Positions 192-bit v3.2.0 and Orders 192-bit v3.2.0, same address on Gnosis and Polygon.
    address constant POSITIONS = 0xA2971E0C37cFdb13aE8440A0C94Ef1A1af39e326;
    address constant ORDERS = 0x9bB520B6192F71ec3D015C8a74F914f9c94bF794;

    address constant FOREIGN_AMB = 0x4C36d2919e407f0Cc2Ee3c993ccF8ac26d9CE64e;
    address constant HOME_AMB = 0x75Df5AF045d91108662D8080fD1FEFAd6aA0bb59;
    uint256 constant AMB_GAS = 500_000;

    address constant FX_ROOT = 0xfe5e5D361b2ad62c541bAb87C45a0B9B018389a2;
    address constant STATE_SENDER = 0x28e4F3a7f651294B9564800b2D01f35189A5bFbE;
    address constant FX_CHILD = 0x8397259c983751DAf40400790063935a11afa28a;
    address constant STATE_RECEIVER = 0x0000000000000000000000000000000000001001;
    address constant BOR_SYSTEM = 0xffffFFFfFFffffffffffffffFfFFFfffFFFfFFfE;

    bytes32 constant USER_REQUEST_FOR_AFFIRMATION = keccak256("UserRequestForAffirmation(bytes32,bytes)");
    bytes32 constant STATE_SYNCED = keccak256("StateSynced(uint256,address,bytes)");
    bytes32 constant HANDOVER_REQUESTED = keccak256("OwnershipHandoverRequested(address)");

    uint256 ethFork;
    uint256 gnosisFork;
    uint256 polygonFork;

    function setUp() public {
        string memory eth = vm.envOr("ETH_RPC_URL", string(""));
        string memory gno = vm.envOr("GNOSIS_RPC_URL", string(""));
        string memory pol = vm.envOr("POLYGON_RPC_URL", string(""));
        if (bytes(eth).length == 0 || bytes(gno).length == 0 || bytes(pol).length == 0) {
            vm.skip(true);
            return;
        }
        ethFork = _fork(eth, "ETH_FORK_BLOCK");
        gnosisFork = _fork(gno, "GNOSIS_FORK_BLOCK");
        polygonFork = _fork(pol, "POLYGON_FORK_BLOCK");
    }

    function _fork(string memory url, string memory blockVar) internal returns (uint256) {
        uint256 b = vm.envOr(blockVar, uint256(0));
        return b == 0 ? vm.createFork(url) : vm.createFork(url, b);
    }

    function _handoverCalls() internal pure returns (BridgedOwnerProxy.Call[] memory calls) {
        calls = new BridgedOwnerProxy.Call[](2);
        calls[0] = BridgedOwnerProxy.Call(POSITIONS, 0, abi.encodeCall(IOwnable.requestOwnershipHandover, ()));
        calls[1] = BridgedOwnerProxy.Call(ORDERS, 0, abi.encodeCall(IOwnable.requestOwnershipHandover, ()));
    }

    function _assertHandoverRequested(Vm.Log[] memory logs, address target, address pending) internal pure {
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == target && logs[i].topics.length == 2 && logs[i].topics[0] == HANDOVER_REQUESTED
                    && logs[i].topics[1] == bytes32(uint256(uint160(pending)))
            ) return;
        }
        revert("OwnershipHandoverRequested(proxy) not emitted");
    }

    function _completeAndCheck(address proxy) internal {
        assertEq(IOwnable(POSITIONS).owner(), COMPANY_KEY);
        assertEq(IOwnable(ORDERS).owner(), COMPANY_KEY);
        assertGt(IOwnable(POSITIONS).ownershipHandoverExpiresAt(proxy), block.timestamp);
        assertGt(IOwnable(ORDERS).ownershipHandoverExpiresAt(proxy), block.timestamp);
        // R5: the company key completes only after observing the request event.
        vm.startPrank(COMPANY_KEY);
        IOwnable(POSITIONS).completeOwnershipHandover(proxy);
        IOwnable(ORDERS).completeOwnershipHandover(proxy);
        vm.stopPrank();
        assertEq(IOwnable(POSITIONS).owner(), proxy);
        assertEq(IOwnable(ORDERS).owner(), proxy);
    }

    // ---------------------------------------------------------------- Gnosis AMB

    function _ambSend(address proxy, BridgedOwnerProxy.Call[] memory calls) internal returns (bytes memory encoded) {
        vm.selectFork(ethFork);
        assertEq(L1_PROXY.code.length > 0, true);
        bytes memory data = abi.encodeCall(
            IForeignAMB.requireToPassMessage, (proxy, abi.encodeCall(AMBOwnerProxy.executeBatch, (calls)), AMB_GAS)
        );
        vm.recordLogs();
        vm.prank(L1_PROXY);
        uint256 g = gasleft();
        (bool ok,) = FOREIGN_AMB.call(data);
        g -= gasleft();
        assertTrue(ok, "requireToPassMessage");
        emit log_named_uint("eth: requireToPassMessage gas (incl. call overhead)", g);
        emit log_named_bytes("eth: L1 proxy -> ForeignAMB calldata", data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == FOREIGN_AMB && logs[i].topics[0] == USER_REQUEST_FOR_AFFIRMATION) {
                return abi.decode(logs[i].data, (bytes));
            }
        }
        revert("no UserRequestForAffirmation");
    }

    function _ambAffirm(bytes memory encoded) internal returns (Vm.Log[] memory logs) {
        vm.selectFork(gnosisFork);
        address[] memory validators = IValidatorSet(IHomeAMB(HOME_AMB).validatorContract()).validatorList();
        uint256 required = IHomeAMB(HOME_AMB).requiredSignatures();
        vm.recordLogs();
        for (uint256 i = 0; i < required; i++) {
            vm.prank(validators[i]);
            uint256 g = gasleft();
            IHomeAMB(HOME_AMB).executeAffirmation(encoded);
            if (i + 1 == required) emit log_named_uint("gnosis: final executeAffirmation gas", g - gasleft());
        }
        logs = vm.getRecordedLogs();
    }

    function test_fork_gnosis_amb_handover_end_to_end() public {
        vm.selectFork(gnosisFork);
        assertEq(L1_PROXY.code.length, 0, "R4: l1Owner must have no code on Gnosis");
        AMBOwnerProxy proxy = new AMBOwnerProxy(L1_PROXY, IAMB(HOME_AMB), 1);

        bytes memory encoded = _ambSend(address(proxy), _handoverCalls());
        bytes32 messageId;
        assembly ("memory-safe") {
            messageId := mload(add(encoded, 32))
        }

        Vm.Log[] memory logs = _ambAffirm(encoded);
        assertTrue(IHomeAMB(HOME_AMB).messageCallStatus(messageId), "AMB call status");
        _assertHandoverRequested(logs, POSITIONS, address(proxy));
        _assertHandoverRequested(logs, ORDERS, address(proxy));
        _completeAndCheck(address(proxy));

        // Migration path (R1): the proxy moves the targets' ownership, never its own.
        AMBOwnerProxy next = new AMBOwnerProxy(L1_PROXY, IAMB(HOME_AMB), 1);
        BridgedOwnerProxy.Call[] memory calls = new BridgedOwnerProxy.Call[](2);
        calls[0] = BridgedOwnerProxy.Call(POSITIONS, 0, abi.encodeCall(IOwnable.transferOwnership, (address(next))));
        calls[1] = BridgedOwnerProxy.Call(ORDERS, 0, abi.encodeCall(IOwnable.transferOwnership, (address(next))));
        _ambAffirm(_ambSend(address(proxy), calls));
        vm.selectFork(gnosisFork);
        assertEq(IOwnable(POSITIONS).owner(), address(next));
        assertEq(IOwnable(ORDERS).owner(), address(next));
    }

    function test_fork_gnosis_amb_failed_message_is_final_and_batch_atomic() public {
        vm.selectFork(gnosisFork);
        AMBOwnerProxy proxy = new AMBOwnerProxy(L1_PROXY, IAMB(HOME_AMB), 1);
        // Second call fails (the proxy does not own Positions), so the first must not land either.
        BridgedOwnerProxy.Call[] memory calls = new BridgedOwnerProxy.Call[](2);
        calls[0] = BridgedOwnerProxy.Call(ORDERS, 0, abi.encodeCall(IOwnable.requestOwnershipHandover, ()));
        calls[1] = BridgedOwnerProxy.Call(POSITIONS, 0, abi.encodeCall(IOwnable.transferOwnership, (address(1))));
        bytes memory encoded = _ambSend(address(proxy), calls);
        bytes32 messageId;
        assembly ("memory-safe") {
            messageId := mload(add(encoded, 32))
        }
        _ambAffirm(encoded);
        assertFalse(IHomeAMB(HOME_AMB).messageCallStatus(messageId));
        assertEq(IOwnable(ORDERS).ownershipHandoverExpiresAt(address(proxy)), 0);

        // The same message cannot be executed again, by any validator.
        address[] memory validators = IValidatorSet(IHomeAMB(HOME_AMB).validatorContract()).validatorList();
        for (uint256 i = 0; i < validators.length; i++) {
            vm.prank(validators[i]);
            (bool ok,) = HOME_AMB.call(abi.encodeCall(IHomeAMB.executeAffirmation, (encoded)));
            assertFalse(ok);
        }
        assertEq(IOwnable(ORDERS).ownershipHandoverExpiresAt(address(proxy)), 0);
    }

    function test_fork_gnosis_amb_rejects_other_ethereum_sender() public {
        vm.selectFork(gnosisFork);
        AMBOwnerProxy proxy = new AMBOwnerProxy(L1_PROXY, IAMB(HOME_AMB), 1);
        vm.selectFork(ethFork);
        vm.recordLogs();
        vm.prank(address(0xBAD));
        IForeignAMB(FOREIGN_AMB)
            .requireToPassMessage(
                address(proxy), abi.encodeCall(AMBOwnerProxy.executeBatch, (_handoverCalls())), AMB_GAS
            );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory encoded;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == FOREIGN_AMB && logs[i].topics[0] == USER_REQUEST_FOR_AFFIRMATION) {
                encoded = abi.decode(logs[i].data, (bytes));
            }
        }
        _ambAffirm(encoded);
        assertEq(IOwnable(POSITIONS).ownershipHandoverExpiresAt(address(proxy)), 0);
        assertEq(IOwnable(ORDERS).ownershipHandoverExpiresAt(address(proxy)), 0);
    }

    // ---------------------------------------------------------------- Polygon FxPortal

    /// @return stateData the StateSender payload (abi.encode(rootMessageSender, receiver, message)).
    function _fxSend(address sender, address proxy, BridgedOwnerProxy.Call[] memory calls, uint64 deadline)
        internal
        returns (bytes memory stateData)
    {
        vm.selectFork(ethFork);
        bytes memory data = abi.encodeCall(IFxRoot.sendMessageToChild, (proxy, abi.encode(calls, deadline)));
        vm.recordLogs();
        vm.prank(sender);
        uint256 g = gasleft();
        (bool ok,) = FX_ROOT.call(data);
        g -= gasleft();
        assertTrue(ok, "sendMessageToChild");
        if (sender == L1_PROXY) {
            emit log_named_uint("eth: sendMessageToChild gas (incl. call overhead)", g);
            emit log_named_bytes("eth: L1 proxy -> FxRoot calldata", data);
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == STATE_SENDER && logs[i].topics[0] == STATE_SYNCED) {
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(FX_CHILD))));
                return abi.decode(logs[i].data, (bytes));
            }
        }
        revert("no StateSynced");
    }

    /// @dev Commits the next state sync on Polygon exactly as Bor does (system call into StateReceiver).
    function _fxCommit(bytes memory stateData) internal returns (uint256 stateId, bool success, Vm.Log[] memory logs) {
        vm.selectFork(polygonFork);
        stateId = IStateReceiver(STATE_RECEIVER).lastStateId() + 1;
        bytes memory record = _rlpList3(_rlpUint(stateId), _rlpAddress(FX_CHILD), _rlpBytes(stateData));
        vm.recordLogs();
        vm.prank(BOR_SYSTEM);
        success = IStateReceiver(STATE_RECEIVER).commitState(block.timestamp, record);
        logs = vm.getRecordedLogs();
    }

    function test_fork_polygon_fx_handover_end_to_end() public {
        vm.selectFork(polygonFork);
        assertEq(L1_PROXY.code.length, 0, "R4: l1Owner must have no code on Polygon");
        FxPortalOwnerProxy proxy = new FxPortalOwnerProxy(L1_PROXY, FX_CHILD);
        vm.deal(address(proxy), 0); // the test deployer's CREATE address holds POL on mainnet
        uint64 deadline = uint64(block.timestamp + 7 days);

        (uint256 id, bool success, Vm.Log[] memory logs) =
            _fxCommit(_fxSend(L1_PROXY, address(proxy), _handoverCalls(), deadline));
        assertTrue(success, "state sync");
        assertEq(proxy.lastStateId(), id);
        _assertHandoverRequested(logs, POSITIONS, address(proxy));
        _assertHandoverRequested(logs, ORDERS, address(proxy));
        _completeAndCheck(address(proxy));

        // Migration path (R1).
        FxPortalOwnerProxy next = new FxPortalOwnerProxy(L1_PROXY, FX_CHILD);
        BridgedOwnerProxy.Call[] memory calls = new BridgedOwnerProxy.Call[](2);
        calls[0] = BridgedOwnerProxy.Call(POSITIONS, 0, abi.encodeCall(IOwnable.transferOwnership, (address(next))));
        calls[1] = BridgedOwnerProxy.Call(ORDERS, 0, abi.encodeCall(IOwnable.transferOwnership, (address(next))));
        (, success,) = _fxCommit(_fxSend(L1_PROXY, address(proxy), calls, deadline));
        assertTrue(success);
        assertEq(IOwnable(POSITIONS).owner(), address(next));
        assertEq(IOwnable(ORDERS).owner(), address(next));
    }

    function test_fork_polygon_fx_rejects_other_ethereum_sender() public {
        vm.selectFork(polygonFork);
        FxPortalOwnerProxy proxy = new FxPortalOwnerProxy(L1_PROXY, FX_CHILD);
        (uint256 id, bool success,) =
            _fxCommit(_fxSend(address(0xBAD), address(proxy), _handoverCalls(), uint64(block.timestamp + 1 days)));
        assertFalse(success);
        assertEq(proxy.lastStateId(), 0);
        assertEq(IOwnable(POSITIONS).ownershipHandoverExpiresAt(address(proxy)), 0);
        // Stored by StateReceiver, but a replay fails the same way.
        vm.expectRevert(BridgedOwnerProxy.Unauthorized.selector);
        IStateReceiver(STATE_RECEIVER).replayFailedStateSync(id);
    }

    /// R3: a failed sync is stored (PIP-36) and an in-order replay before the deadline succeeds.
    function test_fork_polygon_fx_in_order_replay_before_deadline() public {
        vm.selectFork(polygonFork);
        FxPortalOwnerProxy proxy = new FxPortalOwnerProxy(L1_PROXY, FX_CHILD);
        vm.deal(address(proxy), 0); // the test deployer's CREATE address holds POL on mainnet
        uint64 deadline = uint64(block.timestamp + 7 days);
        BridgedOwnerProxy.Call[] memory calls = new BridgedOwnerProxy.Call[](3);
        calls[0] = _handoverCalls()[0];
        calls[1] = _handoverCalls()[1];
        calls[2] = BridgedOwnerProxy.Call(address(0xFEE), 1, ""); // fails: the proxy holds no POL yet
        (uint256 id, bool success,) = _fxCommit(_fxSend(L1_PROXY, address(proxy), calls, deadline));
        assertFalse(success);
        assertGt(IStateReceiver(STATE_RECEIVER).failedStateSyncs(id).length, 0);
        assertEq(IOwnable(POSITIONS).ownershipHandoverExpiresAt(address(proxy)), 0);

        vm.deal(address(proxy), 1);
        vm.warp(deadline);
        vm.recordLogs();
        vm.prank(address(0xA11CE)); // anyone
        IStateReceiver(STATE_RECEIVER).replayFailedStateSync(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertHandoverRequested(logs, POSITIONS, address(proxy));
        _assertHandoverRequested(logs, ORDERS, address(proxy));
        assertEq(proxy.lastStateId(), id);
    }

    function test_fork_polygon_fx_replay_after_deadline_fails() public {
        vm.selectFork(polygonFork);
        FxPortalOwnerProxy proxy = new FxPortalOwnerProxy(L1_PROXY, FX_CHILD);
        vm.deal(address(proxy), 0); // the test deployer's CREATE address holds POL on mainnet
        uint64 deadline = uint64(block.timestamp + 7 days);
        BridgedOwnerProxy.Call[] memory calls = new BridgedOwnerProxy.Call[](1);
        calls[0] = BridgedOwnerProxy.Call(address(0xFEE), 1, "");
        (uint256 id, bool success,) = _fxCommit(_fxSend(L1_PROXY, address(proxy), calls, deadline));
        assertFalse(success);
        vm.deal(address(proxy), 1);
        vm.warp(uint256(deadline) + 1);
        vm.expectRevert(abi.encodeWithSelector(FxPortalOwnerProxy.Expired.selector, deadline));
        IStateReceiver(STATE_RECEIVER).replayFailedStateSync(id);
    }

    /// R3 / CSO F1: after a newer message executes, the replay of an older stored failure is rejected.
    function test_fork_polygon_fx_stale_replay_rejected() public {
        vm.selectFork(polygonFork);
        FxPortalOwnerProxy proxy = new FxPortalOwnerProxy(L1_PROXY, FX_CHILD);
        vm.deal(address(proxy), 0); // the test deployer's CREATE address holds POL on mainnet
        uint64 deadline = uint64(block.timestamp + 7 days);
        BridgedOwnerProxy.Call[] memory stale = new BridgedOwnerProxy.Call[](1);
        stale[0] = BridgedOwnerProxy.Call(address(0xFEE), 1, "");
        (uint256 staleId, bool success,) = _fxCommit(_fxSend(L1_PROXY, address(proxy), stale, deadline));
        assertFalse(success);

        (uint256 newId, bool success2,) = _fxCommit(_fxSend(L1_PROXY, address(proxy), _handoverCalls(), deadline));
        assertTrue(success2);
        assertEq(proxy.lastStateId(), newId);

        vm.deal(address(proxy), 1);
        vm.expectRevert(abi.encodeWithSelector(FxPortalOwnerProxy.StaleStateId.selector, staleId, newId));
        IStateReceiver(STATE_RECEIVER).replayFailedStateSync(staleId);
        assertEq(address(0xFEE).balance, 0);
    }

    // ---------------------------------------------------------------- RLP (only what StateReceiver parses)

    function _rlpLength(uint256 len, uint8 offset) internal pure returns (bytes memory) {
        if (len < 56) return abi.encodePacked(uint8(offset + len));
        uint256 n;
        for (uint256 l = len; l != 0; l >>= 8) {
            n++;
        }
        bytes memory b = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            b[i] = bytes1(uint8(len >> (8 * (n - 1 - i))));
        }
        return abi.encodePacked(uint8(offset + 55 + n), b);
    }

    function _rlpBytes(bytes memory b) internal pure returns (bytes memory) {
        if (b.length == 1 && uint8(b[0]) < 0x80) return b;
        return abi.encodePacked(_rlpLength(b.length, 0x80), b);
    }

    function _rlpUint(uint256 x) internal pure returns (bytes memory) {
        uint256 n;
        for (uint256 v = x; v != 0; v >>= 8) {
            n++;
        }
        bytes memory b = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            b[i] = bytes1(uint8(x >> (8 * (n - 1 - i))));
        }
        return _rlpBytes(b);
    }

    function _rlpAddress(address a) internal pure returns (bytes memory) {
        return _rlpBytes(abi.encodePacked(a));
    }

    function _rlpList3(bytes memory a, bytes memory b, bytes memory c) internal pure returns (bytes memory) {
        bytes memory body = abi.encodePacked(a, b, c);
        return abi.encodePacked(_rlpLength(body.length, 0xc0), body);
    }
}
