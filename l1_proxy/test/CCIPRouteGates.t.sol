// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Client} from "../vendor/ccip-2.0.0/libraries/Client.sol";
import {StarknetOwnerProxy, IStarknetMessaging} from "../src/StarknetOwnerProxy.sol";
import {CCIPGovernancePayload} from "../src/CCIPGovernancePayload.sol";
import {CCIPGovernanceSender} from "../src/CCIPGovernanceSender.sol";
import {CCIPOwnerExecutor} from "../src/CCIPOwnerExecutor.sol";
import {CCIPRouteVerifier} from "../script/CCIPRouteVerifier.sol";
import {CCIPRouteGates} from "../script/CCIPRouteGates.s.sol";
import {MockCCIPRouter, MockOwnedTarget} from "./CCIPMocks.sol";
import {MockSafe} from "./CCIPSafeMock.sol";

/// @notice EKU-1217 (CSO EKU-1200 M-B / D1-D5 / L-1 / I-1 / I-2): the T5/T6 gate logic. Evidence class: MOCKED,
///         local EVM only. Targets are owned by the company key, as on mainnet before T6.
contract CCIPRouteGatesTest is Test {
    uint64 constant ETH_SELECTOR = 5009297550715157269;
    uint64 constant BNB_SELECTOR = 11344663589394136015;
    uint64 constant MONAD_SELECTOR = 8481857512324358265;
    uint64 constant DELAY = 259200;
    uint64 constant WINDOW = 1209600;
    uint64 constant TTL = 2592000;
    address constant SENDER = address(0x5E4D);
    address constant COMPANY_KEY = 0x00000C771F6176268D5A9846E0956C3eF58597A1;
    address constant ATTACKER = address(0xBAD);

    CCIPRouteGates h;
    MockCCIPRouter router;
    MockSafe safe;
    MockOwnedTarget t0;
    MockOwnedTarget t1;
    CCIPOwnerExecutor ex;
    uint256 msgNonce;

    function setUp() public {
        vm.warp(1_800_000_000);
        h = new CCIPRouteGates();
        router = new MockCCIPRouter();
        address[] memory owners = new address[](2);
        owners[0] = makeAddr("signer-a");
        owners[1] = makeAddr("signer-b");
        safe = new MockSafe();
        safe.setup(address(0x5afe), owners, 2, address(0));
        t0 = new MockOwnedTarget(COMPANY_KEY);
        t1 = new MockOwnedTarget(COMPANY_KEY);
        address[] memory ts = new address[](2);
        ts[0] = address(t0);
        ts[1] = address(t1);
        ex = new CCIPOwnerExecutor(address(router), ETH_SELECTOR, SENDER, DELAY, WINDOW, TTL, address(safe), ts);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _err(string memory what) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CCIPRouteVerifier.VerificationFailed.selector, what);
    }

    function _one(address target, bytes memory data) internal pure returns (CCIPGovernancePayload.Call[] memory c) {
        c = new CCIPGovernancePayload.Call[](1);
        c[0] = CCIPGovernancePayload.Call(target, data);
    }

    function _ownerBatch(address[] memory ts) internal pure returns (CCIPGovernancePayload.Call[] memory c) {
        c = new CCIPGovernancePayload.Call[](ts.length);
        for (uint256 i = 0; i < ts.length; i++) {
            c[i] = CCIPGovernancePayload.Call(ts[i], hex"8da5cb5b");
        }
    }

    function _payload(uint64 opId, CCIPGovernancePayload.Call[] memory calls) internal view returns (bytes memory) {
        return CCIPGovernancePayload.encode(block.chainid, address(ex), opId, 2, uint64(_now() + 7 days), calls);
    }

    /// Delivers through the mock router and returns the executor's Queued logs in eth_getLogs shape.
    function _queue(bytes memory payload) internal returns (Vm.EthGetLogs memory out) {
        Client.Any2EVMMessage memory m;
        m.messageId = keccak256(abi.encode("m", ++msgNonce));
        m.sourceChainSelector = ETH_SELECTOR;
        m.sender = abi.encode(SENDER);
        m.data = payload;
        vm.recordLogs();
        (bool ok,, bytes memory ret) = router.deliver(address(ex), m, 500_000);
        assertTrue(ok, string(ret));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(ex) && logs[i].topics[0] == CCIPOwnerExecutor.Queued.selector) {
                out.emitter = logs[i].emitter;
                out.topics = logs[i].topics;
                out.data = logs[i].data;
                out.blockNumber = uint64(block.number);
                return out;
            }
        }
        revert("no Queued");
    }

    function _report(Vm.EthGetLogs[] memory raw, bytes32[] memory known)
        internal
        view
        returns (CCIPRouteGates.QueueReport memory)
    {
        return h.classifyQueued(ex, h.decodeQueued(raw), known, _now());
    }

    function _arr(Vm.EthGetLogs memory a) internal pure returns (Vm.EthGetLogs[] memory r) {
        r = new Vm.EthGetLogs[](1);
        r[0] = a;
    }

    function _arr(Vm.EthGetLogs memory a, Vm.EthGetLogs memory b, Vm.EthGetLogs memory c)
        internal
        pure
        returns (Vm.EthGetLogs[] memory r)
    {
        r = new Vm.EthGetLogs[](3);
        (r[0], r[1], r[2]) = (a, b, c);
    }

    function _h(bytes32 x) internal pure returns (bytes32[] memory r) {
        r = new bytes32[](1);
        r[0] = x;
    }

    // ---------------------------------------------------------------- M-B / D2

    /// CSO M-B: a forgery queued while the company key owns the target fails at execute but stays Queued, and
    /// becomes executable once the company key transfers to the executor. The D2 audit flags it, emits exactly the
    /// cancel-many calldata, and is clean only after the Safe cancels.
    function test_D2_forgeryQueuedBeforeTransfer_flagged_cancelled_clean() public {
        bytes memory forged = _payload(1, _one(address(t0), abi.encodeCall(Ownable.transferOwnership, (ATTACKER))));
        bytes32 hf = keccak256(forged);
        Vm.EthGetLogs memory lf = _queue(forged);

        vm.warp(_now() + DELAY);
        vm.expectRevert();
        ex.execute(forged); // company key still owns t0
        (CCIPOwnerExecutor.OpStatus st,,) = ex.ops(hf);
        assertEq(uint8(st), 1, "stays Queued");

        // The exposure: after a direct transfer the forgery executes.
        uint256 snap = vm.snapshotState();
        vm.prank(COMPANY_KEY);
        t0.transferOwnership(address(ex));
        ex.execute(forged);
        assertEq(t0.owner(), ATTACKER, "capture after transfer (M-B)");
        vm.revertToState(snap);

        CCIPRouteGates.QueueReport memory r = _report(_arr(lf), new bytes32[](0));
        assertEq(r.total, 1);
        assertEq(r.unknownLive.length, 1);
        assertEq(r.unknownLive[0], hf);
        vm.expectRevert(_err("D2: unknown live Queued op(s); Safe must cancel before any transfer"));
        h.requireClean(r);

        safe.exec(address(ex), abi.encodeCall(CCIPOwnerExecutor.cancel, (r.unknownLive)));
        r = _report(_arr(lf), new bytes32[](0));
        assertEq(r.cancelled, 1);
        assertEq(r.unknownLive.length, 0);
        h.requireClean(r);

        vm.prank(COMPANY_KEY);
        t0.transferOwnership(address(ex));
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.NotQueued.selector, hf));
        ex.execute(forged);
        assertEq(t0.owner(), address(ex));
    }

    /// I-2: the cancel list holds only currently-Queued hashes, so it never trips the all-or-nothing revert that a
    /// naive list of every Queued log would.
    function test_D2_cancelList_onlyCurrentlyQueued_allOrNothingSafe() public {
        address[] memory ts = ex.targets();
        bytes memory a = _payload(1, _ownerBatch(ts)); // known proof, executed
        bytes memory b = _payload(7, _one(address(t1), abi.encodeCall(Ownable.transferOwnership, (ATTACKER))));
        bytes memory c = _payload(9, _one(address(t0), hex"8da5cb5b"));
        Vm.EthGetLogs memory la = _queue(a);
        Vm.EthGetLogs memory lb = _queue(b);
        Vm.EthGetLogs memory lc = _queue(c);
        safe.exec(address(ex), abi.encodeCall(CCIPOwnerExecutor.cancel, (_h(keccak256(c)))));
        vm.warp(_now() + DELAY);
        ex.execute(a);

        CCIPRouteGates.QueueReport memory r = _report(_arr(la, lb, lc), _h(keccak256(a)));
        assertEq(r.total, 3);
        assertEq(r.executed, 1);
        assertEq(r.cancelled, 1);
        assertEq(r.unknownLive.length, 1);
        assertEq(r.unknownLive[0], keccak256(b));

        bytes32[] memory naive = new bytes32[](3);
        (naive[0], naive[1], naive[2]) = (keccak256(a), keccak256(b), keccak256(c));
        vm.expectRevert(abi.encodeWithSelector(CCIPOwnerExecutor.NotQueued.selector, keccak256(a)));
        safe.exec(address(ex), abi.encodeCall(CCIPOwnerExecutor.cancel, (naive)));

        safe.exec(address(ex), abi.encodeCall(CCIPOwnerExecutor.cancel, (r.unknownLive)));
        h.requireClean(_report(_arr(la, lb, lc), _h(keccak256(a))));
    }

    function test_D2_expiredWindow_isClosed() public {
        bytes memory forged = _payload(1, _one(address(t0), abi.encodeCall(Ownable.transferOwnership, (ATTACKER))));
        Vm.EthGetLogs memory lf = _queue(forged);
        (,, uint64 eta) = ex.ops(keccak256(forged));
        vm.warp(uint256(eta) + WINDOW);
        assertEq(_report(_arr(lf), new bytes32[](0)).unknownLive.length, 1, "last executable second is live");
        vm.warp(uint256(eta) + WINDOW + 1);
        CCIPRouteGates.QueueReport memory r = _report(_arr(lf), new bytes32[](0));
        assertEq(r.expired, 1);
        h.requireClean(r);
        vm.expectRevert();
        ex.execute(forged);
    }

    /// I-1: at most one manifest-known GOVERNOR op live per executor.
    function test_I1_twoKnownLive_rejected() public {
        address[] memory ts = ex.targets();
        bytes memory a = _payload(1, _ownerBatch(ts));
        bytes memory b = _payload(2, _ownerBatch(ts));
        Vm.EthGetLogs memory la = _queue(a);
        Vm.EthGetLogs memory lb = _queue(b);
        bytes32[] memory known = new bytes32[](2);
        (known[0], known[1]) = (keccak256(a), keccak256(b));
        Vm.EthGetLogs[] memory both = new Vm.EthGetLogs[](2);
        (both[0], both[1]) = (la, lb);
        CCIPRouteGates.QueueReport memory r = _report(both, known);
        assertEq(r.knownLive.length, 2);
        vm.expectRevert(_err("I-1: more than one GOVERNOR op in flight"));
        h.requireClean(r);
        h.requireClean(_report(_arr(la), known));
    }

    function test_D2_tamperedOrDuplicateLogs_failClosed() public {
        bytes memory a = _payload(1, _ownerBatch(ex.targets()));
        Vm.EthGetLogs memory la = _queue(a);
        bytes32[] memory none = new bytes32[](0);

        (uint64 lEta, uint64 lDeadline,) = abi.decode(la.data, (uint64, uint64, bytes));
        Vm.EthGetLogs memory bad = VmSafe.EthGetLogs(
            la.emitter,
            la.topics,
            abi.encode(lEta, lDeadline, _payload(2, _ownerBatch(ex.targets()))),
            0,
            0,
            0,
            0,
            0,
            false
        );
        try h.classifyQueued(ex, h.decodeQueued(_arr(bad)), none, _now()) {
            revert("tampered payload accepted");
        } catch (bytes memory err) {
            assertEq(err, _err("Queued payload does not hash to its payloadHash"));
        }

        bad = VmSafe.EthGetLogs(la.emitter, la.topics, abi.encode(lEta + 1, lDeadline, a), 0, 0, 0, 0, 0, false);
        try h.classifyQueued(ex, h.decodeQueued(_arr(bad)), none, _now()) {
            revert("wrong eta accepted");
        } catch (bytes memory err) {
            assertEq(err, _err("ops() does not match the Queued log"));
        }

        Vm.EthGetLogs[] memory dup = new Vm.EthGetLogs[](2);
        (dup[0], dup[1]) = (la, la);
        try h.classifyQueued(ex, h.decodeQueued(dup), none, _now()) {
            revert("duplicate accepted");
        } catch (bytes memory err) {
            assertEq(err, _err("duplicate Queued payloadHash"));
        }

        bytes32[] memory wrongTopics = new bytes32[](4);
        wrongTopics[0] = CCIPOwnerExecutor.Executed.selector;
        bad = VmSafe.EthGetLogs(la.emitter, wrongTopics, la.data, 0, 0, 0, 0, 0, false);
        try h.decodeQueued(_arr(bad)) {
            revert("non-Queued log accepted");
        } catch (bytes memory err) {
            assertEq(err, _err("not a Queued log"));
        }
    }

    // ---------------------------------------------------------------- D1 / D5 proof payload

    function test_D1_D5_proofPayload() public {
        address[] memory ts = ex.targets();
        h.checkProofPayload(ex, _payload(1, _ownerBatch(ts)));

        CCIPGovernancePayload.Call[] memory c = _ownerBatch(ts);
        c[1].data = abi.encodeCall(Ownable.transferOwnership, (address(ex)));
        _proofFails(_payload(1, c), "D5: proof must be owner() only");
        _proofFails(_payload(1, _one(ts[0], hex"8da5cb5b")), "D5: proof must call every target");
        c = _ownerBatch(ts);
        (c[0], c[1]) = (c[1], c[0]);
        _proofFails(_payload(1, c), "D5: proof must be owner() only");
        _proofFails(
            CCIPGovernancePayload.encode(block.chainid, address(0xE), 1, 2, uint64(_now() + 1 days), _ownerBatch(ts)),
            "D1: proof payload identity"
        );
        _proofFails(
            CCIPGovernancePayload.encode(56, address(ex), 1, 2, uint64(_now() + 1 days), _ownerBatch(ts)),
            "D1: proof payload identity"
        );
        _proofFails(
            CCIPGovernancePayload.encode(block.chainid, address(ex), 1, 1, uint64(_now() + 1 days), _ownerBatch(ts)),
            "D1: proof payload identity"
        );
    }

    function _proofFails(bytes memory p, string memory what) internal view {
        try h.checkProofPayload(ex, p) {
            revert(string.concat("expected failure: ", what));
        } catch (bytes memory err) {
            assertEq(err, _err(what), what);
        }
    }

    // ---------------------------------------------------------------- D3 / D4 direct transfer simulation

    function test_D3_simulateTransfers_exactCalldata_postState() public {
        h.simulateTransfers(ex, address(0));
        assertEq(t0.owner(), address(ex));
        assertEq(t1.owner(), address(ex));
        // Repeat run skips targets already owned by the executor.
        h.simulateTransfers(ex, address(0));
    }

    function test_D3_simulateTransfers_rejects() public {
        vm.prank(COMPANY_KEY);
        t1.transferOwnership(ATTACKER);
        vm.expectRevert(_err("target owner is not the company key"));
        h.simulateTransfers(ex, address(0));
        vm.expectRevert(_err("TRANSFER_TARGET not pinned"));
        h.simulateTransfers(ex, address(0x1234));
        h.simulateTransfers(ex, address(t0));
        assertEq(t0.owner(), address(ex));
        assertEq(t1.owner(), ATTACKER);
    }

    // ---------------------------------------------------------------- L-1 / D5 / C9: Governor message to the sender

    function _proxy() internal returns (StarknetOwnerProxy) {
        return new StarknetOwnerProxy(IStarknetMessaging(address(0x5701)), 1);
    }

    function _proofRequest(uint64 dest, uint32 gasLimit) internal view returns (bytes memory) {
        address[] memory ts = h.targetsFor(dest == BNB_SELECTOR ? 56 : 143);
        return abi.encodeCall(CCIPGovernanceSender.request, (dest, gasLimit, uint64(_now() + 20 days), _ownerBatch(ts)));
    }

    function test_L1_decodeL1Message_roundTrip() public {
        StarknetOwnerProxy p = _proxy();
        bytes memory data = _proofRequest(MONAD_SELECTOR, 500_000);
        (address target, uint256 value, uint64 nonce, bytes memory got) =
            h.decodeL1Message(p.getPayload(SENDER, 0, 28, data));
        assertEq(target, SENDER);
        assertEq(value, 0);
        assertEq(nonce, 28);
        assertEq(got, data);
    }

    function testFuzz_L1_decodeL1Message_roundTrip(bytes calldata data, uint64 nonce, uint256 value) public {
        StarknetOwnerProxy p = _proxy();
        (address target, uint256 v, uint64 n, bytes memory got) =
            h.decodeL1Message(p.getPayload(SENDER, value, nonce, data));
        assertEq(target, SENDER);
        assertEq(v, value);
        assertEq(n, nonce);
        assertEq(got, data);
    }

    function test_L1_decodeL1Message_rejectsMalformed() public {
        StarknetOwnerProxy p = _proxy();
        uint256[] memory f = p.getPayload(SENDER, 0, 28, _proofRequest(BNB_SELECTOR, 500_000));
        uint256[] memory g = new uint256[](f.length - 1);
        for (uint256 i = 0; i < g.length; i++) {
            g[i] = f[i];
        }
        vm.expectRevert(_err("L1 message length"));
        h.decodeL1Message(g);
        f[4] |= 1 << 250;
        vm.expectRevert(_err("L1 message chunk > 31 bytes"));
        h.decodeL1Message(f);
        f[4] &= ~uint256(1 << 250);
        f[0] |= 1 << 200;
        vm.expectRevert(_err("L1 message header"));
        h.decodeL1Message(f);
    }

    function test_L1_requestCalldata_proof_passes_bothChains() public view {
        h.checkRequestCalldata(SENDER, SENDER, 0, _proofRequest(BNB_SELECTOR, 500_000), true);
        h.checkRequestCalldata(SENDER, SENDER, 0, _proofRequest(MONAD_SELECTOR, 100_000), true);
        h.checkRequestCalldata(SENDER, SENDER, 0, _proofRequest(MONAD_SELECTOR, 1_000_000), true);
    }

    function _reqFails(address target, uint256 value, bytes memory data, bool proofOnly, string memory what)
        internal
        view
    {
        try h.checkRequestCalldata(SENDER, target, value, data, proofOnly) {
            revert(string.concat("expected failure: ", what));
        } catch (bytes memory err) {
            assertEq(err, _err(what), what);
        }
    }

    function test_L1_requestCalldata_rejects() public view {
        address[] memory bnb = h.targetsFor(56);
        uint64 dl = uint64(_now() + 20 days);
        bytes memory ok = _proofRequest(BNB_SELECTOR, 500_000);
        _reqFails(address(0x5E4E), 0, ok, true, "L-1: L1 message target != sender");
        _reqFails(SENDER, 1, ok, true, "L-1: L1 message value != 0");
        _reqFails(SENDER, 0, abi.encodeCall(CCIPGovernanceSender.handoff, ()), true, "L-1: not request()");
        _reqFails(SENDER, 0, bytes.concat(ok, hex"00"), true, "L-1: non-canonical request calldata");
        _reqFails(
            SENDER,
            0,
            abi.encodeCall(CCIPGovernanceSender.request, (ETH_SELECTOR, 500_000, dl, _ownerBatch(bnb))),
            true,
            "L-1: destination selector"
        );
        _reqFails(SENDER, 0, _proofRequest(BNB_SELECTOR, 99_999), true, "L-1: gasLimit outside [100000, 1000000]");
        _reqFails(SENDER, 0, _proofRequest(BNB_SELECTOR, 1_000_001), true, "L-1: gasLimit outside [100000, 1000000]");
        _reqFails(
            SENDER,
            0,
            abi.encodeCall(
                CCIPGovernanceSender.request, (BNB_SELECTOR, 500_000, dl, new CCIPGovernancePayload.Call[](0))
            ),
            false,
            "L-1: call count outside 1..8"
        );
        CCIPGovernancePayload.Call[] memory nine = new CCIPGovernancePayload.Call[](9);
        for (uint256 i = 0; i < 9; i++) {
            nine[i] = CCIPGovernancePayload.Call(bnb[0], hex"8da5cb5b");
        }
        _reqFails(
            SENDER,
            0,
            abi.encodeCall(CCIPGovernanceSender.request, (BNB_SELECTOR, 500_000, dl, nine)),
            false,
            "L-1: call count outside 1..8"
        );
        // Monad-only target sent to BNB.
        _reqFails(
            SENDER,
            0,
            abi.encodeCall(
                CCIPGovernanceSender.request,
                (BNB_SELECTOR, 500_000, dl, _one(0x02D9876A21AF7545f8632C3af76eC90b5ad4b66D, hex"8da5cb5b"))
            ),
            false,
            "L-1: call target not pinned"
        );
        bytes4[5] memory denied = [bytes4(0xf2fde38b), 0x715018a6, 0x25692962, 0xf04e283e, 0x54d1f13d];
        for (uint256 i = 0; i < denied.length; i++) {
            CCIPGovernancePayload.Call[] memory c = _ownerBatch(bnb);
            c[1].data = abi.encodePacked(denied[i], bytes32(uint256(uint160(address(ex)))));
            _reqFails(
                SENDER,
                0,
                abi.encodeCall(CCIPGovernanceSender.request, (BNB_SELECTOR, 500_000, dl, c)),
                false,
                "D5: ownership mutator in Governor op"
            );
        }
        _reqFails(
            SENDER,
            0,
            abi.encodeCall(CCIPGovernanceSender.request, (BNB_SELECTOR, 500_000, dl, _one(bnb[0], hex"8da5cb5b"))),
            true,
            "D5: owner() proof must cover every target"
        );
        CCIPGovernancePayload.Call[] memory swapped = _ownerBatch(bnb);
        (swapped[0], swapped[1]) = (swapped[1], swapped[0]);
        _reqFails(
            SENDER,
            0,
            abi.encodeCall(CCIPGovernanceSender.request, (BNB_SELECTOR, 500_000, dl, swapped)),
            true,
            "D5: owner() proof call"
        );
    }

    // ---------------------------------------------------------------- EKU-1232: L-4, L-5, L-7 (CSO EKU-1218)

    /// L-4: a known (manifest) operation that is still live blocks a transfer, and the known list must be exactly
    /// the proof hash; once the proof has executed and nothing else is live, the transfer gate passes.
    function test_L4_knownLiveBlocksTransfer_knownListIsExactlyProof() public {
        bytes memory proof = _payload(1, _ownerBatch(ex.targets()));
        bytes32 hp = keccak256(proof);
        Vm.EthGetLogs memory lp = _queue(proof);
        CCIPRouteGates.QueueReport memory r = _report(_arr(lp), _h(hp));
        assertEq(r.knownLive.length, 1);
        h.requireClean(r); // the general D2/I-1 gate tolerates one known live op
        vm.expectRevert(_err("L-4: knownLive must be zero at a transfer"));
        h.requireTransferClean(r, _h(hp), hp);

        vm.warp(_now() + DELAY);
        ex.execute(proof);
        r = _report(_arr(lp), _h(hp));
        h.requireTransferClean(r, _h(hp), hp);

        bytes32[] memory two = new bytes32[](2);
        (two[0], two[1]) = (hp, keccak256("later op"));
        vm.expectRevert(_err("L-4: KNOWN_PAYLOAD_HASHES must be exactly the proof hash"));
        h.requireTransferClean(r, two, hp);
        vm.expectRevert(_err("L-4: KNOWN_PAYLOAD_HASHES must be exactly the proof hash"));
        h.requireTransferClean(r, new bytes32[](0), hp);
        vm.expectRevert(_err("L-4: KNOWN_PAYLOAD_HASHES must be exactly the proof hash"));
        h.requireTransferClean(r, _h(keccak256("not the proof")), hp);
    }

    /// L-7: Monad (143 and testnet 10143) log pages are at most 100 blocks; other chains keep the default.
    function test_L7_monadLogChunk_enforced() public {
        if (!vm.envExists("LOG_CHUNK")) assertEq(h.logChunk(), 1000);
        vm.chainId(143);
        assertEq(h.logChunk(), 100);
        h.checkChunk(100);
        vm.expectRevert(_err("L-7: Monad LOG_CHUNK must be <= 100"));
        h.checkChunk(101);
        vm.setEnv("LOG_CHUNK", "1000");
        vm.expectRevert(_err("L-7: Monad LOG_CHUNK must be <= 100"));
        h.logChunk();
        vm.chainId(10143);
        vm.expectRevert(_err("L-7: Monad LOG_CHUNK must be <= 100"));
        h.fetchQueued(address(ex), 0, block.number, 1000);
        vm.setEnv("LOG_CHUNK", "100");
        assertEq(h.logChunk(), 100);
    }

    /// L-5: the audit needs a second source at the same block; the C10 monitor export must match the RPC logs
    /// exactly (missing log, extra log or a different block fail closed). The provider path is fork-tested.
    function test_L5_secondSource_required_and_reconciled() public {
        Vm.EthGetLogs memory la = _queue(_payload(1, _one(address(t0), hex"8da5cb5b")));
        Vm.EthGetLogs memory lb = _queue(_payload(2, _one(address(t1), hex"8da5cb5b")));
        Vm.EthGetLogs[] memory raw = new Vm.EthGetLogs[](2);
        (raw[0], raw[1]) = (la, lb);
        CCIPRouteGates.QueuedLog[] memory logs = h.decodeQueued(raw);
        CCIPRouteGates.QueueReport memory r = h.classifyQueued(ex, logs, new bytes32[](0), _now());

        if (!vm.envExists("AUDIT_RPC_URL_2") && !vm.envExists("AUDIT_MONITOR_QUEUED_HASHES")) {
            vm.expectRevert(_err("L-5: second log source required (AUDIT_RPC_URL_2 or AUDIT_MONITOR_*)"));
            h.reconcileSecondSource(ex, logs, r);
        }

        bytes32[] memory seen = new bytes32[](2);
        (seen[0], seen[1]) = (lb.topics[1], la.topics[1]);
        h.reconcileWithMonitor(logs, seen, block.number);
        vm.expectRevert(_err("L-5: monitor export is not at the audited block"));
        h.reconcileWithMonitor(logs, seen, block.number + 1);
        vm.expectRevert(_err("L-5: Queued count differs from the monitor"));
        h.reconcileWithMonitor(logs, _h(la.topics[1]), block.number);
        seen[1] = keccak256("x");
        vm.expectRevert(_err("L-5: Queued log missing from the monitor"));
        h.reconcileWithMonitor(logs, seen, block.number);
    }

    /// L-c: a monitor export that is a strict superset of the RPC logs fails closed (count check), as does a
    ///      permutation-preserving superset with a duplicate.
    function test_Lc_monitorSuperset_rejected() public {
        Vm.EthGetLogs memory la = _queue(_payload(1, _one(address(t0), hex"8da5cb5b")));
        Vm.EthGetLogs[] memory raw = new Vm.EthGetLogs[](1);
        raw[0] = la;
        CCIPRouteGates.QueuedLog[] memory logs = h.decodeQueued(raw);
        bytes32[] memory seen = new bytes32[](2);
        (seen[0], seen[1]) = (la.topics[1], keccak256("extra"));
        vm.expectRevert(_err("L-5: Queued count differs from the monitor"));
        h.reconcileWithMonitor(logs, seen, block.number);
        seen[1] = la.topics[1];
        vm.expectRevert(_err("L-5: Queued count differs from the monitor"));
        h.reconcileWithMonitor(logs, seen, block.number);
    }

    /// L-c: the second provider must be a different host from the primary.
    function test_Lc_distinctHosts() public {
        h.requireDistinctHosts("https://eth.llamarpc.com", "https://ethereum-rpc.publicnode.com/x");
        h.requireDistinctHosts("https://a.example/key1", "https://b.example/key1");
        string[4] memory same = [
            "https://RPC.example.com/v2/key-b",
            "http://user:pw@rpc.example.com:8545",
            "https://rpc.example.com?x=1",
            "https://rpc.example.com/"
        ];
        for (uint256 i = 0; i < same.length; i++) {
            vm.expectRevert(_err("L-c: AUDIT_RPC_URL_2 must be a different host from AUDIT_RPC_URL_1"));
            h.requireDistinctHosts("https://rpc.example.com/v2/key-a", same[i]);
        }
        vm.expectRevert(_err("L-c: AUDIT_RPC_URL host missing"));
        h.requireDistinctHosts("", "https://rpc.example.com");
    }

    /// L-d: the transfer must be mined in TRANSFER_TX_BLOCK within [presign, presign + 72 h].
    function test_Ld_transferTiming() public {
        h.checkTransferTiming(101, 2000, 101, 1000);
        h.checkTransferTiming(101, 1000 + 72 hours, 101, 1000);
        vm.expectRevert(_err("L-d: transfer tx is not in TRANSFER_TX_BLOCK"));
        h.checkTransferTiming(102, 2000, 101, 1000);
        vm.expectRevert(_err("L-d: transfer mined outside the 72 h pre-sign window"));
        h.checkTransferTiming(101, 1001 + 72 hours, 101, 1000);
        vm.expectRevert(_err("L-d: transfer mined outside the 72 h pre-sign window"));
        h.checkTransferTiming(101, 999, 101, 1000);
        vm.expectRevert(_err("L-d: PRESIGN_AUDIT_TS required"));
        h.checkTransferTiming(101, 2000, 101, 0);
    }

    /// L-7: a pre-sign audit must fork the latest available block; the lag bound itself is capped.
    function test_L7_auditFreshness() public view {
        h.checkAuditFreshness(1000, 1000, 600);
        h.checkAuditFreshness(1000, 1600, 600);
        h.checkAuditFreshness(1000, 940, 600); // block clock up to 60 s ahead of the wall clock
    }

    function test_L7_auditFreshness_rejects() public {
        vm.expectRevert(_err("L-7: pre-sign audit must fork the latest available block"));
        h.checkAuditFreshness(1000, 1601, 600);
        vm.expectRevert(_err("L-7: pre-sign audit must fork the latest available block"));
        h.checkAuditFreshness(1000, 939, 600);
        vm.expectRevert(_err("L-7: AUDIT_MAX_LAG above 1 hour"));
        h.checkAuditFreshness(1000, 1000, 3601);
    }
}
