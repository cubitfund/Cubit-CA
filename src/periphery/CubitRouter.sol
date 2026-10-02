// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {ICubitHook} from "../interfaces/ICubitHook.sol";

/// @title CubitRouter — minimal, stateless swap router for the CUBIT dapp
/// @notice Single-pool router with slippage and deadline checks. Buys are paid in native ETH
///         (`msg.value`), sells pull CUBIT with a standard ERC-20 approval (no Permit2).
///         It holds nothing between transactions; excess ETH is refunded in the same call.
/// @dev    Universal Router / aggregator compatibility (H4) is validated separately in the
///         testnet campaign; this router is the guaranteed path for the dashboard (PRD risk
///         "aggregators do not route the pool").
contract CubitRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;
    ICubitHook public immutable hook;
    PoolId public immutable poolId;

    /// @dev Set for the entire swap, including post-settlement burn and refund. The manager
    ///      calls back the address that called `unlock`, so `unlockCallback` is already
    ///      unreachable from outside — this is defence in depth, and it is what makes the
    ///      `payer` in the callback data provably our own caller.
    bool private _unlocking;

    struct Callback {
        address payer;
        address recipient;
        PoolKey key;
        SwapParams params;
        uint256 limit; // min output (exact input) or max input (exact output)
    }

    error NotPoolManager();
    error Expired();
    error TooLittleReceived(uint256 received, uint256 minimum);
    error TooMuchRequested(uint256 required, uint256 maximum);
    error RefundFailed();
    error WrongValue();
    error NotUnlocking();
    error TransferFailed();
    error InsufficientOutput();
    error InvalidAmount();
    error IncompleteInput();
    error ZeroRecipient();
    error WrongPool();
    error WrongPoolManager();
    error Reentrancy();

    constructor(IPoolManager pm, ICubitHook hook_) {
        if (address(pm) == address(0) || address(hook_.poolManager()) != address(pm)) revert WrongPoolManager();
        poolManager = pm;
        hook = hook_;
        poolId = hook_.poolKey().toId();
    }

    /// @notice Exact-input swap. For buys (zeroForOne) send `amountIn` as msg.value.
    /// @return amountOut net amount received by `recipient` (after the hook's taxes)
    function swapExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 amountOut) {
        if (_unlocking) revert Reentrancy();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
        if (amountIn == 0 || amountIn > uint256(uint128(type(int128).max))) revert InvalidAmount();
        if (recipient == address(0)) revert ZeroRecipient();
        if (block.timestamp > deadline) revert Expired();
        if (zeroForOne ? msg.value != amountIn : msg.value != 0) revert WrongValue();
        _unlocking = true;
        bytes memory result = poolManager.unlock(
            abi.encode(
                Callback({
                    payer: msg.sender,
                    recipient: recipient,
                    key: key,
                    params: SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: -int256(amountIn),
                        sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                    }),
                    limit: amountOutMin
                })
            )
        );
        amountOut = abi.decode(result, (uint256));
        _finishSwap(zeroForOne);
    }

    /// @notice Exact-output swap. For buys send `amountInMax` as msg.value; the excess is refunded.
    /// @return amountIn gross amount taken from the payer (taxes included)
    function swapExactOut(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountOut,
        uint256 amountInMax,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 amountIn) {
        if (_unlocking) revert Reentrancy();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
        if (amountOut == 0 || amountOut > uint256(uint128(type(int128).max))) revert InvalidAmount();
        if (recipient == address(0)) revert ZeroRecipient();
        if (block.timestamp > deadline) revert Expired();
        if (zeroForOne ? msg.value != amountInMax : msg.value != 0) revert WrongValue();
        _unlocking = true;
        bytes memory result = poolManager.unlock(
            abi.encode(
                Callback({
                    payer: msg.sender,
                    recipient: recipient,
                    key: key,
                    params: SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: int256(amountOut),
                        sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                    }),
                    limit: amountInMax
                })
            )
        );
        amountIn = abi.decode(result, (uint256));
        _finishSwap(zeroForOne);
    }

    /// @dev After a sale, hand the CUBIT that crossed walls absorbed to their sink (the vault reserve).
    ///      A failing sink never blocks trading: the tokens stay isolated in the hook and anyone can
    ///      deliver them later, as for sales routed elsewhere.
    function _finishSwap(bool zeroForOne) internal {
        // A refund receiver can use another router and add to the isolated queue.
        // Deliver after the last arbitrary recipient call, while our guard is still set.
        _refund(msg.sender);
        if (!zeroForOne && hook.pendingAbsorbedTokens() != 0) {
            try hook.deliverAbsorbed() {} catch {}
        }
        _unlocking = false;
    }

    /// @inheritdoc IUnlockCallback
    // The authenticated PoolManager callback can only decode payer=msg.sender set by our
    // entrypoints while _unlocking. Arbitrary callers cannot spend another payer's allowance.
    // slither-disable-next-line arbitrary-send-erc20
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (!_unlocking) revert NotUnlocking();
        Callback memory c = abi.decode(raw, (Callback));

        // the delta returned already includes the hook's taxes (net for the swapper)
        BalanceDelta delta = poolManager.swap(c.key, c.params, "");
        (Currency cIn, Currency cOut, int128 dIn, int128 dOut) = c.params.zeroForOne
            ? (c.key.currency0, c.key.currency1, delta.amount0(), delta.amount1())
            : (c.key.currency1, c.key.currency0, delta.amount1(), delta.amount0());

        uint256 amountIn = dIn < 0 ? uint256(uint128(-dIn)) : 0;
        uint256 amountOut = dOut > 0 ? uint256(uint128(dOut)) : 0;

        // An exact-output sell beyond what the book can serve can leave the swapper owing
        // on BOTH sides: the hook's tax is sized on the amount asked for, and v4 fills
        // partially without reverting (see docs/REVIEW.md finding 7). Fail with a name instead
        // of an opaque settlement error, and never silently drop a debt.
        if (dOut < 0) revert InsufficientOutput();

        bool exactInput = c.params.amountSpecified < 0;
        // A partial buy still charges the hook's specified-input tax in full. Revert the
        // entire transaction if the pool cannot consume the input, undoing that tax too.
        if (exactInput && amountIn != uint256(-c.params.amountSpecified)) revert IncompleteInput();
        if (exactInput && amountOut < c.limit) revert TooLittleReceived(amountOut, c.limit);
        // v4 may stop at a price limit with a positive partial output. The input cap alone
        // cannot enforce an exact-output request; check the net fill before settling either leg.
        if (!exactInput && amountOut < uint256(c.params.amountSpecified)) revert InsufficientOutput();
        if (!exactInput && amountIn > c.limit) revert TooMuchRequested(amountIn, c.limit);

        // pay
        if (amountIn != 0) {
            if (cIn.isAddressZero()) {
                // sync() is public and its transient currency can survive an earlier
                // operation in this transaction. Explicitly select native settlement.
                poolManager.sync(cIn);
                poolManager.settle{value: amountIn}();
            } else {
                poolManager.sync(cIn);
                if (!IERC20Minimal(Currency.unwrap(cIn)).transferFrom(c.payer, address(poolManager), amountIn)) {
                    revert TransferFailed();
                }
                poolManager.settle();
            }
        }
        // receive
        if (amountOut != 0) poolManager.take(cOut, c.recipient, amountOut);

        return abi.encode(exactInput ? amountOut : amountIn);
    }

    // `to` is exclusively the caller of the payable swap; this router has no custody book.
    // slither-disable-next-line arbitrary-send-eth
    function _refund(address to) internal {
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool ok,) = to.call{value: bal}("");
        if (!ok) revert RefundFailed();
    }

    /// @dev Only the PoolManager may send normally. Forced ETH donations are not custody
    ///      deposits and are included in the next caller's refund.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }
}
