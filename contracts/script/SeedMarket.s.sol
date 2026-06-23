// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";

/// @notice Creates a sample market on an already-deployed PredictionMarket.
///         Handy for local/anvil end-to-end testing of the CRE resolver: it
///         sets a short trading window and an immediate resolve time so the
///         workflow can pick it up right away.
///
/// Env vars:
///   PRIVATE_KEY      - owner key
///   MARKET           - deployed PredictionMarket address
///   QUESTION         - question text (optional)
///   EVENT_ID         - oracle event id (optional, default wc2026-ronaldo-champion)
///   TRADING_SECONDS  - seconds until trading closes (optional, default 60)
///   RESOLVE_SECONDS  - seconds until resolvable (optional, default 60)
contract SeedMarket is Script {
    function run() external returns (uint256 marketId) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        PredictionMarket market = PredictionMarket(vm.envAddress("MARKET"));

        string memory question =
            vm.envOr("QUESTION", string("Will Ronaldo win his first World Cup?"));
        string memory eventId = vm.envOr("EVENT_ID", string("wc2026-ronaldo-champion"));
        uint64 trading = uint64(block.timestamp + vm.envOr("TRADING_SECONDS", uint256(60)));
        uint64 resolve = uint64(block.timestamp + vm.envOr("RESOLVE_SECONDS", uint256(60)));
        if (resolve < trading) resolve = trading;

        vm.startBroadcast(pk);
        marketId = market.createMarket(question, eventId, trading, resolve);
        vm.stopBroadcast();

        console2.log("Created market id:", marketId);
        console2.log("Question:", question);
        console2.log("Event id:", eventId);
    }
}
