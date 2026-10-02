// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

// A test swapper for rehearsals (Anvil, Sepolia) and tests only: the app trades through the Universal Router.

/// @notice A plain v4 swapper that pays like the Universal Router does: SafeERC20 pulls (so USDT's missing return
///         value is accepted), native ETH from the call's value, any unspent ETH refunded. Partial fills allowed.
contract QuoteSwapper is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        external
        payable
        returns (BalanceDelta d)
    {
        bytes memory data = abi.encode(false, msg.sender, key, zeroForOne, amountSpecified, key);
        d = abi.decode(manager.unlock(data), (BalanceDelta));
        _refund();
    }

    /// @notice Two hops in one unlock: sell `tokensIn` of child A for its quote, then spend exactly that quote on child
    ///         B. The quote nets to zero inside the PoolManager: the quote token itself is never called.
    function swapThrough(PoolKey memory keyA, PoolKey memory keyB, uint256 tokensIn)
        external
        returns (uint256 tokensOut)
    {
        bytes memory data = abi.encode(true, msg.sender, keyA, false, -int256(tokensIn), keyB);
        tokensOut = abi.decode(manager.unlock(data), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (
            bool through,
            address payer,
            PoolKey memory key,
            bool zeroForOne,
            int256 amountSpecified,
            PoolKey memory keyB
        ) =
            abi.decode(data, (bool, address, PoolKey, bool, int256, PoolKey));
        BalanceDelta d = _swap(key, zeroForOne, amountSpecified);
        if (!through) {
            _settle(key.currency0, payer, d.amount0());
            _settle(key.currency1, payer, d.amount1());
            return abi.encode(d);
        }
        // Hop 1 left +quote and -tokensA; hop 2 spends that quote on child B.
        BalanceDelta d2 = _swap(keyB, true, -int256(d.amount0()));
        _settle(key.currency1, payer, d.amount1());
        _settle(keyB.currency1, payer, d2.amount1());
        require(d.amount0() + d2.amount0() == 0, "quote did not net");
        return abi.encode(uint256(uint128(d2.amount1())));
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) private returns (BalanceDelta) {
        return manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
    }

    function _refund() private {
        if (address(this).balance != 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok, "refund failed");
        }
    }

    function _settle(Currency currency, address payer, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (Currency.unwrap(currency) == address(0)) {
                manager.settle{value: owed}();
            } else {
                manager.sync(currency);
                IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, payer, uint256(uint128(amount)));
        }
    }

    receive() external payable {}
}
