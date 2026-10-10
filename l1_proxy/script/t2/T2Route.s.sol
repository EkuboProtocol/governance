// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IRouterClient} from "../../vendor/ccip-2.0.0/interfaces/IRouterClient.sol";
import {IRouter} from "../../vendor/ccip-2.0.0/interfaces/IRouter.sol";
import {Client} from "../../vendor/ccip-2.0.0/libraries/Client.sol";
import {StarknetOwnerProxy, IStarknetMessaging} from "../../src/StarknetOwnerProxy.sol";
import {CCIPGovernancePayload} from "../../src/CCIPGovernancePayload.sol";
import {CCIPGovernanceSender} from "../../src/CCIPGovernanceSender.sol";
import {CCIPOwnerExecutor} from "../../src/CCIPOwnerExecutor.sol";
import {T2DummyTarget} from "./T2DummyTarget.sol";
import {T2Config, ISafeProxyFactory141, ISafe141, IStarknetCoreView} from "./T2Config.sol";

/// @notice TESTNET-ONLY runner for the T2 real-delivery rehearsal (EKU-1232). NOT AUTHORIZED TO BROADCAST until the
///         T2 authorization (keys, funding, exact pack revision) is approved. Every step asserts its chain, its key's
///         nonce, the predicted address and an exact read-back, and fails closed otherwise.
///
///         `T2_MODE` is required: `testnet` (all identities must be real, never placeholders, fixtures, the
///         company key or the production L1 proxy) or `dryrun` (refuses `--broadcast`/`--resume`, accepts the
///         `0x1232…` placeholders and prints NOT EXECUTABLE). Production chains 1, 56, 143 are always refused.
///
///         Env: T2_DEPLOYER, T2_BOOTSTRAP, T2_SAFE_OWNERS (3, comma), T2_SAFE_SALT, T2_L2_GOVERNOR (felt),
///         SEPOLIA_RPC_URL, BNB_TESTNET_RPC_URL, MONAD_TESTNET_RPC_URL. Step-specific variables are listed per step.
///         Order: t2ProxyStep (Sepolia) -> t2DestStep (97, then 10143 with --network monad) -> t2SenderStep
///         (Sepolia) -> t2VerifyRoute -> pings -> handoff -> proposals.
contract T2Route is T2Config {
    /// @dev `StarknetOwnerProxy(0x1E0E…).l2Owner()` on Ethereum mainnet; never a T2 input.
    uint256 internal constant PRODUCTION_L2_GOVERNOR =
        0x053499f7aa2706395060fe72d00388803fb2dcc111429891ad7b2d9dcea29acd;

    // ---------------------------------------------------------------- mode and identities

    function _testnet() internal view returns (bool) {
        requireT2Chain();
        bytes32 m = keccak256(bytes(vm.envString("T2_MODE")));
        if (m == keccak256("testnet")) return true;
        if (m == keccak256("dryrun")) {
            if (!vm.isContext(VmSafe.ForgeContext.ScriptDryRun) && !vm.isContext(VmSafe.ForgeContext.Test)) {
                revert VerificationFailed("T2 dryrun refuses --broadcast and --resume");
            }
            console.log("T2 DRY RUN: placeholders accepted; output is NOT EXECUTABLE");
            return false;
        }
        revert VerificationFailed("T2_MODE must be testnet or dryrun");
    }

    function _id(bool testnet, string memory name) internal view returns (address a) {
        a = vm.envAddress(name);
        if (testnet && isT2Placeholder(a)) revert VerificationFailed(string.concat(name, ": placeholder or fixture"));
        _eq(a != COMPANY_KEY && a != L1_PROXY, string.concat(name, ": production identity"));
    }

    function _owners(bool testnet) internal view returns (address[] memory o) {
        o = vm.envAddress("T2_SAFE_OWNERS", ",");
        _eq(o.length == T2_SAFE_OWNER_COUNT, "T2_SAFE_OWNERS: exactly 3");
        address deployer = vm.envAddress("T2_DEPLOYER");
        address bootstrap = vm.envAddress("T2_BOOTSTRAP");
        for (uint256 i = 0; i < o.length; i++) {
            if (testnet) _eq(!isT2Placeholder(o[i]), "T2_SAFE_OWNERS: placeholder or fixture");
            _eq(o[i] != COMPANY_KEY && o[i] != deployer && o[i] != bootstrap, "T2_SAFE_OWNERS: role reuse");
            for (uint256 j = 0; j < i; j++) {
                _eq(o[i] != o[j], "T2_SAFE_OWNERS: duplicate");
            }
        }
    }

    function _rpc(uint256 cid) internal view returns (string memory) {
        if (cid == SEPOLIA) return vm.envString("SEPOLIA_RPC_URL");
        if (cid == BNB_TESTNET) return vm.envString("BNB_TESTNET_RPC_URL");
        if (cid == MONAD_TESTNET) return vm.envString("MONAD_TESTNET_RPC_URL");
        revert NotT2Chain(cid);
    }

    function _governor() internal view returns (uint256 g) {
        g = vm.envUint("T2_L2_GOVERNOR");
        _eq(g != 0 && g < (uint256(1) << 251), "T2_L2_GOVERNOR felt");
        _eq(g != PRODUCTION_L2_GOVERNOR, "T2_L2_GOVERNOR: production Governor");
    }

    /// @notice Read-only lane check on the current chain: router identity, OnRamp/OffRamp registration.
    function checkLane() public view {
        uint256 cid = block.chainid;
        if (cid == SEPOLIA) {
            _eq(IRouterClient(SEPOLIA_ROUTER).isChainSupported(BNB_TESTNET_SELECTOR), "lane Sepolia->97");
            _eq(IRouterClient(SEPOLIA_ROUTER).isChainSupported(MONAD_TESTNET_SELECTOR), "lane Sepolia->10143");
            _eq(IRouter(SEPOLIA_ROUTER).getOnRamp(BNB_TESTNET_SELECTOR) == SEPOLIA_ONRAMP, "OnRamp ->97");
            _eq(IRouter(SEPOLIA_ROUTER).getOnRamp(MONAD_TESTNET_SELECTOR) == SEPOLIA_ONRAMP, "OnRamp ->10143");
        } else {
            _eq(IRouter(t2Router(cid)).isOffRamp(SEPOLIA_SELECTOR, t2OffRamp(cid)), "OffRamp 2.0.0 registered");
        }
    }

    // ---------------------------------------------------------------- plan (read-only, any T2 chain)

    /// @notice Prints every address the T2 keys will create, for binding into the manifest after key generation.
    function t2Plan() external view {
        requireT2Chain();
        address d = vm.envAddress("T2_DEPLOYER");
        console.log("T2 deployer", d);
        console.log("Sepolia nonce 0: StarknetOwnerProxy (test)", t2Proxy(d));
        console.log("Sepolia nonce 1: CCIPGovernanceSender", t2Sender(d));
        for (uint256 k = 0; k < 2; k++) {
            uint256 cid = k == 0 ? BNB_TESTNET : MONAD_TESTNET;
            address[] memory ts = t2Targets(d, cid);
            console.log("chain", cid);
            for (uint256 i = 0; i < ts.length; i++) {
                console.log("  nonce i: T2DummyTarget", i, ts[i]);
            }
            console.log("  nonce n: Safe creation call; nonce n+1: executor", t2SafeNonce(cid), t2Executor(d, cid));
        }
        if (isDest(block.chainid)) {
            address[] memory owners = vm.envAddress("T2_SAFE_OWNERS", ",");
            console.log(
                "Safe (this chain)",
                t2SafeAddress(
                    ISafeProxyFactory141(SAFE_FACTORY_141).proxyCreationCode(), owners, vm.envUint("T2_SAFE_SALT")
                )
            );
        }
    }

    // ---------------------------------------------------------------- deployment steps

    /// @notice Sepolia, deployer nonce 0: the TEST StarknetOwnerProxy (unchanged production source) bound to the
    ///         Starknet Sepolia core and the T2 Governor. Never the production proxy 0x1E0E….
    function t2ProxyStep() external returns (StarknetOwnerProxy p) {
        p = _proxyStep(_testnet());
    }

    function _proxyStep(bool testnet) internal returns (StarknetOwnerProxy p) {
        _eq(block.chainid == SEPOLIA, "proxy: Sepolia only");
        checkLane();
        address d = _id(testnet, "T2_DEPLOYER");
        uint256 g = _governor();
        _eq(vm.getNonce(d) == 0, "deployer nonce != 0 on Sepolia");
        _eq(STARKNET_SEPOLIA_CORE.code.length != 0, "Starknet Sepolia core has no code");
        vm.broadcast(d);
        p = new StarknetOwnerProxy(IStarknetMessaging(STARKNET_SEPOLIA_CORE), g);
        _eq(address(p) == t2Proxy(d), "proxy address");
        verifyProxy(local(), address(p), g);
        console.log("T2 proxy", address(p));
        console.logBytes32(keccak256(address(p).code));
    }

    function verifyProxy(Src memory src, address p, uint256 g) public {
        _eq(_chainId(src) == SEPOLIA, "proxy.chainId");
        _eq(_code(src, p).length != 0, "proxy.code");
        _eq(_addr(src, p, abi.encodeWithSignature("l2MessageBridge()")) == STARKNET_SEPOLIA_CORE, "proxy.core");
        _eq(_uint(src, p, abi.encodeWithSignature("l2Owner()")) == g, "proxy.l2Owner");
    }

    /// @notice Destination (97, or 10143 with `--network monad`): dummy targets (owner = deployer), the 2-of-3 test
    ///         canceller Safe and the executor, in that nonce order, each verified exactly before the next.
    function t2DestStep() external returns (CCIPOwnerExecutor e) {
        bool testnet = _testnet();
        uint256 cid = block.chainid;
        _eq(isDest(cid), "dest: chain 97 or 10143");
        checkLane();
        address d = _id(testnet, "T2_DEPLOYER");
        address[] memory owners = _owners(testnet);
        uint256 salt = vm.envUint("T2_SAFE_SALT");
        _eq(vm.getNonce(d) == 0, "deployer nonce != 0 on destination");

        // Sepolia must not have used deployer nonce 1 yet (the sender is created after the executors).
        Src memory sep = remote(_rpc(SEPOLIA), "latest");
        _eq(_chainId(sep) == SEPOLIA, "SEPOLIA_RPC_URL chain id");
        _eq(_nonce(sep, d) <= 1, "Sepolia deployer nonce > 1");
        _eq(_code(sep, t2Sender(d)).length == 0, "code already at the predicted sender");
        address senderPredicted = t2Sender(d);

        address[] memory ts = t2Targets(d, cid);
        for (uint256 i = 0; i < ts.length; i++) {
            vm.broadcast(d);
            T2DummyTarget t = new T2DummyTarget(d);
            _eq(address(t) == ts[i] && t.owner() == d, "dummy target");
        }

        address safe = t2SafeAddress(ISafeProxyFactory141(SAFE_FACTORY_141).proxyCreationCode(), owners, salt);
        _eq(safe.code.length == 0, "Safe already exists");
        vm.broadcast(d);
        address created =
            ISafeProxyFactory141(SAFE_FACTORY_141).createProxyWithNonce(SAFE_L2_141, t2SafeInitializer(owners), salt);
        _eq(created == safe, "Safe address");
        verifySafe(local(), t2SafeExpect(cid, safe, owners));

        ExecutorExpect memory x = t2ExecutorExpect(cid, t2Executor(d, cid), senderPredicted, safe, ts);
        checkTiming(false, cid, x.delay, x.executionWindow, x.maxTtl);
        vm.broadcast(d);
        e = new CCIPOwnerExecutor(
            t2Router(cid), SEPOLIA_SELECTOR, senderPredicted, T2_DELAY, T2_WINDOW, T2_TTL, safe, ts
        );
        verifyExecutor(local(), x);
        console.log("T2 executor / canceller Safe", address(e), safe);
        console.logBytes32(x.runtimeKeccak);
        console.log(testnet ? "dest: exact read-backs PASSED" : "dest: read-backs PASSED; DRY RUN, NOT EXECUTABLE");
    }

    /// @notice Sepolia, deployer nonce 1, immediately after both destination steps: both Safes and executors are
    ///         re-verified over raw RPC in this process (skipped in dry run), then the sender is created.
    function t2SenderStep() external returns (CCIPGovernanceSender s) {
        s = _senderStep(_testnet());
    }

    /// @notice DRY RUN ONLY: simulates both Sepolia steps back to back (the destination steps are simulated
    ///         separately on their own chains). Refused in testnet mode, where the destinations come in between.
    function t2SepoliaDryRun() external {
        _eq(!_testnet(), "t2SepoliaDryRun is dry-run only");
        _proxyStep(false);
        _senderStep(false);
    }

    function _senderStep(bool testnet) internal returns (CCIPGovernanceSender s) {
        _eq(block.chainid == SEPOLIA, "sender: Sepolia only");
        checkLane();
        address d = _id(testnet, "T2_DEPLOYER");
        address bootstrap = _id(testnet, "T2_BOOTSTRAP");
        _eq(bootstrap != d, "C11: bootstrap must differ from deployer");
        address proxy = t2Proxy(d);
        uint256 g = _governor();
        _eq(vm.getNonce(d) == 1, "deployer nonce != 1 on Sepolia");
        verifyProxy(local(), proxy, g);
        address eBnb = t2Executor(d, BNB_TESTNET);
        address eMon = t2Executor(d, MONAD_TESTNET);
        if (testnet) {
            _verifyDest(BNB_TESTNET, d, remote(_rpc(BNB_TESTNET), "latest"));
            _verifyDest(MONAD_TESTNET, d, remote(_rpc(MONAD_TESTNET), "latest"));
        } else {
            console.log("destinations NOT VERIFIED (dry run: nothing deployed)");
        }
        SenderExpect memory x = t2SenderExpect(t2Sender(d), proxy, bootstrap, eBnb, eMon);
        x.runtimeKeccak = t2SenderRuntimeKeccak(x, bootstrap);
        vm.broadcast(d);
        s = new CCIPGovernanceSender(
            IRouterClient(SEPOLIA_ROUTER), proxy, bootstrap, x.dest0, x.dest1, T2_MAX_GAS_LIMIT
        );
        _eq(address(s) == x.sender, "sender address");
        verifySender(local(), x);
        console.log("T2 sender", address(s));
        console.logBytes32(x.runtimeKeccak);
    }

    function _verifyDest(uint256 cid, address d, Src memory src) internal {
        address[] memory owners = vm.envAddress("T2_SAFE_OWNERS", ",");
        address safe = vm.envAddress(string.concat("T2_SAFE_", vm.toString(cid)));
        verifySafe(src, t2SafeExpect(cid, safe, owners));
        _eq(_nonce(src, d) >= t2TargetCount(cid) + 2, "destination deployer nonce");
        ExecutorExpect memory x = t2ExecutorExpect(cid, t2Executor(d, cid), t2Sender(d), safe, t2Targets(d, cid));
        verifyExecutor(src, x);
        console.log("destination VERIFIED over raw RPC", cid);
    }

    /// @notice Read-only, any T2 chain: sender (EXPECTED_AUTHORITY), proxy, both Safes and executors over raw RPC.
    ///         Env T2_SAFE_97, T2_SAFE_10143, EXPECTED_AUTHORITY, VERIFY_TAG (default finalized).
    function t2VerifyRoute() external {
        requireT2Chain();
        string memory tag = vm.envOr("VERIFY_TAG", string("finalized"));
        address d = vm.envAddress("T2_DEPLOYER");
        address bootstrap = vm.envAddress("T2_BOOTSTRAP");
        Src memory sep = remote(_rpc(SEPOLIA), tag);
        verifyProxy(sep, t2Proxy(d), _governor());
        SenderExpect memory x = t2SenderExpect(
            t2Sender(d), t2Proxy(d), vm.envAddress("EXPECTED_AUTHORITY"), t2Executor(d, 97), t2Executor(d, 10143)
        );
        x.runtimeKeccak = keccak256(_code(sep, x.sender));
        _eq(x.runtimeKeccak == vm.envBytes32("T2_SENDER_RUNTIME_KECCAK"), "sender runtime != manifest pin");
        verifySender(sep, x);
        _eq(x.authority == bootstrap || x.authority == x.finalAuthority, "authority is neither bootstrap nor proxy");
        _verifyDest(BNB_TESTNET, d, remote(_rpc(BNB_TESTNET), tag));
        _verifyDest(MONAD_TESTNET, d, remote(_rpc(MONAD_TESTNET), tag));
        console.log("T2 route VERIFIED at tag", tag);
    }

    // ---------------------------------------------------------------- runtime steps (Sepolia)

    /// @notice Bootstrap ping to destination `cid`, then dispatch paying the exact fee (capped by T2_MAX_FEE_WEI).
    ///         `deadlineFromNow` is seconds; > T2_TTL (+ margin) makes a deliberate recoverable DeadlineTooFar.
    function t2Ping(uint256 cid, uint64 deadlineFromNow) external {
        bool testnet = _testnet();
        _eq(block.chainid == SEPOLIA, "Sepolia only");
        CCIPGovernanceSender s = CCIPGovernanceSender(t2Sender(vm.envAddress("T2_DEPLOYER")));
        address bootstrap = _id(testnet, "T2_BOOTSTRAP");
        _eq(s.authority() == bootstrap, "authority is not the bootstrap key");
        uint64 deadline = uint64(block.timestamp) + deadlineFromNow;
        uint64 opId = s.nextOpId(t2Selector(cid)) + 1;
        bytes memory payload = CCIPGovernancePayload.encode(
            cid, t2Executor(vm.envAddress("T2_DEPLOYER"), cid), opId, 1, deadline, new CCIPGovernancePayload.Call[](0)
        );
        vm.broadcast(bootstrap);
        bytes32 id = s.request(t2Selector(cid), T2_GAS_LIMIT, deadline, new CCIPGovernancePayload.Call[](0));
        _eq(id == keccak256(payload), "requestId != keccak(expected payload)");
        _dispatch(s, payload, testnet);
    }

    /// @notice Permissionless dispatch of a Pending request, exact fee, capped. Env T2_PAYER, T2_MAX_FEE_WEI.
    function t2Dispatch(bytes calldata payload) external {
        bool testnet = _testnet();
        _eq(block.chainid == SEPOLIA, "Sepolia only");
        _dispatch(CCIPGovernanceSender(t2Sender(vm.envAddress("T2_DEPLOYER"))), payload, testnet);
    }

    function _dispatch(CCIPGovernanceSender s, bytes memory payload, bool testnet) internal {
        address payer = _id(testnet, "T2_PAYER");
        (CCIPGovernanceSender.RequestStatus st, uint64 dest, uint32 gasLimit) = s.requests(keccak256(payload));
        _eq(st == CCIPGovernanceSender.RequestStatus.Pending, "request not Pending");
        uint256 fee = IRouterClient(SEPOLIA_ROUTER).getFee(dest, _message(s, dest, payload, gasLimit));
        uint256 cap = vm.envUint("T2_MAX_FEE_WEI");
        _eq(fee <= cap, "CCIP fee above T2_MAX_FEE_WEI: stop");
        vm.broadcast(payer);
        bytes32 mid = s.dispatch{value: fee}(payload);
        console.log("dispatched: dest selector, fee (wei)", dest, fee);
        console.log("  requestId = payloadHash, ccipMessageId");
        console.logBytes32(keccak256(payload));
        console.logBytes32(mid);
        console.logBytes(payload);
    }

    function _message(CCIPGovernanceSender s, uint64 dest, bytes memory payload, uint32 gasLimit)
        internal
        view
        returns (Client.EVM2AnyMessage memory m)
    {
        (CCIPGovernanceSender.Destination memory d0, CCIPGovernanceSender.Destination memory d1) = s.destinations();
        address executor = dest == d0.chainSelector ? d0.executor : d1.executor;
        m.receiver = abi.encode(executor);
        m.data = payload;
        m.feeToken = address(0);
        m.extraArgs = s.extraArgs(gasLimit);
    }

    /// @notice One-way authority handoff by the bootstrap key (T4 analogue).
    function t2Handoff() external {
        bool testnet = _testnet();
        _eq(block.chainid == SEPOLIA, "Sepolia only");
        CCIPGovernanceSender s = CCIPGovernanceSender(t2Sender(vm.envAddress("T2_DEPLOYER")));
        address bootstrap = _id(testnet, "T2_BOOTSTRAP");
        _eq(s.authority() == bootstrap, "authority is not the bootstrap key");
        vm.broadcast(bootstrap);
        s.handoff();
        _eq(s.authority() == s.finalAuthority(), "handoff");
    }

    /// @notice Read-only (Sepolia): the exact L1 message for proxy nonce `nonce` and the serialized Starknet call to
    ///         put in the Governor proposal. kind 0 owner(), 1 setValue(value), 2 padded note (gas T2_LOW_GAS_LIMIT).
    function t2Message(uint256 cid, uint64 nonce, uint8 kind, uint256 value, uint64 deadline)
        public
        view
        returns (bytes memory data, uint256[] memory felts, bytes memory payload)
    {
        requireT2Chain();
        address d = vm.envAddress("T2_DEPLOYER");
        address[] memory ts = t2Targets(d, cid);
        CCIPGovernancePayload.Call[] memory calls = t2Calls(ts, kind, value);
        uint32 gasLimit = kind == 2 ? T2_LOW_GAS_LIMIT : T2_GAS_LIMIT;
        data = abi.encodeCall(CCIPGovernanceSender.request, (t2Selector(cid), gasLimit, deadline, calls));
        felts = t2Felts(t2Sender(d), 0, nonce, data);
        // The opId is assigned when the proxy executes the message on L1: the next one if executed in order.
        uint64 opId = t2Sender(d).code.length == 0 ? 0 : CCIPGovernanceSender(t2Sender(d)).nextOpId(t2Selector(cid)) + 1;
        payload = CCIPGovernancePayload.encode(cid, t2Executor(d, cid), opId, 2, deadline, calls);
        uint256[] memory sn = t2StarknetCall(_governor(), t2Proxy(d), felts);
        console.log("L1 message: dest chain, proxy nonce, kind", cid, nonce, kind);
        console.log("  starknet Call felts (to, selector, len, calldata...): count", sn.length);
        for (uint256 i = 0; i < sn.length; i++) {
            console.log(vm.toString(bytes32(sn[i])));
        }
        console.log("  L2->L1 message hash on StarknetCore");
        console.logBytes32(t2MessageHash(_governor(), t2Proxy(d), felts));
    }

    /// @notice Sepolia, anyone: `StarknetOwnerProxy.execute` for a settled message; refuses if Core has not
    ///         recorded it (no wasted transaction, no nonce jam).
    function t2L1Execute(uint256 cid, uint64 nonce, uint8 kind, uint256 value, uint64 deadline) external {
        bool testnet = _testnet();
        _eq(block.chainid == SEPOLIA, "Sepolia only");
        (bytes memory data, uint256[] memory felts,) = t2Message(cid, nonce, kind, value, deadline);
        address d = vm.envAddress("T2_DEPLOYER");
        StarknetOwnerProxy p = StarknetOwnerProxy(payable(t2Proxy(d)));
        _eq(p.currentNonce() == nonce, "C9: proxy currentNonce != message nonce");
        _eq(
            IStarknetCoreView(STARKNET_SEPOLIA_CORE).l2ToL1Messages(t2MessageHash(_governor(), address(p), felts)) > 0,
            "L2->L1 message not settled on StarknetCore yet"
        );
        vm.broadcast(_id(testnet, "T2_PAYER"));
        p.execute(t2Sender(d), 0, nonce, data);
        _eq(p.currentNonce() == nonce + 1, "nonce not consumed");
    }

    // ---------------------------------------------------------------- runtime steps (destinations)

    /// @notice Destination, anyone, after eta: executes a Queued GOVERNOR operation. Env T2_PAYER.
    function t2Execute(bytes calldata payload) external {
        bool testnet = _testnet();
        CCIPOwnerExecutor e = CCIPOwnerExecutor(t2Executor(vm.envAddress("T2_DEPLOYER"), block.chainid));
        (CCIPOwnerExecutor.OpStatus st,, uint64 eta) = e.ops(keccak256(payload));
        _eq(st == CCIPOwnerExecutor.OpStatus.Queued && block.timestamp >= eta, "not Queued or not ready");
        vm.broadcast(_id(testnet, "T2_PAYER"));
        e.execute(payload);
    }

    /// @notice Read-only: the Safe transaction cancelling `hashes` and its safeTxHash for the two test signers
    ///         (`cast wallet sign --no-hash <safeTxHash>` with each signer's isolated key, never here).
    function t2CancelTx(bytes32[] calldata hashes) public view returns (bytes memory data, bytes32 safeTxHash) {
        requireT2Chain();
        address d = vm.envAddress("T2_DEPLOYER");
        CCIPOwnerExecutor e = CCIPOwnerExecutor(t2Executor(d, block.chainid));
        for (uint256 i = 0; i < hashes.length; i++) {
            (CCIPOwnerExecutor.OpStatus st,,) = e.ops(hashes[i]);
            _eq(st == CCIPOwnerExecutor.OpStatus.Queued, "I-2: cancel list must contain only Queued hashes");
        }
        ISafe141 safe = ISafe141(e.canceller());
        data = abi.encodeCall(CCIPOwnerExecutor.cancel, (hashes));
        safeTxHash = safe.getTransactionHash(address(e), 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce());
        console.log("Safe tx: to executor, value 0, operation CALL, data, safeTxHash");
        console.log(address(e));
        console.logBytes(data);
        console.logBytes32(safeTxHash);
    }

    /// @notice Destination: submits the Safe cancellation with T2_SAFE_SIGNATURES (2 signatures sorted by signer),
    ///         checked by the Safe itself before sending. Sent by T2_PAYER (anyone may submit valid signatures).
    function t2CancelExec(bytes32[] calldata hashes) external {
        bool testnet = _testnet();
        (bytes memory data, bytes32 h) = t2CancelTx(hashes);
        CCIPOwnerExecutor e = CCIPOwnerExecutor(t2Executor(vm.envAddress("T2_DEPLOYER"), block.chainid));
        ISafe141 safe = ISafe141(e.canceller());
        bytes memory sigs = vm.envBytes("T2_SAFE_SIGNATURES");
        safe.checkSignatures(h, data, sigs);
        vm.broadcast(_id(testnet, "T2_PAYER"));
        safe.execTransaction(address(e), 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sigs);
        for (uint256 i = 0; i < hashes.length; i++) {
            (CCIPOwnerExecutor.OpStatus st,,) = e.ops(hashes[i]);
            _eq(st == CCIPOwnerExecutor.OpStatus.Cancelled, "not Cancelled");
        }
    }

    /// @notice Destination, deployer: transfers every dummy target to the executor after this chain's owner()
    ///         proof executed (T6 analogue, dummy ownership only). Env T2_PROOF_PAYLOAD.
    function t2TransferDummies() external {
        bool testnet = _testnet();
        address d = _id(testnet, "T2_DEPLOYER");
        CCIPOwnerExecutor e = CCIPOwnerExecutor(t2Executor(d, block.chainid));
        bytes memory proof = vm.envBytes("T2_PROOF_PAYLOAD");
        (CCIPOwnerExecutor.OpStatus st,,) = e.ops(keccak256(proof));
        _eq(st == CCIPOwnerExecutor.OpStatus.Executed, "D3: proof not Executed on this chain");
        address[] memory ts = e.targets();
        for (uint256 i = 0; i < ts.length; i++) {
            _eq(T2DummyTarget(ts[i]).owner() == d, "dummy owner is not the deployer");
            vm.broadcast(d);
            T2DummyTarget(ts[i]).transferOwnership(address(e));
            _eq(T2DummyTarget(ts[i]).owner() == address(e), "dummy owner != executor");
        }
    }
}
