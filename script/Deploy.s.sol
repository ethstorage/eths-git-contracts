// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {EthsHub} from "../src/EthsHub.sol";

contract Deploy is Script {
    function run() public {
        vm.startBroadcast();

        // TODO
        address flatDirectoryFactory;
        if (block.chainid == 11155111) {
            // Sepolia
            flatDirectoryFactory = 0xF2B7ef5e5bf88A15B68046Ffa784f98702621Ee7;
        } else if (block.chainid == 3335) {
            // quarkchain L2 network
            flatDirectoryFactory = 0x7a677F74827E7296978f1c2dC07b054d16F5E878;
        } else {
            flatDirectoryFactory = address(0);
        }

        EthsHub dir = new EthsHub(flatDirectoryFactory);
        console.log("Deployed Hub at:", address(dir));

        vm.stopBroadcast();
    }
}
