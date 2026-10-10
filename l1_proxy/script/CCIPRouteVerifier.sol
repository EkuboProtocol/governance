// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {CCIPGovernanceSender} from "../src/CCIPGovernanceSender.sol";
import {CCIPOwnerExecutor} from "../src/CCIPOwnerExecutor.sol";
import {IAny2EVMMessageReceiverV2} from "../vendor/ccip-2.0.0/interfaces/IAny2EVMMessageReceiverV2.sol";

interface ISafeView {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);
}

/// @notice Fail-closed read-back checks for the A'-CCIP owner route (EKU-1217, CSO EKU-1200 M-A / L-2 / D1).
///         Every check is an exact equality against a pinned expectation; nothing is a `>=` comparison.
/// @dev A `Src` selects where state is read: an empty `rpc` reads the current (forked) EVM state, otherwise every
///      read is a raw JSON-RPC call to `rpc` at block tag `tag` (`latest`, `finalized` or a hex number). The raw
///      path lets one script process verify BNB Chain and Monad state while running on an Ethereum fork, which
///      Foundry cannot do with forks. Remote reads never fall back to local state.
abstract contract CCIPRouteVerifier is Script {
    struct Src {
        string rpc;
        string tag;
    }

    struct ExecutorExpect {
        address executor;
        uint256 chainId;
        address router;
        uint64 sourceChainSelector;
        address sender;
        uint64 delay;
        uint64 executionWindow;
        uint64 maxTtl;
        address canceller;
        address[] targets;
        bytes32 runtimeKeccak;
    }

    struct SenderExpect {
        address sender;
        uint256 chainId;
        address router;
        address finalAuthority;
        address authority;
        uint32 maxGasLimit;
        CCIPGovernanceSender.Destination dest0;
        CCIPGovernanceSender.Destination dest1;
        bytes32 runtimeKeccak;
    }

    struct SafeExpect {
        address safe;
        uint256 chainId;
        address[] owners;
        uint256 threshold;
        address guard;
        address fallbackHandler;
        address singleton;
        bytes32 proxyRuntimeKeccak;
        /// @dev L-6 (CSO EKU-1218): the canonical singleton's runtime keccak, not only its address.
        bytes32 singletonCodehash;
    }

    error VerificationFailed(string what);

    // ---------------------------------------------------------------- pinned production values (plan 479b4dcf)

    uint64 internal constant ETH_SELECTOR = 5009297550715157269;
    uint64 internal constant BNB_SELECTOR = 11344663589394136015;
    uint64 internal constant MONAD_SELECTOR = 8481857512324358265;
    address internal constant ETH_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    address internal constant BNB_ROUTER = 0x34B03Cb9086d7D758AC55af71584F81A598759FE;
    address internal constant MONAD_ROUTER = 0x33566fE5976AAa420F3d5C64996641Fc3858CaDB;
    address internal constant L1_PROXY = 0x1E0EF4162e42C9bF820c307218c4E41cCcA6E9CC;
    address internal constant COMPANY_KEY = 0x00000C771F6176268D5A9846E0956C3eF58597A1;

    uint64 internal constant PROD_DELAY = 259200; // 72 h
    uint64 internal constant PROD_WINDOW = 1209600; // 14 d
    uint64 internal constant PROD_TTL = 2592000; // 30 d
    uint32 internal constant PROD_MAX_GAS_LIMIT = 1_000_000;

    /// @dev Bounds for an explicitly approved non-production (testnet) profile only. Production uses exact values.
    uint64 internal constant TEST_MAX_DELAY = 30 days;
    uint64 internal constant TEST_MAX_WINDOW = 90 days;

    // Safe 1.3.0 / 1.4.1 storage layout and constants.
    address internal constant SAFE_SENTINEL = address(1);
    bytes32 internal constant SAFE_GUARD_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;
    bytes32 internal constant SAFE_FALLBACK_HANDLER_SLOT =
        0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;
    /// @dev Safe 1.5.0 module guard slot; must be empty on any accepted canceller (always empty before 1.5.0).
    bytes32 internal constant SAFE_MODULE_GUARD_SLOT =
        0xb104e0b93118902c651344349b610029d694cfdec91c589c91ebafbcd0289947;
    uint256 internal constant SAFE_MODULE_PAGE = 10;
    uint256 internal constant SAFE_MAX_MODULE_PAGES = 100;

    function targetsFor(uint256 chainId) public pure returns (address[] memory ts) {
        if (chainId == 56) {
            ts = new address[](2);
            ts[0] = 0xA2971E0C37cFdb13aE8440A0C94Ef1A1af39e326; // Positions 192-bit v3.2.0
            ts[1] = 0x9bB520B6192F71ec3D015C8a74F914f9c94bF794; // Orders 192-bit v3.2.0
        } else if (chainId == 143) {
            ts = new address[](4);
            ts[0] = 0x02D9876A21AF7545f8632C3af76eC90b5ad4b66D; // Positions original v3.1.1
            ts[1] = 0x3325428adB409c239E88ca472F50b0efe00E98B4; // Orders original v3.1.1
            ts[2] = 0xA2971E0C37cFdb13aE8440A0C94Ef1A1af39e326; // Positions 192-bit v3.2.0
            ts[3] = 0x9bB520B6192F71ec3D015C8a74F914f9c94bF794; // Orders 192-bit v3.2.0
        } else {
            revert VerificationFailed("chain must be 56 or 143");
        }
    }

    function routerFor(uint256 chainId) public pure returns (address) {
        if (chainId == 56) return BNB_ROUTER;
        if (chainId == 143) return MONAD_ROUTER;
        revert VerificationFailed("chain must be 56 or 143");
    }

    function selectorFor(uint256 chainId) public pure returns (uint64) {
        if (chainId == 56) return BNB_SELECTOR;
        if (chainId == 143) return MONAD_SELECTOR;
        revert VerificationFailed("chain must be 56 or 143");
    }

    /// @notice The only executor expectation accepted on BNB Chain and Monad mainnet.
    function productionExecutor(
        uint256 chainId,
        address executor,
        address sender,
        address canceller,
        bytes32 runtimeKeccak
    ) public pure returns (ExecutorExpect memory x) {
        x = ExecutorExpect({
            executor: executor,
            chainId: chainId,
            router: routerFor(chainId),
            sourceChainSelector: ETH_SELECTOR,
            sender: sender,
            delay: PROD_DELAY,
            executionWindow: PROD_WINDOW,
            maxTtl: PROD_TTL,
            canceller: canceller,
            targets: targetsFor(chainId),
            runtimeKeccak: runtimeKeccak
        });
    }

    /// @notice The only sender expectation accepted on Ethereum mainnet.
    function productionSender(
        address sender,
        address authority,
        address executorBnb,
        address executorMonad,
        bytes32 runtimeKeccak
    ) public pure returns (SenderExpect memory x) {
        x = SenderExpect({
            sender: sender,
            chainId: 1,
            router: ETH_ROUTER,
            finalAuthority: L1_PROXY,
            authority: authority,
            maxGasLimit: PROD_MAX_GAS_LIMIT,
            dest0: CCIPGovernanceSender.Destination(BNB_SELECTOR, 56, executorBnb),
            dest1: CCIPGovernanceSender.Destination(MONAD_SELECTOR, 143, executorMonad),
            runtimeKeccak: runtimeKeccak
        });
    }

    /// @notice Timing parameters. Production: exact pinned values only. Non-production profile (never on chain 1,
    ///         56 or 143): explicit values within bounds that cannot overflow `eta` or brick delivery.
    function checkTiming(bool production, uint256 chainId, uint64 delay, uint64 window, uint64 ttl) public pure {
        bool prodChain = chainId == 1 || chainId == 56 || chainId == 143;
        if (production) {
            _eq(delay == PROD_DELAY, "timing.delay != 259200");
            _eq(window == PROD_WINDOW, "timing.executionWindow != 1209600");
            _eq(ttl == PROD_TTL, "timing.maxTtl != 2592000");
        } else {
            _eq(!prodChain, "timing: test profile on a production chain");
            _eq(delay != 0 && delay <= TEST_MAX_DELAY, "timing.delay out of test bounds");
            _eq(window != 0 && window <= TEST_MAX_WINDOW, "timing.executionWindow out of test bounds");
            _eq(ttl != 0 && ttl <= PROD_TTL, "timing.maxTtl out of test bounds");
        }
    }

    // ---------------------------------------------------------------- placeholders

    /// @notice Addresses that must never be accepted as a production input: zero, the Safe sentinel, the dry-run
    ///         placeholders (`0x1199…`), the company key, and Safe singletons (a singleton is not a Safe wallet).
    function isPlaceholder(address a) public pure returns (bool) {
        return a == address(0) || a == SAFE_SENTINEL || uint160(a) >> 144 == 0x1199 || a == COMPANY_KEY
            || isKnownSafeSingleton(a);
    }

    function isKnownSafeSingleton(address a) public pure returns (bool) {
        return a == 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762 // SafeL2 1.4.1
            || a == 0x41675C099F32341bf84BFc5382aF534df5C7461a // Safe 1.4.1
            || a == 0x3E5c63644E683549055b9Be8653de26E0B4CD36E // SafeL2 1.3.0
            || a == 0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552 // Safe 1.3.0
            || a == 0xfb1bffC9d739B8D520DaF37dF666da4C687191EA // SafeL2 1.3.0 (eip155)
            || a == 0x69f4D1788e39c87893C980c06EdF4b7f686e2938; // Safe 1.3.0 (eip155)
    }

    function requireReal(address a, string memory what) public pure {
        if (isPlaceholder(a)) revert VerificationFailed(string.concat(what, ": missing or placeholder"));
    }

    // ---------------------------------------------------------------- executor

    function verifyExecutor(Src memory src, ExecutorExpect memory x) public {
        address e = x.executor;
        _eq(_chainId(src) == x.chainId, "executor.chainId");
        bytes memory code = _code(src, e);
        _eq(code.length != 0, "executor.code empty");
        _eq(keccak256(code) == x.runtimeKeccak, "executor.runtimeKeccak");
        _eq(_bool(src, e, abi.encodeCall(CCIPOwnerExecutor.supportsInterface, (0x85572ffb))), "executor.legacy");
        _eq(_bool(src, e, abi.encodeCall(CCIPOwnerExecutor.supportsInterface, (0x01ffc9a7))), "executor.erc165");
        _eq(
            !_bool(
                src,
                e,
                abi.encodeCall(CCIPOwnerExecutor.supportsInterface, (type(IAny2EVMMessageReceiverV2).interfaceId))
            ),
            "executor.V2"
        );
        _eq(!_bool(src, e, abi.encodeCall(CCIPOwnerExecutor.supportsInterface, (0xffffffff))), "executor.0xffffffff");
        _eq(_addr(src, e, abi.encodeWithSignature("router()")) == x.router, "executor.router");
        _eq(
            _uint(src, e, abi.encodeWithSignature("sourceChainSelector()")) == x.sourceChainSelector,
            "executor.sourceChainSelector"
        );
        _eq(_addr(src, e, abi.encodeWithSignature("sender()")) == x.sender, "executor.sender");
        _eq(_uint(src, e, abi.encodeWithSignature("delay()")) == x.delay, "executor.delay");
        _eq(
            _uint(src, e, abi.encodeWithSignature("executionWindow()")) == x.executionWindow, "executor.executionWindow"
        );
        _eq(_uint(src, e, abi.encodeWithSignature("maxTtl()")) == x.maxTtl, "executor.maxTtl");
        _eq(_addr(src, e, abi.encodeWithSignature("canceller()")) == x.canceller, "executor.canceller");
        _eq(
            keccak256(_call(src, e, abi.encodeWithSignature("targets()"))) == keccak256(abi.encode(x.targets)),
            "executor.targets"
        );
        _eq(_addr(src, e, abi.encodeWithSignature("owner()")) == address(0), "executor.owner");
    }

    // ---------------------------------------------------------------- sender

    function verifySender(Src memory src, SenderExpect memory x) public {
        address s = x.sender;
        _eq(_chainId(src) == x.chainId, "sender.chainId");
        bytes memory code = _code(src, s);
        _eq(code.length != 0, "sender.code empty");
        _eq(keccak256(code) == x.runtimeKeccak, "sender.runtimeKeccak");
        _eq(_addr(src, s, abi.encodeWithSignature("router()")) == x.router, "sender.router");
        _eq(_addr(src, s, abi.encodeWithSignature("finalAuthority()")) == x.finalAuthority, "sender.finalAuthority");
        _eq(_addr(src, s, abi.encodeWithSignature("authority()")) == x.authority, "sender.authority");
        _eq(_uint(src, s, abi.encodeWithSignature("maxGasLimit()")) == x.maxGasLimit, "sender.maxGasLimit");
        _eq(
            keccak256(_call(src, s, abi.encodeWithSignature("destinations()")))
                == keccak256(abi.encode(x.dest0, x.dest1)),
            "sender.destinations"
        );
    }

    // ---------------------------------------------------------------- canceller Safe

    /// @notice The canceller must be an initialised Safe proxy with exactly the approved owners and threshold
    ///         (>= 2), no modules (complete pagination), and the pinned guard, fallback handler and singleton.
    function verifySafe(Src memory src, SafeExpect memory x) public {
        address safe = x.safe;
        _eq(_chainId(src) == x.chainId, "safe.chainId");
        _eq(!isPlaceholder(safe), "safe: placeholder or singleton address");
        _eq(x.singleton != address(0) && x.singleton != safe, "safe.singleton expectation");
        _eq(x.singletonCodehash != bytes32(0), "safe.singletonCodehash expectation");
        uint256 n = x.owners.length;
        _eq(x.threshold >= 2 && x.threshold <= n, "safe.threshold expectation (>= 2, <= owners)");
        for (uint256 i = 0; i < n; i++) {
            _eq(!isPlaceholder(x.owners[i]) && x.owners[i] != safe, "safe.owners expectation: placeholder");
            for (uint256 j = 0; j < i; j++) {
                _eq(x.owners[j] != x.owners[i], "safe.owners expectation: duplicate");
            }
        }

        bytes memory code = _code(src, safe);
        _eq(code.length != 0, "safe.code empty");
        _eq(keccak256(code) == x.proxyRuntimeKeccak, "safe.proxyRuntimeKeccak");
        _eq(address(uint160(uint256(_slot(src, safe, bytes32(0))))) == x.singleton, "safe.singleton");
        _eq(_slot(src, safe, bytes32(0)) == bytes32(uint256(uint160(x.singleton))), "safe.singleton slot dirty");
        _eq(keccak256(_code(src, x.singleton)) == x.singletonCodehash, "safe.singletonCodehash");

        _eq(_uint(src, safe, abi.encodeCall(ISafeView.getThreshold, ())) == x.threshold, "safe.threshold");
        _eq(uint256(_slot(src, safe, bytes32(uint256(4)))) == x.threshold, "safe.threshold slot");
        address[] memory owners = abi.decode(_call(src, safe, abi.encodeCall(ISafeView.getOwners, ())), (address[]));
        _eq(owners.length == n, "safe.owners count");
        _eq(uint256(_slot(src, safe, bytes32(uint256(3)))) == n, "safe.ownerCount slot");
        for (uint256 i = 0; i < n; i++) {
            bool found;
            for (uint256 j = 0; j < n; j++) {
                if (owners[j] == x.owners[i]) found = true;
            }
            _eq(found, "safe.owners set");
        }

        // Modules: walk every page from the sentinel; any module, or a list that does not terminate at the
        // sentinel, fails. `modules[SENTINEL] == SENTINEL` is also read from storage (slot 1 mapping).
        address start = SAFE_SENTINEL;
        for (uint256 page = 0;; page++) {
            _eq(page < SAFE_MAX_MODULE_PAGES, "safe.modules pagination did not terminate");
            (address[] memory mods, address next) = abi.decode(
                _call(src, safe, abi.encodeCall(ISafeView.getModulesPaginated, (start, SAFE_MODULE_PAGE))),
                (address[], address)
            );
            _eq(mods.length == 0, "safe.modules not empty");
            if (next == SAFE_SENTINEL) break;
            _eq(next != address(0) && next != start, "safe.modules list malformed");
            start = next;
        }
        _eq(
            _slot(src, safe, keccak256(abi.encode(SAFE_SENTINEL, uint256(1)))) == bytes32(uint256(1)),
            "safe.modules[SENTINEL] slot"
        );

        _eq(_slot(src, safe, SAFE_GUARD_SLOT) == bytes32(uint256(uint160(x.guard))), "safe.guard");
        _eq(
            _slot(src, safe, SAFE_FALLBACK_HANDLER_SLOT) == bytes32(uint256(uint160(x.fallbackHandler))),
            "safe.fallbackHandler"
        );
        _eq(_slot(src, safe, SAFE_MODULE_GUARD_SLOT) == bytes32(0), "safe.moduleGuard");
    }

    // ---------------------------------------------------------------- readers

    function local() internal pure returns (Src memory) {
        return Src("", "");
    }

    function remote(string memory rpc, string memory tag) internal pure returns (Src memory) {
        if (bytes(rpc).length == 0) revert VerificationFailed("remote: empty RPC URL");
        return Src(rpc, tag);
    }

    function _isLocal(Src memory src) internal pure returns (bool) {
        return bytes(src.rpc).length == 0;
    }

    function _chainId(Src memory src) internal returns (uint256) {
        if (_isLocal(src)) return block.chainid;
        return _quantity(vm.rpc(src.rpc, "eth_chainId", "[]"));
    }

    function _code(Src memory src, address a) internal returns (bytes memory) {
        if (_isLocal(src)) return a.code;
        return vm.rpc(src.rpc, "eth_getCode", string.concat('["', vm.toString(a), '","', src.tag, '"]'));
    }

    function _slot(Src memory src, address a, bytes32 slot) internal returns (bytes32 v) {
        if (_isLocal(src)) return vm.load(a, slot);
        bytes memory r = vm.rpc(
            src.rpc,
            "eth_getStorageAt",
            string.concat('["', vm.toString(a), '","', vm.toString(slot), '","', src.tag, '"]')
        );
        if (r.length != 32) revert VerificationFailed("remote: eth_getStorageAt length");
        v = bytes32(r);
    }

    function _nonce(Src memory src, address a) internal returns (uint256) {
        if (_isLocal(src)) return vm.getNonce(a);
        return _quantity(
            vm.rpc(src.rpc, "eth_getTransactionCount", string.concat('["', vm.toString(a), '","', src.tag, '"]'))
        );
    }

    /// @dev A failed call is a verification failure, never a default value.
    function _call(Src memory src, address a, bytes memory data) internal returns (bytes memory ret) {
        if (_isLocal(src)) {
            bool ok;
            (ok, ret) = a.staticcall(data);
            if (!ok) revert VerificationFailed("call reverted");
            return ret;
        }
        return vm.rpc(
            src.rpc,
            "eth_call",
            string.concat('[{"to":"', vm.toString(a), '","data":"', vm.toString(data), '"},"', src.tag, '"]')
        );
    }

    function _word(Src memory src, address a, bytes memory data) internal returns (bytes32) {
        bytes memory r = _call(src, a, data);
        if (r.length != 32) revert VerificationFailed("return is not one word");
        return bytes32(r);
    }

    function _addr(Src memory src, address a, bytes memory data) internal returns (address) {
        uint256 w = uint256(_word(src, a, data));
        if (w >> 160 != 0) revert VerificationFailed("dirty address return");
        return address(uint160(w));
    }

    function _uint(Src memory src, address a, bytes memory data) internal returns (uint256) {
        return uint256(_word(src, a, data));
    }

    function _bool(Src memory src, address a, bytes memory data) internal returns (bool) {
        uint256 w = uint256(_word(src, a, data));
        if (w > 1) revert VerificationFailed("dirty bool return");
        return w == 1;
    }

    function _quantity(bytes memory b) internal pure returns (uint256 v) {
        if (b.length > 32) revert VerificationFailed("remote: quantity too long");
        for (uint256 i = 0; i < b.length; i++) {
            v = (v << 8) | uint8(b[i]);
        }
    }

    function _eq(bool ok, string memory what) internal pure {
        if (!ok) revert VerificationFailed(what);
    }

    function _hashOf(address a) internal view returns (bytes32) {
        return keccak256(a.code);
    }
}
