// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CCIPGovernancePayload} from "../../src/CCIPGovernancePayload.sol";
import {CCIPGovernanceSender} from "../../src/CCIPGovernanceSender.sol";
import {CCIPOwnerExecutor} from "../../src/CCIPOwnerExecutor.sol";
import {IRouterClient} from "../../vendor/ccip-2.0.0/interfaces/IRouterClient.sol";
import {CCIPRouteVerifier} from "../CCIPRouteVerifier.sol";
import {T2DummyTarget} from "./T2DummyTarget.sol";

interface ISafeProxyFactory141 {
    function proxyCreationCode() external pure returns (bytes memory);
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ISafe141 {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function nonce() external view returns (uint256);
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);
    function checkSignatures(bytes32 dataHash, bytes memory data, bytes memory signatures) external view;
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool);
}

interface IStarknetCoreView {
    function l2ToL1Messages(bytes32 msgHash) external view returns (uint256);
}

/// @notice TESTNET-ONLY configuration of the T2 real-delivery rehearsal of the A'-CCIP owner route (EKU-1232).
///         Ethereum Sepolia (StarknetOwnerProxy test instance + sender) -> CCIP -> BNB Chain testnet (97) and Monad
///         testnet (10143) executors owning dummy targets, driven by a short-period Governor on Starknet Sepolia.
///         Every value below was read from the official CCIP directory API and public RPCs (EKU-1232
///         `logs/lane-snapshot.log`); the scripts re-read and assert them before every step.
/// @dev Nothing here is a production value. Production chains 1, 56 and 143 are refused by `requireT2Chain`.
abstract contract T2Config is CCIPRouteVerifier {
    uint256 internal constant SEPOLIA = 11155111;
    uint256 internal constant BNB_TESTNET = 97;
    uint256 internal constant MONAD_TESTNET = 10143;

    uint64 internal constant SEPOLIA_SELECTOR = 16015286601757825753;
    uint64 internal constant BNB_TESTNET_SELECTOR = 13264668187771770619;
    uint64 internal constant MONAD_TESTNET_SELECTOR = 2183018362218727504;

    address internal constant SEPOLIA_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59; // Router 1.2.0
    address internal constant SEPOLIA_ONRAMP = 0x8dcf17f298c881A547D91ca4aA3C2AD7568C6777; // OnRamp 2.0.0
    address internal constant BNB_TESTNET_ROUTER = 0xE1053aE1857476f36A3C62580FF9b016E8EE8F6f; // Router 1.2.0
    address internal constant BNB_TESTNET_OFFRAMP = 0x32d4DD31a03e82FE7B1b8C9E5E6fa028B2fcA770; // OffRamp 2.0.0
    address internal constant MONAD_TESTNET_ROUTER = 0x5aD0A67f4Da0E8665a3fbf15E4215A780407Cf33; // Router 1.2.0
    address internal constant MONAD_TESTNET_OFFRAMP = 0x8C7676A0E7289Fe1ECb09d77a755E52AFd5eC471; // OffRamp 2.0.0
    /// @dev Starknet Sepolia core contract on Ethereum Sepolia ("StarkWare_Starknet_2026_12").
    address internal constant STARKNET_SEPOLIA_CORE = 0xE2Bb56ee936fd6433DC0F6e7e3b8365C906AA057;

    // Safe 1.4.1 canonical deployments (identical code on 97 and 10143; codehashes read in the lane snapshot).
    address internal constant SAFE_L2_141 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    bytes32 internal constant SAFE_L2_141_CODEHASH = 0xb1f926978a0f44a2c0ec8fe822418ae969bd8c3f18d61e5103100339894f81ff;
    address internal constant SAFE_FACTORY_141 = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_FALLBACK_141 = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    bytes32 internal constant SAFE_PROXY_141_KECCAK =
        0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c;
    uint256 internal constant T2_SAFE_THRESHOLD = 2;
    uint256 internal constant T2_SAFE_OWNER_COUNT = 3;

    // Constructor-shortened TESTNET timing (bounded by `checkTiming(false, ...)`; production is 72 h / 14 d / 30 d).
    uint64 internal constant T2_DELAY = 600; // 10 min
    uint64 internal constant T2_WINDOW = 86400; // 1 d
    uint64 internal constant T2_TTL = 604800; // 7 d
    uint32 internal constant T2_MAX_GAS_LIMIT = 1_000_000;
    uint32 internal constant T2_GAS_LIMIT = 300_000;
    uint32 internal constant T2_LOW_GAS_LIMIT = 100_000; // = sender MIN_GAS_LIMIT
    /// @dev Calldata bytes of the padded `note` call that makes `ccipReceive` exceed `T2_LOW_GAS_LIMIT`
    ///      (measured in `T2RehearsalFork`: >= 1.5x headroom over the limit, well under maxDataBytes 32000).
    uint256 internal constant T2_PAD_BYTES = 14_000;

    /// @dev Starknet `selector!("send_message_to_l1")` (starknet_keccak).
    uint256 public constant SEND_MESSAGE_TO_L1_SELECTOR =
        uint256(keccak256("send_message_to_l1")) & ((uint256(1) << 250) - 1);

    error NotT2Chain(uint256 chainId);

    function requireT2Chain() public view {
        uint256 c = block.chainid;
        if (c != SEPOLIA && c != BNB_TESTNET && c != MONAD_TESTNET) revert NotT2Chain(c);
    }

    function isDest(uint256 cid) public pure returns (bool) {
        return cid == BNB_TESTNET || cid == MONAD_TESTNET;
    }

    function t2Router(uint256 cid) public pure returns (address) {
        if (cid == SEPOLIA) return SEPOLIA_ROUTER;
        if (cid == BNB_TESTNET) return BNB_TESTNET_ROUTER;
        if (cid == MONAD_TESTNET) return MONAD_TESTNET_ROUTER;
        revert NotT2Chain(cid);
    }

    function t2OffRamp(uint256 cid) public pure returns (address) {
        if (cid == BNB_TESTNET) return BNB_TESTNET_OFFRAMP;
        if (cid == MONAD_TESTNET) return MONAD_TESTNET_OFFRAMP;
        revert NotT2Chain(cid);
    }

    function t2Selector(uint256 cid) public pure returns (uint64) {
        if (cid == BNB_TESTNET) return BNB_TESTNET_SELECTOR;
        if (cid == MONAD_TESTNET) return MONAD_TESTNET_SELECTOR;
        revert NotT2Chain(cid);
    }

    /// @notice Dummy targets per destination: 2 on BNB testnet and 4 on Monad testnet, the production shape.
    function t2TargetCount(uint256 cid) public pure returns (uint256) {
        if (cid == BNB_TESTNET) return 2;
        if (cid == MONAD_TESTNET) return 4;
        revert NotT2Chain(cid);
    }

    // ---------------------------------------------------------------- deterministic address plan

    /// @notice One fresh single-purpose T2 deployer key is used on all three EVM chains. Its nonces are the plan:
    ///         Sepolia 0 = StarknetOwnerProxy (test instance), 1 = sender. Destination 0..n-1 = dummy targets,
    ///         n = Safe creation call (CREATE2 by the factory), n+1 = executor, n+2.. = transfers to the executor.
    function t2Proxy(address deployer) public pure returns (address) {
        return vm.computeCreateAddress(deployer, 0);
    }

    function t2Sender(address deployer) public pure returns (address) {
        return vm.computeCreateAddress(deployer, 1);
    }

    function t2Targets(address deployer, uint256 cid) public pure returns (address[] memory ts) {
        ts = new address[](t2TargetCount(cid));
        for (uint256 i = 0; i < ts.length; i++) {
            ts[i] = vm.computeCreateAddress(deployer, i);
        }
    }

    function t2SafeNonce(uint256 cid) public pure returns (uint256) {
        return t2TargetCount(cid);
    }

    function t2Executor(address deployer, uint256 cid) public pure returns (address) {
        return vm.computeCreateAddress(deployer, t2TargetCount(cid) + 1);
    }

    function t2SafeInitializer(address[] memory owners) public pure returns (bytes memory) {
        return abi.encodeCall(
            ISafe141.setup,
            (owners, T2_SAFE_THRESHOLD, address(0), "", SAFE_FALLBACK_141, address(0), 0, payable(address(0)))
        );
    }

    /// @notice CREATE2 address of the Safe 1.4.1 proxy `createProxyWithNonce(SAFE_L2_141, initializer, salt)`.
    function t2SafeAddress(bytes memory proxyCreationCode, address[] memory owners, uint256 saltNonce)
        public
        pure
        returns (address)
    {
        bytes32 salt = keccak256(abi.encodePacked(keccak256(t2SafeInitializer(owners)), saltNonce));
        bytes32 initHash = keccak256(abi.encodePacked(proxyCreationCode, uint256(uint160(SAFE_L2_141))));
        return vm.computeCreate2Address(salt, initHash, SAFE_FACTORY_141);
    }

    // ---------------------------------------------------------------- exact expectations

    function t2ExecutorExpect(uint256 cid, address executor, address sender, address canceller, address[] memory ts)
        public
        returns (ExecutorExpect memory x)
    {
        x = ExecutorExpect({
            executor: executor,
            chainId: cid,
            router: t2Router(cid),
            sourceChainSelector: SEPOLIA_SELECTOR,
            sender: sender,
            delay: T2_DELAY,
            executionWindow: T2_WINDOW,
            maxTtl: T2_TTL,
            canceller: canceller,
            targets: ts,
            runtimeKeccak: bytes32(0)
        });
        x.runtimeKeccak = t2ExecutorRuntimeKeccak(x);
    }

    /// @notice Runtime keccak of a local, never-broadcast reference build with exactly these constructor arguments.
    ///         Must not be called while a broadcast is active.
    function t2ExecutorRuntimeKeccak(ExecutorExpect memory x) public returns (bytes32 h) {
        uint256 snap = vm.snapshotState();
        h = keccak256(
            address(
                new CCIPOwnerExecutor(
                    x.router,
                    x.sourceChainSelector,
                    x.sender,
                    x.delay,
                    x.executionWindow,
                    x.maxTtl,
                    x.canceller,
                    x.targets
                )
            )
            .code
        );
        vm.revertToState(snap);
    }

    function t2SenderExpect(address sender, address proxy, address authority, address eBnb, address eMon)
        public
        pure
        returns (SenderExpect memory x)
    {
        x = SenderExpect({
            sender: sender,
            chainId: SEPOLIA,
            router: SEPOLIA_ROUTER,
            finalAuthority: proxy,
            authority: authority,
            maxGasLimit: T2_MAX_GAS_LIMIT,
            dest0: CCIPGovernanceSender.Destination(BNB_TESTNET_SELECTOR, uint64(BNB_TESTNET), eBnb),
            dest1: CCIPGovernanceSender.Destination(MONAD_TESTNET_SELECTOR, uint64(MONAD_TESTNET), eMon),
            runtimeKeccak: bytes32(0)
        });
    }

    /// @notice Runtime keccak of a local reference sender build (bootstrap is not an immutable, `authority` is
    ///         storage, so the hash does not depend on it). Must not be called while a broadcast is active.
    function t2SenderRuntimeKeccak(SenderExpect memory x, address bootstrap) public returns (bytes32 h) {
        uint256 snap = vm.snapshotState();
        h = keccak256(
            address(
                new CCIPGovernanceSender(
                    IRouterClient(x.router), x.finalAuthority, bootstrap, x.dest0, x.dest1, x.maxGasLimit
                )
            )
            .code
        );
        vm.revertToState(snap);
    }

    function t2SafeExpect(uint256 cid, address safe, address[] memory owners)
        public
        pure
        returns (SafeExpect memory x)
    {
        x = SafeExpect({
            safe: safe,
            chainId: cid,
            owners: owners,
            threshold: T2_SAFE_THRESHOLD,
            guard: address(0),
            fallbackHandler: SAFE_FALLBACK_141,
            singleton: SAFE_L2_141,
            proxyRuntimeKeccak: SAFE_PROXY_141_KECCAK,
            singletonCodehash: SAFE_L2_141_CODEHASH
        });
    }

    // ---------------------------------------------------------------- T2 operations

    /// @notice The T2 operation batches. `kind`: 0 = owner() on every dummy target (the harmless proof shape),
    ///         1 = setValue(value) on every dummy target (real owner-gated calls), 2 = one padded note() call on
    ///         the first target (forced low gas; cancelled by the Safe, never executed).
    function t2Calls(address[] memory ts, uint8 kind, uint256 value)
        public
        pure
        returns (CCIPGovernancePayload.Call[] memory c)
    {
        if (kind == 2) {
            c = new CCIPGovernancePayload.Call[](1);
            c[0] = CCIPGovernancePayload.Call(ts[0], abi.encodeCall(T2DummyTarget.note, (new bytes(T2_PAD_BYTES))));
            return c;
        }
        _eq(kind <= 1, "unknown T2 call kind");
        c = new CCIPGovernancePayload.Call[](ts.length);
        for (uint256 i = 0; i < ts.length; i++) {
            c[i] = CCIPGovernancePayload.Call(
                ts[i], kind == 0 ? abi.encodeWithSignature("owner()") : abi.encodeCall(T2DummyTarget.setValue, (value))
            );
        }
    }

    /// @notice StarknetOwnerProxy payload felts (byte-identical to `StarknetOwnerProxy.getPayload`).
    function t2Felts(address target, uint256 value, uint64 nonce, bytes memory data)
        public
        pure
        returns (uint256[] memory felts)
    {
        uint256 chunks = (data.length + 30) / 31;
        felts = new uint256[](4 + chunks);
        felts[0] = uint256(uint160(target));
        felts[1] = value;
        felts[2] = nonce;
        felts[3] = data.length;
        for (uint256 i = 0; i < chunks; i++) {
            uint256 f;
            for (uint256 k = 0; k < 31; k++) {
                uint256 j = i * 31 + k;
                f = (f << 8) | (j < data.length ? uint8(data[j]) : 0);
            }
            felts[4 + i] = f;
        }
    }

    /// @notice keccak of the L2->L1 message as StarknetCore records it (`l2ToL1Messages`).
    function t2MessageHash(uint256 l2Governor, address proxy, uint256[] memory felts) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(l2Governor, uint256(uint160(proxy)), felts.length, felts));
    }

    /// @notice One Governor proposal call `send_message_to_l1(proxy, felts)` serialized as a Starknet `Call`
    ///         (to, selector, calldata_len, calldata...). A proposal is `[n_calls, call_0..., call_1...]`.
    function t2StarknetCall(uint256 l2Governor, address proxy, uint256[] memory felts)
        public
        pure
        returns (uint256[] memory out)
    {
        out = new uint256[](3 + 2 + felts.length);
        out[0] = l2Governor;
        out[1] = SEND_MESSAGE_TO_L1_SELECTOR;
        out[2] = 2 + felts.length;
        out[3] = uint256(uint160(proxy));
        out[4] = felts.length;
        for (uint256 i = 0; i < felts.length; i++) {
            out[5 + i] = felts[i];
        }
    }

    // ---------------------------------------------------------------- identity checks

    /// @dev T2 dry-run placeholders are `0x1232…`; local fork fixtures are derived from the public label below.
    function isT2Placeholder(address a) public pure returns (bool) {
        return isPlaceholder(a) || uint160(a) >> 144 == 0x1232 || a == L1_PROXY || isFixture(a);
    }

    function isFixture(address a) public pure returns (bool) {
        for (uint256 i = 0; i < 8; i++) {
            if (a == vm.addr(fixtureKey(i))) return true;
        }
        return false;
    }

    /// @notice PUBLICLY KNOWN keys for local fork tests only. Never fund or use them on any network.
    function fixtureKey(uint256 i) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("eku1232-local-fork-fixture-NEVER-FUND", i)));
    }
}
