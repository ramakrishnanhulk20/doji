// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Audit finding M-01. An auction's curve is fixed at its start value and never rises. When the start value is
// below the debt the curve is flat at that value, and it stays on sale at that price until settle, which can be
// weeks away. If Bitcoin then recovers, whoever buys first pays the old price: the market is paid less than the
// debt even though the collateral covers the debt at the moment of the sale. The borrower can be that buyer,
// which turns a default into a cheap buy-back. Both tests assert what C29 promises ("a loan whose collateral
// still covers its debt never leaves a shortfall through an auction") and fail on today's code.
// It does NOT cover: real Mezo contracts, or a recovery large enough to make an LTV auction safe again (that
// case is cancelled and restarted correctly, see Resolution.t.sol test_Finding2).

import {console} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";

contract AuctionNeverReanchorsTest is LoanFixture {
    function _collected() internal view returns (uint256) {
        return cm.marketOf(m1).collectedMusd;
    }

    /// LTV auction: a crash puts the loan underwater, the price comes back while the loan is still over its
    /// line, and the borrower buys the position back for less than the debt.
    function test_M01_BorrowerBuysBackBelowDebtAfterRecovery() public {
        _openLoan();
        uint256 owed = lm.owedOf(TOKEN);

        // Bitcoin falls until the debt is 125% of the collateral, and the auction starts there.
        feed.setPrice(_priceAtLtv(TOKEN, 12_500));
        lm.startAuction(TOKEN);
        uint256 startValue = lm.auctionOf(TOKEN).startValue;
        assertLt(startValue, owed, "auction starts underwater");
        assertEq(lm.auctionOf(TOKEN).floorPrice, startValue, "curve is flat at the start value");

        // An hour later Bitcoin is back to an 80% LTV: the collateral covers the debt 1.25 times, still unsafe.
        vm.warp(block.timestamp + 1 hours);
        feed.setPrice(_priceAtLtv(TOKEN, 8_000));
        (, uint256 valueNow) = lm.collateralValue(TOKEN);
        assertTrue(lm.isUnsafe(TOKEN), "still above the 65% line, so it cannot be cancelled");
        assertGt(valueNow, owed, "collateral covers the debt at the time of sale");

        uint256 aliceBefore = musd.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = lm.purchase(TOKEN, type(uint256).max, block.timestamp);

        console.log("debt owed (MUSD wei)            ", owed);
        console.log("collateral value at sale         ", valueNow);
        console.log("price paid by the borrower       ", paid);
        console.log("market shortfall against the debt", owed - _collected());
        console.log("borrower saved versus repaying   ", owed - (aliceBefore - musd.balanceOf(alice)));
        assertEq(ve.ownerOf(TOKEN), alice, "the borrower has the position back");

        assertGe(_collected(), Math.min(owed, valueNow), "C29: market paid less than min(debt, value) at sale");
    }

    /// Overdue auction: no price is read at purchase, so the stale curve sells even after Bitcoin has doubled.
    function test_M01_OverdueAuctionSellsAtStaleValueAfterBtcDoubles() public {
        _openLoan();
        uint256 owed = lm.owedOf(TOKEN);

        vm.warp(m1 + 1);
        feed.setPrice(_priceAtLtv(TOKEN, 12_500));
        lm.startAuction(TOKEN);
        uint256 startValue = lm.auctionOf(TOKEN).startValue;
        assertLt(startValue, owed, "overdue auction starts underwater");

        // Ten days later, long past the 72-hour floor time, Bitcoin is worth twice the debt. The lock ends at m3,
        // so settle is still out of reach and the position is still for sale at the old price.
        vm.warp(m1 + 10 days);
        feed.setPrice(_priceAtLtv(TOKEN, 5_000));
        (, uint256 valueNow) = lm.collateralValue(TOKEN);

        vm.prank(buyer);
        uint256 paid = lm.purchase(TOKEN, type(uint256).max, block.timestamp);

        console.log("debt owed (MUSD wei)            ", owed);
        console.log("collateral value at sale         ", valueNow);
        console.log("price paid                       ", paid);
        console.log("market shortfall against the debt", owed - _collected());
        console.log("borrower claimable               ", lm.claimableMusd(alice));

        assertGe(_collected(), Math.min(owed, valueNow), "C29: market paid less than min(debt, value) at sale");
    }
}
