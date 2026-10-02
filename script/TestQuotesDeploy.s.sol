// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockQuote, MockNoReturnQuote} from "./mocks/TestQuotes.sol";

/// @notice Test quotes for a rehearsal of the launchpad v2 on Anvil or Sepolia, where USDC, USDT, WBTC and the Ondo
///         stocks do not exist: one mintable token per mainnet quote, with the same symbol and decimals (USDT without
///         return values, like the real one). Writes deployments/quotes/<chainId>.json, the table LaunchpadV2Deploy
///         reads, with illustrative launch values of about 3.75 ETH each. Runs on Anvil and Sepolia only:
///           forge script script/TestQuotesDeploy.s.sol --rpc-url anvil --broadcast --private-key <anvil key>
contract TestQuotesDeploy is Script {
    function run() external {
        // Freely mintable tokens must never back a production quote table: Anvil and Sepolia only.
        require(block.chainid == 31337 || block.chainid == 11155111, "test quotes are for Anvil or Sepolia only");
        string[8] memory symbols = ["USDC", "USDT", "WBTC", "NVDAon", "SPCXon", "TSLAon", "AAPLon", "GOOGLon"];
        uint8[8] memory decimals = [6, 6, 8, 18, 18, 18, 18, 18];
        uint256[8] memory values = [uint256(15_000e6), 15_000e6, 0.15e8, 80e18, 50e18, 35e18, 60e18, 60e18];
        address[8] memory quotes;

        vm.startBroadcast();
        for (uint256 i; i < 8; i++) {
            quotes[i] = i == 1 ? address(new MockNoReturnQuote()) : address(new MockQuote(symbols[i], decimals[i]));
        }
        vm.stopBroadcast();

        string memory json = string.concat(
            "{\n  \"chainId\": ", vm.toString(block.chainid),
            ",\n  \"note\": \"Test quotes (mintable by anyone, no value) for a launchpad v2 rehearsal.\",",
            "\n  \"quotes\": [\n    { \"symbol\": \"ETH\", \"address\": \"", vm.toString(address(0)),
            "\", \"decimals\": 18, \"launchValue\": \"3750000000000000000\" }"
        );
        for (uint256 i; i < 8; i++) {
            json = string.concat(
                json, ",\n    { \"symbol\": \"", symbols[i], "\", \"address\": \"", vm.toString(quotes[i]),
                "\", \"decimals\": ", vm.toString(uint256(decimals[i])), ", \"launchValue\": \"",
                vm.toString(values[i]), "\" }"
            );
            console2.log(symbols[i], quotes[i]);
        }
        json = string.concat(json, "\n  ]\n}\n");
        string memory path = string.concat("deployments/quotes/", vm.toString(block.chainid), ".json");
        vm.writeFile(path, json);
        console2.log("quote table written to", path);
    }
}
