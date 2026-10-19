// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Resolution
/// @notice The single source of the numbers that end a bad loan: when a loan is unsafe, the auction floor and
///         price curve, and how a sale or a settle splits between the market, the treasury and the borrower.
///         LoanManager, its views and the tests all call these, so the line, the curve and the splits can
///         never be computed two different ways.
library Resolution {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PRICE_SCALE = 1e18;

    /// @notice True when the debt is above the liquidation line: owed > value * lineBps / 10,000.
    /// @dev The line is rounded down, so a debt exactly on the rounded line is still safe.
    /// @param owed MUSD still owed.
    /// @param usdValue Collateral value in MUSD wei.
    /// @param lineBps The loan's liquidation line in basis points.
    /// @return True when the debt is above the line.
    function isUnsafe(uint256 owed, uint256 usdValue, uint256 lineBps) internal pure returns (bool) {
        return owed > Math.mulDiv(usdValue, lineBps, BPS);
    }

    /// @notice The lowest an auction may sell for (C29): max(start * floorBps / 10,000, min(owed, start)).
    /// @dev Never above the start value while floorBps is at most 10,000, so the curve only ever falls.
    /// @param startValue Collateral value when the auction starts, in MUSD wei.
    /// @param owed MUSD still owed.
    /// @param floorBps Floor share of the start value in basis points.
    /// @return The floor price in MUSD wei.
    function floorPrice(uint256 startValue, uint256 owed, uint256 floorBps) internal pure returns (uint256) {
        return Math.max(Math.mulDiv(startValue, floorBps, BPS), Math.min(owed, startValue));
    }

    /// @notice The auction price after `elapsed` seconds: linear from the start value to the floor over
    ///         `duration`, then flat at the floor.
    /// @dev The drop is rounded down, so the price is rounded up, in favour of the market and the borrower.
    ///      Callers keep floor <= start and duration > 0.
    /// @param startValue Price at the auction's start, in MUSD wei.
    /// @param floor Price the curve falls to, in MUSD wei.
    /// @param elapsed Seconds since the auction started.
    /// @param duration Seconds the curve takes to reach the floor.
    /// @return The price now, in MUSD wei.
    function priceAt(uint256 startValue, uint256 floor, uint256 elapsed, uint256 duration)
        internal
        pure
        returns (uint256)
    {
        if (elapsed >= duration) return floor;
        return startValue - Math.mulDiv(startValue - floor, elapsed, duration);
    }

    /// @notice The penalty on a debt in MUSD: owed * penaltyBps / 10,000, rounded down.
    /// @param owed MUSD still owed.
    /// @param penaltyBps Penalty in basis points.
    /// @return The penalty in MUSD wei.
    function penalty(uint256 owed, uint256 penaltyBps) internal pure returns (uint256) {
        return Math.mulDiv(owed, penaltyBps, BPS);
    }

    /// @notice Splits a sale price (C11): the market min(P, D), the treasury min(penalty, P - min(P, D)), the
    ///         borrower the rest. The three always sum to `price`.
    /// @param price MUSD the buyer paid.
    /// @param owed MUSD still owed on the loan.
    /// @param penaltyBps The auction's penalty in basis points.
    /// @return toMarket MUSD to the loan's market.
    /// @return toTreasury MUSD to the treasury.
    /// @return toBorrower MUSD left for the borrower as a claimable.
    function splitSale(uint256 price, uint256 owed, uint256 penaltyBps)
        internal
        pure
        returns (uint256 toMarket, uint256 toTreasury, uint256 toBorrower)
    {
        toMarket = Math.min(price, owed);
        toTreasury = Math.min(penalty(owed, penaltyBps), price - toMarket);
        toBorrower = price - toMarket - toTreasury;
    }

    /// @notice Splits the BTC a settle received (C12) at `btcPrice` (MUSD per BTC, 18 decimals): the market
    ///         min(received, owed / price rounded up), the treasury min(the rest, penalty / price rounded
    ///         down), the borrower the rest. The three always sum to `received`.
    /// @dev Rounding the market's share up means lenders are never a wei short of the debt's BTC value.
    ///      `btcPrice` must be above zero; LoanManager's price function guarantees it.
    /// @param received BTC measured arriving from veBTC.withdraw.
    /// @param owed MUSD still owed on the loan.
    /// @param penaltyBps The auction's penalty in basis points.
    /// @param btcPrice MUSD per BTC, 18 decimals.
    /// @return toMarket BTC to the loan's market.
    /// @return toTreasury BTC to the treasury.
    /// @return toBorrower BTC left for the borrower as a claimable.
    function splitSettle(uint256 received, uint256 owed, uint256 penaltyBps, uint256 btcPrice)
        internal
        pure
        returns (uint256 toMarket, uint256 toTreasury, uint256 toBorrower)
    {
        toMarket = Math.min(received, Math.mulDiv(owed, PRICE_SCALE, btcPrice, Math.Rounding.Ceil));
        toTreasury = Math.min(received - toMarket, Math.mulDiv(penalty(owed, penaltyBps), PRICE_SCALE, btcPrice));
        toBorrower = received - toMarket - toTreasury;
    }
}
