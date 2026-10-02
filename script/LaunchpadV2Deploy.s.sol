// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CubitHook} from "../src/CubitHook.sol";
import {CubitV2} from "../src/periphery/CubitV2.sol";
import {CubitForge} from "../src/periphery/CubitForge.sol";
import {CubitForgeV2} from "../src/periphery/CubitForgeV2.sol";
import {CubitQuoteHook} from "../src/quote/CubitQuoteHook.sol";
import {QuoteBandLib} from "../src/quote/QuoteBandLib.sol";
import {QuoteWallLib} from "../src/quote/QuoteWallLib.sol";
import {BandLib} from "../src/libraries/BandLib.sol";

/// @notice Replaces the launchpad in force with the launchpad v2 (CubitForgeV2): children paired with the quotes of a
///         reviewed table. The Forge keeps the governance vault of the Forge it replaces, so the fees and the absorbed
///         tokens of every launchpad land in one vault with one claimant. Before anything is sent, the table is
///         checked against the chain: its chain ID, each quote's code, `decimals()` and `symbol()`, each launch value
///         against the hook's bounds, and the address mining each quote demands; the table is printed with its launch
///         ticks for the user to read. On mainnet each row must also carry `usdPriceCents`, the quote's price in US
///         cents on deploy day, and every launch value must be worth the ETH row's within ±25 %: a value written at
///         the wrong scale (15000 USDC as `15000` instead of `15000000000`) is refused. The launch fee is the replaced
///         Forge's unless ALLOW_FEE_CHANGE=true accompanies FORGE_LAUNCH_FEE_WEI.
///
///         Registration. Off mainnet, a team signer registers the Forge in the same run. On mainnet the run only
///         deploys, unless REGISTER=true: `setForge` stops the launchpad in force at once, and an app built without
///         the v2 manifest would read the new Forge as a v1. The mainnet order, like a Lens replacement:
///           1. deploy (this script, no REGISTER), verify the contracts, promote the manifest;
///           2. publish an app build that knows the v2 manifest;
///           3. `setForge` (REGISTER=true, or the printed call), then `activate(8)` in a separate transaction:
///           cast send <v2> 'activate(uint8)' 8 --account <team keystore> --password-file <file>
///         Reads DEPLOYMENT (the CUBIT launch manifest), LAUNCHPAD (the launchpad manifest in force) and QUOTES (the
///         table, deployments/quotes/<chainId>.json), and writes deployments/<chainId>.launchpad-v2.candidate.json:
///           DEPLOYMENT=deployments/1.json LAUNCHPAD=deployments/1.launchpad.json QUOTES=deployments/quotes/1.json \
///             forge script script/LaunchpadV2Deploy.s.sol --rpc-url mainnet --account <team keystore> ...
///         Run it first without --broadcast: the simulation performs every check and prints the table.
contract LaunchpadV2Deploy is Script {
    struct Quote {
        string symbol;
        address quote;
        uint8 decimals;
        uint256 launchValue;
        /// US cents per whole quote token on deploy day (0 when the table does not give it; required on mainnet).
        uint256 usdPriceCents;
    }

    /// @notice A child token's address must sort above its quote's: the launcher's browser mines the token salt.
    ///         A quote demanding more tries than this on average is refused.
    uint256 public constant MAX_MINING_TRIES = 1_000_000;

    function run() external {
        string memory json = vm.readFile(vm.envString("DEPLOYMENT"));
        CubitHook hook = CubitHook(payable(vm.parseJsonAddress(json, ".hook")));
        CubitV2 v2 = CubitV2(vm.parseJsonAddress(json, ".v2"));
        string memory launchpad = vm.readFile(vm.envString("LAUNCHPAD"));
        address previous = vm.parseJsonAddress(launchpad, ".forge");
        address governanceVault = vm.parseJsonAddress(launchpad, ".governanceVault");
        Quote[] memory table = readTable(vm.readFile(vm.envString("QUOTES")));
        uint256 previousFee = CubitForge(previous).launchFee();
        uint256 fee = vm.envOr("FORGE_LAUNCH_FEE_WEI", previousFee);
        checkFee(previousFee, fee, vm.envOr("ALLOW_FEE_CHANGE", false));

        require(v2.forge() == previous, "the registry names another Forge than the launchpad manifest");
        require(CubitForge(previous).governanceVault() == governanceVault,
            "the launchpad manifest names another governance vault than its Forge");
        checkTable(table);
        checkValues(table, block.chainid == 1);
        printTable(table);
        bool register = shouldRegister(msg.sender == v2.authority(), block.chainid, vm.envOr("REGISTER", false));

        vm.startBroadcast();
        CubitForgeV2 forge = deployForge(hook, fee, governanceVault, table);
        if (register) v2.setForge(address(forge));
        vm.stopBroadcast();

        checkDeployed(forge, hook, fee, governanceVault, table);
        require(v2.forge() == (register ? address(forge) : previous), "unexpected Forge in the registry");
        require(!register || v2.enabledFeatures() & v2.FORGE() == 0, "setForge must leave the launchpad inactive");
        string memory path = writeManifest(forge, hook, v2, previous, table);

        console2.log("launchpad v2 written to", path);
        console2.log("replaced forge  ", previous);
        console2.log("forge v2        ", address(forge));
        console2.log("governanceVault ", governanceVault);
        console2.log("QuoteWallLib    ", address(QuoteWallLib));
        if (register) {
            console2.log("OK forge v2 registered, inactive until activate(8)");
        } else {
            console2.log("Not registered: when the app is ready, the team sends setForge(forge) to", address(v2));
            console2.logBytes(abi.encodeCall(CubitV2.setForge, (address(forge))));
        }
    }

    /// @notice The table: `.chainId`, then `.quotes[i]` with `symbol`, `address`, `decimals` and `launchValue` (a
    ///         decimal string, in the quote's base units). Native ETH is the zero address.
    function readTable(string memory json) public view returns (Quote[] memory table) {
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "the quote table is for another chain");
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".quotes[", vm.toString(n), "]"))) n++;
        table = new Quote[](n);
        for (uint256 i; i < n; i++) {
            string memory at = string.concat(".quotes[", vm.toString(i), "]");
            table[i] = Quote({
                symbol: vm.parseJsonString(json, string.concat(at, ".symbol")),
                quote: vm.parseJsonAddress(json, string.concat(at, ".address")),
                decimals: uint8(vm.parseJsonUint(json, string.concat(at, ".decimals"))),
                launchValue: vm.parseJsonUint(json, string.concat(at, ".launchValue")),
                usdPriceCents: vm.keyExistsJson(json, string.concat(at, ".usdPriceCents"))
                    ? vm.parseJsonUint(json, string.concat(at, ".usdPriceCents"))
                    : 0
            });
        }
    }

    /// @notice Every check that can be made before sending anything.
    function checkTable(Quote[] memory table) public view {
        require(table.length != 0, "empty quote table");
        for (uint256 i; i < table.length; i++) {
            Quote memory q = table[i];
            string memory name = q.symbol;
            if (q.quote == address(0)) {
                require(_same(q.symbol, "ETH") && q.decimals == 18, "address zero must be ETH with 18 decimals");
            } else {
                require(q.quote.code.length != 0, string.concat(name, ": no contract at the address"));
                require(IERC20Metadata(q.quote).decimals() == q.decimals, string.concat(name, ": decimals differ"));
                require(_same(IERC20Metadata(q.quote).symbol(), q.symbol), string.concat(name, ": symbol differs"));
            }
            (bool ok,) = QuoteBandLib.launchSqrtPrice(q.launchValue, 21_000_000e18);
            require(ok, string.concat(name, ": launch value zero or outside the hook's bounds"));
            require(
                miningTries(q.quote) <= MAX_MINING_TRIES,
                string.concat(name, ": its address leaves too few token addresses above it")
            );
            for (uint256 j; j < i; j++) require(table[j].quote != q.quote, string.concat(name, ": listed twice"));
        }
    }

    /// @notice The launch fee is locked at 0.005 ETH: a new Forge keeps the replaced one's unless the change is explicit.
    function checkFee(uint256 previousFee, uint256 fee, bool allowChange) public pure {
        require(fee == previousFee || allowChange,
            "the launch fee differs from the replaced Forge's: set ALLOW_FEE_CHANGE=true if intended");
    }

    /// @notice Whether this run sends `setForge`: only a team signer can, and on mainnet only with REGISTER=true.
    function shouldRegister(bool signerIsTeam, uint256 chainId, bool registerFlag) public pure returns (bool) {
        return signerIsTeam && (chainId != 1 || registerFlag);
    }

    /// @notice Every launch value must be worth the ETH row's within ±25 % at the table's prices: one FDV for every
    ///         pair, and a value at the wrong scale refused. Skipped when a price is missing, unless `required`.
    function checkValues(Quote[] memory table, bool required) public pure {
        bool complete = true;
        uint256 eth = type(uint256).max;
        for (uint256 i; i < table.length; i++) {
            if (table[i].usdPriceCents == 0) complete = false;
            if (table[i].quote == address(0)) eth = i;
        }
        if (!complete) {
            require(!required, "every row needs its usdPriceCents on this chain");
            return;
        }
        require(eth != type(uint256).max, "the table has no ETH row to compare with");
        uint256 ethCents = table[eth].launchValue * table[eth].usdPriceCents / 1e18;
        require(ethCents != 0, "the ETH row is worth nothing");
        for (uint256 i; i < table.length; i++) {
            Quote memory q = table[i];
            uint256 cents = q.launchValue * q.usdPriceCents / 10 ** q.decimals;
            require(cents * 100 >= ethCents * 75 && cents * 100 <= ethCents * 125,
                string.concat(q.symbol, ": launch value not worth the ETH row's (+/-25%): wrong scale or price?"));
        }
    }

    function deployForge(CubitHook hook, uint256 fee, address governanceVault, Quote[] memory table)
        public returns (CubitForgeV2)
    {
        (address[] memory quotes, uint256[] memory values) = _columns(table);
        return new CubitForgeV2(hook, fee, governanceVault, quotes, values);
    }

    function checkDeployed(
        CubitForgeV2 forge,
        CubitHook hook,
        uint256 fee,
        address governanceVault,
        Quote[] memory table
    ) public view
    {
        require(address(forge.hook()) == address(hook), "the Forge serves another hook");
        require(forge.launchFee() == fee, "unexpected launch fee");
        require(forge.governanceVault() == governanceVault, "the Forge names another governance vault");
        require(forge.hookCreationCodeHash() == keccak256(type(CubitQuoteHook).creationCode),
            "the Forge froze another hook template");
        address[] memory listed = forge.quotes();
        require(listed.length == table.length, "the Forge lists another number of quotes");
        for (uint256 i; i < table.length; i++) {
            require(listed[i] == table[i].quote, "the Forge lists another quote");
            require(forge.launchValue(table[i].quote) == table[i].launchValue, "the Forge froze another launch value");
        }
        require(
            address(QuoteWallLib).code.length != 0 && address(BandLib).code.length != 0, "a linked library is missing"
        );
    }

    /// @notice Average number of token salts to try before a child token sorts above `quote`.
    function miningTries(address quote) public pure returns (uint256) {
        uint256 space = uint256(type(uint160).max) + 1;
        return space / (space - uint160(quote));
    }

    function printTable(Quote[] memory table) public pure {
        console2.log("symbol | address | decimals | launch value (human) | base units | launch tick | tries");
        for (uint256 i; i < table.length; i++) {
            Quote memory q = table[i];
            (, uint160 sqrtPrice) = QuoteBandLib.launchSqrtPrice(q.launchValue, 21_000_000e18);
            console2.log(
                string.concat(
                    q.symbol, " | ", vm.toString(q.quote), " | ", vm.toString(uint256(q.decimals)), " | ",
                    _human(q.launchValue, q.decimals), " | ", vm.toString(q.launchValue), " | ",
                    vm.toString(TickMath.getTickAtSqrtPrice(sqrtPrice)), " | ", vm.toString(miningTries(q.quote))
                )
            );
        }
    }

    function writeManifest(CubitForgeV2 forge, CubitHook hook, CubitV2 v2, address previous, Quote[] memory table)
        internal returns (string memory path)
    {
        (address[] memory quotes, uint256[] memory values) = _columns(table);
        string[] memory symbols = new string[](table.length);
        for (uint256 i; i < table.length; i++) symbols[i] = table[i].symbol;
        string memory obj = "launchpadV2";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "hook", address(hook));
        vm.serializeAddress(obj, "v2", address(v2));
        vm.serializeAddress(obj, "forge", address(forge));
        vm.serializeAddress(obj, "previousForge", previous);
        vm.serializeAddress(obj, "governanceVault", forge.governanceVault());
        vm.serializeUint(obj, "forgeLaunchFee", forge.launchFee());
        vm.serializeBytes32(obj, "hookCreationCodeHash", forge.hookCreationCodeHash());
        vm.serializeBytes32(obj, "forgeRuntimeCodeHash", address(forge).codehash);
        vm.serializeAddress(obj, "bandLib", address(BandLib));
        vm.serializeAddress(obj, "quoteWallLib", address(QuoteWallLib));
        vm.serializeAddress(obj, "quotes", quotes);
        vm.serializeString(obj, "quoteSymbols", symbols);
        vm.serializeUint(obj, "launchValues", values);
        string memory out = vm.serializeUint(obj, "deployBlock", block.number);
        path = string.concat("deployments/", vm.toString(block.chainid), ".launchpad-v2.candidate.json");
        vm.writeJson(out, path);
    }

    function _columns(Quote[] memory table) internal pure returns (address[] memory quotes, uint256[] memory values) {
        quotes = new address[](table.length);
        values = new uint256[](table.length);
        for (uint256 i; i < table.length; i++) (quotes[i], values[i]) = (table[i].quote, table[i].launchValue);
    }

    /// @dev `units` with `decimals` decimals, trailing zeros removed: 15000000000 with 6 decimals reads 15000.
    function _human(uint256 units, uint8 decimals) internal pure returns (string memory) {
        uint256 unit = 10 ** decimals;
        string memory whole = vm.toString(units / unit);
        uint256 fraction = units % unit;
        if (fraction == 0) return whole;
        bytes memory digits = bytes(vm.toString(fraction + unit)); // leading "1" keeps the zeros
        uint256 end = digits.length;
        while (digits[end - 1] == "0") end--;
        bytes memory kept = new bytes(end - 1);
        for (uint256 i = 1; i < end; i++) kept[i - 1] = digits[i];
        return string.concat(whole, ".", string(kept));
    }

    function _same(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
