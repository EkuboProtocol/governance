// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {StarknetOwnerProxy} from "../src/StarknetOwnerProxy.sol";
import {CCIPGovernancePayload} from "../src/CCIPGovernancePayload.sol";
import {CCIPGovernanceSender} from "../src/CCIPGovernanceSender.sol";
import {CCIPOwnerExecutor} from "../src/CCIPOwnerExecutor.sol";
import {DeployCCIPOwnerRoute} from "./DeployCCIPOwnerRoute.s.sol";

interface IOwnableTarget {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external payable;
    function ownershipHandoverExpiresAt(address pendingOwner) external view returns (uint256);
}

/// @notice Read-only / fork-simulation gate checks for T5 and T6 of the A'-CCIP owner route (CSO EKU-1200 M-B,
///         L-1, L-2, D1-D6, I-1, I-2; EKU-1217). Nothing here broadcasts: run every entry point with `forge script`
///         and WITHOUT `--broadcast`. Simulations (`vm.prank`, `vm.store`, `vm.deal`) exist only on the local fork.
///
///         - `auditQueued()`            D2 / I-1 / I-2: every `Queued` log since deployment, reconciled; cancel-many
///                                      calldata for the unknown live ops; reverts unless clean.
///         - `checkGovernorMessages()`  L-1 / D5 / C9 (T5): exact Starknet->L1 messages fork-simulated end to end on
///                                      Ethereum after a FINALIZED `authority() == StarknetOwnerProxy` read-back.
///         - `checkProofOnEthereum()`   D1 (Ethereum side): `Requested` + `Dispatched` for the proof payload hash.
///         - `checkDirectTransfer()`    D1 / D2 / D3 / D5 / D6-config (T6, destination): exact executor + Safe +
///                                      sender + proof identity + clean queue, then the exact `transferOwnership`
///                                      calldata simulated per target. Run on a fork of the block immediately before
///                                      EACH transfer.
///         - `checkPostTransfer()`      D4: `owner() == executor` and `OwnershipTransferred(company, executor)` logs.
contract CCIPRouteGates is DeployCCIPOwnerRoute {
    Vm internal constant cheats = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant STARKNET_CORE = 0xc662c410C0ECf747543f5bA90660f6ABeBD9C8c4;
    bytes32 internal constant L1_PROXY_RUNTIME_KECCAK =
        0x36dd779b80b7e5d7aa29000cbf24b1811e2bb640055a53114f1bf7687a616fb3;
    bytes4 internal constant OWNER_SELECTOR = 0x8da5cb5b;
    uint8 internal constant STATUS_QUEUED = 1;
    uint8 internal constant STATUS_CANCELLED = 2;
    uint8 internal constant STATUS_EXECUTED = 3;

    struct QueuedLog {
        bytes32 payloadHash;
        bytes32 ccipMessageId;
        uint64 opId;
        uint64 eta;
        uint64 deadline;
        bytes payload;
        uint64 blockNumber;
    }

    /// @dev L-7 (CSO EKU-1218): Monad RPCs cap eth_getLogs at 100 blocks.
    uint256 internal constant MONAD_LOG_CHUNK = 100;
    /// @dev L-7: absolute ceiling between the pre-sign audit block and sending the transfer.
    uint256 internal constant AUDIT_SEND_CEILING = 72 hours;

    struct QueueReport {
        uint256 total;
        uint256 executed;
        uint256 cancelled;
        uint256 expired;
        bytes32[] knownLive;
        bytes32[] unknownLive;
    }

    // ---------------------------------------------------------------- D2: Queued enumeration

    /// @notice All logs of `topic0` (optionally `topic1`) from `emitter` in [fromBlock, toBlock], fetched from the
    ///         fork's RPC in `chunk`-block pages so no page exceeds the provider's range limit.
    function fetchLogs(
        address emitter,
        bytes32 topic0,
        bytes32 topic1,
        uint256 fromBlock,
        uint256 toBlock,
        uint256 chunk
    ) public returns (Vm.EthGetLogs[] memory all) {
        _eq(chunk != 0 && fromBlock <= toBlock, "fetchLogs range");
        bytes32[] memory topics = new bytes32[](topic1 == bytes32(0) ? 1 : 2);
        topics[0] = topic0;
        if (topic1 != bytes32(0)) topics[1] = topic1;
        all = new Vm.EthGetLogs[](0);
        for (uint256 b = fromBlock; b <= toBlock; b += chunk) {
            uint256 e = b + chunk - 1 > toBlock ? toBlock : b + chunk - 1;
            Vm.EthGetLogs[] memory page = cheats.eth_getLogs(b, e, emitter, topics);
            Vm.EthGetLogs[] memory merged = new Vm.EthGetLogs[](all.length + page.length);
            for (uint256 i = 0; i < all.length; i++) {
                merged[i] = all[i];
            }
            for (uint256 i = 0; i < page.length; i++) {
                _eq(page[i].emitter == emitter && page[i].blockNumber >= b && page[i].blockNumber <= e, "log page");
                merged[all.length + i] = page[i];
            }
            all = merged;
        }
    }

    function decodeQueued(Vm.EthGetLogs[] memory raw) public pure returns (QueuedLog[] memory q) {
        q = new QueuedLog[](raw.length);
        for (uint256 i = 0; i < raw.length; i++) {
            _eq(raw[i].topics.length == 4 && raw[i].topics[0] == CCIPOwnerExecutor.Queued.selector, "not a Queued log");
            (uint64 eta, uint64 deadline, bytes memory payload) = abi.decode(raw[i].data, (uint64, uint64, bytes));
            q[i] = QueuedLog({
                payloadHash: raw[i].topics[1],
                ccipMessageId: raw[i].topics[2],
                opId: uint64(uint256(raw[i].topics[3])),
                eta: eta,
                deadline: deadline,
                payload: payload,
                blockNumber: raw[i].blockNumber
            });
        }
    }

    function fetchQueued(address e, uint256 fromBlock, uint256 toBlock, uint256 chunk)
        public
        returns (QueuedLog[] memory)
    {
        checkChunk(chunk);
        return decodeQueued(fetchLogs(e, CCIPOwnerExecutor.Queued.selector, bytes32(0), fromBlock, toBlock, chunk));
    }

    /// @notice Reconciles every `Queued` log against the executor's current state. Closed = Executed, Cancelled, or
    ///         still Queued with `now > eta + executionWindow` (execute reverts `WindowElapsed`). Everything else is
    ///         live: manifest-known (`known`) or unknown. `unknownLive` holds only hashes whose on-chain status is
    ///         Queued right now, so a cancel-many built from it cannot hit the all-or-nothing revert (I-2).
    function classifyQueued(CCIPOwnerExecutor e, QueuedLog[] memory logs, bytes32[] memory known, uint256 nowTs)
        public
        view
        returns (QueueReport memory r)
    {
        uint64 window = e.executionWindow();
        bytes32[] memory kl = new bytes32[](logs.length);
        bytes32[] memory ul = new bytes32[](logs.length);
        uint256 nk;
        uint256 nu;
        for (uint256 i = 0; i < logs.length; i++) {
            QueuedLog memory q = logs[i];
            _eq(keccak256(q.payload) == q.payloadHash, "Queued payload does not hash to its payloadHash");
            for (uint256 j = 0; j < i; j++) {
                _eq(logs[j].payloadHash != q.payloadHash, "duplicate Queued payloadHash");
            }
            (uint8 version, uint256 chainId, address executor, uint64 opId, uint8 phase, uint64 deadline,) =
                CCIPGovernancePayload.decode(q.payload);
            _eq(
                version == CCIPGovernancePayload.VERSION && chainId == block.chainid && executor == address(e)
                    && opId == q.opId && phase == CCIPGovernancePayload.PHASE_GOVERNOR && deadline == q.deadline,
                "Queued payload fields do not match the log"
            );
            (CCIPOwnerExecutor.OpStatus st, uint64 sOpId, uint64 sEta) = e.ops(q.payloadHash);
            uint8 status = uint8(st);
            _eq(status != 0 && sOpId == q.opId && sEta == q.eta, "ops() does not match the Queued log");
            r.total++;
            if (status == STATUS_EXECUTED) {
                r.executed++;
            } else if (status == STATUS_CANCELLED) {
                r.cancelled++;
            } else if (nowTs > uint256(sEta) + window) {
                r.expired++;
            } else if (_contains(known, q.payloadHash)) {
                kl[nk++] = q.payloadHash;
            } else {
                ul[nu++] = q.payloadHash;
            }
        }
        r.knownLive = _trim(kl, nk);
        r.unknownLive = _trim(ul, nu);
    }

    /// @notice D2 at the forked block (pin `--fork-block-number` to the block immediately before the transfer).
    ///         Env: EXECUTOR, EXECUTOR_DEPLOY_BLOCK, optional KNOWN_PAYLOAD_HASHES (comma list), LOG_CHUNK, and a
    ///         second log source for L-5 (AUDIT_RPC_URL_2, or AUDIT_MONITOR_QUEUED_HASHES + AUDIT_MONITOR_BLOCK).
    function auditQueued() external returns (QueueReport memory r) {
        r = _audit(CCIPOwnerExecutor(vm.envAddress("EXECUTOR")));
        requireClean(r);
    }

    function _audit(CCIPOwnerExecutor e) internal returns (QueueReport memory r) {
        uint256 from = vm.envUint("EXECUTOR_DEPLOY_BLOCK");
        bytes32[] memory known = vm.envOr("KNOWN_PAYLOAD_HASHES", ",", new bytes32[](0));
        QueuedLog[] memory logs = fetchQueued(address(e), from, block.number, logChunk());
        r = classifyQueued(e, logs, known, vm.getBlockTimestamp());
        reconcileSecondSource(e, logs, r);
        console.log("D2 audit: chain, block", block.chainid, block.number);
        console.log("  executor", address(e));
        console.log("  Queued logs / executed / cancelled", r.total, r.executed, r.cancelled);
        console.log("  expired / known live / UNKNOWN LIVE", r.expired, r.knownLive.length, r.unknownLive.length);
        for (uint256 i = 0; i < r.knownLive.length; i++) {
            console.log("  known live");
            console.logBytes32(r.knownLive[i]);
        }
        if (r.unknownLive.length != 0) {
            console.log("  canceller Safe must submit to the executor, before any transfer: cancel(bytes32[])");
            console.logBytes(abi.encodeCall(CCIPOwnerExecutor.cancel, (r.unknownLive)));
        }
    }

    function requireClean(QueueReport memory r) public pure {
        _eq(r.unknownLive.length == 0, "D2: unknown live Queued op(s); Safe must cancel before any transfer");
        _eq(r.knownLive.length <= 1, "I-1: more than one GOVERNOR op in flight");
    }

    /// @notice L-4 (CSO EKU-1218): at a transfer no operation may be live at all, known or not, and the known list is
    ///         exactly the harmless proof hash recorded in manifest section 6.
    function requireTransferClean(QueueReport memory r, bytes32[] memory known, bytes32 proofHash) public pure {
        requireClean(r);
        _eq(r.knownLive.length == 0, "L-4: knownLive must be zero at a transfer");
        _eq(known.length == 1 && known[0] == proofHash, "L-4: KNOWN_PAYLOAD_HASHES must be exactly the proof hash");
    }

    function isMonad(uint256 cid) public pure returns (bool) {
        return cid == 143 || cid == 10143;
    }

    /// @notice Page size for every gate log query; L-7: at most 100 blocks on Monad.
    function logChunk() public view returns (uint256 chunk) {
        chunk = vm.envOr("LOG_CHUNK", isMonad(block.chainid) ? MONAD_LOG_CHUNK : uint256(1000));
        checkChunk(chunk);
    }

    function checkChunk(uint256 chunk) public view {
        _eq(chunk != 0, "LOG_CHUNK zero");
        _eq(!isMonad(block.chainid) || chunk <= MONAD_LOG_CHUNK, "L-7: Monad LOG_CHUNK must be <= 100");
    }

    // ---------------------------------------------------------------- L-5: second, independent log source

    /// @notice L-5 (CSO EKU-1218): reconciles the audit against a second source at the SAME block and fails closed on
    ///         any difference or when no second source is configured. Source 2 is `AUDIT_RPC_URL_2` (an independent
    ///         provider forked at this block) or the C10 monitor export `AUDIT_MONITOR_QUEUED_HASHES` at
    ///         `AUDIT_MONITOR_BLOCK`.
    function reconcileSecondSource(CCIPOwnerExecutor e, QueuedLog[] memory logs, QueueReport memory r) public {
        if (vm.envExists("AUDIT_RPC_URL_2")) {
            requireDistinctHosts(vm.envString("AUDIT_RPC_URL_1"), vm.envString("AUDIT_RPC_URL_2"));
            reconcileWithProvider(
                e,
                logs,
                r,
                vm.envString("AUDIT_RPC_URL_2"),
                vm.envUint("EXECUTOR_DEPLOY_BLOCK"),
                vm.envOr("KNOWN_PAYLOAD_HASHES", ",", new bytes32[](0))
            );
        } else if (vm.envExists("AUDIT_MONITOR_QUEUED_HASHES")) {
            reconcileWithMonitor(
                logs, vm.envBytes32("AUDIT_MONITOR_QUEUED_HASHES", ","), vm.envUint("AUDIT_MONITOR_BLOCK")
            );
        } else {
            revert VerificationFailed("L-5: second log source required (AUDIT_RPC_URL_2 or AUDIT_MONITOR_*)");
        }
    }

    /// @notice L-c (CSO EKU-1233): the second provider must be a different host from the primary `AUDIT_RPC_URL_1`
    ///         (which the runbook passes as --fork-url/--rpc-url). Scheme, userinfo, port, path and case are ignored.
    function requireDistinctHosts(string memory url1, string memory url2) public pure {
        bytes memory h1 = _host(url1);
        bytes memory h2 = _host(url2);
        _eq(h1.length != 0 && h2.length != 0, "L-c: AUDIT_RPC_URL host missing");
        _eq(keccak256(h1) != keccak256(h2), "L-c: AUDIT_RPC_URL_2 must be a different host from AUDIT_RPC_URL_1");
    }

    function _host(string memory url) internal pure returns (bytes memory h) {
        bytes memory u = bytes(url);
        uint256 i;
        for (uint256 j = 0; j + 2 < u.length; j++) {
            if (u[j] == ":" && u[j + 1] == "/" && u[j + 2] == "/") {
                i = j + 3;
                break;
            }
        }
        uint256 start = i;
        uint256 end = u.length;
        for (uint256 j = i; j < u.length; j++) {
            bytes1 c = u[j];
            if (c == "@") start = j + 1;
            if (c == "/" || c == "?" || c == "#") {
                end = j;
                break;
            }
        }
        uint256 colon = end;
        for (uint256 j = start; j < end; j++) {
            if (u[j] == ":") colon = j;
        }
        h = new bytes(colon > start ? colon - start : 0);
        for (uint256 j = 0; j < h.length; j++) {
            bytes1 c = u[start + j];
            h[j] = (c >= "A" && c <= "Z") ? bytes1(uint8(c) + 32) : c;
        }
    }

    /// @notice L-5 with an independent RPC provider forked at the current block: the parent block hash, timestamp,
    ///         every Queued log and the ops() classification must match exactly. The caller's fork is restored.
    function reconcileWithProvider(
        CCIPOwnerExecutor e,
        QueuedLog[] memory logs,
        QueueReport memory r,
        string memory rpc2,
        uint256 fromBlock,
        bytes32[] memory known
    ) public {
        uint256 b = block.number;
        bytes32 parent = blockhash(b - 1);
        uint256 ts = block.timestamp;
        _eq(parent != bytes32(0), "L-5: parent block hash unavailable");
        uint256 primary = vm.activeFork();
        vm.createSelectFork(rpc2, b);
        _eq(block.number == b && blockhash(b - 1) == parent && block.timestamp == ts, "L-5: provider 2 block");
        QueuedLog[] memory logs2 = fetchQueued(address(e), fromBlock, b, logChunk());
        QueueReport memory r2 = classifyQueued(e, logs2, known, ts);
        vm.selectFork(primary);
        _eq(block.number == b, "L-5: primary fork not restored");
        _eq(logs2.length == logs.length, "L-5: Queued log count differs between providers");
        for (uint256 i = 0; i < logs.length; i++) {
            _eq(
                logs2[i].payloadHash == logs[i].payloadHash && logs2[i].ccipMessageId == logs[i].ccipMessageId
                    && logs2[i].opId == logs[i].opId && logs2[i].eta == logs[i].eta
                    && logs2[i].deadline == logs[i].deadline && logs2[i].blockNumber == logs[i].blockNumber
                    && keccak256(logs2[i].payload) == keccak256(logs[i].payload),
                "L-5: Queued log differs between providers"
            );
        }
        _eq(
            keccak256(abi.encode(r2)) == keccak256(abi.encode(r)), "L-5: ops() classification differs between providers"
        );
        console.log("L-5: provider 2 reconciled at block", b);
    }

    /// @notice L-5 with the C10 monitor's export: every Queued payloadHash it saw up to `monitorBlock`.
    function reconcileWithMonitor(QueuedLog[] memory logs, bytes32[] memory seen, uint256 monitorBlock) public view {
        _eq(monitorBlock == block.number, "L-5: monitor export is not at the audited block");
        _eq(seen.length == logs.length, "L-5: Queued count differs from the monitor");
        for (uint256 i = 0; i < logs.length; i++) {
            _eq(_contains(seen, logs[i].payloadHash), "L-5: Queued log missing from the monitor");
        }
        console.log("L-5: C10 monitor export reconciled at block", monitorBlock);
    }

    // ---------------------------------------------------------------- L-1: Governor messages (T5)

    function _denied(bytes4 sel) internal pure returns (bool) {
        return sel == 0xf2fde38b // transferOwnership(address)
            || sel == 0x715018a6 // renounceOwnership()
            || sel == 0x25692962 // requestOwnershipHandover()
            || sel == 0xf04e283e // completeOwnershipHandover(address)
            || sel == 0x54d1f13d; // cancelOwnershipHandover()
    }

    /// @notice Decodes a StarknetOwnerProxy message payload (felts) and rejects any non-canonical encoding.
    function decodeL1Message(uint256[] memory felts)
        public
        pure
        returns (address target, uint256 value, uint64 nonce, bytes memory data)
    {
        _eq(felts.length >= 4, "L1 message too short");
        _eq(felts[0] >> 160 == 0 && felts[2] >> 64 == 0, "L1 message header");
        target = address(uint160(felts[0]));
        value = felts[1];
        nonce = uint64(felts[2]);
        uint256 len = felts[3];
        uint256 chunks = (len + 30) / 31;
        _eq(felts.length == 4 + chunks, "L1 message length");
        data = new bytes(chunks * 31);
        for (uint256 i = 0; i < chunks; i++) {
            uint256 f = felts[4 + i];
            _eq(f >> 248 == 0, "L1 message chunk > 31 bytes");
            for (uint256 k = 0; k < 31; k++) {
                data[i * 31 + k] = bytes1(uint8(f >> (8 * (30 - k))));
            }
        }
        assembly ("memory-safe") {
            mstore(data, len)
        }
    }

    /// @notice Static L-1 / D5 / I-1 checks on one decoded message. Returns the request arguments.
    function checkRequestCalldata(address senderAddr, address target, uint256 value, bytes memory data, bool proofOnly)
        public
        pure
        returns (uint64 dest, uint32 gasLimit, uint64 deadline, CCIPGovernancePayload.Call[] memory calls)
    {
        _eq(target == senderAddr, "L-1: L1 message target != sender");
        _eq(value == 0, "L-1: L1 message value != 0");
        _eq(data.length >= 4 && bytes4(data) == CCIPGovernanceSender.request.selector, "L-1: not request()");
        bytes memory args = new bytes(data.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = data[i + 4];
        }
        (dest, gasLimit, deadline, calls) = abi.decode(args, (uint64, uint32, uint64, CCIPGovernancePayload.Call[]));
        _eq(
            keccak256(abi.encodeCall(CCIPGovernanceSender.request, (dest, gasLimit, deadline, calls)))
                == keccak256(data),
            "L-1: non-canonical request calldata"
        );
        _eq(dest == BNB_SELECTOR || dest == MONAD_SELECTOR, "L-1: destination selector");
        _eq(gasLimit >= 100_000 && gasLimit <= PROD_MAX_GAS_LIMIT, "L-1: gasLimit outside [100000, 1000000]");
        _eq(calls.length >= 1 && calls.length <= CCIPGovernancePayload.MAX_CALLS, "L-1: call count outside 1..8");
        address[] memory ts = targetsFor(dest == BNB_SELECTOR ? 56 : 143);
        for (uint256 i = 0; i < calls.length; i++) {
            _eq(_containsAddr(ts, calls[i].target), "L-1: call target not pinned");
            _eq(calls[i].data.length >= 4, "L-1: call data < 4 bytes");
            _eq(!_denied(bytes4(calls[i].data)), "D5: ownership mutator in Governor op");
        }
        if (proofOnly) {
            _eq(calls.length == ts.length, "D5: owner() proof must cover every target");
            for (uint256 i = 0; i < ts.length; i++) {
                _eq(
                    calls[i].target == ts[i] && keccak256(calls[i].data) == keccak256(abi.encodePacked(OWNER_SELECTOR)),
                    "D5: owner() proof call"
                );
            }
        }
    }

    /// @notice T5 gate on an Ethereum fork. Env: SENDER, SENDER_RUNTIME_KECCAK, EXECUTOR_56, EXECUTOR_143,
    ///         ETH_RPC_URL, L1_MESSAGE_0 and optional L1_MESSAGE_1 (comma-separated felts exactly as in the Starknet
    ///         proposal), PROOF_ONLY (default true), DEADLINE_MIN_FROM_NOW (default 7 days).
    function checkGovernorMessages() external {
        _eq(block.chainid == 1, "Ethereum only");
        address senderAddr = vm.envAddress("SENDER");
        bytes32 senderHash = vm.envBytes32("SENDER_RUNTIME_KECCAK");
        address eb = vm.envAddress(_key("EXECUTOR", 56));
        address em = vm.envAddress(_key("EXECUTOR", 143));

        // L-1 / L-2: FINALIZED read-back of the handoff and the sender identity, then the same on the fork.
        verifySender(
            remote(vm.envString("ETH_RPC_URL"), "finalized"), productionSender(senderAddr, L1_PROXY, eb, em, senderHash)
        );
        verifySender(local(), productionSender(senderAddr, L1_PROXY, eb, em, senderHash));
        _eq(keccak256(L1_PROXY.code) == L1_PROXY_RUNTIME_KECCAK, "StarknetOwnerProxy runtime keccak");

        uint256 count = vm.envExists("L1_MESSAGE_1") ? 2 : 1;
        uint64 firstDest;
        bool proofOnly = vm.envOr("PROOF_ONLY", true);
        uint256 minFromNow = vm.envOr("DEADLINE_MIN_FROM_NOW", uint256(7 days));
        for (uint256 k = 0; k < count; k++) {
            uint64 dest = simulateGovernorMessage(
                senderAddr, eb, em, vm.envUint(k == 0 ? "L1_MESSAGE_0" : "L1_MESSAGE_1", ","), proofOnly, minFromNow
            );
            _eq(k == 0 || dest != firstDest, "I-1: one GOVERNOR op per executor per proposal");
            firstDest = dest;
        }
        console.log("T5 messages PASSED (fork simulation only; nothing sent)");
    }

    /// @notice Exact-calldata fork simulation of one Starknet->L1 message: canonical felts, in-order nonce, static
    ///         L-1 / D5 checks, then simulated settlement, `StarknetOwnerProxy.execute` and `dispatch`, asserting the
    ///         sender records exactly the expected destination payload.
    function simulateGovernorMessage(
        address senderAddr,
        address eb,
        address em,
        uint256[] memory felts,
        bool proofOnly,
        uint256 minFromNow
    ) public returns (uint64 dest) {
        StarknetOwnerProxy proxy = StarknetOwnerProxy(payable(L1_PROXY));
        CCIPGovernanceSender s = CCIPGovernanceSender(senderAddr);
        _eq(s.authority() == L1_PROXY, "L-1: sender authority != StarknetOwnerProxy");
        (address target, uint256 value, uint64 nonce, bytes memory data) = decodeL1Message(felts);
        _eq(
            keccak256(abi.encode(proxy.getPayload(target, value, nonce, data))) == keccak256(abi.encode(felts)),
            "L1 felts canonical"
        );
        _eq(nonce == proxy.currentNonce(), "C9: message nonce != proxy currentNonce (in order)");
        uint64 deadline;
        CCIPGovernancePayload.Call[] memory calls;
        (dest,, deadline, calls) = checkRequestCalldata(senderAddr, target, value, data, proofOnly);
        uint256 nowTs = vm.getBlockTimestamp();
        _eq(deadline >= nowTs + minFromNow, "deadline too early");
        _eq(deadline <= nowTs + PROD_TTL, "I-3: deadline > now + maxTtl would fail DeadlineTooFar");

        bytes memory expected = CCIPGovernancePayload.encode(
            dest == BNB_SELECTOR ? 56 : 143,
            dest == BNB_SELECTOR ? eb : em,
            s.nextOpId(dest) + 1,
            CCIPGovernancePayload.PHASE_GOVERNOR,
            deadline,
            calls
        );

        _injectStarknetMessage(felts);
        cheats.recordLogs();
        proxy.execute(target, value, nonce, data);
        _eq(proxy.currentNonce() == nonce + 1, "nonce not consumed");
        _eq(
            _hasLog(cheats.getRecordedLogs(), senderAddr, CCIPGovernanceSender.Requested.selector, keccak256(expected)),
            "Requested(expected payload)"
        );
        address payer = address(uint160(uint256(keccak256("eku-1217-sim-payer"))));
        cheats.deal(payer, 1 ether);
        cheats.prank(payer);
        bytes32 mid = s.dispatch{value: 0.1 ether}(expected);
        console.log("proxy nonce", nonce);
        console.log("  requestId = payloadHash, then simulated ccipMessageId");
        console.logBytes32(keccak256(expected));
        console.logBytes32(mid);
        console.log("  destination payload");
        console.logBytes(expected);
    }

    function _injectStarknetMessage(uint256[] memory payload) internal {
        uint256 l2Owner = StarknetOwnerProxy(payable(L1_PROXY)).l2Owner();
        bytes32 msgHash = keccak256(abi.encodePacked(l2Owner, uint256(uint160(L1_PROXY)), payload.length, payload));
        bytes32 base = keccak256(abi.encodePacked("STARKNET_1.0_MSGING_L2TOL1_MAPPPING"));
        cheats.store(STARKNET_CORE, keccak256(abi.encode(msgHash, base)), bytes32(uint256(1)));
    }

    // ---------------------------------------------------------------- D1: Ethereum side of the proof

    /// @notice Env: SENDER, PROOF_PAYLOAD, PROOF_CCIP_MESSAGE_ID, SENDER_DEPLOY_BLOCK, LOG_CHUNK.
    function checkProofOnEthereum() external {
        _eq(block.chainid == 1, "Ethereum only");
        address senderAddr = vm.envAddress("SENDER");
        bytes memory payload = vm.envBytes("PROOF_PAYLOAD");
        bytes32 h = keccak256(payload);
        bytes32 mid = vm.envBytes32("PROOF_CCIP_MESSAGE_ID");
        uint256 from = vm.envUint("SENDER_DEPLOY_BLOCK");
        uint256 chunk = logChunk();
        _eq(CCIPGovernanceSender(senderAddr).authority() == L1_PROXY, "authority");
        (CCIPGovernanceSender.RequestStatus st,,) = CCIPGovernanceSender(senderAddr).requests(h);
        _eq(uint8(st) == 2, "D1: proof request not Dispatched");
        Vm.EthGetLogs[] memory req =
            fetchLogs(senderAddr, CCIPGovernanceSender.Requested.selector, h, from, block.number, chunk);
        _eq(req.length == 1, "D1: exactly one Requested(payloadHash)");
        (uint8 phase,,, bytes memory logged) = abi.decode(req[0].data, (uint8, uint32, uint64, bytes));
        _eq(phase == CCIPGovernancePayload.PHASE_GOVERNOR && keccak256(logged) == h, "D1: Requested payload");
        Vm.EthGetLogs[] memory dis =
            fetchLogs(senderAddr, CCIPGovernanceSender.Dispatched.selector, h, from, block.number, chunk);
        _eq(dis.length == 1 && dis[0].topics[3] == mid, "D1: Dispatched(payloadHash, ccipMessageId)");
        console.log("D1 Ethereum: Requested tx / Dispatched tx");
        console.logBytes32(req[0].transactionHash);
        console.logBytes32(dis[0].transactionHash);
    }

    // ---------------------------------------------------------------- T6: direct transfer, per destination

    /// @notice Run on a fork of the destination at the block immediately before EACH transfer. Env: EXECUTOR_<cid>,
    ///         EXECUTOR_RUNTIME_KECCAK_<cid>, SAFE_* / CANCELLER_<cid>, SENDER, SENDER_RUNTIME_KECCAK, EXECUTOR_56,
    ///         EXECUTOR_143, ETH_RPC_URL, PROOF_PAYLOAD, PROOF_CCIP_MESSAGE_ID, EXECUTOR_DEPLOY_BLOCK,
    ///         KNOWN_PAYLOAD_HASHES, optional TRANSFER_TARGET (default: every target still owned by the company key).
    function checkDirectTransfer() external {
        uint256 cid = block.chainid;
        CCIPOwnerExecutor e = CCIPOwnerExecutor(vm.envAddress(_key("EXECUTOR", cid)));
        address senderAddr = vm.envAddress("SENDER");

        // D1 / D6 configuration: exact executor, exact Safe, exact sender with finalized authority.
        SafeExpect memory safe = safeExpectFromEnv(cid);
        requireReal(safe.safe, _key("CANCELLER", cid));
        verifySafe(local(), safe);
        verifyExecutor(
            local(),
            productionExecutor(
                cid, address(e), senderAddr, safe.safe, vm.envBytes32(_key("EXECUTOR_RUNTIME_KECCAK", cid))
            )
        );
        Src memory eth = remote(vm.envString("ETH_RPC_URL"), "finalized");
        verifySender(
            eth,
            productionSender(
                senderAddr,
                L1_PROXY,
                vm.envAddress(_key("EXECUTOR", 56)),
                vm.envAddress(_key("EXECUTOR", 143)),
                vm.envBytes32("SENDER_RUNTIME_KECCAK")
            )
        );

        // D1 / D5: the proof is this chain's owner()-only batch, executed by THIS executor, and dispatched on L1.
        bytes memory proof = vm.envBytes("PROOF_PAYLOAD");
        bytes32 h = keccak256(proof);
        checkProofPayload(e, proof);
        (CCIPOwnerExecutor.OpStatus st,,) = e.ops(h);
        _eq(st == CCIPOwnerExecutor.OpStatus.Executed, "D3: proof op not Executed on this chain");
        uint256 from = vm.envUint("EXECUTOR_DEPLOY_BLOCK");
        uint256 chunk = logChunk();
        _eq(
            fetchLogs(address(e), CCIPOwnerExecutor.Executed.selector, h, from, block.number, chunk).length == 1,
            "D1: Executed(proof) emitted by executor"
        );
        Vm.EthGetLogs[] memory q =
            fetchLogs(address(e), CCIPOwnerExecutor.Queued.selector, h, from, block.number, chunk);
        _eq(
            q.length == 1 && q[0].topics[2] == vm.envBytes32("PROOF_CCIP_MESSAGE_ID"), "D1: Queued(proof) ccipMessageId"
        );
        bytes memory reqView = _call(eth, senderAddr, abi.encodeWithSignature("requests(bytes32)", h));
        (uint8 rs, uint64 rDest,) = abi.decode(reqView, (uint8, uint64, uint32));
        _eq(rs == 2 && rDest == selectorFor(cid), "D1: proof not Dispatched to this chain on Ethereum (finalized)");

        // L-7: the pre-sign audit forks the latest available block; a post-transfer audit is evidence only.
        if (keccak256(bytes(vm.envOr("AUDIT_MODE", string("presign")))) == keccak256("post")) {
            _eq(vm.envUint("TRANSFER_TX_BLOCK") == block.number + 1, "L-7: post audit must fork transferBlock - 1");
            checkTransferReceipt(
                vm.envBytes32("TRANSFER_TX_HASH"), vm.envUint("TRANSFER_TX_BLOCK"), vm.envUint("PRESIGN_AUDIT_TS")
            );
            console.log("L-7: POST-TRANSFER AUDIT AT transferBlock - 1: EVIDENCE ONLY, NOT A PRE-SIGN APPROVAL");
        } else {
            checkAuditFreshness(block.timestamp, vm.unixTime() / 1000, vm.envOr("AUDIT_MAX_LAG", uint256(600)));
            console.log(
                "L-7: audit block timestamp, absolute send ceiling (unix)",
                block.timestamp,
                block.timestamp + AUDIT_SEND_CEILING
            );
        }

        // D2 + L-4 + L-5 at this block.
        requireTransferClean(_audit(e), vm.envOr("KNOWN_PAYLOAD_HASHES", ",", new bytes32[](0)), h);

        // D3: exact calldata, simulated.
        simulateTransfers(e, vm.envOr("TRANSFER_TARGET", address(0)));
        console.log("T6 pre-transfer checks PASSED at block", block.number);
    }

    /// @notice L-d (CSO EKU-1233): the transfer transaction is mined in `txBlock`, whose timestamp lies within the
    ///         72 h send ceiling of the pre-sign audit (`presignTs` = the audited block timestamp the pre-sign run
    ///         printed). The active fork is rolled to the transaction and restored.
    function checkTransferReceipt(bytes32 txHash, uint256 txBlock, uint256 presignTs) public {
        uint256 back = block.number;
        vm.rollFork(txHash);
        uint256 b = block.number;
        uint256 ts = block.timestamp;
        vm.rollFork(back);
        _eq(block.number == back, "L-d: fork not restored");
        checkTransferTiming(b, ts, txBlock, presignTs);
    }

    function checkTransferTiming(uint256 minedBlock, uint256 minedTs, uint256 txBlock, uint256 presignTs)
        public
        pure
    {
        _eq(presignTs != 0, "L-d: PRESIGN_AUDIT_TS required");
        _eq(minedBlock == txBlock, "L-d: transfer tx is not in TRANSFER_TX_BLOCK");
        _eq(
            minedTs >= presignTs && minedTs <= presignTs + AUDIT_SEND_CEILING,
            "L-d: transfer mined outside the 72 h pre-sign window"
        );
    }

    /// @notice L-7: the pre-sign audit block must be the latest available one (within `maxLag` seconds of wall time).
    function checkAuditFreshness(uint256 blockTs, uint256 wallTs, uint256 maxLag) public pure {
        _eq(maxLag <= 1 hours, "L-7: AUDIT_MAX_LAG above 1 hour");
        _eq(
            wallTs + 60 >= blockTs && wallTs <= blockTs + maxLag,
            "L-7: pre-sign audit must fork the latest available block"
        );
    }

    /// @notice D3 / D4 / D5: simulates the exact `transferOwnership(executor)` calldata from the company key on each
    ///         pinned target (or only `only`), asserting the post-state and the single `OwnershipTransferred` log.
    function simulateTransfers(CCIPOwnerExecutor e, address only) public {
        address[] memory ts = e.targets();
        _eq(only == address(0) || _containsAddr(ts, only), "TRANSFER_TARGET not pinned");
        for (uint256 i = 0; i < ts.length; i++) {
            if (only != address(0) && ts[i] != only) continue;
            IOwnableTarget t = IOwnableTarget(ts[i]);
            if (only == address(0) && t.owner() == address(e)) {
                console.log("already owned by executor", ts[i]);
                continue;
            }
            _eq(t.owner() == COMPANY_KEY, "target owner is not the company key");
            bytes memory data = abi.encodeCall(IOwnableTarget.transferOwnership, (address(e)));
            cheats.recordLogs();
            cheats.prank(COMPANY_KEY);
            (bool ok,) = ts[i].call(data);
            _eq(ok, "D3: simulated transferOwnership failed");
            _eq(t.owner() == address(e), "D3: owner() != executor after simulation");
            _eq(t.ownershipHandoverExpiresAt(address(e)) == 0, "D5: handover state present");
            Vm.Log[] memory logs = cheats.getRecordedLogs();
            _eq(
                logs.length == 1 && logs[0].emitter == ts[i]
                    && logs[0].topics[0] == keccak256("OwnershipTransferred(address,address)")
                    && logs[0].topics[1] == bytes32(uint256(uint160(COMPANY_KEY)))
                    && logs[0].topics[2] == bytes32(uint256(uint160(address(e)))),
                "D4: exactly OwnershipTransferred(company, executor)"
            );
            console.log("SIMULATED ONLY. Sign from the company key: to, value 0, data", ts[i]);
            console.logBytes(data);
        }
    }

    function checkProofPayload(CCIPOwnerExecutor e, bytes memory proof) public view {
        (uint8 version, uint256 chainId, address executor,, uint8 phase,, CCIPGovernancePayload.Call[] memory calls) =
            CCIPGovernancePayload.decode(proof);
        _eq(
            version == CCIPGovernancePayload.VERSION && chainId == block.chainid && executor == address(e)
                && phase == CCIPGovernancePayload.PHASE_GOVERNOR,
            "D1: proof payload identity"
        );
        address[] memory ts = e.targets();
        _eq(calls.length == ts.length, "D5: proof must call every target");
        for (uint256 i = 0; i < ts.length; i++) {
            _eq(
                calls[i].target == ts[i] && keccak256(calls[i].data) == keccak256(abi.encodePacked(OWNER_SELECTOR)),
                "D5: proof must be owner() only"
            );
        }
    }

    /// @notice D4 after the transfers. Env: EXECUTOR_<cid>, TRANSFER_FROM_BLOCK, TRANSFER_TX_BLOCK, PRESIGN_AUDIT_TS,
    ///         LOG_CHUNK. L-d: every transfer log is in TRANSFER_TX_BLOCK, within 72 h of the pre-sign audit.
    function checkPostTransfer() external {
        uint256 cid = block.chainid;
        address e = vm.envAddress(_key("EXECUTOR", cid));
        uint256 from = vm.envUint("TRANSFER_FROM_BLOCK");
        uint256 txBlock = vm.envUint("TRANSFER_TX_BLOCK");
        uint256 presignTs = vm.envUint("PRESIGN_AUDIT_TS");
        uint256 chunk = logChunk();
        address[] memory ts = targetsFor(cid);
        for (uint256 i = 0; i < ts.length; i++) {
            _eq(IOwnableTarget(ts[i]).owner() == e, "D4: owner() != executor");
            Vm.EthGetLogs[] memory l = fetchLogs(
                ts[i],
                keccak256("OwnershipTransferred(address,address)"),
                bytes32(uint256(uint160(COMPANY_KEY))),
                from,
                block.number,
                chunk
            );
            _eq(
                l.length == 1 && l[0].topics[2] == bytes32(uint256(uint160(e))),
                "D4: OwnershipTransferred(company, executor)"
            );
            _eq(l[0].blockNumber == txBlock, "L-d: transfer log is not in TRANSFER_TX_BLOCK");
            checkTransferReceipt(l[0].transactionHash, txBlock, presignTs);
            console.log("transferred", ts[i]);
            console.logBytes32(l[0].transactionHash);
        }
    }

    // ---------------------------------------------------------------- utils

    function _contains(bytes32[] memory xs, bytes32 x) internal pure returns (bool) {
        for (uint256 i = 0; i < xs.length; i++) {
            if (xs[i] == x) return true;
        }
        return false;
    }

    function _containsAddr(address[] memory xs, address x) internal pure returns (bool) {
        for (uint256 i = 0; i < xs.length; i++) {
            if (xs[i] == x) return true;
        }
        return false;
    }

    function _trim(bytes32[] memory xs, uint256 n) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = xs[i];
        }
    }

    function _hasLog(Vm.Log[] memory logs, address emitter, bytes32 topic0, bytes32 topic1)
        internal
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == emitter && logs[i].topics.length > 1 && logs[i].topics[0] == topic0
                    && logs[i].topics[1] == topic1
            ) {
                return true;
            }
        }
        return false;
    }
}
