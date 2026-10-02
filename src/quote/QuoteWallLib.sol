// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DApp:          https://cubit.fund/
// Documentation: https://gitbook.cubit.fund/
// X:             https://x.com/Cubit_fund

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {BandLib} from "../libraries/BandLib.sol";
import {ICubitQuoteHook} from "./ICubitQuoteHook.sol";

/// @notice Fixed-price wall positions of a launchpad v2 child: WallLib with the quote currency (currency0 of the
/// pool: native ETH, or an ERC-20 such as USDC, WBTC or a tokenized stock) in place of native ETH. The hook's claims
/// on the quote are the ERC-6909 id of currency0 instead of id 0; everything else, the events included, is WallLib's.
/// Linked library: all state and claims belong to the hook. Each tick has one permanent identity. New funding NEVER
/// withdraws or moves another wall.
library QuoteWallLib {
    using CurrencyLibrary for Currency;

    // Every usable one-spacing range at the core's fixed spacing of ten. No small
    // operational quota: a busy market must not stop placing fees after 64 deposits.
    uint256 internal constant MAX_ACTIVE_WALLS = 177_454;
    bytes32 internal constant SALT = keccak256("CUBIT.FLOOR");

    struct Wall {
        int24 lower;
        uint128 liquidity;
        uint32 activeIndex; // 1-based; zero when no executable position remains
        uint256 idleQuote; // ERC-6909 quote claims earmarked exclusively for THIS tick
        uint256 fundedQuote; // cumulative fresh fee funds actually deployed at this tick
    }

    struct Book {
        Wall[] walls; // stable historical IDs, never deleted or re-priced
        uint256[] active; // enumeration for paginated readers; swaps do not scan this array
        mapping(int24 => uint256) idPlusOne;
        uint256 latestId;
        uint256 idleQuote;
        int24 nearestTick; // minimum active tick = highest active quote price of the token
        // Three-level bitmap over the 177,454 possible ranges at spacing 10. Finding
        // the nearest active wall takes bounded reads regardless of the wall count.
        mapping(uint256 => uint256) tickWords;
        uint256[3] wordGroups;
        uint256 groups;
    }

    /// @notice A sale placed wall funds at `lower`: `addedQuote` fresh quote, `liquidity` the wall's total after
    ///         merging.
    /// @dev    Same signature as WallLib's event, so one reader follows the walls of every child.
    event WallFunded(uint256 indexed id, int24 indexed lower, uint256 addedQuote, uint128 liquidity);
    /// @notice A sale fully crossed the wall and emptied it: `tokens` absorbed child tokens. `quoteRemaining` is the
    ///         quote the wall released back to the pending wall funds (its realized fees and earmarked dust).
    event WallAbsorbed(uint256 indexed id, uint256 tokens, uint256 quoteRemaining);

    /// @dev Deposit `freshQuote`, plus the quote already earmarked for this tick, in the one-spacing wall at
    ///      `lower`, merging with the wall there. The caller guarantees the range lies strictly above the
    ///      pool tick, so the deposit is pure quote. An amount too small to mint liquidity returns zero
    ///      instead of reverting: the funds stay pending. Pays its principal from the hook's quote claims
    ///      and keeps realized fees as claims, so it leaves no open delta.
    function fund(
        Book storage b,
        IPoolManager manager,
        PoolKey memory key,
        int24 lower,
        uint256 freshQuote,
        uint128 cap
    )
        public returns (uint256 freshUsed, uint256 tokenFees)
    {
        uint256 plusOne = b.idPlusOne[lower];
        uint128 existing;
        uint256 idle;
        if (plusOne != 0) {
            Wall storage prior = b.walls[plusOne - 1];
            existing = prior.liquidity;
            idle = prior.idleQuote;
        }
        (uint128 added, uint256 used) = BandLib.liquidityForEth(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(lower + key.tickSpacing),
            freshQuote + idle, cap - existing
        );
        if (added == 0) return (0, 0);
        freshUsed = used > idle ? used - idle : 0;
        uint256 id;
        if (plusOne == 0) {
            id = b.walls.length;
            b.idPlusOne[lower] = id + 1;
            b.walls.push(Wall(lower, 0, 0, 0, 0));
        } else id = plusOne - 1;
        Wall storage w = b.walls[id];
        uint256 idleUsed = used - freshUsed;
        w.idleQuote -= idleUsed;
        b.idleQuote -= idleUsed;
        (BalanceDelta d, BalanceDelta fees) = _modify(manager, key, lower, int256(uint256(added)));
        // Exact budget from the same rounding as v4. No floor deposit may borrow child tokens.
        if (d.amount1() != fees.amount1() || int256(d.amount0()) - int256(fees.amount0()) != -int256(used)) {
            revert ICubitQuoteHook.WallInRange();
        }
        uint256 quoteId = key.currency0.toId();
        manager.burn(address(this), quoteId, used);
        uint256 quoteFees = _positive(fees.amount0());
        if (quoteFees != 0) {
            w.idleQuote += quoteFees;
            b.idleQuote += quoteFees;
            manager.mint(address(this), quoteId, quoteFees);
        }
        tokenFees = _positive(fees.amount1());
        if (tokenFees != 0) manager.mint(address(this), key.currency1.toId(), tokenFees);
        w.liquidity += added;
        w.fundedQuote += freshUsed;
        if (w.activeIndex == 0) _addActive(b, id);
        b.latestId = id;
        emit WallFunded(id, lower, freshUsed, w.liquidity);
    }

    /// @dev Empty every wall the price has fully crossed (tick at or past its upper bound), nearest first:
    ///      such a wall holds only child tokens. No per-sale quota: each wall costs one withdrawal and O(1)
    ///      bookkeeping, so a sale crossing more walls than a transaction's gas allows reverts and the
    ///      seller splits it. A wall the price merely entered keeps its position — if the price comes
    ///      back, it sells those tokens back and refills with quote. No price reset, no redeposit. Mints
    ///      what it withdraws as hook claims, so it leaves no open delta.
    /// @return tokens Child tokens taken out of the crossed walls
    /// @return quote  Quote those walls release: realized fees plus the dust earmarked for their ticks
    function collectCrossed(Book storage b, IPoolManager manager, PoolKey memory key, int24 tick)
        public returns (uint256 tokens, uint256 quote)
    {
        uint256 withdrawnQuote;
        while (b.active.length != 0 && tick >= b.nearestTick + key.tickSpacing) {
            uint256 id = b.idPlusOne[b.nearestTick] - 1;
            Wall storage w = b.walls[id];
            (BalanceDelta d,) = _modify(manager, key, w.lower, -int256(uint256(w.liquidity)));
            uint256 absorbed = _positive(d.amount1());
            uint256 fees = _positive(d.amount0());
            uint256 released = fees + w.idleQuote;
            tokens += absorbed;
            withdrawnQuote += fees;
            quote += released;
            b.idleQuote -= w.idleQuote;
            w.idleQuote = 0;
            w.liquidity = 0;
            _removeActive(b, id);
            emit WallAbsorbed(id, absorbed, released);
        }
        if (tokens != 0) manager.mint(address(this), key.currency1.toId(), tokens);
        if (withdrawnQuote != 0) manager.mint(address(this), key.currency0.toId(), withdrawnQuote);
    }

    function amounts(Book storage b, uint160 sqrtP, int24 spacing)
        public view returns (uint256 quote, uint256 tokens)
    {
        for (uint256 i; i < b.active.length; i++) {
            Wall storage w = b.walls[b.active[i]];
            (uint256 a0, uint256 a1) = BandLib.amountsForLiquidity(sqrtP, w.lower, w.lower + spacing, w.liquidity);
            quote += a0;
            tokens += a1;
        }
    }

    function _removeActive(Book storage b, uint256 id) private {
        uint256 index = b.walls[id].activeIndex - 1;
        uint256 lastId = b.active[b.active.length - 1];
        b.active[index] = lastId;
        b.walls[lastId].activeIndex = uint32(index + 1);
        b.active.pop();
        b.walls[id].activeIndex = 0;
        uint256 bitIndex = uint256(int256(b.walls[id].lower) + 887_270) / 10;
        uint256 word = bitIndex >> 8;
        b.tickWords[word] &= ~(uint256(1) << (bitIndex & 255));
        if (b.tickWords[word] == 0) {
            uint256 group = word >> 8;
            b.wordGroups[group] &= ~(uint256(1) << (word & 255));
            if (b.wordGroups[group] == 0) b.groups &= ~(uint256(1) << group);
        }
        _nearest(b);
    }

    function _addActive(Book storage b, uint256 id) private {
        Wall storage w = b.walls[id];
        b.active.push(id);
        w.activeIndex = uint32(b.active.length);
        uint256 bitIndex = uint256(int256(w.lower) + 887_270) / 10;
        uint256 word = bitIndex >> 8;
        uint256 group = word >> 8;
        b.tickWords[word] |= uint256(1) << (bitIndex & 255);
        b.wordGroups[group] |= uint256(1) << (word & 255);
        b.groups |= uint256(1) << group;
        if (b.active.length == 1 || w.lower < b.nearestTick) b.nearestTick = w.lower;
    }

    function _nearest(Book storage b) private {
        if (b.groups == 0) {
            b.nearestTick = type(int24).max;
            return;
        }
        uint256 group = BitMath.leastSignificantBit(b.groups);
        uint256 word = (group << 8) | BitMath.leastSignificantBit(b.wordGroups[group]);
        uint256 bitIndex = (word << 8) | BitMath.leastSignificantBit(b.tickWords[word]);
        b.nearestTick = int24(int256(bitIndex * 10) - 887_270);
    }

    function _modify(IPoolManager manager, PoolKey memory key, int24 lower, int256 delta)
        private returns (BalanceDelta d, BalanceDelta fees)
    {
        (d, fees) = manager.modifyLiquidity(key, ModifyLiquidityParams({
            tickLower: lower, tickUpper: lower + key.tickSpacing, liquidityDelta: delta, salt: SALT
        }), "");
    }

    function _positive(int128 value) private pure returns (uint256) {
        return value > 0 ? uint256(uint128(value)) : 0;
    }
}
