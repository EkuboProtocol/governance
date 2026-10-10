// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {IRouterClient} from "../vendor/ccip-2.0.0/interfaces/IRouterClient.sol";
import {StarknetOwnerProxy, IStarknetMessaging} from "../src/StarknetOwnerProxy.sol";
import {CCIPGovernanceSender} from "../src/CCIPGovernanceSender.sol";
import {CCIPOwnerExecutor} from "../src/CCIPOwnerExecutor.sol";
import {CCIPRouteVerifier} from "../script/CCIPRouteVerifier.sol";
import {CCIPRouteGates} from "../script/CCIPRouteGates.s.sol";
import {MockCCIPRouter, MockOwnedTarget} from "./CCIPMocks.sol";
import {MockSafe} from "./CCIPSafeMock.sol";

/// @notice EKU-1217 (CSO EKU-1200 M-A): positive and one-mismatch-per-field negative tests of the fail-closed
///         executor, sender and canceller-Safe read-backs and of the production / test timing profiles.
///         Evidence class: MOCKED, local EVM only (no fork, no key, no broadcast). `MockSafe` is a test-only Safe
///         look-alike and is never an approved canceller.
contract CCIPRouteVerificationTest is Test {
    uint64 constant ETH_SELECTOR = 5009297550715157269;
    uint64 constant BNB_SELECTOR = 11344663589394136015;
    uint64 constant MONAD_SELECTOR = 8481857512324358265;
    uint64 constant DELAY = 259200;
    uint64 constant WINDOW = 1209600;
    uint64 constant TTL = 2592000;
    address constant SENDER = address(0x5E4D);
    address constant BOOT = address(0xB007);
    address constant E_BNB = address(0xE56);
    address constant E_MONAD = address(0xE143);
    address constant SINGLETON = 0x5afe5afE5afE5afE5afE5aFe5aFe5Afe5Afe5AfE;
    address constant FALLBACK = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    CCIPRouteGates h;
    MockCCIPRouter router;
    MockSafe safe;
    MockOwnedTarget t0;
    MockOwnedTarget t1;
    CCIPOwnerExecutor ex;
    StarknetOwnerProxy l1;
    CCIPGovernanceSender snd;
    address[] owners;

    function setUp() public {
        vm.warp(1_800_000_000);
        h = new CCIPRouteGates();
        router = new MockCCIPRouter();
        owners.push(makeAddr("signer-a"));
        owners.push(makeAddr("signer-b"));
        owners.push(makeAddr("signer-c"));
        safe = new MockSafe();
        safe.setup(SINGLETON, owners, 2, FALLBACK);
        t0 = new MockOwnedTarget(address(this));
        t1 = new MockOwnedTarget(address(this));
        ex = new CCIPOwnerExecutor(address(router), ETH_SELECTOR, SENDER, DELAY, WINDOW, TTL, address(safe), _ts());
        l1 = new StarknetOwnerProxy(IStarknetMessaging(address(0x5701)), 1);
        snd = new CCIPGovernanceSender(
            IRouterClient(address(router)),
            address(l1),
            BOOT,
            CCIPGovernanceSender.Destination(BNB_SELECTOR, 56, E_BNB),
            CCIPGovernanceSender.Destination(MONAD_SELECTOR, 143, E_MONAD),
            1_000_000
        );
    }

    function _ts() internal view returns (address[] memory ts) {
        ts = new address[](2);
        ts[0] = address(t0);
        ts[1] = address(t1);
    }

    function _local() internal pure returns (CCIPRouteVerifier.Src memory) {
        return CCIPRouteVerifier.Src("", "");
    }

    function _err(string memory what) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CCIPRouteVerifier.VerificationFailed.selector, what);
    }

    // ---------------------------------------------------------------- executor

    function _ex() internal view returns (CCIPRouteVerifier.ExecutorExpect memory x) {
        x = CCIPRouteVerifier.ExecutorExpect({
            executor: address(ex),
            chainId: block.chainid,
            router: address(router),
            sourceChainSelector: ETH_SELECTOR,
            sender: SENDER,
            delay: DELAY,
            executionWindow: WINDOW,
            maxTtl: TTL,
            canceller: address(safe),
            targets: _ts(),
            runtimeKeccak: keccak256(address(ex).code)
        });
    }

    function _exFails(CCIPRouteVerifier.ExecutorExpect memory x, string memory what) internal {
        try h.verifyExecutor(_local(), x) {
            revert(string.concat("expected failure: ", what));
        } catch (bytes memory err) {
            assertEq(err, _err(what), what);
        }
    }

    function test_executor_exact_passes() public {
        h.verifyExecutor(_local(), _ex());
    }

    function test_executor_eachFieldMismatch_fails() public {
        CCIPRouteVerifier.ExecutorExpect memory x;
        x = _ex();
        x.chainId = 56;
        _exFails(x, "executor.chainId");
        x = _ex();
        x.executor = address(0xDEAD);
        _exFails(x, "executor.code empty");
        x = _ex();
        x.runtimeKeccak = bytes32(uint256(x.runtimeKeccak) ^ 1);
        _exFails(x, "executor.runtimeKeccak");
        x = _ex();
        x.router = address(0x1234);
        _exFails(x, "executor.router");
        x = _ex();
        x.sourceChainSelector = BNB_SELECTOR;
        _exFails(x, "executor.sourceChainSelector");
        x = _ex();
        x.sender = address(0x5E4E);
        _exFails(x, "executor.sender");
        x = _ex();
        x.delay = DELAY - 1;
        _exFails(x, "executor.delay");
        x = _ex();
        x.executionWindow = WINDOW + 1;
        _exFails(x, "executor.executionWindow");
        x = _ex();
        x.maxTtl = TTL - 1;
        _exFails(x, "executor.maxTtl");
        x = _ex();
        x.canceller = owners[0];
        _exFails(x, "executor.canceller");
        x = _ex();
        (x.targets[0], x.targets[1]) = (x.targets[1], x.targets[0]);
        _exFails(x, "executor.targets");
        x = _ex();
        x.targets = new address[](1);
        x.targets[0] = address(t0);
        _exFails(x, "executor.targets");
        x = _ex();
        x.targets = new address[](3);
        (x.targets[0], x.targets[1], x.targets[2]) = (address(t0), address(t1), address(router));
        _exFails(x, "executor.targets");
    }

    /// A differently-parameterised executor never matches the pinned runtime; with its own hash it still fails
    /// on the exact field.
    function test_executor_differentDeployment_failsOnHash() public {
        CCIPOwnerExecutor other =
            new CCIPOwnerExecutor(address(router), ETH_SELECTOR, SENDER, 1, WINDOW, TTL, address(safe), _ts());
        CCIPRouteVerifier.ExecutorExpect memory x = _ex();
        x.executor = address(other);
        _exFails(x, "executor.runtimeKeccak");
        x.runtimeKeccak = keccak256(address(other).code);
        _exFails(x, "executor.delay");
    }

    /// CSO M-A: the constructor accepts `delay = 2^64-1` (eta overflow bricks every GOVERNOR delivery) and an extreme
    /// window. Exact read-back rejects both deployments.
    function test_executor_unsafeExtremeDelayAndWindow_rejected() public {
        CCIPOwnerExecutor bricked = new CCIPOwnerExecutor(
            address(router), ETH_SELECTOR, SENDER, type(uint64).max, WINDOW, TTL, address(safe), _ts()
        );
        CCIPRouteVerifier.ExecutorExpect memory x = _ex();
        x.executor = address(bricked);
        x.runtimeKeccak = keccak256(address(bricked).code);
        _exFails(x, "executor.delay");

        CCIPOwnerExecutor wide = new CCIPOwnerExecutor(
            address(router), ETH_SELECTOR, SENDER, DELAY, type(uint64).max, TTL, address(safe), _ts()
        );
        x = _ex();
        x.executor = address(wide);
        x.runtimeKeccak = keccak256(address(wide).code);
        _exFails(x, "executor.executionWindow");
    }

    // ---------------------------------------------------------------- timing profiles

    function _timingFails(bool production, uint256 cid, uint64 d, uint64 w, uint64 t, string memory what)
        internal
        view
    {
        try h.checkTiming(production, cid, d, w, t) {
            revert(string.concat("expected failure: ", what));
        } catch (bytes memory err) {
            assertEq(err, _err(what), what);
        }
    }

    function test_timing_production_exactOnly() public view {
        h.checkTiming(true, 56, DELAY, WINDOW, TTL);
        h.checkTiming(true, 143, DELAY, WINDOW, TTL);
    }

    function test_timing_production_rejectsAnyOther() public {
        _timingFails(true, 56, DELAY + 1, WINDOW, TTL, "timing.delay != 259200");
        _timingFails(true, 56, 1, WINDOW, TTL, "timing.delay != 259200");
        _timingFails(true, 56, type(uint64).max, WINDOW, TTL, "timing.delay != 259200");
        _timingFails(true, 143, DELAY, type(uint64).max, TTL, "timing.executionWindow != 1209600");
        _timingFails(true, 143, DELAY, WINDOW - 1, TTL, "timing.executionWindow != 1209600");
        _timingFails(true, 56, DELAY, WINDOW, TTL - 1, "timing.maxTtl != 2592000");
    }

    function test_timing_testProfile_boundedAndNeverOnProductionChains() public {
        h.checkTiming(false, 11155111, 600, 1 days, 7 days);
        _timingFails(false, 56, 600, 1 days, 7 days, "timing: test profile on a production chain");
        _timingFails(false, 143, DELAY, WINDOW, TTL, "timing: test profile on a production chain");
        _timingFails(false, 1, DELAY, WINDOW, TTL, "timing: test profile on a production chain");
        _timingFails(false, 97, type(uint64).max, 1 days, 7 days, "timing.delay out of test bounds");
        _timingFails(false, 97, 0, 1 days, 7 days, "timing.delay out of test bounds");
        _timingFails(false, 97, 600, type(uint64).max, 7 days, "timing.executionWindow out of test bounds");
        _timingFails(false, 97, 600, 0, 7 days, "timing.executionWindow out of test bounds");
        _timingFails(false, 97, 600, 1 days, 31 days, "timing.maxTtl out of test bounds");
    }

    // ---------------------------------------------------------------- sender

    function _sx() internal view returns (CCIPRouteVerifier.SenderExpect memory x) {
        x = CCIPRouteVerifier.SenderExpect({
            sender: address(snd),
            chainId: block.chainid,
            router: address(router),
            finalAuthority: address(l1),
            authority: BOOT,
            maxGasLimit: 1_000_000,
            dest0: CCIPGovernanceSender.Destination(BNB_SELECTOR, 56, E_BNB),
            dest1: CCIPGovernanceSender.Destination(MONAD_SELECTOR, 143, E_MONAD),
            runtimeKeccak: keccak256(address(snd).code)
        });
    }

    function _sxFails(CCIPRouteVerifier.SenderExpect memory x, string memory what) internal {
        try h.verifySender(_local(), x) {
            revert(string.concat("expected failure: ", what));
        } catch (bytes memory err) {
            assertEq(err, _err(what), what);
        }
    }

    function test_sender_exact_passes_andAuthorityTracksHandoff() public {
        h.verifySender(_local(), _sx());
        vm.prank(BOOT);
        snd.handoff();
        _sxFails(_sx(), "sender.authority");
        CCIPRouteVerifier.SenderExpect memory x = _sx();
        x.authority = address(l1);
        h.verifySender(_local(), x);
    }

    function test_sender_eachFieldMismatch_fails() public {
        CCIPRouteVerifier.SenderExpect memory x;
        x = _sx();
        x.chainId = 1;
        _sxFails(x, "sender.chainId");
        x = _sx();
        x.sender = address(0xDEAD);
        _sxFails(x, "sender.code empty");
        x = _sx();
        x.runtimeKeccak = bytes32(0);
        _sxFails(x, "sender.runtimeKeccak");
        x = _sx();
        x.router = address(0x1234);
        _sxFails(x, "sender.router");
        x = _sx();
        x.finalAuthority = BOOT;
        _sxFails(x, "sender.finalAuthority");
        x = _sx();
        x.authority = address(l1);
        _sxFails(x, "sender.authority");
        x = _sx();
        x.maxGasLimit = 999_999;
        _sxFails(x, "sender.maxGasLimit");
        x = _sx();
        x.dest0.chainSelector = MONAD_SELECTOR;
        _sxFails(x, "sender.destinations");
        x = _sx();
        x.dest0.chainId = 57;
        _sxFails(x, "sender.destinations");
        x = _sx();
        x.dest0.executor = E_MONAD;
        _sxFails(x, "sender.destinations");
        x = _sx();
        x.dest1.chainSelector = BNB_SELECTOR;
        _sxFails(x, "sender.destinations");
        x = _sx();
        x.dest1.chainId = 144;
        _sxFails(x, "sender.destinations");
        x = _sx();
        x.dest1.executor = E_BNB;
        _sxFails(x, "sender.destinations");
    }

    // ---------------------------------------------------------------- canceller Safe

    function _safeX() internal view returns (CCIPRouteVerifier.SafeExpect memory x) {
        x = CCIPRouteVerifier.SafeExpect({
            safe: address(safe),
            chainId: block.chainid,
            owners: owners,
            threshold: 2,
            guard: address(0),
            fallbackHandler: FALLBACK,
            singleton: SINGLETON,
            proxyRuntimeKeccak: keccak256(address(safe).code)
        });
    }

    function _safeFails(CCIPRouteVerifier.SafeExpect memory x, string memory what) internal {
        try h.verifySafe(_local(), x) {
            revert(string.concat("expected failure: ", what));
        } catch (bytes memory err) {
            assertEq(err, _err(what), what);
        }
    }

    function test_safe_exact_passes_ownerOrderIndependent() public {
        h.verifySafe(_local(), _safeX());
        CCIPRouteVerifier.SafeExpect memory x = _safeX();
        (x.owners[0], x.owners[2]) = (x.owners[2], x.owners[0]);
        h.verifySafe(_local(), x);
    }

    function test_safe_pinnedNonZeroGuard_mustMatchExactly() public {
        address guard = makeAddr("guard");
        safe.setGuard(guard);
        _safeFails(_safeX(), "safe.guard");
        CCIPRouteVerifier.SafeExpect memory x = _safeX();
        x.guard = guard;
        h.verifySafe(_local(), x);
        x.guard = makeAddr("other-guard");
        _safeFails(x, "safe.guard");
    }

    function test_safe_expectationMismatches_fail() public {
        CCIPRouteVerifier.SafeExpect memory x;
        x = _safeX();
        x.owners[1] = makeAddr("intruder");
        _safeFails(x, "safe.owners set");
        x = _safeX();
        x.owners = new address[](2);
        (x.owners[0], x.owners[1]) = (owners[0], owners[1]);
        _safeFails(x, "safe.owners count");
        x = _safeX();
        x.owners = new address[](4);
        (x.owners[0], x.owners[1], x.owners[2], x.owners[3]) = (owners[0], owners[1], owners[2], makeAddr("d"));
        _safeFails(x, "safe.owners count");
        x = _safeX();
        x.owners[2] = owners[0];
        _safeFails(x, "safe.owners expectation: duplicate");
        x = _safeX();
        x.owners[2] = 0x00000C771F6176268D5A9846E0956C3eF58597A1;
        _safeFails(x, "safe.owners expectation: placeholder");
        x = _safeX();
        x.threshold = 3;
        _safeFails(x, "safe.threshold");
        x = _safeX();
        x.threshold = 1;
        _safeFails(x, "safe.threshold expectation (>= 2, <= owners)");
        x = _safeX();
        x.threshold = 4;
        _safeFails(x, "safe.threshold expectation (>= 2, <= owners)");
        x = _safeX();
        x.fallbackHandler = address(0);
        _safeFails(x, "safe.fallbackHandler");
        x = _safeX();
        x.guard = makeAddr("guard");
        _safeFails(x, "safe.guard");
        x = _safeX();
        x.singleton = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
        _safeFails(x, "safe.singleton");
        x = _safeX();
        x.singleton = address(0);
        _safeFails(x, "safe.singleton expectation");
        x = _safeX();
        x.proxyRuntimeKeccak = bytes32(0);
        _safeFails(x, "safe.proxyRuntimeKeccak");
        x = _safeX();
        x.chainId = 56;
        _safeFails(x, "safe.chainId");
    }

    function test_safe_stateMismatches_fail() public {
        MockSafe s1 = new MockSafe();
        s1.setup(SINGLETON, owners, 2, FALLBACK);
        CCIPRouteVerifier.SafeExpect memory x = _safeX();
        x.safe = address(s1);
        h.verifySafe(_local(), x);

        s1.enableModule(makeAddr("module"));
        _safeFails(x, "safe.modules not empty");

        MockSafe s2 = new MockSafe();
        s2.setup(SINGLETON, owners, 2, FALLBACK);
        for (uint256 i = 0; i < 25; i++) {
            s2.enableModule(address(uint160(0x1000 + i)));
        }
        x.safe = address(s2);
        _safeFails(x, "safe.modules not empty");

        MockSafe s3 = new MockSafe();
        s3.setup(SINGLETON, owners, 1, FALLBACK);
        x.safe = address(s3);
        _safeFails(x, "safe.threshold");

        MockSafe s4 = new MockSafe();
        s4.setup(SINGLETON, owners, 2, FALLBACK);
        s4.setModuleGuard(makeAddr("module-guard"));
        x.safe = address(s4);
        _safeFails(x, "safe.moduleGuard");

        MockSafe s5 = new MockSafe();
        s5.setup(SINGLETON, owners, 2, makeAddr("other-handler"));
        x.safe = address(s5);
        _safeFails(x, "safe.fallbackHandler");

        MockSafe s6 = new MockSafe();
        s6.setup(makeAddr("other-singleton"), owners, 2, FALLBACK);
        x.safe = address(s6);
        _safeFails(x, "safe.singleton");

        address[] memory wrongOwners = new address[](3);
        (wrongOwners[0], wrongOwners[1], wrongOwners[2]) = (owners[0], owners[1], makeAddr("intruder"));
        MockSafe s7 = new MockSafe();
        s7.setup(SINGLETON, wrongOwners, 2, FALLBACK);
        x.safe = address(s7);
        _safeFails(x, "safe.owners set");

        // An uninitialised Safe (what a bare singleton looks like): no singleton pointer, threshold 0.
        MockSafe s8 = new MockSafe();
        x.safe = address(s8);
        _safeFails(x, "safe.singleton");
        vm.store(address(s8), bytes32(0), bytes32(uint256(uint160(SINGLETON))));
        _safeFails(x, "safe.threshold");
    }

    function test_safe_placeholderOrSingletonAddress_rejected() public {
        address[6] memory bad = [
            address(0),
            address(1),
            0x29fcB43b46531BcA003ddC8FCB67FFE91900C762,
            0x41675C099F32341bf84BFc5382aF534df5C7461a,
            0x1199000000000000000000000000000000001199,
            0x00000C771F6176268D5A9846E0956C3eF58597A1
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            CCIPRouteVerifier.SafeExpect memory x = _safeX();
            x.safe = bad[i];
            _safeFails(x, "safe: placeholder or singleton address");
        }
    }

    // ---------------------------------------------------------------- placeholders

    function test_requireReal_rejectsEveryPlaceholder() public {
        address[9] memory bad = [
            address(0),
            address(1),
            0x1199000000000000000000000000000000001199,
            0x1199000000000000000000000000000000B00775,
            0x00000C771F6176268D5A9846E0956C3eF58597A1,
            0x29fcB43b46531BcA003ddC8FCB67FFE91900C762,
            0x41675C099F32341bf84BFc5382aF534df5C7461a,
            0x3E5c63644E683549055b9Be8653de26E0B4CD36E,
            0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            try h.requireReal(bad[i], "X") {
                revert("placeholder accepted");
            } catch (bytes memory err) {
                assertEq(err, _err("X: missing or placeholder"));
            }
        }
        h.requireReal(makeAddr("real"), "X");
    }

    function test_productionExpectations_pinExactValues() public view {
        CCIPRouteVerifier.ExecutorExpect memory b = h.productionExecutor(56, E_BNB, SENDER, address(safe), bytes32(0));
        assertEq(b.router, 0x34B03Cb9086d7D758AC55af71584F81A598759FE);
        assertEq(b.sourceChainSelector, ETH_SELECTOR);
        assertEq(b.delay, 259200);
        assertEq(b.executionWindow, 1209600);
        assertEq(b.maxTtl, 2592000);
        assertEq(b.targets.length, 2);
        CCIPRouteVerifier.ExecutorExpect memory m = h.productionExecutor(143, E_MONAD, SENDER, address(safe), 0);
        assertEq(m.router, 0x33566fE5976AAa420F3d5C64996641Fc3858CaDB);
        assertEq(m.targets.length, 4);
        CCIPRouteVerifier.SenderExpect memory s = h.productionSender(SENDER, BOOT, E_BNB, E_MONAD, 0);
        assertEq(s.chainId, 1);
        assertEq(s.router, 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D);
        assertEq(s.finalAuthority, 0x1E0EF4162e42C9bF820c307218c4E41cCcA6E9CC);
        assertEq(s.maxGasLimit, 1_000_000);
        assertEq(s.dest0.chainSelector, BNB_SELECTOR);
        assertEq(s.dest1.chainSelector, MONAD_SELECTOR);
    }
}
