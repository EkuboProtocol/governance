// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {StarknetOwnerProxy, IStarknetMessaging} from "../src/StarknetOwnerProxy.sol";

contract CounterScript is Script {
    error UnrecognizedChainId(uint256 chainId);

    StarknetOwnerProxy public proxy;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        if (block.chainid == 0x1) {
            proxy = new StarknetOwnerProxy(
                // Starknet core contract: https://etherscan.io/address/0xc662c410C0ECf747543f5bA90660f6ABeBD9C8c4
                IStarknetMessaging(0xc662c410C0ECf747543f5bA90660f6ABeBD9C8c4),
                // Ekubo governor contract: https://starkscan.co/contract/0x053499f7aa2706395060fe72d00388803fb2dcc111429891ad7b2d9dcea29acd
                0x053499f7aa2706395060fe72d00388803fb2dcc111429891ad7b2d9dcea29acd
            );
        } else if (block.chainid == 0xaa36a7) {
            proxy = new StarknetOwnerProxy(
                // Starknet core contract: https://sepolia.etherscan.io/address/0xE2Bb56ee936fd6433DC0F6e7e3b8365C906AA057
                IStarknetMessaging(0xE2Bb56ee936fd6433DC0F6e7e3b8365C906AA057),
                // Ekubo governor contract: https://sepolia.starkscan.co/contract/0x048bb83134ce6a312d1b41b0b3deccc4ce9a9d280e6c68c0eb1c517259c89d74
                0x048bb83134ce6a312d1b41b0b3deccc4ce9a9d280e6c68c0eb1c517259c89d74
            );
        } else {
            revert UnrecognizedChainId(block.chainid);
        }

        vm.stopBroadcast();
    }
}
