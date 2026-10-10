// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IRouterClient} from "../vendor/ccip-2.0.0/interfaces/IRouterClient.sol";
import {StarknetOwnerProxy} from "../src/StarknetOwnerProxy.sol";
import {CCIPGovernancePayload} from "../src/CCIPGovernancePayload.sol";
import {CCIPGovernanceSender} from "../src/CCIPGovernanceSender.sol";
import {CCIPOwnerExecutor} from "../src/CCIPOwnerExecutor.sol";
import {CCIPRouteVerifier} from "../script/CCIPRouteVerifier.sol";
import {CCIPRouteGates} from "../script/CCIPRouteGates.s.sol";

interface IOwnable {
    function owner() external view returns (address);
}

/// @notice EKU-1217 read-only fork regression for the verification and gate tooling against real chain state.
///         Local forks and raw `eth_call` / `eth_getStorageAt` / `eth_getCode` reads only: no key, no broadcast.
///         The Safe below is an UNRELATED third-party Safe 1.4.1 (2-of-3, no modules) used only to prove the
///         reader matches real Safe storage and getters. It is NOT an approved canceller; no canceller is chosen.
/// @dev Needs BNB_RPC_URL (BNB tests) and ETH_RPC_URL (Ethereum tests); skipped otherwise.
contract CCIPRouteGatesBnbForkTest is Test {
    address constant FORMAT_SAFE = 0x0d2Cb430f0da03cACDfa57ec5c4B502999999999;
    address constant SAFE_L2_141 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address constant FALLBACK_141 = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    bytes32 constant SAFE_PROXY_141_KECCAK = 0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c;
    /// @dev L-6: SafeL2 1.4.1 singleton runtime keccak (same bytes on BNB Chain, BNB testnet and Monad testnet).
    bytes32 constant SAFE_L2_141_CODEHASH = 0xb1f926978a0f44a2c0ec8fe822418ae969bd8c3f18d61e5103100339894f81ff;
    address constant COMPANY_KEY = 0x00000C771F6176268D5A9846E0956C3eF58597A1;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    CCIPRouteGates h;
    string rpc;
    uint256 forkBlock;

    function setUp() public {
        rpc = vm.envOr("BNB_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // Public BNB RPCs serve only recent state over raw RPC, so the fork is taken at the latest block and the
        // raw reads are pinned to that same block number.
        uint256 b = vm.envOr("BNB_FORK_BLOCK", uint256(0));
        if (b == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, b);
        forkBlock = block.number;
        h = new CCIPRouteGates();
    }

    function _err(string memory what) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CCIPRouteVerifier.VerificationFailed.selector, what);
    }

    function _formatSafe() internal pure returns (CCIPRouteVerifier.SafeExpect memory x) {
        address[] memory owners = new address[](3);
        owners[0] = 0xa8E1eF8220522a5f26ec7b7B7F9d987342b6cd99;
        owners[1] = 0x7193a17E17C4FC9A5f81f109502f1F7f017B32e2;
        owners[2] = 0xa873D6deDA99ef98F806b3955595Dc1a5F3d3B81;
        x = CCIPRouteVerifier.SafeExpect({
            safe: FORMAT_SAFE,
            chainId: 56,
            owners: owners,
            threshold: 2,
            guard: address(0),
            fallbackHandler: FALLBACK_141,
            singleton: SAFE_L2_141,
            proxyRuntimeKeccak: SAFE_PROXY_141_KECCAK,
            singletonCodehash: SAFE_L2_141_CODEHASH
        });
    }

    function _remote() internal view returns (CCIPRouteVerifier.Src memory) {
        return CCIPRouteVerifier.Src(rpc, _hexQuantity(forkBlock));
    }

    function _local() internal pure returns (CCIPRouteVerifier.Src memory) {
        return CCIPRouteVerifier.Src("", "");
    }

    function _hexQuantity(uint256 v) internal pure returns (string memory) {
        bytes memory digits = "0123456789abcdef";
        bytes memory out = new bytes(64);
        uint256 n;
        do {
            out[63 - n] = digits[v & 15];
            v >>= 4;
            n++;
        } while (v != 0);
        bytes memory r = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            r[i] = out[64 - n + i];
        }
        return string.concat("0x", string(r));
    }

    function _bothFail(CCIPRouteVerifier.SafeExpect memory x, string memory what) internal {
        try h.verifySafe(_local(), x) {
            revert(string.concat("local accepted: ", what));
        } catch (bytes memory err) {
            assertEq(err, _err(what), what);
        }
        try h.verifySafe(_remote(), x) {
            revert(string.concat("remote accepted: ", what));
        } catch (bytes memory err) {
            assertEq(err, _err(what), what);
        }
    }

    /// Real Safe 1.4.1 storage and getters, read from the fork AND over raw RPC at the same block.
    function test_fork_bnb_realSafe141_reader_localAndRemote() public {
        h.verifySafe(_local(), _formatSafe());
        h.verifySafe(_remote(), _formatSafe());

        CCIPRouteVerifier.SafeExpect memory x = _formatSafe();
        x.threshold = 3;
        _bothFail(x, "safe.threshold");
        x = _formatSafe();
        x.owners[1] = makeAddr("intruder");
        _bothFail(x, "safe.owners set");
        x = _formatSafe();
        x.guard = makeAddr("guard");
        _bothFail(x, "safe.guard");
        x = _formatSafe();
        x.fallbackHandler = address(0);
        _bothFail(x, "safe.fallbackHandler");
        x = _formatSafe();
        x.singleton = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
        _bothFail(x, "safe.singleton");
        x = _formatSafe();
        x.proxyRuntimeKeccak = keccak256("other");
        _bothFail(x, "safe.proxyRuntimeKeccak");
        x = _formatSafe();
        x.chainId = 143;
        _bothFail(x, "safe.chainId");
    }

    /// The EKU-1199 dry-run "canceller" was the SafeL2 1.4.1 singleton. It is rejected as a Safe, and even with the
    /// placeholder screen bypassed by expectation, its real state (no owners, threshold 1) cannot pass.
    function test_fork_bnb_singletonPlaceholder_rejected() public {
        CCIPRouteVerifier.SafeExpect memory x = _formatSafe();
        x.safe = SAFE_L2_141;
        _bothFail(x, "safe: placeholder or singleton address");
        assertEq(abi.decode(_remoteCall(SAFE_L2_141, abi.encodeWithSignature("getThreshold()")), (uint256)), 1);
    }

    function _remoteCall(address to, bytes memory data) internal returns (bytes memory) {
        return vm.rpc(
            rpc,
            "eth_call",
            string.concat('[{"to":"', vm.toString(to), '","data":"', vm.toString(data), '"},"', _remote().tag, '"]')
        );
    }

    /// Production-parameter executor on a fork: exact read-back passes, and the D3 simulation transfers every real
    /// target from the company key with the exact calldata. Canceller here is a code-bearing stand-in only.
    function test_fork_bnb_productionExecutor_readback_and_D3() public {
        address deployer = makeAddr("eku1217-fork-deployer");
        address senderPredicted = vm.computeCreateAddress(deployer, 0);
        address[] memory ts = h.targetsFor(56);
        address router = h.routerFor(56);
        vm.prank(deployer);
        CCIPOwnerExecutor e = new CCIPOwnerExecutor(
            router, 5009297550715157269, senderPredicted, 259200, 1209600, 2592000, FORMAT_SAFE, ts
        );
        assertEq(address(e), vm.computeCreateAddress(deployer, 0));
        CCIPRouteVerifier.ExecutorExpect memory x =
            h.productionExecutor(56, address(e), senderPredicted, FORMAT_SAFE, keccak256(address(e).code));
        h.verifyExecutor(_local(), x);
        x.sender = address(0x5E4D);
        try h.verifyExecutor(_local(), x) {
            revert("wrong sender accepted");
        } catch (bytes memory err) {
            assertEq(err, _err("executor.sender"));
        }

        for (uint256 i = 0; i < ts.length; i++) {
            assertEq(IOwnable(ts[i]).owner(), COMPANY_KEY);
        }
        h.simulateTransfers(e, address(0));
        for (uint256 i = 0; i < ts.length; i++) {
            assertEq(IOwnable(ts[i]).owner(), address(e));
        }
    }

    /// L-5 (CSO EKU-1218): a second, independent provider forked at the same block must agree on the parent block
    /// hash, timestamp, every Queued log and the ops() classification; a log only one provider reports fails
    /// closed. The executor is a local deployment made persistent across both forks (no Queued logs on chain).
    function test_fork_bnb_L5_twoProviders_sameBlock() public {
        string memory rpc2 = vm.envOr("BNB_RPC_URL_2", string(""));
        if (bytes(rpc2).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, forkBlock - 5);
        h = new CCIPRouteGates();
        address deployer = makeAddr("eku1232-fork-deployer");
        vm.prank(deployer);
        CCIPOwnerExecutor e = new CCIPOwnerExecutor(
            h.routerFor(56),
            5009297550715157269,
            vm.computeCreateAddress(deployer, 0),
            259200,
            1209600,
            2592000,
            FORMAT_SAFE,
            h.targetsFor(56)
        );
        vm.makePersistent(address(e));
        vm.makePersistent(address(h));
        uint256 from = block.number - 20;
        CCIPRouteGates.QueuedLog[] memory logs = h.fetchQueued(address(e), from, block.number, 100);
        CCIPRouteGates.QueueReport memory r = h.classifyQueued(e, logs, new bytes32[](0), block.timestamp);
        uint256 b = block.number;
        h.reconcileWithProvider(e, logs, r, rpc2, from, new bytes32[](0));
        assertEq(block.number, b, "primary fork restored");

        CCIPRouteGates.QueuedLog[] memory extra = new CCIPRouteGates.QueuedLog[](1);
        extra[0].payloadHash = keccak256("only on provider 1");
        try h.reconcileWithProvider(e, extra, r, rpc2, from, new bytes32[](0)) {
            revert("discrepancy accepted");
        } catch (bytes memory err) {
            assertEq(err, _err("L-5: Queued log count differs between providers"));
        }
    }

    /// `fetchLogs` paging: one-block pages return exactly what one wide page returns, in order.
    function test_fork_bnb_fetchLogs_chunkParity() public {
        bytes32 transfer = keccak256("Transfer(address,address,uint256)");
        uint256 to = forkBlock;
        uint256 from = to - 3;
        Vm.EthGetLogs[] memory wide = h.fetchLogs(USDT, transfer, bytes32(0), from, to, 100);
        Vm.EthGetLogs[] memory narrow = h.fetchLogs(USDT, transfer, bytes32(0), from, to, 1);
        assertGt(wide.length, 0);
        assertEq(wide.length, narrow.length);
        for (uint256 i = 0; i < wide.length; i++) {
            assertEq(wide[i].transactionHash, narrow[i].transactionHash);
            assertEq(wide[i].logIndex, narrow[i].logIndex);
            assertEq(keccak256(wide[i].data), keccak256(narrow[i].data));
        }
    }
}

