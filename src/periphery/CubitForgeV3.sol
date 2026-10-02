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
import {ICubitQuoteHook} from "../quote/ICubitQuoteHook.sol";
import {QuoteBandLib} from "../quote/QuoteBandLib.sol";
import {TokenFirstBandLib} from "../quote/TokenFirstBandLib.sol";
import {QuoteTaxes} from "../quote/QuoteTaxes.sol";
import {ICubitV2, ICubitGovernanceVault} from "../interfaces/ICubitV2.sol";

/// @notice The public launchpad v3: CubitForgeV2 with every ERC-20 pair in the TOKEN/QUOTE orientation. Anyone launches a
///         token by paying the launch fee, paired with one of the quote currencies fixed at construction — native ETH,
///         or an ERC-20 such as USDC, USDT, WBTC or a tokenized stock. An ETH child runs the frozen CubitQuoteHook
///         creation code (ETH, address zero, is always currency0); an ERC-20 child runs the frozen CubitTokenFirstHook
///         creation code, its token being currency0, so explorers and aggregators that take currency0 as the base show
///         TOKEN/QUOTE. Same imposed parameters as the launchpad v2: the whole fixed supply in the band, the launch value
///         this Forge fixed for the quote, the launcher's taxes within QuoteTaxes' bounds frozen in the hook, an optional
///         first buy in the launch transaction, and the launch fee to the governance vault.
/// @dev    The quote table is written once, by the constructor, and has no setter. Both CREATE2 salts are bound to the
///         launcher. The child token's address must sort ABOVE native ETH (always true) and BELOW an ERC-20 quote: the
///         launcher chooses a token salt that gives such an address. The Forge keeps nothing.
contract CubitForgeV3 is ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    /// @notice The CUBIT hook this launchpad serves: the registry checks it before registering the module.
    CubitHook public immutable hook;
    IPoolManager public immutable poolManager;
    /// @notice Frozen creation code of an ETH child's hook (CubitQuoteHook, quote as currency0).
    bytes32 public immutable hookCreationCodeHash;
    /// @notice Frozen creation code of an ERC-20 child's hook (CubitTokenFirstHook, token as currency0).
    bytes32 public immutable tokenFirstHookCreationCodeHash;
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

    /// @param quoteHookCodeHash_      keccak256 of CubitQuoteHook's linked creation code (ETH children)
    /// @param tokenFirstHookCodeHash_ keccak256 of CubitTokenFirstHook's linked creation code (ERC-20 children)
    /// @dev   The two templates are given as hashes: embedding both creation codes to hash them here would exceed the
    ///        initcode size limit (EIP-3860). LaunchpadV3Deploy checks them against the build before and after the
    ///        deployment, the app checks the template it links against them before every launch, and a child hook
    ///        only deploys from code matching one of them.
    constructor(CubitHook hook_, uint256 launchFee_, address governanceVault_, address[] memory quotes_,
        uint256[] memory launchValues_, bytes32 quoteHookCodeHash_, bytes32 tokenFirstHookCodeHash_)
    {
        require(quoteHookCodeHash_ != bytes32(0) && tokenFirstHookCodeHash_ != bytes32(0) &&
            quoteHookCodeHash_ != tokenFirstHookCodeHash_, "invalid templates");
        require(launchFee_ != 0, "zero fee");
        require(governanceVault_.code.length != 0, "governance vault missing");
        require(quotes_.length != 0 && quotes_.length <= MAX_QUOTES && quotes_.length == launchValues_.length,
            "invalid quotes");
        for (uint256 i; i < quotes_.length; i++) {
            address quote = quotes_[i];
            require(quote == address(0) || quote.code.length != 0, "quote missing");
            require(launchValue[quote] == 0, "duplicate quote");
            require(validLaunchValueFor(quote, launchValues_[i]), "invalid launch value");
            launchValue[quote] = launchValues_[i];
            _quotes.push(quote);
        }
        hook = hook_;
        poolManager = hook_.poolManager();
        launchFee = launchFee_;
        governanceVault = governanceVault_;
        hookCreationCodeHash = quoteHookCodeHash_;
        tokenFirstHookCreationCodeHash = tokenFirstHookCodeHash_;
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

    /// @notice Whether the hook `quote`'s children use accepts this launch value: CubitQuoteHook's bounds for native
    ///         ETH, CubitTokenFirstHook's (the same, mirrored) for an ERC-20.
    function validLaunchValueFor(address quote, uint256 value) public pure returns (bool ok) {
        if (quote == address(0)) return validLaunchValue(value);
        (ok,) = TokenFirstBandLib.launchSqrtPrice(value, CHILD_SUPPLY);
    }

    /// @notice The frozen hook template of a child paired with `quote`.
    function hookCreationCodeHashFor(address quote) public view returns (bytes32) {
        return quote == address(0) ? hookCreationCodeHash : tokenFirstHookCreationCodeHash;
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
        // The pair itself could never pass them on either (audit of 28/09, C2).
        require(p.team != address(0) && p.team != address(hook) && p.team != address(this) &&
            p.team != address(poolManager) && p.team != governanceVault && p.team != p.quote, "invalid team");
        require(keccak256(creationCode) == hookCreationCodeHashFor(p.quote), "template mismatch");

        bytes32 tokenSalt = keccak256(abi.encode(msg.sender, p.tokenSalt));
        CubitForgeToken token = new CubitForgeToken{salt: tokenSalt}(p.name, p.symbol);
        // ETH (address zero) is always currency0; an ERC-20 pair is always currency1, under the child token.
        if (p.quote != address(0)) require(uint160(address(token)) < uint160(p.quote), "token sorts above quote");
        require(p.team != address(token), "invalid team");
        // The prefix hash is frozen and the constructor suffix is exactly eight static ABI words (the taxes are a
        // static struct of three).
        bytes memory initCode =
            bytes.concat(creationCode, abi.encode(poolManager, token, p.team, p.quote, value, p.taxes));
        bytes32 salt = keccak256(abi.encode(msg.sender, p.hookSalt));
        assembly ("memory-safe") { childHook := create2(0, add(initCode, 32), mload(initCode), salt) }
        require(childHook != address(0), "child deployment failed");
        ICubitQuoteHook child = ICubitQuoteHook(childHook);
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
        // An ETH child's pool is ETH/TOKEN (the buy is zeroForOne); an ERC-20 child's is TOKEN/QUOTE (oneForZero).
        bool quoteIs0 = key.currency0.isAddressZero();
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: quoteIs0,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        uint256 paid = uint256(uint128(-(quoteIs0 ? d.amount0() : d.amount1())));
        uint256 out = uint256(uint128(quoteIs0 ? d.amount1() : d.amount0()));
        if (quoteIs0) {
            poolManager.settle{value: paid}();
            poolManager.take(key.currency1, buyer, out);
        } else {
            poolManager.sync(key.currency1);
            // `buyer` is always `launch`'s msg.sender: the PoolManager only calls back the contract that unlocked it,
            // and only `launch` unlocks, encoding its own caller. Nobody can pull from another account's allowance.
            // slither-disable-next-line arbitrary-send-erc20
            IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(buyer, address(poolManager), paid);
            poolManager.settle();
            poolManager.take(key.currency0, buyer, out);
        }
        return abi.encode(paid, out);
    }
}
