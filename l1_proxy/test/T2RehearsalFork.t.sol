// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Client} from "../vendor/ccip-2.0.0/libraries/Client.sol";
import {IRouterClient} from "../vendor/ccip-2.0.0/interfaces/IRouterClient.sol";
import {IRouter} from "../vendor/ccip-2.0.0/interfaces/IRouter.sol";
import {StarknetOwnerProxy, IStarknetMessaging} from "../src/StarknetOwnerProxy.sol";
import {CCIPGovernancePayload} from "../src/CCIPGovernancePayload.sol";
import {CCIPGovernanceSender} from "../src/CCIPGovernanceSender.sol";
import {CCIPOwnerExecutor} from "../src/CCIPOwnerExecutor.sol";
import {CCIPRouteVerifier} from "../script/CCIPRouteVerifier.sol";
import {T2Route} from "../script/t2/T2Route.s.sol";
import {T2DummyTarget} from "../script/t2/T2DummyTarget.sol";
import {ISafeProxyFactory141, ISafe141, IStarknetCoreView} from "../script/t2/T2Config.sol";

/// @notice EKU-1232 local fork REHEARSAL of the T2 testnet pack. Nothing here touches a live network and no real key
///         is used: identities are PUBLIC local fixtures (`T2Config.fixtureKey`), refused by the T2 scripts.
///
///         Evidence classes (labelled per assertion group):
///         - REAL CODE ON A FORK: Sepolia Router 1.2.0 + OnRamp 2.0.0 `getFee`/`ccipSend` with the sender's
///           GenericExtraArgsV3, the real Starknet Sepolia core consuming the message (message INJECTED with vm.store,
///           i.e. SIMULATED Starknet settlement), real Safe 1.4.1 factory/singleton on BNB testnet and Monad testnet.
///         - IMPERSONATED: the registered OffRamp 2.0.0 is pranked to call the real destination Router.routeMessage.
///           No DON, committee verifier, executor service or RMN is involved. This is NOT T2 real delivery; T2 is the
///           funded run this rehearses.
abstract contract T2ForkBase is Test {
    uint16 constant GAS_FOR_CALL_EXACT_CHECK = 5_000;
    uint256 constant L2_GOVERNOR = 0x0123200000000000000000000000000000000000000000000000000000001232;

    T2Route r;
    address deployer;
    address bootstrap;
    address payer;
    uint256[3] ownerKeys;
    address[] owners;

    function _identities() internal {
        r = new T2Route();
        vm.makePersistent(address(r));
        deployer = vm.addr(r.fixtureKey(0));
        bootstrap = vm.addr(r.fixtureKey(1));
        payer = vm.addr(r.fixtureKey(5));
        for (uint256 i = 0; i < 3; i++) {
            ownerKeys[i] = r.fixtureKey(2 + i);
            owners.push(vm.addr(ownerKeys[i]));
        }
        assertTrue(r.isT2Placeholder(deployer) && r.isT2Placeholder(owners[0]), "fixtures are refused by the scripts");
    }

    function _fork(string memory url, string memory blockVar) internal returns (uint256) {
        uint256 b = vm.envOr(blockVar, uint256(0));
        return b == 0 ? vm.createFork(url) : vm.createFork(url, b);
    }

    function _local() internal pure returns (CCIPRouteVerifier.Src memory) {
        return CCIPRouteVerifier.Src("", "");
    }

    /// Destination deployment exactly in the T2 nonce plan: targets, Safe (factory CREATE2), executor.
    function _deployDest(uint256 cid) internal returns (CCIPOwnerExecutor e, address safe) {
        assertEq(vm.getNonce(deployer), 0, "fresh deployer");
        address[] memory ts = r.t2Targets(deployer, cid);
        for (uint256 i = 0; i < ts.length; i++) {
            vm.prank(deployer);
            assertEq(address(new T2DummyTarget(deployer)), ts[i]);
        }
        bytes memory code = ISafeProxyFactory141(0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67).proxyCreationCode();
        safe = r.t2SafeAddress(code, owners, 1232);
        vm.prank(deployer);
        address created = ISafeProxyFactory141(0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67)
            .createProxyWithNonce(0x29fcB43b46531BcA003ddC8FCB67FFE91900C762, r.t2SafeInitializer(owners), 1232);
        assertEq(created, safe, "Safe CREATE2 prediction");
        // On chain this call is a transaction from the deployer and consumes nonce n; a prank does not.
        vm.setNonce(deployer, uint64(vm.getNonce(deployer) + 1));
        r.verifySafe(_local(), r.t2SafeExpect(cid, safe, owners));

        address senderPredicted = r.t2Sender(deployer);
        CCIPRouteVerifier.ExecutorExpect memory x =
            r.t2ExecutorExpect(cid, r.t2Executor(deployer, cid), senderPredicted, safe, ts);
        address router = r.t2Router(cid);
        vm.prank(deployer);
        e = new CCIPOwnerExecutor(router, 16015286601757825753, senderPredicted, 600, 86400, 604800, safe, ts);
        assertEq(address(e), r.t2Executor(deployer, cid), "executor at deployer nonce n+1");
        r.verifyExecutor(_local(), x);
        emit log_named_address("dest: executor", address(e));
        emit log_named_address("dest: canceller Safe (fixture owners)", safe);
    }

    function _route(uint256 cid, address receiver, address senderAddr, bytes32 mid, bytes memory data, uint32 gasLimit)
        internal
        returns (bool ok, bytes memory ret, Vm.Log[] memory logs, uint256 gasUsed)
    {
        address router = r.t2Router(cid);
        address offRamp = r.t2OffRamp(cid);
        assertTrue(IRouter(router).isOffRamp(16015286601757825753, offRamp), "registered OffRamp 2.0.0");
        Client.Any2EVMMessage memory m = Client.Any2EVMMessage({
            messageId: mid,
            sourceChainSelector: 16015286601757825753,
            sender: abi.encode(senderAddr),
            data: data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        vm.recordLogs();
        vm.prank(offRamp);
        (ok, ret, gasUsed) = IRouter(router).routeMessage(m, GAS_FOR_CALL_EXACT_CHECK, gasLimit, receiver);
        logs = vm.getRecordedLogs();
    }

    function _has(Vm.Log[] memory logs, address emitter, bytes32 topic0, bytes32 topic1) internal pure returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic0 && logs[i].topics[1] == topic1) return true;
        }
        return false;
    }

    function _ping(uint256 cid, CCIPOwnerExecutor e, address senderAddr, bytes32 mid, bytes memory p) internal {
        (bool ok, bytes memory ret, Vm.Log[] memory logs, uint256 g) =
            _route(cid, address(e), senderAddr, mid, p, 300_000);
        assertTrue(ok, string(ret));
        assertTrue(_has(logs, address(e), CCIPOwnerExecutor.Pinged.selector, keccak256(p)), "own Pinged event");
        emit log_named_uint("dest: ccipReceive(ping) gas", g);
    }

    function _queue(uint256 cid, CCIPOwnerExecutor e, address senderAddr, bytes32 mid, bytes memory p, uint32 gas)
        internal
    {
        (bool ok, bytes memory ret, Vm.Log[] memory logs, uint256 g) = _route(cid, address(e), senderAddr, mid, p, gas);
        assertTrue(ok, string(ret));
        assertTrue(_has(logs, address(e), CCIPOwnerExecutor.Queued.selector, keccak256(p)), "own Queued event");
        emit log_named_uint("dest: ccipReceive(queue) gas", g);
    }

    /// Real Safe 1.4.1 execTransaction with two fixture signatures (sorted by signer).
    function _safeCancel(CCIPOwnerExecutor e, bytes32[] memory hs) internal {
        ISafe141 safe = ISafe141(e.canceller());
        bytes memory data = abi.encodeCall(CCIPOwnerExecutor.cancel, (hs));
        bytes32 h = safe.getTransactionHash(address(e), 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce());
        (uint256 k0, uint256 k1) =
            vm.addr(ownerKeys[0]) < vm.addr(ownerKeys[1]) ? (ownerKeys[0], ownerKeys[1]) : (ownerKeys[1], ownerKeys[0]);
        bytes memory sigs;
        for (uint256 i = 0; i < 2; i++) {
            (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(i == 0 ? k0 : k1, h);
            sigs = abi.encodePacked(sigs, rr, ss, v);
        }
        safe.checkSignatures(h, data, sigs);
        // One signature is not enough (threshold 2).
        vm.expectRevert(bytes("GS020"));
        safe.checkSignatures(h, data, _first65(sigs));
        vm.recordLogs();
        vm.prank(owners[2]);
        assertTrue(safe.execTransaction(address(e), 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sigs));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < hs.length; i++) {
            assertTrue(_has(logs, address(e), CCIPOwnerExecutor.Cancelled.selector, hs[i]), "own Cancelled event");
        }
    }

    function _first65(bytes memory b) internal pure returns (bytes memory out) {
        out = new bytes(65);
        for (uint256 i = 0; i < 65; i++) {
            out[i] = b[i];
        }
    }
}

