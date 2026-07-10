// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {OPStackOwnerProxy} from "../src/OPStackOwnerProxy.sol";

contract DeployOPStackOwnerProxy is Script {
    OPStackOwnerProxy public proxy;

    function setUp() public {}

    function run() public {
        address l1Owner = vm.envAddress("L1_OWNER");

        vm.startBroadcast();
        proxy = new OPStackOwnerProxy(l1Owner);
        vm.stopBroadcast();
    }
}
