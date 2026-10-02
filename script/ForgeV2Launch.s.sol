// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {CubitForgeToken} from "../src/periphery/CubitForge.sol";
import {CubitForgeV2} from "../src/periphery/CubitForgeV2.sol";
import {CubitGovernanceVault} from "../src/periphery/CubitGovernanceVault.sol";
import {CubitQuoteHook} from "../src/quote/CubitQuoteHook.sol";
import {QuoteTaxes} from "../src/quote/QuoteTaxes.sol";
import {MockQuote} from "./mocks/TestQuotes.sol";
import {QuoteSwapper} from "./mocks/TestSwapper.sol";

/// @notice A public launch on the launchpad v2, then one trading cycle, for a rehearsal on Anvil or Sepolia.
///         The token salt is mined so that the child token sorts above its quote,
///         then the hook salt so that the hook address carries the six flags, both bound to the launcher. The launch
///         includes the launcher's buy. The cycle buys, sells a tenth (a wall), sells the rest through it, delivers the
///         absorbed tokens to the governance vault and pays the child team in the quote. On a test chain the test
///         quote is minted to the launcher first. Run after LaunchpadV2Deploy and the team's activate(8):
///           LAUNCHPAD_V2=deployments/31337.launchpad-v2.candidate.json QUOTE=<quote address, 0 for ETH> \
///             forge script script/ForgeV2Launch.s.sol --rpc-url <anvil or public sepolia rpc> --broadcast \
///               --account <test keystore> --password-file <file>
///         Anvil and Sepolia only: on mainnet it would launch a public token and trade it for real.
///         BUY (the launcher's buy) and CYCLE_BUY default to 1/100 and 1/5 of the quote's launch value; off Anvil,
///         CHILD_TEAM is required. BUY_TEAM_BPS, SELL_TEAM_BPS and SELL_WALL_BPS set the child's taxes (CUBIT's by
///         default: 300, 300, 1200).
contract ForgeV2Launch is Script {
    using SafeERC20 for IERC20;

    uint160 internal constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external {
        require(block.chainid == 31337 || block.chainid == 11155111, "rehearsal script: Anvil or Sepolia only");
        CubitForgeV2 forge = CubitForgeV2(vm.parseJsonAddress(vm.readFile(vm.envString("LAUNCHPAD_V2")), ".forge"));
        address quote = vm.envOr("QUOTE", address(0));
        uint256 value = forge.launchValue(quote);
        require(value != 0, "quote not in the Forge's table");
        address launcher = msg.sender;
        address childTeam = block.chainid == 31337
            ? vm.envOr("CHILD_TEAM", address(0x976EA74026E726554dB657fA54763abd0C3a0aa9)) // Anvil #6
            : vm.envAddress("CHILD_TEAM");
        uint256 buy = vm.envOr("BUY", value / 100);
        uint256 cycleBuy = vm.envOr("CYCLE_BUY", value / 5);
        CubitForgeV2.LaunchParams memory p = _params(forge, launcher, childTeam, quote, value, buy);

        vm.startBroadcast();
        if (quote != address(0)) {
            MockQuote(quote).mint(launcher, buy + cycleBuy);
            IERC20(quote).forceApprove(address(forge), buy);
        }
        uint256 value_ = forge.launchFee() + (quote == address(0) ? buy : 0);
        (address childToken, address childHook, uint256 bought) =
            forge.launch{value: value_}(p, type(CubitQuoteHook).creationCode);
        vm.stopBroadcast();

        CubitQuoteHook child = CubitQuoteHook(childHook);
        require(child.initialized(), "child not initialized");
        require(
            IERC20(childToken).balanceOf(launcher) == bought && bought != 0, "the launcher's buy was not delivered"
        );
        console2.log("launcher   ", launcher);
        console2.log("quote      ", quote);
        console2.log("childToken ", childToken);
        console2.log("childHook  ", childHook);
        console2.log("bought at launch", bought);
        _cycle(child, forge, quote, cycleBuy, bought);
    }

    function _params(CubitForgeV2 forge, address launcher, address team, address quote, uint256 value, uint256 buy)
        internal view returns (CubitForgeV2.LaunchParams memory p)
    {
        string memory name_ = "Child v2";
        string memory symbol_ = "CHV2";
        bytes32 codeHash = keccak256(abi.encodePacked(type(CubitForgeToken).creationCode, abi.encode(name_, symbol_)));
        uint256 start = uint256(keccak256(abi.encode(block.number, launcher)));
        address token;
        bytes32 tokenSalt;
        for (uint256 i; ; i++) {
            tokenSalt = bytes32(start + i);
            token = vm.computeCreate2Address(keccak256(abi.encode(launcher, tokenSalt)), codeHash, address(forge));
            if (uint160(token) > uint160(quote) && token.code.length == 0) break;
        }
        // Check the raw values before narrowing them: a uint16 cast would silently wrap 65,536 to 0, and the child's
        // taxes are frozen forever.
        uint256 buyTeam = vm.envOr("BUY_TEAM_BPS", uint256(300));
        uint256 sellTeam = vm.envOr("SELL_TEAM_BPS", uint256(300));
        uint256 sellWall = vm.envOr("SELL_WALL_BPS", uint256(1_200));
        require(buyTeam <= QuoteTaxes.MAX_BUY_TEAM_BPS && sellTeam <= QuoteTaxes.MAX_SELL_TEAM_BPS
            && sellWall <= QuoteTaxes.MAX_SELL_WALL_BPS && sellTeam + sellWall <= QuoteTaxes.MAX_SELL_TAX_BPS,
            "taxes outside QuoteTaxes' bounds");
        QuoteTaxes.Taxes memory taxes = QuoteTaxes.Taxes(uint16(buyTeam), uint16(sellTeam), uint16(sellWall));
        bytes32 initCodeHash = keccak256(abi.encodePacked(
            type(CubitQuoteHook).creationCode, abi.encode(forge.poolManager(), token, team, quote, value, taxes)
        ));
        bytes32 hookSalt;
        for (uint256 i; i < 1_000_000; i++) {
            address candidate =
                vm.computeCreate2Address(keccak256(abi.encode(launcher, bytes32(i))), initCodeHash, address(forge));
            if (uint160(candidate) & Hooks.ALL_HOOK_MASK == FLAGS && candidate.code.length == 0) {
                hookSalt = bytes32(i);
                break;
            }
            require(i != 999_999, "no hook salt found");
        }
        p = CubitForgeV2.LaunchParams(name_, symbol_, team, quote, tokenSalt, hookSalt, buy, taxes);
    }

    function _cycle(CubitQuoteHook child, CubitForgeV2 forge, address quote, uint256 cycleBuy, uint256 bought)
        internal
    {
        PoolKey memory key = child.poolKey();
        IERC20 token = IERC20(address(child.token()));
        CubitGovernanceVault governance = CubitGovernanceVault(forge.governanceVault());
        address team = child.TEAM_ADDRESS();

        vm.startBroadcast();
        QuoteSwapper swapper = new QuoteSwapper(forge.poolManager());
        if (quote != address(0)) IERC20(quote).forceApprove(address(swapper), cycleBuy);
        token.approve(address(swapper), type(uint256).max);
        swapper.swap{value: quote == address(0) ? cycleBuy : 0}(key, true, -int256(cycleBuy));
        uint256 held = token.balanceOf(msg.sender) - bought; // the cycle leaves the launch buy alone
        swapper.swap(key, false, -int256(held / 10));
        require(child.activeWallCount() == (child.SELL_FLOOR_BPS() == 0 ? 0 : 1), "unexpected wall count");
        swapper.swap(key, false, -int256(held - held / 10));
        uint256 absorbed = child.pendingAbsorbedTokens();
        require(absorbed != 0 || child.SELL_FLOOR_BPS() == 0, "the crossed wall absorbed nothing");
        uint256 held0 = governance.held(address(token));
        child.deliverAbsorbed();
        uint256 due = child.teamAccrued();
        uint256 paid0 = child.teamPaidCumulative();
        // Read right before the claim: when the team is also the launcher, the cycle's buys spend its quote.
        uint256 teamBefore = quote == address(0) ? team.balance : IERC20(quote).balanceOf(team);
        child.claimTeam();
        vm.stopBroadcast();

        require(
            governance.held(address(token)) - held0 == absorbed, "the governance vault did not book the absorbed tokens"
        );
        require(child.teamPaidCumulative() - paid0 == due && child.teamAccrued() == 0, "the team's due was not paid");
        // A team that also sends the claim pays its gas in ETH: only an ERC-20 quote, or another team, is exact.
        if (quote != address(0) || team != msg.sender) {
            uint256 teamAfter = quote == address(0) ? team.balance : IERC20(quote).balanceOf(team);
            require(teamAfter - teamBefore == due, "the team was not paid in the quote");
        }
        console2.log("tokens absorbed -> governance vault", absorbed);
        console2.log("team paid in the quote", due);
        console2.log("launcher still holds its launch buy", bought);
        console2.log("OK launchpad v2 launch and cycle");
    }
}
