// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IRouterClient} from "../vendor/ccip-2.0.0/interfaces/IRouterClient.sol";
import {CCIPGovernanceSender} from "../src/CCIPGovernanceSender.sol";
import {CCIPOwnerExecutor} from "../src/CCIPOwnerExecutor.sol";
import {CCIPRouteVerifier} from "./CCIPRouteVerifier.sol";

/// @notice Deployment of the A'-CCIP owner route (EKU-1199, verification per CSO EKU-1200 M-A / L-2, EKU-1217).
///         DRAFT: not authorized for `--broadcast` until CSO clears the exact commit and the real-input manifest and
///         a human approves deployment.
///
///         `CCIP_ROUTE_MODE` is required:
///         - `production`: every input is pinned by env, placeholders are rejected, every immutable and the runtime
///           keccak are checked for exact equality against the manifest, and the canceller Safe is verified.
///         - `dryrun`: refuses `--broadcast`/`--resume`; accepts the dry-run placeholders, verifies nothing about the
///           canceller Safe and prints `NOT EXECUTABLE`. Used only to regenerate manifest evidence.
///
///         Order (M-1, L-2), one fresh single-purpose DEPLOYER whose first transaction on every chain is its
///         contract (so the sender is `computeCreateAddress(DEPLOYER, 0)`):
///         1. `executor()` on BNB Chain, then on Monad (`--network monad`): Safe verified, executor deployed and read
///            back exactly.
///         2. `sender()` on Ethereum, immediately after: both Safes and both executors are re-verified over raw RPC
///            in the same process, then the sender is deployed and read back exactly.
///         3. `verifyRoute()` (read-only) before T3 pings, T4, T5 and every transfer.
///
///         Env, per destination chain id `<cid>` (56, 143): `CANCELLER_<cid>`, `SAFE_OWNERS_<cid>` (comma list),
///         `SAFE_THRESHOLD_<cid>`, `SAFE_GUARD_<cid>`, `SAFE_FALLBACK_HANDLER_<cid>`, `SAFE_SINGLETON_<cid>`,
///         `SAFE_PROXY_RUNTIME_KECCAK_<cid>`, `EXECUTOR_<cid>`, `EXECUTOR_RUNTIME_KECCAK_<cid>`. Route-wide:
///         `DEPLOYER`, `SENDER_PREDICTED`, `BOOTSTRAP`, `SENDER_RUNTIME_KECCAK`, `ETH_RPC_URL`, `BNB_RPC_URL`,
///         `MONAD_RPC_URL`.
contract DeployCCIPOwnerRoute is CCIPRouteVerifier {
    // ---------------------------------------------------------------- mode

    function _production() internal view returns (bool) {
        bytes32 m = keccak256(bytes(vm.envString("CCIP_ROUTE_MODE")));
        if (m == keccak256("production")) return true;
        if (m == keccak256("dryrun")) {
            if (!vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
                revert VerificationFailed("dryrun mode refuses --broadcast and --resume");
            }
            console.log("DRY RUN: placeholders accepted, canceller Safe NOT verified. Output is NOT EXECUTABLE.");
            return false;
        }
        revert VerificationFailed("CCIP_ROUTE_MODE must be production or dryrun");
    }

    function _input(bool production, string memory name) internal view returns (address a) {
        a = vm.envAddress(name);
        if (production) requireReal(a, name);
    }

    function _key(string memory name, uint256 cid) internal pure returns (string memory) {
        return string.concat(name, "_", vm.toString(cid));
    }

    function safeExpectFromEnv(uint256 cid) public view returns (SafeExpect memory x) {
        x.safe = vm.envAddress(_key("CANCELLER", cid));
        x.chainId = cid;
        x.owners = vm.envAddress(_key("SAFE_OWNERS", cid), ",");
        x.threshold = vm.envUint(_key("SAFE_THRESHOLD", cid));
        x.guard = vm.envAddress(_key("SAFE_GUARD", cid));
        x.fallbackHandler = vm.envAddress(_key("SAFE_FALLBACK_HANDLER", cid));
        x.singleton = vm.envAddress(_key("SAFE_SINGLETON", cid));
        x.proxyRuntimeKeccak = vm.envBytes32(_key("SAFE_PROXY_RUNTIME_KECCAK", cid));
    }

    function _rpcFor(uint256 cid) internal view returns (string memory) {
        if (cid == 1) return vm.envString("ETH_RPC_URL");
        if (cid == 56) return vm.envString("BNB_RPC_URL");
        if (cid == 143) return vm.envString("MONAD_RPC_URL");
        revert VerificationFailed("no RPC for chain");
    }

    // ---------------------------------------------------------------- step 1: executors

    function executor() external returns (CCIPOwnerExecutor e) {
        bool production = _production();
        uint256 cid = block.chainid;
        address router = routerFor(cid);
        address deployer = _input(production, "DEPLOYER");
        address senderPredicted = vm.envAddress("SENDER_PREDICTED");
        address canceller = _input(production, _key("CANCELLER", cid));
        if (canceller == COMPANY_KEY || canceller.code.length == 0) revert VerificationFailed("canceller");

        // L-2: fresh single-purpose deployer; the sender will be its first Ethereum transaction.
        _eq(vm.getNonce(deployer) == 0, "deployer nonce != 0 on this chain");
        _eq(senderPredicted == vm.computeCreateAddress(deployer, 0), "SENDER_PREDICTED != create(DEPLOYER, 0)");
        if (production || vm.envExists("ETH_RPC_URL")) {
            Src memory eth = remote(vm.envString("ETH_RPC_URL"), "latest");
            _eq(_chainId(eth) == 1, "ETH_RPC_URL chain id");
            _eq(_nonce(eth, deployer) == 0, "deployer nonce != 0 on Ethereum");
            _eq(_code(eth, senderPredicted).length == 0, "code already at SENDER_PREDICTED");
        }

        // Canceller Safe before anything is deployed (M-A).
        if (production) {
            verifySafe(local(), safeExpectFromEnv(cid));
            console.log("canceller Safe VERIFIED", canceller);
        } else {
            console.log("canceller Safe NOT VERIFIED (dry-run placeholder)", canceller);
        }

        address[] memory ts = targetsFor(cid);
        bytes memory args =
            abi.encode(router, ETH_SELECTOR, senderPredicted, PROD_DELAY, PROD_WINDOW, PROD_TTL, canceller, ts);
        checkTiming(true, cid, PROD_DELAY, PROD_WINDOW, PROD_TTL);

        // Local, non-broadcast reference instance: the runtime keccak the pinned source yields for these exact
        // constructor arguments. Production requires the manifest pin to equal it.
        bytes32 refHash = _hashOf(
            address(
                new CCIPOwnerExecutor(
                    router, ETH_SELECTOR, senderPredicted, PROD_DELAY, PROD_WINDOW, PROD_TTL, canceller, ts
                )
            )
        );
        bytes32 pinned = production ? vm.envBytes32(_key("EXECUTOR_RUNTIME_KECCAK", cid)) : refHash;
        _eq(pinned == refHash, "manifest EXECUTOR_RUNTIME_KECCAK != reference build");

        address predicted = vm.computeCreateAddress(deployer, 0);
        vm.broadcast(deployer);
        e = new CCIPOwnerExecutor(
            router, ETH_SELECTOR, senderPredicted, PROD_DELAY, PROD_WINDOW, PROD_TTL, canceller, ts
        );
        _eq(address(e) == predicted, "executor address");
        verifyExecutor(local(), productionExecutor(cid, address(e), senderPredicted, canceller, pinned));

        console.log("executor", address(e));
        console.log("runtime keccak");
        console.logBytes32(keccak256(address(e).code));
        console.log("constructor args");
        console.logBytes(args);
        console.log(
            production
                ? "executor: all exact read-backs PASSED"
                : "executor: read-backs PASSED; DRY RUN, NOT EXECUTABLE"
        );
    }

    // ---------------------------------------------------------------- step 2: sender

    function sender() external returns (CCIPGovernanceSender s) {
        bool production = _production();
        _eq(block.chainid == 1, "sender: Ethereum only");
        address deployer = _input(production, "DEPLOYER");
        address bootstrap = _input(production, "BOOTSTRAP");
        _eq(bootstrap != COMPANY_KEY && bootstrap != deployer && bootstrap != L1_PROXY, "C11: fresh bootstrap key");
        address executorBnb = vm.envAddress(_key("EXECUTOR", 56));
        address executorMonad = vm.envAddress(_key("EXECUTOR", 143));
        address senderPredicted = vm.envAddress("SENDER_PREDICTED");

        _eq(vm.getNonce(deployer) == 0, "deployer nonce != 0 on Ethereum");
        address predicted = vm.computeCreateAddress(deployer, 0);
        _eq(predicted == senderPredicted, "SENDER_PREDICTED != create(DEPLOYER, 0)");

        // Destination re-verification in this process, immediately before deployment (M-A, L-2).
        if (production) {
            _verifyDestination(56, executorBnb, deployer, senderPredicted);
            _verifyDestination(143, executorMonad, deployer, senderPredicted);
        } else {
            console.log("destinations NOT VERIFIED (dry run: executors and Safes are not deployed)");
        }

        CCIPGovernanceSender.Destination memory bnb = CCIPGovernanceSender.Destination(BNB_SELECTOR, 56, executorBnb);
        CCIPGovernanceSender.Destination memory monad =
            CCIPGovernanceSender.Destination(MONAD_SELECTOR, 143, executorMonad);
        bytes memory args = abi.encode(ETH_ROUTER, L1_PROXY, bootstrap, bnb, monad, PROD_MAX_GAS_LIMIT);

        bytes32 refHash = _hashOf(
            address(
                new CCIPGovernanceSender(IRouterClient(ETH_ROUTER), L1_PROXY, bootstrap, bnb, monad, PROD_MAX_GAS_LIMIT)
            )
        );
        bytes32 pinned = production ? vm.envBytes32("SENDER_RUNTIME_KECCAK") : refHash;
        _eq(pinned == refHash, "manifest SENDER_RUNTIME_KECCAK != reference build");

        vm.broadcast(deployer);
        s = new CCIPGovernanceSender(IRouterClient(ETH_ROUTER), L1_PROXY, bootstrap, bnb, monad, PROD_MAX_GAS_LIMIT);
        _eq(address(s) == predicted, "sender address");
        verifySender(local(), productionSender(address(s), bootstrap, executorBnb, executorMonad, pinned));

        console.log("sender", address(s));
        console.log("runtime keccak");
        console.logBytes32(keccak256(address(s).code));
        console.log("constructor args");
        console.logBytes(args);
        console.log(
            production ? "sender: all exact read-backs PASSED" : "sender: read-backs PASSED; DRY RUN, NOT EXECUTABLE"
        );
    }

    function _verifyDestination(uint256 cid, address e, address deployer, address senderAddr) internal {
        Src memory src = remote(_rpcFor(cid), "latest");
        SafeExpect memory safe = safeExpectFromEnv(cid);
        requireReal(safe.safe, _key("CANCELLER", cid));
        verifySafe(src, safe);
        _eq(e == vm.computeCreateAddress(deployer, 0), "executor != create(DEPLOYER, 0)");
        _eq(_nonce(src, deployer) == 1, "deployer is not single-purpose on destination");
        verifyExecutor(
            src, productionExecutor(cid, e, senderAddr, safe.safe, vm.envBytes32(_key("EXECUTOR_RUNTIME_KECCAK", cid)))
        );
        console.log("destination VERIFIED (Safe + executor exact)", cid);
    }

    // ---------------------------------------------------------------- read-only gates

    /// @notice Read-only canceller Safe verification for chain `cid` over `<CHAIN>_RPC_URL` (any fork/process).
    function verifyCanceller(uint256 cid) external {
        SafeExpect memory safe = safeExpectFromEnv(cid);
        requireReal(safe.safe, _key("CANCELLER", cid));
        verifySafe(remote(_rpcFor(cid), vm.envOr("VERIFY_TAG", string("latest"))), safe);
        console.log("canceller Safe VERIFIED", cid, safe.safe);
    }

    /// @notice L-2 / D1: read-only re-verification of the whole deployed route over raw RPC, required before T3
    ///         pings, T4, T5 and every transfer. `EXPECTED_AUTHORITY` is the bootstrap key before T4 and the
    ///         StarknetOwnerProxy after. Reads at `VERIFY_TAG` (default `finalized`).
    function verifyRoute() external {
        string memory tag = vm.envOr("VERIFY_TAG", string("finalized"));
        address senderAddr = vm.envAddress("SENDER");
        address authority = vm.envAddress("EXPECTED_AUTHORITY");
        _eq(authority == L1_PROXY || !isPlaceholder(authority), "EXPECTED_AUTHORITY placeholder");
        address eb = vm.envAddress(_key("EXECUTOR", 56));
        address em = vm.envAddress(_key("EXECUTOR", 143));
        verifySender(
            remote(_rpcFor(1), tag),
            productionSender(senderAddr, authority, eb, em, vm.envBytes32("SENDER_RUNTIME_KECCAK"))
        );
        for (uint256 i = 0; i < 2; i++) {
            uint256 cid = i == 0 ? 56 : 143;
            Src memory src = remote(_rpcFor(cid), tag);
            SafeExpect memory safe = safeExpectFromEnv(cid);
            requireReal(safe.safe, _key("CANCELLER", cid));
            verifySafe(src, safe);
            verifyExecutor(
                src,
                productionExecutor(
                    cid, i == 0 ? eb : em, senderAddr, safe.safe, vm.envBytes32(_key("EXECUTOR_RUNTIME_KECCAK", cid))
                )
            );
        }
        console.log("route VERIFIED at tag", tag);
    }
}