/// @notice L-1 on an Ethereum fork: the exact Starknet->L1 message for each chain's owner() proof is simulated
///         end to end through the REAL StarknetOwnerProxy (message settlement injected with vm.store), the sender
///         and the real CCIP router; pre-handoff, wrong nonce, value and deadline fail closed.
contract CCIPRouteGatesEthForkTest is Test {
    address constant L1_PROXY = 0x1E0EF4162e42C9bF820c307218c4E41cCcA6E9CC;
    address constant ETH_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    uint64 constant BNB_SELECTOR = 11344663589394136015;
    uint64 constant MONAD_SELECTOR = 8481857512324358265;
    address constant E_BNB = address(0xE56);
    address constant E_MONAD = address(0xE143);

    CCIPRouteGates h;
    string rpc;
    address bootstrap = makeAddr("eku1217-bootstrap");

    function setUp() public {
        rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 b = vm.envOr("ETH_FORK_BLOCK", uint256(0));
        if (b == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, b);
        h = new CCIPRouteGates();
    }

    function _err(string memory what) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CCIPRouteVerifier.VerificationFailed.selector, what);
    }

    function _sender() internal returns (CCIPGovernanceSender) {
        return new CCIPGovernanceSender(
            IRouterClient(ETH_ROUTER),
            L1_PROXY,
            bootstrap,
            CCIPGovernanceSender.Destination(BNB_SELECTOR, 56, E_BNB),
            CCIPGovernanceSender.Destination(MONAD_SELECTOR, 143, E_MONAD),
            1_000_000
        );
    }

    function _felts(CCIPGovernanceSender s, uint64 dest, uint256 value, uint64 nonce, uint64 deadline)
        internal
        view
        returns (uint256[] memory)
    {
        address[] memory ts = h.targetsFor(dest == BNB_SELECTOR ? 56 : 143);
        CCIPGovernancePayload.Call[] memory c = new CCIPGovernancePayload.Call[](ts.length);
        for (uint256 i = 0; i < ts.length; i++) {
            c[i] = CCIPGovernancePayload.Call(ts[i], hex"8da5cb5b");
        }
        bytes memory data = abi.encodeCall(CCIPGovernanceSender.request, (dest, 500_000, deadline, c));
        return StarknetOwnerProxy(payable(L1_PROXY)).getPayload(address(s), value, nonce, data);
    }

    function _simFails(CCIPGovernanceSender s, uint256[] memory felts, string memory what) internal {
        try h.simulateGovernorMessage(address(s), E_BNB, E_MONAD, felts, true, 7 days) {
            revert(string.concat("accepted: ", what));
        } catch (bytes memory err) {
            assertEq(err, _err(what), what);
        }
    }

    function test_fork_eth_L1_exactMessages_simulated_afterHandoff() public {
        CCIPGovernanceSender s = _sender();
        StarknetOwnerProxy p = StarknetOwnerProxy(payable(L1_PROXY));
        uint64 n = p.currentNonce();
        uint64 deadline = uint64(vm.getBlockTimestamp() + 20 days);

        uint256 nowTs = vm.getBlockTimestamp();
        uint256[] memory bnbOk = _felts(s, BNB_SELECTOR, 0, n, deadline);
        uint256[] memory monOk = _felts(s, MONAD_SELECTOR, 0, n + 1, deadline);
        uint256[] memory wrongNonce = _felts(s, BNB_SELECTOR, 0, n + 1, deadline);
        uint256[] memory withValue = _felts(s, BNB_SELECTOR, 1, n, deadline);
        uint256[] memory tooFar = _felts(s, BNB_SELECTOR, 0, n, uint64(nowTs + 31 days));
        uint256[] memory tooEarly = _felts(s, BNB_SELECTOR, 0, n, uint64(nowTs + 1 days));

        // Pre-handoff: refused before anything is simulated (the real path would jam nonce n).
        _simFails(s, bnbOk, "L-1: sender authority != StarknetOwnerProxy");

        vm.prank(bootstrap);
        s.handoff();

        _simFails(s, wrongNonce, "C9: message nonce != proxy currentNonce (in order)");
        _simFails(s, withValue, "L-1: L1 message value != 0");
        _simFails(s, tooFar, "I-3: deadline > now + maxTtl would fail DeadlineTooFar");
        _simFails(s, tooEarly, "deadline too early");
        assertEq(p.currentNonce(), n, "nothing consumed by refused messages");

        assertEq(h.simulateGovernorMessage(address(s), E_BNB, E_MONAD, bnbOk, true, 7 days), BNB_SELECTOR);
        assertEq(h.simulateGovernorMessage(address(s), E_BNB, E_MONAD, monOk, true, 7 days), MONAD_SELECTOR);
        assertEq(p.currentNonce(), n + 2);
        assertEq(s.nextOpId(BNB_SELECTOR), 1);
        assertEq(s.nextOpId(MONAD_SELECTOR), 1);
    }

    /// L-1 / L-2: the finalized read-back is a raw RPC read of real chain state; a sender that exists only on the
    /// local fork (i.e. not deployed / not finalized) fails closed.
    function test_fork_eth_finalizedReadback_failsForUndeployedSender() public {
        CCIPGovernanceSender s = _sender();
        CCIPRouteVerifier.SenderExpect memory x =
            h.productionSender(address(s), L1_PROXY, E_BNB, E_MONAD, keccak256(address(s).code));
        vm.expectRevert(_err("sender.code empty"));
        h.verifySender(CCIPRouteVerifier.Src(rpc, "finalized"), x);
    }
}
