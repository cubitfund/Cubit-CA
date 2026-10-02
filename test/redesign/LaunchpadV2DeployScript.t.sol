// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RedesignBase} from "./utils/RedesignBase.sol";
import {MockQuote, MockNoReturnQuote} from "../../script/mocks/TestQuotes.sol";
import {LaunchpadV2Deploy} from "../../script/LaunchpadV2Deploy.s.sol";
import {CubitForgeV2} from "../../src/periphery/CubitForgeV2.sol";

contract LaunchpadV2DeployHarness is LaunchpadV2Deploy {
    function human(uint256 units, uint8 decimals) external pure returns (string memory) {
        return _human(units, decimals);
    }
}

/// @notice The launchpad v2 deployment script's checks: every wrong table is refused
///         before anything is sent, and a good one deploys a Forge on the v1 Forge's governance vault.
contract LaunchpadV2DeployScriptTest is RedesignBase {
    LaunchpadV2DeployHarness internal script;
    address internal usdc;
    address internal usdt;
    address internal wbtc;

    function setUp() public override {
        super.setUp();
        _deployLaunchpad();
        script = new LaunchpadV2DeployHarness();
        usdc = address(new MockQuote("USDC", 6));
        usdt = address(new MockNoReturnQuote());
        wbtc = address(new MockQuote("WBTC", 8));
    }

    function _table() internal view returns (LaunchpadV2Deploy.Quote[] memory t) {
        t = new LaunchpadV2Deploy.Quote[](4);
        t[0] = LaunchpadV2Deploy.Quote("ETH", address(0), 18, 3.75 ether, 400_000); // $4,000
        t[1] = LaunchpadV2Deploy.Quote("USDC", usdc, 6, 15_000e6, 100);
        t[2] = LaunchpadV2Deploy.Quote("USDT", usdt, 6, 15_000e6, 100);
        t[3] = LaunchpadV2Deploy.Quote("WBTC", wbtc, 8, 0.15e8, 10_000_000); // $100,000
    }

    function test_AGoodTableDeploys() public {
        LaunchpadV2Deploy.Quote[] memory t = _table();
        script.checkTable(t);
        CubitForgeV2 forgeV2 = script.deployForge(hook, 0.005 ether, forge.governanceVault(), t);
        script.checkDeployed(forgeV2, hook, 0.005 ether, forge.governanceVault(), t);
        assertEq(forgeV2.governanceVault(), address(governanceVault), "not the v1 Forge's governance vault");
        vm.prank(team);
        registry.setForge(address(forgeV2));
        assertEq(registry.forge(), address(forgeV2));
    }

    function test_WrongDecimalsRefused() public {
        LaunchpadV2Deploy.Quote[] memory t = _table();
        t[1].decimals = 18; // 15,000 USDC written as if USDC had 18 decimals
        vm.expectRevert(bytes("USDC: decimals differ"));
        script.checkTable(t);
    }

    function test_WrongSymbolRefused() public {
        LaunchpadV2Deploy.Quote[] memory t = _table();
        t[3].symbol = "BTC";
        vm.expectRevert(bytes("BTC: symbol differs"));
        script.checkTable(t);
    }

    function test_ZeroOrOutOfBoundsValueRefused() public {
        LaunchpadV2Deploy.Quote[] memory t = _table();
        t[1].launchValue = 0;
        vm.expectRevert(bytes("USDC: launch value zero or outside the hook's bounds"));
        script.checkTable(t);
        t[1].launchValue = 1e40;
        vm.expectRevert(bytes("USDC: launch value zero or outside the hook's bounds"));
        script.checkTable(t);
    }

    function test_NoContractRefused() public {
        LaunchpadV2Deploy.Quote[] memory t = _table();
        t[1].quote = makeAddr("no code");
        vm.expectRevert(bytes("USDC: no contract at the address"));
        script.checkTable(t);
    }

    function test_DuplicateRefused() public {
        LaunchpadV2Deploy.Quote[] memory t = _table();
        t[3] = t[1];
        vm.expectRevert(bytes("USDC: listed twice"));
        script.checkTable(t);
    }

    function test_EthMustBeTheZeroAddress() public {
        LaunchpadV2Deploy.Quote[] memory t = _table();
        t[0].symbol = "WETH";
        vm.expectRevert(bytes("address zero must be ETH with 18 decimals"));
        script.checkTable(t);
    }

    /// @dev A quote so close to the top of the address space that almost no token sorts above it.
    function test_UnminableQuoteRefused() public {
        address high = address(type(uint160).max - 1_000);
        vm.etch(high, usdt.code); // the USDT mock keeps its symbol and decimals in code, not storage
        LaunchpadV2Deploy.Quote[] memory t = _table();
        t[2].quote = high;
        vm.expectRevert(bytes("USDT: its address leaves too few token addresses above it"));
        script.checkTable(t);
    }

    function test_MiningTriesOfTheMainnetQuotes() public view {
        assertEq(script.miningTries(address(0)), 1);
        assertEq(script.miningTries(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), 2); // USDC
        assertEq(script.miningTries(0xdAC17F958D2ee523a2206206994597C13D831ec7), 6); // USDT
        assertEq(script.miningTries(0xf6b1117ec07684D3958caD8BEb1b302bfD21103f), 27); // TSLAon, the highest
    }

    function test_TableForAnotherChainRefused() public {
        string memory json = '{"chainId": 1, "quotes": []}';
        vm.expectRevert(bytes("the quote table is for another chain"));
        script.readTable(json);
    }

    function test_ReadTable() public view {
        string memory json = string.concat(
            '{"chainId": 31337, "quotes": [{"symbol": "ETH", "address": "0x0000000000000000000000000000000000000000", ',
            '"decimals": 18, "launchValue": "3750000000000000000"}, {"symbol": "USDC", "address": "', vm.toString(usdc),
            '", "decimals": 6, "launchValue": "15000000000"}]}'
        );
        LaunchpadV2Deploy.Quote[] memory t = script.readTable(json);
        assertEq(t.length, 2);
        assertEq(t[1].quote, usdc);
        assertEq(t[1].decimals, 6);
        assertEq(t[1].launchValue, 15_000e6);
        script.checkTable(t);
    }

    function test_HumanValues() public view {
        assertEq(script.human(15_000e6, 6), "15000");
        assertEq(script.human(0.15e8, 8), "0.15");
        assertEq(script.human(3.75 ether, 18), "3.75");
        assertEq(script.human(1, 6), "0.000001");
    }

    /// @dev The mainnet table as committed: filled on 28/09 from that day's prices for the launchpad v2 deployment (and
    ///      reused by the launchpad v3), every value worth the ETH row's within 25%.
    function test_CommittedMainnetTableIsTheDeployedOne() public {
        vm.chainId(1);
        LaunchpadV2Deploy.Quote[] memory t = script.readTable(vm.readFile("deployments/quotes/1.json"));
        assertEq(t.length, 9);
        assertEq(t[6].quote, 0xf6b1117ec07684D3958caD8BEb1b302bfD21103f);
        assertEq(t[6].decimals, 18);
        assertEq(t[1].launchValue, 10_000e6, "USDC's launch value");
        assertEq(t[6].launchValue, 27.6e18, "TSLAon's launch value");
        script.checkValues(t, true);
    }

    // ------------------------------------------------------------------ deployment checks

    /// @dev A launch value at the wrong scale passed checkTable (any tick in the hook's bounds): the prices refuse it.
    function test_MisScaledValueRefused() public {
        LaunchpadV2Deploy.Quote[] memory t = _table();
        script.checkValues(t, true);
        t[1].launchValue = 15_000; // 15000 USDC written without its 6 decimals: a $0.015 FDV
        script.checkTable(t); // the hook's bounds accept it...
        vm.expectRevert(bytes("USDC: launch value not worth the ETH row's (+/-25%): wrong scale or price?"));
        script.checkValues(t, true); // ...the prices do not
        t[1].launchValue = 15_000e18; // or with 18 decimals
        vm.expectRevert(bytes("USDC: launch value not worth the ETH row's (+/-25%): wrong scale or price?"));
        script.checkValues(t, true);
    }

    function test_ValuesWithinTwentyFivePercent() public {
        LaunchpadV2Deploy.Quote[] memory t = _table();
        t[3].launchValue = 0.1875e8; // +25% exactly
        script.checkValues(t, true);
        t[3].launchValue = 0.1876e8;
        vm.expectRevert(bytes("WBTC: launch value not worth the ETH row's (+/-25%): wrong scale or price?"));
        script.checkValues(t, true);
    }

    function test_PricesRequiredWhenAsked() public {
        LaunchpadV2Deploy.Quote[] memory t = _table();
        t[2].usdPriceCents = 0;
        script.checkValues(t, false); // a test chain may skip the check
        vm.expectRevert(bytes("every row needs its usdPriceCents on this chain"));
        script.checkValues(t, true); // mainnet may not
    }

    function test_ReadTableTakesPrices() public view {
        string memory json = string.concat(
            '{"chainId": 31337, "quotes": [{"symbol": "ETH", "address": "0x0000000000000000000000000000000000000000", ',
            '"decimals": 18, "launchValue": "3750000000000000000", "usdPriceCents": 400000}, {"symbol": "USDC", "address": "',
            vm.toString(usdc), '", "decimals": 6, "launchValue": "15000000000", "usdPriceCents": 100}]}'
        );
        LaunchpadV2Deploy.Quote[] memory t = script.readTable(json);
        assertEq(t[0].usdPriceCents, 400_000);
        assertEq(t[1].usdPriceCents, 100);
        script.checkValues(t, true);
    }

    function test_FeeLockedToTheReplacedForge() public {
        script.checkFee(0.005 ether, 0.005 ether, false);
        vm.expectRevert(bytes("the launch fee differs from the replaced Forge's: set ALLOW_FEE_CHANGE=true if intended"));
        script.checkFee(0.005 ether, 0.01 ether, false);
        script.checkFee(0.005 ether, 0.01 ether, true);
    }

    /// @dev On mainnet the Forge is only registered with REGISTER=true: setForge stops the launchpad in force, and the
    ///      app must be published with the v2 manifest first.
    function test_MainnetDoesNotRegisterByDefault() public view {
        assertFalse(script.shouldRegister(true, 1, false));
        assertTrue(script.shouldRegister(true, 1, true));
        assertTrue(script.shouldRegister(true, 11155111, false));
        assertFalse(script.shouldRegister(false, 11155111, true), "only the team can register");
    }
}