/// @notice Sepolia + BNB Chain testnet. Emits the exact Monad testnet payloads for `T2MonadRehearsalForkTest`.
/// @dev Needs SEPOLIA_RPC_URL and BNB_TESTNET_RPC_URL; optional SEPOLIA_FORK_BLOCK / BNB_TESTNET_FORK_BLOCK.
contract T2RehearsalForkTest is T2ForkBase {
    receive() external payable {}

    uint256 sepFork;
    uint256 bnbFork;
    StarknetOwnerProxy proxy;
    CCIPGovernanceSender sender;
    CCIPOwnerExecutor eBnb;
    address eMon;

    function setUp() public {
        string memory sep = vm.envOr("SEPOLIA_RPC_URL", string(""));
        string memory bnb = vm.envOr("BNB_TESTNET_RPC_URL", string(""));
        if (bytes(sep).length == 0 || bytes(bnb).length == 0) {
            vm.skip(true);
            return;
        }
        sepFork = _fork(sep, "SEPOLIA_FORK_BLOCK");
        bnbFork = _fork(bnb, "BNB_TESTNET_FORK_BLOCK");
        vm.selectFork(sepFork);
        _identities();
        r.checkLane();

        // Sepolia nonce 0: test StarknetOwnerProxy bound to the real Starknet Sepolia core.
        assertEq(vm.getNonce(deployer), 0);
        vm.prank(deployer);
        proxy = new StarknetOwnerProxy(IStarknetMessaging(0xE2Bb56ee936fd6433DC0F6e7e3b8365C906AA057), L2_GOVERNOR);
        assertEq(address(proxy), r.t2Proxy(deployer));
        r.verifyProxy(_local(), address(proxy), L2_GOVERNOR);

        vm.selectFork(bnbFork);
        r.checkLane();
        (eBnb,) = _deployDest(97);
        eMon = r.t2Executor(deployer, 10143); // deployed and checked by the Monad run

        // Sepolia nonce 1: sender, after the executors.
        vm.selectFork(sepFork);
        CCIPRouteVerifier.SenderExpect memory x =
            r.t2SenderExpect(r.t2Sender(deployer), address(proxy), bootstrap, address(eBnb), eMon);
        x.runtimeKeccak = r.t2SenderRuntimeKeccak(x, bootstrap);
        vm.prank(deployer);
        sender = new CCIPGovernanceSender(
            IRouterClient(0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59),
            address(proxy),
            bootstrap,
            x.dest0,
            x.dest1,
            1_000_000
        );
        assertEq(address(sender), x.sender, "sender at deployer nonce 1");
        r.verifySender(_local(), x);
        emit log_named_bytes32("sepolia: sender runtime keccak (fixture inputs)", x.runtimeKeccak);
        vm.deal(payer, 10 ether);
    }

    function _requested(Vm.Log[] memory logs) internal view returns (bytes memory payload) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(sender) && logs[i].topics[0] == CCIPGovernanceSender.Requested.selector) {
                (,,, payload) = abi.decode(logs[i].data, (uint8, uint32, uint64, bytes));
                return payload;
            }
        }
        revert("no Requested");
    }

    /// REAL CODE ON FORK: Sepolia Router 1.2.0 / OnRamp 2.0.0 accept the sender's GenericExtraArgsV3 message.
    function _dispatch(bytes memory payload) internal returns (bytes32 mid) {
        vm.selectFork(sepFork);
        uint256 before = payer.balance;
        vm.recordLogs();
        vm.prank(payer);
        uint256 g = gasleft();
        mid = sender.dispatch{value: 0.05 ether}(payload);
        emit log_named_uint("sepolia: dispatch gas", g - gasleft());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == 0x8dcf17f298c881A547D91ca4aA3C2AD7568C6777 && logs[i].topics.length == 4
                    && logs[i].topics[3] == mid
            ) {
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(sender), "OnRamp sender");
                seen = true;
            }
        }
        assertTrue(seen, "CCIPMessageSent from Sepolia OnRamp 2.0.0");
        uint256 fee = before - payer.balance;
        assertGt(fee, 0);
        assertEq(address(sender).balance, 0, "exact fee, refund");
        emit log_named_uint("sepolia: CCIP fee (wei)", fee);
    }

    function _bootstrapPing(uint64 sel, uint64 deadline) internal returns (bytes memory p) {
        vm.selectFork(sepFork);
        vm.recordLogs();
        vm.prank(bootstrap);
        sender.request(sel, 300_000, deadline, new CCIPGovernancePayload.Call[](0));
        p = _requested(vm.getRecordedLogs());
    }

    /// SIMULATED settlement: the Governor's L2->L1 message is injected into the real Starknet Sepolia core.
    function _governorMessage(uint256 cid, uint8 kind, uint256 value, uint64 deadline)
        internal
        returns (bytes memory payload)
    {
        vm.selectFork(sepFork);
        uint64 n = proxy.currentNonce();
        CCIPGovernancePayload.Call[] memory calls = r.t2Calls(r.t2Targets(deployer, cid), kind, value);
        uint32 gasLimit = kind == 2 ? 100_000 : 300_000;
        bytes memory data = abi.encodeCall(CCIPGovernanceSender.request, (r.t2Selector(cid), gasLimit, deadline, calls));
        uint256[] memory felts = proxy.getPayload(address(sender), 0, n, data);
        assertEq(
            keccak256(abi.encode(felts)),
            keccak256(abi.encode(r.t2Felts(address(sender), 0, n, data))),
            "t2Felts == getPayload"
        );
        bytes32 h = r.t2MessageHash(L2_GOVERNOR, address(proxy), felts);
        bytes32 slot = keccak256(abi.encode(h, keccak256(abi.encodePacked("STARKNET_1.0_MSGING_L2TOL1_MAPPPING"))));
        address core = 0xE2Bb56ee936fd6433DC0F6e7e3b8365C906AA057;
        assertEq(IStarknetCoreView(core).l2ToL1Messages(h), 0);
        vm.store(core, slot, bytes32(uint256(1)));
        assertEq(IStarknetCoreView(core).l2ToL1Messages(h), 1, "message injected");

        (bool ok,) =
            address(proxy).call{gas: 80_000}(abi.encodeCall(StarknetOwnerProxy.execute, (address(sender), 0, n, data)));
        assertFalse(ok, "forced low-gas L1 execute fails");
        assertEq(proxy.currentNonce(), n, "nonce unchanged, retryable");

        vm.recordLogs();
        uint256 g = gasleft();
        proxy.execute(address(sender), 0, n, data);
        emit log_named_uint("sepolia: StarknetOwnerProxy.execute -> request gas", g - gasleft());
        emit log_named_uint("sepolia: L2->L1 payload felts", felts.length);
        assertEq(IStarknetCoreView(core).l2ToL1Messages(h), 0, "message consumed");
        payload = _requested(vm.getRecordedLogs());

        vm.expectRevert(abi.encodeWithSelector(StarknetOwnerProxy.InvalidNonce.selector, n + 1, n));
        proxy.execute(address(sender), 0, n, data);
    }

    function test_t2_rehearsal_sepolia_bnbTestnet() public {
        // Step 1: bootstrap pings on both lanes; BNB delivered here, Monad by the Monad run.
        uint64 deadline = uint64(vm.getBlockTimestamp() + 3 days);
        bytes memory pingBnb = _bootstrapPing(13264668187771770619, deadline);
        bytes memory pingMon = _bootstrapPing(2183018362218727504, deadline);
        bytes32 midPingBnb = _dispatch(pingBnb);
        bytes32 midPingMon = _dispatch(pingMon);
        vm.selectFork(bnbFork);
        _ping(97, eBnb, address(sender), midPingBnb, pingBnb);

        // Step 6a: deliberate recoverable FAILURE on real code: deadline beyond maxTtl at delivery, then the same
        // message re-executed (manual execution analogue) once within maxTtl.
        vm.selectFork(sepFork);
        uint256 sendTs = vm.getBlockTimestamp();
        bytes memory farPing = _bootstrapPing(13264668187771770619, uint64(sendTs + 604800 + 4 hours));
        bytes32 midFar = _dispatch(farPing);
        vm.selectFork(bnbFork);
        vm.warp(sendTs + 30 minutes);
        (bool ok, bytes memory ret,,) = _route(97, address(eBnb), address(sender), midFar, farPing, 300_000);
        assertFalse(ok);
        assertEq(bytes4(ret), CCIPOwnerExecutor.DeadlineTooFar.selector, "FAILURE: DeadlineTooFar");
        vm.warp(sendTs + 4 hours + 1);
        _ping(97, eBnb, address(sender), midFar, farPing);

        // Step 2-3: one-way handoff; the bootstrap key is rejected locally afterwards.
        vm.selectFork(sepFork);
        vm.prank(bootstrap);
        sender.handoff();
        assertEq(sender.authority(), address(proxy));
        vm.prank(bootstrap);
        vm.expectRevert(CCIPGovernanceSender.Unauthorized.selector);
        sender.request(13264668187771770619, 300_000, deadline, new CCIPGovernancePayload.Call[](0));
        vm.prank(bootstrap);
        vm.expectRevert(CCIPGovernanceSender.AlreadyHandedOff.selector);
        sender.handoff();

        // Step 4-5 (proposal P1): owner() proof on both chains; BNB queued, delayed, executed (no state change).
        uint64 dl = uint64(vm.getBlockTimestamp() + 3 days);
        bytes memory proofBnb = _governorMessage(97, 0, 0, dl);
        bytes memory proofMon = _governorMessage(10143, 0, 0, dl);
        bytes32 midProofBnb = _dispatch(proofBnb);
        bytes32 midProofMon = _dispatch(proofMon);
        vm.selectFork(bnbFork);
        vm.warp(vm.getBlockTimestamp() + 20 minutes);
        _queue(97, eBnb, address(sender), midProofBnb, proofBnb, 300_000);
        (,, uint64 eta) = eBnb.ops(keccak256(proofBnb));
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.NotReady.selector, eta));
        eBnb.execute(proofBnb);
        vm.warp(eta);
        eBnb.execute(proofBnb);
        address[] memory ts = eBnb.targets();

        // T6 analogue on dummies only: the deployer transfers each dummy directly to the executor.
        for (uint256 i = 0; i < ts.length; i++) {
            vm.prank(deployer);
            T2DummyTarget(ts[i]).transferOwnership(address(eBnb));
            assertEq(T2DummyTarget(ts[i]).owner(), address(eBnb));
            assertEq(T2DummyTarget(ts[i]).ownershipHandoverExpiresAt(address(eBnb)), 0);
        }

        // Proposal P2: setValue(42) [opId 4], padded low-gas note [opId 5], setValue(43) [opId 6] on BNB; Monad 42.
        // (BNB opIds 1-2 were the pings, 3 the proof: every request consumes the destination's next opId.)
        dl = uint64(vm.getBlockTimestamp() + 3 days);
        bytes memory set42 = _governorMessage(97, 1, 42, dl);
        bytes memory pad = _governorMessage(97, 2, 0, dl);
        bytes memory set43 = _governorMessage(97, 1, 43, dl);
        bytes memory setMon = _governorMessage(10143, 1, 42, dl);
        assertLt(pad.length, 32000, "padded payload within lane maxDataBytes 32000");
        bytes32 mid42 = _dispatch(set42);
        bytes32 midPad = _dispatch(pad);
        bytes32 mid43 = _dispatch(set43);
        bytes32 midSetMon = _dispatch(setMon);

        vm.selectFork(bnbFork);
        vm.warp(vm.getBlockTimestamp() + 20 minutes);
        _queue(97, eBnb, address(sender), mid42, set42, 300_000);

        // Step 6b: forced low gas. 100k (the sender's floor) cannot run ccipReceive on the padded payload: FAILURE.
        // Manual execution with a gas override (OffRamp 2.0.0 `execute(..., gasLimitOverride)`) then queues it.
        uint256 gUsed;
        (ok,,, gUsed) = _route(97, address(eBnb), address(sender), midPad, pad, 100_000);
        assertFalse(ok, "FAILURE: out of gas at gasLimit 100000");
        uint256 snap = vm.snapshotState();
        (ok,,, gUsed) = _route(97, address(eBnb), address(sender), keccak256("measure"), pad, 1_000_000);
        assertTrue(ok);
        emit log_named_uint("dest: ccipReceive(padded) gas when not limited", gUsed);
        assertGe(gUsed, 150_000, "padded op needs >= 1.5x the low gas limit");
        vm.revertToState(snap);
        _queue(97, eBnb, address(sender), midPad, pad, 400_000);
        _queue(97, eBnb, address(sender), mid43, set43, 300_000);

        // Step 7: the test canceller Safe (2-of-3) cancels the padded op through the real Safe 1.4.1.
        bytes32[] memory hs = new bytes32[](1);
        hs[0] = keccak256(pad);
        _safeCancel(eBnb, hs);
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.NotQueued.selector, hs[0]));
        eBnb.execute(pad);

        // Step 5: delayed dummy calls; Step 8: stale and replayed operations are rejected.
        (,, eta) = eBnb.ops(keccak256(set43));
        vm.warp(eta);
        eBnb.execute(set43);
        assertEq(T2DummyTarget(ts[0]).value(), 43);
        assertEq(T2DummyTarget(ts[1]).value(), 43);
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.StaleOpId.selector, 4, 6));
        eBnb.execute(set42);
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.NotQueued.selector, keccak256(set43)));
        eBnb.execute(set43);
        (ok, ret,,) = _route(97, address(eBnb), address(sender), keccak256("replay"), set43, 300_000);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(CCIPOwnerExecutor.StaleOpId.selector, 6, 6), "re-delivery after execute");
        (ok, ret,,) = _route(97, address(eBnb), address(sender), keccak256("replay2"), pad, 400_000);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(CCIPOwnerExecutor.StaleOpId.selector, 5, 6), "cancelled op stays dead");
        vm.selectFork(sepFork);
        vm.expectRevert(abi.encodeWithSelector(CCIPGovernanceSender.NotPending.selector, keccak256(set43)));
        sender.dispatch{value: 0.05 ether}(set43);

        // Hand the exact Monad testnet bytes to the Monad run.
        emit log_named_address("MONAD_T2_SENDER", address(sender));
        emit log_named_address("MONAD_T2_EXECUTOR", eMon);
        emit log_named_bytes32("MONAD_T2_PING_MSG", midPingMon);
        emit log_named_bytes("MONAD_T2_PING_PAYLOAD", pingMon);
        emit log_named_bytes32("MONAD_T2_PROOF_MSG", midProofMon);
        emit log_named_bytes("MONAD_T2_PROOF_PAYLOAD", proofMon);
        emit log_named_bytes32("MONAD_T2_SET_MSG", midSetMon);
        emit log_named_bytes("MONAD_T2_SET_PAYLOAD", setMon);
    }
}

