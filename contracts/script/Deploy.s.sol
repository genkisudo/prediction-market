// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";

/// @notice Deploys PredictionMarket.
///
/// Env vars:
///   PRIVATE_KEY  - deployer key (hex, 0x-prefixed)
///   FORWARDER    - CRE KeystoneForwarder address for the target chain
///                  (Ethereum Sepolia: 0xF8344CFd5c43616a4366C34E3EEE75af79a74482)
///   FEE_BPS      - protocol fee in basis points (optional, default 200 = 2%)
///
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url $RPC --broadcast
contract Deploy is Script {
    function run() external returns (PredictionMarket market) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address forwarder = vm.envAddress("FORWARDER");
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(200)));
        address owner = vm.addr(pk);

        vm.startBroadcast(pk);
        market = new PredictionMarket(forwarder, owner, feeBps);
        vm.stopBroadcast();

        console2.log("PredictionMarket deployed at:", address(market));
        console2.log("Owner:", owner);
        console2.log("Forwarder:", forwarder);
        console2.log("Fee bps:", feeBps);
    }
}
