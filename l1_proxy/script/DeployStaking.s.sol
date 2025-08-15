// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {StarknetStakingProxy} from "../src/StarknetStakingProxy.sol";

contract DeployStakingScript is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        // Starknet messaging contract addresses
        address starknetMessaging;
        if (block.chainid == 1) {
            // Mainnet
            starknetMessaging = 0xc662c410C0ECf747543f5bA90660f6ABeBD9C8c4;
        } else if (block.chainid == 11155111) {
            // Sepolia
            starknetMessaging = 0xE2Bb56ee936fd6433DC0F6e7e3b8365C906AA057;
        } else {
            revert("Unsupported chain");
        }
        
        // L2 staking proxy address (to be deployed on Starknet)
        uint256 l2StakingProxy = vm.envUint("L2_STAKING_PROXY_ADDRESS");
        
        // Owner address (can be a multisig)
        address owner = vm.envOr("OWNER_ADDRESS", deployer);
        
        vm.startBroadcast(deployerPrivateKey);

        StarknetStakingProxy stakingProxy = new StarknetStakingProxy(
            IStarknetMessaging(starknetMessaging),
            l2StakingProxy,
            owner
        );

        console.log("StarknetStakingProxy deployed at:", address(stakingProxy));
        console.log("L2 Staking Proxy:", l2StakingProxy);
        console.log("Owner:", owner);

        vm.stopBroadcast();
    }
}
