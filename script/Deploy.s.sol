// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {EthsFactory} from "../src/EthsFactory.sol";
import {EthsHub} from "../src/EthsHub.sol";

contract Deploy is Script {
    function run() public {
        vm.startBroadcast();

        address flatDirectoryFactory;
        if (block.chainid == 11155111) {
            // Sepolia
            flatDirectoryFactory = 0xF2B7ef5e5bf88A15B68046Ffa784f98702621Ee7; // TODO
        } else if (block.chainid == 3335) {
            // quarkchain L2 network
            flatDirectoryFactory = 0x7a677F74827E7296978f1c2dC07b054d16F5E878;
        } else {
            flatDirectoryFactory = address(0);
        }

        EthsFactory dir = new EthsFactory(flatDirectoryFactory); // 0xEEE8Dd4eb7221B190D0E81Fb5689C5eDbD9A5Ee8
        console.log("Deployed HubFactory at:", address(dir));

        if (block.chainid == 11155111 || block.chainid == 3335) {
            // test
            EthsHub impl = EthsHub(payable(dir.createHub("test-repo")));
            console.log("Deployed test hub at:", address(impl)); // 0xaF32710e807bfE002F34Aa5800F26fb1137F750e
        }

        vm.stopBroadcast();
    }
}
