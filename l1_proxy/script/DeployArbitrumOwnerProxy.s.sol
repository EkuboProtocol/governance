// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {ArbitrumOwnerProxy} from "../src/ArbitrumOwnerProxy.sol";

contract DeployArbitrumOwnerProxy is Script {
    ArbitrumOwnerProxy public proxy;

    function setUp() public {}

    function run() public {
        address l1Owner = vm.envAddress("L1_OWNER");

        vm.startBroadcast();
        proxy = new ArbitrumOwnerProxy(l1Owner);
        vm.stopBroadcast();
    }
}
