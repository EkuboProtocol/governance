// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IRouterClient} from "../vendor/ccip-2.0.0/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiverV2} from "../vendor/ccip-2.0.0/interfaces/IAny2EVMMessageReceiverV2.sol";
import {CCIPGovernanceSender} from "../src/CCIPGovernanceSender.sol";
import {CCIPOwnerExecutor} from "../src/CCIPOwnerExecutor.sol";

/// @notice Deployment of the A'-CCIP owner route (EKU-1199). DRAFT: run only as a simulation (no `--broadcast`)
///         until CSO clears the exact commit and manifest and a human approves deployment.
///
///         Order (M-1): `executor()` on BNB Chain and on Monad, both pinned to the predicted sender, then `sender()`
///         on Ethereum, which asserts the prediction. Env:
///         - executor(): DEPLOYER, SENDER_PREDICTED, CANCELLER (canceller Safe on that chain)
///         - sender():   DEPLOYER, BOOTSTRAP (fresh single-purpose key, C11), EXECUTOR_BNB, EXECUTOR_MONAD
contract DeployCCIPOwnerRoute is Script {
    uint64 constant ETH_SELECTOR = 5009297550715157269;
    uint64 constant BNB_SELECTOR = 11344663589394136015;
    uint64 constant MONAD_SELECTOR = 8481857512324358265;
    address constant ETH_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    address constant BNB_ROUTER = 0x34B03Cb9086d7D758AC55af71584F81A598759FE;
    address constant MONAD_ROUTER = 0x33566fE5976AAa420F3d5C64996641Fc3858CaDB;
    address constant L1_PROXY = 0x1E0EF4162e42C9bF820c307218c4E41cCcA6E9CC;
    address constant COMPANY_KEY = 0x00000C771F6176268D5A9846E0956C3eF58597A1;

    uint64 constant DELAY = 72 hours;
    uint64 constant WINDOW = 14 days;
    uint64 constant TTL = 30 days;
    uint32 constant MAX_GAS_LIMIT = 1_000_000;

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
            revert("executor: chain must be 56 or 143");
        }
    }

    function executor() external returns (CCIPOwnerExecutor e) {
        address deployer = vm.envAddress("DEPLOYER");
        address senderPredicted = vm.envAddress("SENDER_PREDICTED");
        address canceller = vm.envAddress("CANCELLER");
        require(canceller != COMPANY_KEY && canceller.code.length > 0, "canceller must be a Safe, not the company key");
        address router = block.chainid == 56 ? BNB_ROUTER : MONAD_ROUTER;
        address[] memory ts = targetsFor(block.chainid);
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        console.log("deployer nonce", vm.getNonce(deployer));

        vm.broadcast(deployer);
        e = new CCIPOwnerExecutor(router, ETH_SELECTOR, senderPredicted, DELAY, WINDOW, TTL, canceller, ts);

        require(address(e) == predicted, "address");
        require(e.supportsInterface(0x85572ffb), "IAny2EVMMessageReceiver");
        require(!e.supportsInterface(type(IAny2EVMMessageReceiverV2).interfaceId), "must not be V2");
        require(e.delay() >= 72 hours && e.maxTtl() <= 30 days, "C3/C1 params");
        require(
            e.router() == router && e.sender() == senderPredicted && e.sourceChainSelector() == ETH_SELECTOR, "auth"
        );
        console.log("executor", address(e));
        console.logBytes32(keccak256(address(e).code));
        console.logBytes(abi.encode(router, ETH_SELECTOR, senderPredicted, DELAY, WINDOW, TTL, canceller, ts));
    }

    function sender() external returns (CCIPGovernanceSender s) {
        require(block.chainid == 1, "sender: Ethereum only");
        address deployer = vm.envAddress("DEPLOYER");
        address bootstrap = vm.envAddress("BOOTSTRAP");
        require(bootstrap != COMPANY_KEY, "C11: fresh bootstrap key");
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        console.log("deployer nonce", vm.getNonce(deployer));
        CCIPGovernanceSender.Destination memory bnb =
            CCIPGovernanceSender.Destination(BNB_SELECTOR, 56, vm.envAddress("EXECUTOR_BNB"));
        CCIPGovernanceSender.Destination memory monad =
            CCIPGovernanceSender.Destination(MONAD_SELECTOR, 143, vm.envAddress("EXECUTOR_MONAD"));

        vm.broadcast(deployer);
        s = new CCIPGovernanceSender(IRouterClient(ETH_ROUTER), L1_PROXY, bootstrap, bnb, monad, MAX_GAS_LIMIT);

        require(address(s) == predicted, "address");
        require(address(s) == vm.envOr("SENDER_PREDICTED", address(s)), "sender prediction pinned in executors");
        console.log("sender", address(s));
        console.logBytes32(keccak256(address(s).code));
        console.logBytes(abi.encode(ETH_ROUTER, L1_PROXY, bootstrap, bnb, monad, MAX_GAS_LIMIT));
    }
}
