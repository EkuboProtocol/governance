// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {AMBOwnerProxy, IAMB} from "../src/AMBOwnerProxy.sol";
import {FxPortalOwnerProxy} from "../src/FxPortalOwnerProxy.sol";

/// @notice Constructor arguments and pre/post-deployment checks for the Gnosis and Polygon owner proxies.
/// @dev Deploy:  forge script script/DeployWave4OwnerProxy.s.sol:DeployWave4OwnerProxy --rpc-url <chain> --broadcast ...
///      Verify:  PROXY=<address> forge script script/DeployWave4OwnerProxy.s.sol:VerifyWave4OwnerProxy --rpc-url <chain>
///      The verifier deploys a reference copy in simulation with the canonical arguments and requires the deployed
///      runtime code to be byte-identical (same compiler settings, same immutables).
abstract contract Wave4OwnerProxyConfig is Script {
    /// @notice Ethereum StarknetOwnerProxy controlled by the Starknet Governor.
    address constant L1_OWNER = 0x1E0EF4162e42C9bF820c307218c4E41cCcA6E9CC;

    uint256 constant GNOSIS = 100;
    address constant HOME_AMB = 0x75Df5AF045d91108662D8080fD1FEFAd6aA0bb59;
    uint256 constant AMB_SOURCE_CHAIN_ID = 1;

    uint256 constant POLYGON = 137;
    address constant FX_CHILD = 0x8397259c983751DAf40400790063935a11afa28a;
    address constant FX_ROOT = 0xfe5e5D361b2ad62c541bAb87C45a0B9B018389a2;

    function _preChecks() internal view {
        // R4: nobody can ever act as l1Owner directly on the destination chain.
        require(L1_OWNER.code.length == 0, "l1Owner has code on this chain");
        if (block.chainid == GNOSIS) {
            require(HOME_AMB.code.length > 0, "HomeAMB missing");
            (bool ok, bytes memory r) = HOME_AMB.staticcall(abi.encodeWithSignature("destinationChainId()"));
            require(ok && abi.decode(r, (uint256)) == AMB_SOURCE_CHAIN_ID, "HomeAMB destination is not Ethereum");
            (ok, r) = HOME_AMB.staticcall(abi.encodeWithSignature("sourceChainId()"));
            require(ok && abi.decode(r, (uint256)) == GNOSIS, "HomeAMB source is not Gnosis");
        } else if (block.chainid == POLYGON) {
            require(FX_CHILD.code.length > 0, "FxChild missing");
            (bool ok, bytes memory r) = FX_CHILD.staticcall(abi.encodeWithSignature("fxRoot()"));
            require(ok && abi.decode(r, (address)) == FX_ROOT, "FxChild.fxRoot mismatch");
        } else {
            revert("unsupported chain");
        }
    }

    function _reference() internal returns (address) {
        if (block.chainid == GNOSIS) return address(new AMBOwnerProxy(L1_OWNER, IAMB(HOME_AMB), AMB_SOURCE_CHAIN_ID));
        return address(new FxPortalOwnerProxy(L1_OWNER, FX_CHILD));
    }

    function _postChecks(address proxy) internal view {
        (bool ok, bytes memory r) = proxy.staticcall(abi.encodeWithSignature("l1Owner()"));
        require(ok && abi.decode(r, (address)) == L1_OWNER, "l1Owner");
        if (block.chainid == GNOSIS) {
            AMBOwnerProxy p = AMBOwnerProxy(payable(proxy));
            require(address(p.amb()) == HOME_AMB, "amb");
            require(p.sourceChainId() == bytes32(AMB_SOURCE_CHAIN_ID), "sourceChainId");
        } else {
            FxPortalOwnerProxy p = FxPortalOwnerProxy(payable(proxy));
            require(p.fxChild() == FX_CHILD, "fxChild");
            require(p.lastStateId() == 0, "lastStateId");
        }
    }
}

contract DeployWave4OwnerProxy is Wave4OwnerProxyConfig {
    function run() public returns (address proxy) {
        _preChecks();
        vm.startBroadcast();
        if (block.chainid == GNOSIS) {
            proxy = address(new AMBOwnerProxy(L1_OWNER, IAMB(HOME_AMB), AMB_SOURCE_CHAIN_ID));
        } else {
            proxy = address(new FxPortalOwnerProxy(L1_OWNER, FX_CHILD));
        }
        vm.stopBroadcast();
        _postChecks(proxy);
        console2.log("proxy", proxy);
    }
}

contract VerifyWave4OwnerProxy is Wave4OwnerProxyConfig {
    function run() public {
        address proxy = vm.envAddress("PROXY");
        _preChecks();
        _postChecks(proxy);
        address ref = _reference();
        require(keccak256(proxy.code) == keccak256(ref.code), "runtime code differs from reference build");
        console2.log("verified", proxy);
        console2.logBytes32(keccak256(proxy.code));
    }
}