/// @notice Monad testnet leg (run with `--network monad`): the same deployer nonce plan, then the exact payloads the
///         Sepolia run's real sender emitted, delivered through an IMPERSONATED OffRamp 2.0.0.
contract T2MonadRehearsalForkTest is T2ForkBase {
    function test_t2_rehearsal_monadTestnet() public {
        string memory mon = vm.envOr("MONAD_TESTNET_RPC_URL", string(""));
        bytes memory setPayload = vm.envOr("MONAD_T2_SET_PAYLOAD", bytes(""));
        if (bytes(mon).length == 0 || setPayload.length == 0) {
            vm.skip(true);
            return;
        }
        vm.selectFork(_fork(mon, "MONAD_TESTNET_FORK_BLOCK"));
        _identities();
        r.checkLane();
        address senderAddr = vm.envAddress("MONAD_T2_SENDER");
        assertEq(senderAddr, r.t2Sender(deployer));
        (CCIPOwnerExecutor e,) = _deployDest(10143);
        assertEq(address(e), vm.envAddress("MONAD_T2_EXECUTOR"), "executor matches the sender's pin");

        vm.warp(vm.getBlockTimestamp() + 20 minutes);
        _ping(10143, e, senderAddr, vm.envBytes32("MONAD_T2_PING_MSG"), vm.envBytes("MONAD_T2_PING_PAYLOAD"));
        bytes memory proof = vm.envBytes("MONAD_T2_PROOF_PAYLOAD");
        _queue(10143, e, senderAddr, vm.envBytes32("MONAD_T2_PROOF_MSG"), proof, 300_000);
        (,, uint64 eta) = e.ops(keccak256(proof));
        vm.warp(eta);
        e.execute(proof);
        address[] memory ts = e.targets();
        for (uint256 i = 0; i < ts.length; i++) {
            vm.prank(deployer);
            T2DummyTarget(ts[i]).transferOwnership(address(e));
        }
        _queue(10143, e, senderAddr, vm.envBytes32("MONAD_T2_SET_MSG"), setPayload, 300_000);
        (,, eta) = e.ops(keccak256(setPayload));
        vm.warp(eta);
        uint256 g = gasleft();
        e.execute(setPayload);
        emit log_named_uint("dest: execute(setValue x4) gas", g - gasleft());
        for (uint256 i = 0; i < ts.length; i++) {
            assertEq(T2DummyTarget(ts[i]).value(), 42);
        }
        // Safe cancellation also works on Monad testnet: queue a duplicate-intent op, then cancel it.
        bytes memory extra = CCIPGovernancePayload.encode(
            10143, address(e), 99, 2, uint64(vm.getBlockTimestamp() + 1 days), r.t2Calls(ts, 1, 7)
        );
        _queue(10143, e, senderAddr, keccak256("extra"), extra, 300_000);
        bytes32[] memory hs = new bytes32[](1);
        hs[0] = keccak256(extra);
        _safeCancel(e, hs);
    }
}
