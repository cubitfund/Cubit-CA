// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CubitHook} from "../CubitHook.sol";
import {CubitForgeToken} from "./CubitForge.sol";
import {CubitQuoteHook} from "../quote/CubitQuoteHook.sol";
import {QuoteBandLib} from "../quote/QuoteBandLib.sol";
import {QuoteTaxes} from "../quote/QuoteTaxes.sol";
import {ICubitV2, ICubitGovernanceVault} from "../interfaces/ICubitV2.sol";

/// @notice The public launchpad v2: anyone launches a token by paying the launch fee, paired with one of the quote
///         currencies fixed at construction — native ETH, or an ERC-20 such as USDC, USDT, WBTC or a tokenized stock.
///         Every child runs the frozen CubitQuoteHook creation code with its own token, claims and pool ID, under the
///         same imposed parameters: its whole fixed supply in its band and the launch value this Forge fixed for its
///         quote. The launcher chooses the child's taxes, within QuoteTaxes' bounds (buys up to 5% to its team; sales
///         up to 5% to its team and up to 20% to the walls, 25% together), and they are frozen in the child's hook. The
///         launch fee to the governance vault is not the launcher's to choose. The launcher may buy in the same
///         transaction, taxed like any buy, so that nobody can buy the first tokens before its own purchase.
/// @dev    The quote table is written once, by the constructor, and has no setter: changing a launch value or adding a
///         quote takes a new Forge, registered by the team with `setForge`; children already launched keep theirs.
///         Both CREATE2 salts are bound to the launcher as in CubitForge. The child token's address must also sort
///         above its quote's, so that the quote is the pool's currency0 (CubitQuoteHook's orientation): the launcher
///         chooses a token salt that gives such an address. Native ETH, address zero, sorts first anyway.
///         The launch fee is always paid in ETH and locked in the governance vault; the Forge keeps nothing.
contract CubitForgeV2 is ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    /// @notice The CUBIT hook this launchpad serves: the registry checks it before registering the module.
    CubitHook public immutable hook;
    IPoolManager public immutable poolManager;
    bytes32 public immutable hookCreationCodeHash;
    uint256 public immutable launchFee;
    /// @notice Launchpad governance vault: every launch fee is locked here, in ETH, and every child's hook delivers the
    ///         tokens its walls absorb here too, finding this address through its token's deployer.
    address public immutable governanceVault;
    uint256 public constant MAX_QUOTES = 16;
    /// @dev Every child's fixed supply: CubitForgeToken inherits CubitToken's TOTAL_SUPPLY.
    uint256 internal constant CHILD_SUPPLY = 21_000_000e18;
    uint256 public launches;

    /// @notice Launch FDV, in the quote's base units, of a child paired with `quote`; zero for a quote not accepted.
    mapping(address quote => uint256) public launchValue;
    address[] internal _quotes;

    struct LaunchParams {
        string name;
        string symbol;
        /// @notice Receives the child's taxes, in the quote.
        address team;
        /// @notice Address zero for native ETH.
        address quote;
        bytes32 tokenSalt;
        bytes32 hookSalt;
        /// @notice Quote the launcher spends on the child's first buy, taxed; zero for none.
        uint256 buyAmount;
        /// @notice The child's tax rates, frozen at launch (QuoteTaxes.cubit() gives CUBIT's own).
        QuoteTaxes.Taxes taxes;
    }

    event ChildLaunched(
        address indexed token,
        address indexed hook,
        address indexed launcher,
        address quote,
        address team,
        uint256 fee,
        uint256 quoteIn,
        uint256 tokensOut
    );

    constructor(CubitHook hook_, uint256 launchFee_, address governanceVault_, address[] memory quotes_,
        uint256[] memory launchValues_)
    {
        require(launchFee_ != 0, "zero fee");
        require(governanceVault_.code.length != 0, "governance vault missing");
        require(quotes_.length != 0 && quotes_.length <= MAX_QUOTES && quotes_.length == launchValues_.length,
            "invalid quotes");
        for (uint256 i; i < quotes_.length; i++) {
            address quote = quotes_[i];
            require(quote == address(0) || quote.code.length != 0, "quote missing");
            require(launchValue[quote] == 0, "duplicate quote");
            require(validLaunchValue(launchValues_[i]), "invalid launch value");
            launchValue[quote] = launchValues_[i];
            _quotes.push(quote);
        }
        hook = hook_;
        poolManager = hook_.poolManager();
        launchFee = launchFee_;
        governanceVault = governanceVault_;
        hookCreationCodeHash = keccak256(type(CubitQuoteHook).creationCode);
    }

    /// @notice The accepted quotes, in construction order.
    function quotes() external view returns (address[] memory) {
        return _quotes;
    }

    /// @notice Whether CubitQuoteHook accepts this launch value for a child's fixed supply: the same bounds as its
    ///         constructor, checked here so that a table the hook would refuse never reaches a launch.
    function validLaunchValue(uint256 value) public pure returns (bool ok) {
        (ok,) = QuoteBandLib.launchSqrtPrice(value, CHILD_SUPPLY);
    }

    /// @notice Launch a child token paired with `p.quote`. Pay `launchFee` in ETH, plus `p.buyAmount` for a native ETH
    ///         pair; for an ERC-20 pair the Forge pulls `p.buyAmount` of the quote, which the launcher approved first.
    ///         The child token is created with the salt `keccak256(abi.encode(msg.sender, p.tokenSalt))` and must sort
    ///         above the quote; the child hook with `keccak256(abi.encode(msg.sender, p.hookSalt))`, which must give
    ///         its address the six hook flags.
    function launch(LaunchParams calldata p, bytes calldata creationCode)
        external payable nonReentrant returns (address childToken, address childHook, uint256 tokensOut)
    {
        address registry = hook.v2();
        require(registry != address(0) && ICubitV2(registry).forge() == address(this) &&
            ICubitV2(registry).enabledFeatures() & 8 != 0, "Forge inactive");
        uint256 value = launchValue[p.quote];
        require(value != 0, "quote not accepted");
        require(p.buyAmount <= uint256(uint128(type(int128).max)), "buy too large");
        require(msg.value == launchFee + (p.quote == address(0) ? p.buyAmount : 0), "wrong payment");
        require(bytes(p.name).length > 0 && bytes(p.name).length <= 64 &&
            bytes(p.symbol).length > 0 && bytes(p.symbol).length <= 12, "invalid name");
        // The team receives the child's taxes forever: none of these addresses could ever pass them on.
        require(QuoteTaxes.valid(p.taxes), "invalid taxes");
        require(p.team != address(0) && p.team != address(hook) && p.team != address(this) &&
            p.team != address(poolManager) && p.team != governanceVault, "invalid team");
        require(keccak256(creationCode) == hookCreationCodeHash, "template mismatch");

        bytes32 tokenSalt = keccak256(abi.encode(msg.sender, p.tokenSalt));
        CubitForgeToken token = new CubitForgeToken{salt: tokenSalt}(p.name, p.symbol);
        require(uint160(address(token)) > uint160(p.quote), "token sorts below quote");
        require(p.team != address(token), "invalid team");
        // The prefix hash is frozen and the constructor suffix is exactly eight static ABI words (the taxes are a
        // static struct of three).
        bytes memory initCode =
            bytes.concat(creationCode, abi.encode(poolManager, token, p.team, p.quote, value, p.taxes));
        bytes32 salt = keccak256(abi.encode(msg.sender, p.hookSalt));
        assembly ("memory-safe") { childHook := create2(0, add(initCode, 32), mload(initCode), salt) }
        require(childHook != address(0), "child deployment failed");
        CubitQuoteHook child = CubitQuoteHook(childHook);
        token.setHook(childHook);
        require(token.transfer(childHook, token.TOTAL_SUPPLY()), "child funding failed");
        poolManager.initialize(child.poolKey(), child.INITIAL_SQRT_PRICE());
        ICubitGovernanceVault(governanceVault).depositEth{value: launchFee}();

        uint256 quoteIn;
        if (p.buyAmount != 0) {
            (quoteIn, tokensOut) = abi.decode(
                poolManager.unlock(abi.encode(child.poolKey(), msg.sender, p.buyAmount)), (uint256, uint256)
            );
            // The hook taxes an exact-input buy on the amount asked, before the fill is known: a buy stopped by the
            // price limit would pay the whole tax on a partial fill. Reaching that limit takes more quote than exists
            // (about 1e31 base units at the cheapest accepted launch price); the check keeps a partial fill impossible.
            require(quoteIn == p.buyAmount, "buy not filled");
        }
        launches++;
        childToken = address(token);
        emit ChildLaunched(childToken, childHook, msg.sender, p.quote, p.team, launchFee, quoteIn, tokensOut);
    }

    /// @notice The launcher's first buy, inside the launch transaction: an exact-input swap of `amount` quote, taxed by
    ///         the child hook like any buy. The quote comes from the ETH sent with the launch, or straight from the
    ///         launcher's balance to the PoolManager; the tokens go to the launcher.
    /// @dev    The PoolManager only calls back the contract that unlocked it, and only `launch` unlocks.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        (PoolKey memory key, address buyer, uint256 amount) = abi.decode(data, (PoolKey, address, uint256));
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        uint256 paid = uint256(uint128(-d.amount0()));
        uint256 out = uint256(uint128(d.amount1()));
        if (key.currency0.isAddressZero()) {
            poolManager.settle{value: paid}();
        } else {
            poolManager.sync(key.currency0);
            // `buyer` is always `launch`'s msg.sender: the PoolManager only calls back the contract that unlocked it,
            // and only `launch` unlocks, encoding its own caller. Nobody can pull from another account's allowance.
            // slither-disable-next-line arbitrary-send-erc20
            IERC20(Currency.unwrap(key.currency0)).safeTransferFrom(buyer, address(poolManager), paid);
            poolManager.settle();
        }
        poolManager.take(key.currency1, buyer, out);
        return abi.encode(paid, out);
    }
}
