// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Unit and fuzz tests for the fixes to the 2026-10-20 audit: a sale is priced on a fresh value, so the market always
// gets at least min(debt, value at the sale) (M-01, C29); each loan keeps the auction terms it opened or rolled
// with (L-01, C19); a pause stops only the cash-out part of a roll (L-02, C19); the treasury's penalty waits as
// a claimable, so no treasury address can block a sale or settle (C11, C12, C28); and ownership can never be
// renounced (C19). Runs on the real CreditMarkets and LoanManager with the LoanFixture mocks.
// It does NOT cover: real Mezo contracts or the live oracle (test/fork), the real MUSD's own list of refused
// recipients (the mock refuses whichever address it is told to), or randomised sequences (CreditInvariants.t.sol).

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICreditMarkets} from "../../src/interfaces/ICreditMarkets.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {Resolution} from "../../src/libraries/Resolution.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";
import {MockMUSD} from "../utils/MockMUSD.sol";

contract AuditFixesTest is LoanFixture {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant TOKEN_B = 8;

    function _buy() internal returns (uint256) {
        vm.prank(buyer);
        return lm.purchase(TOKEN, type(uint256).max, vm.getBlockTimestamp());
    }

    /// @dev The auction's own snapshotted curve at this moment, before any fresh-value floor.
    function _curveNow(uint256 tokenId) internal view returns (uint256) {
        ILoanManager.Auction memory a = lm.auctionOf(tokenId);
        return Resolution.priceAt(a.startValue, a.floorPrice, vm.getBlockTimestamp() - a.startTime, a.duration);
    }

    function _roll(uint64 newMaturity, uint256 offerId, uint128 amount, uint256 maxTopUp) internal {
        (uint256[] memory ids, uint128[] memory amounts) = _one(offerId, amount);
        vm.prank(alice);
        lm.roll(TOKEN, newMaturity, ids, amounts, 5_000, maxTopUp);
    }

    function _pause() internal {
        vm.prank(guardian);
        lm.setBorrowsPaused(true);
    }

    /// @dev The price at the start and at the sale are fuzzed through the LTV each one sets. An LTV auction must
    ///      be over its 65% line at both moments, or it would not start or would refuse the sale.
    function testFuzz_M01_SaleNeverPaysMarketBelowMinOfDebtAndValueNow(
        uint256 ltvAtStart,
        uint256 ltvAtSale,
        uint256 elapsed,
        bool overdue
    ) public {
        uint256 owed = _openLoan();
        uint256 lowest = overdue ? 1_000 : 6_600;
        if (overdue) vm.warp(m1 + 1);
        feed.setPrice(_priceAtLtv(TOKEN, bound(ltvAtStart, lowest, 30_000)));
        lm.startAuction(TOKEN);
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, 10 days));
        feed.setPrice(_priceAtLtv(TOKEN, bound(ltvAtSale, lowest, 30_000)));

        uint256 valueNow = _usdValue(TOKEN);
        uint256 curve = _curveNow(TOKEN);
        uint256 quoted = lm.auctionPrice(TOKEN);
        uint256 paid = _buy();

        assertEq(paid, quoted, "auctionPrice is what purchase charged");
        assertGe(paid, curve, "never below the auction's own curve");
        assertGe(cm.marketOf(m1).collectedMusd, Math.min(owed, valueNow), "C29: market below min(debt, value at sale)");
    }

    function test_M01_ReboundRaisesTheFloorToTheCurrentValue() public {
        uint256 owed = _openLoan();
        vm.warp(m1 + 1);
        uint256 crashPrice = _priceAtLtv(TOKEN, 12_500);
        feed.setPrice(crashPrice);
        lm.startAuction(TOKEN);
        assertLt(lm.auctionOf(TOKEN).startValue, owed, "the overdue auction starts underwater");

        vm.warp(m1 + 10 days);
        feed.setPrice(2 * crashPrice);
        uint256 floorNow = _usdValue(TOKEN) * FLOOR / BPS;
        assertGt(floorNow, owed, "70% of the rebounded value is above the debt");

        uint256 paid = _buy();
        assertEq(paid, floorNow, "the floor follows the value at the sale");
        assertEq(cm.marketOf(m1).collectedMusd, owed, "the market is paid the whole debt");
        assertEq(lm.claimableMusd(alice), paid - owed - owed * PENALTY / BPS, "the borrower keeps the rest");
    }

    function test_M01_FallAfterStartStillPaysTheCurve() public {
        uint256 owed = _openLoan();
        _makeUnsafe(TOKEN);
        lm.startAuction(TOKEN);
        vm.warp(vm.getBlockTimestamp() + DURATION / 2);
        feed.setPrice(_priceAtLtv(TOKEN, 8_000));
        uint256 curve = _curveNow(TOKEN);
        assertGt(curve, Resolution.floorPrice(_usdValue(TOKEN), owed, FLOOR), "the curve is above today's floor");

        uint256 paid = _buy();
        assertEq(paid, curve, "a fall after the start leaves the curve in charge");
        assertEq(cm.marketOf(m1).collectedMusd, owed);
    }

    function test_M01_StalePriceBlocksAnOverduePurchase() public {
        _openLoan();
        vm.warp(m1 + 1);
        lm.startAuction(TOKEN);
        feed.setStale(true);

        vm.expectRevert(ILoanManager.PriceUnavailable.selector);
        lm.auctionPrice(TOKEN);
        vm.expectRevert(ILoanManager.PriceUnavailable.selector);
        _buy();
        assertEq(uint8(lm.loanOf(TOKEN).state), uint8(ILoanManager.LoanState.Auction), "still for sale");
    }

    function test_L01_OpenLoanKeepsItsAuctionTerms() public {
        _openLoan();
        ve.mint(bob, TOKEN_B, LOCK_BTC, m3, false);
        _deposit(bob, TOKEN_B);
        (, uint256 faceB) = _borrow(bob, TOKEN_B, m1, offerM1, 1_000e18);

        vm.startPrank(owner);
        lm.setRiskParams(1_000, 4_900);
        lm.setAuctionParams(1_000, 5_000, 1 hours);
        vm.stopPrank();

        ILoanManager.Loan memory open = lm.loanOf(TOKEN);
        assertEq(open.liqLtvBps, LIQ_LTV);
        assertEq(open.auctionFloorBps, FLOOR);
        assertEq(open.penaltyBps, PENALTY);
        assertEq(open.auctionDuration, DURATION);

        (uint256[] memory ids, uint128[] memory amounts) = _one(offerM2, uint128(faceB));
        vm.prank(bob);
        lm.roll(TOKEN_B, m2, ids, amounts, 5_000, 0);
        ILoanManager.Loan memory rolled = lm.loanOf(TOKEN_B);
        assertEq(rolled.maxLtvBps, 1_000, "a roll after the change takes the new terms");
        assertEq(rolled.liqLtvBps, 4_900);
        assertEq(rolled.auctionFloorBps, 5_000);
        assertEq(rolled.penaltyBps, 1_000);
        assertEq(rolled.auctionDuration, 1 hours);

        vm.warp(m1 + 1);
        lm.startAuction(TOKEN);
        ILoanManager.Auction memory a = lm.auctionOf(TOKEN);
        assertEq(a.floorPrice, Resolution.floorPrice(a.startValue, lm.owedOf(TOKEN), FLOOR), "the open loan's 70%");
        assertEq(a.penaltyBps, PENALTY, "the open loan's 5% penalty");
        assertEq(a.duration, DURATION, "the open loan's 72 hours");

        vm.warp(m2 + 1);
        lm.startAuction(TOKEN_B);
        ILoanManager.Auction memory b = lm.auctionOf(TOKEN_B);
        assertEq(b.floorPrice, Resolution.floorPrice(b.startValue, lm.owedOf(TOKEN_B), 5_000), "the rolled loan's 50%");
        assertEq(b.penaltyBps, 1_000);
        assertEq(b.duration, 1 hours);
    }

    function test_L02_RollCashOutRevertsWhilePaused() public {
        uint256 face = _openLoan();
        _pause();
        uint256 aliceBefore = musd.balanceOf(alice);

        vm.expectRevert(ILoanManager.BorrowsPaused.selector);
        _roll(m2, offerM2, 31_000e18, 0);
        assertEq(musd.balanceOf(alice), aliceBefore, "nothing was paid out");
        assertEq(lm.loanOf(TOKEN).maturity, m1, "the old loan is untouched");
        assertEq(lm.owedOf(TOKEN), face);

        vm.prank(guardian);
        lm.setBorrowsPaused(false);
        _roll(m2, offerM2, 31_000e18, 0);
        assertEq(musd.balanceOf(alice) - aliceBefore, 31_000e18 - face, "the same cash-out runs once resumed");
    }

    function test_L02_RefinanceAndTopUpRollsWorkWhilePaused() public {
        uint256 face = _openLoan();
        _pause();
        uint256 aliceBefore = musd.balanceOf(alice);

        _roll(m2, offerM2, uint128(face), 0);
        assertEq(lm.loanOf(TOKEN).maturity, m2, "an exact refinance runs while paused");
        assertEq(musd.balanceOf(alice), aliceBefore);

        uint256 owedAtM2 = lm.owedOf(TOKEN);
        _roll(m3, offerM3, 20_000e18, type(uint256).max);
        assertEq(lm.loanOf(TOKEN).maturity, m3, "a top-up roll runs while paused");
        assertEq(aliceBefore - musd.balanceOf(alice), owedAtM2 - 20_000e18, "the borrower added the shortfall");
    }

    function test_TreasuryThatRefusesMusdCannotBlockAPurchase() public {
        uint256 owed = _openLoan();
        vm.warp(m1 + 1);
        lm.startAuction(TOKEN);
        address refusing = makeAddr("refusingTreasury");
        musd.setRefused(refusing, true);
        vm.prank(owner);
        cm.setTreasury(refusing);

        _buy();
        assertEq(ve.ownerOf(TOKEN), buyer, "the sale went through");
        assertEq(cm.marketOf(m1).collectedMusd, owed);
        assertEq(lm.claimableMusd(refusing), owed * PENALTY / BPS, "the penalty waits as a claimable");

        // The refusal is real: only the treasury's own collection fails.
        vm.expectRevert(abi.encodeWithSelector(MockMUSD.RecipientRefused.selector, refusing));
        vm.prank(refusing);
        lm.claim();
    }

    function test_TreasuryCollectsTheMusdPenaltyThroughClaim() public {
        uint256 owed = _openLoan();
        vm.warp(m1 + 1);
        lm.startAuction(TOKEN);
        uint256 treasuryBefore = musd.balanceOf(treasury);
        _buy();
        uint256 penalty = owed * PENALTY / BPS;
        assertEq(musd.balanceOf(treasury), treasuryBefore, "nothing is sent to the treasury during the sale");
        assertEq(lm.claimableMusd(treasury), penalty);

        vm.expectEmit(true, false, false, true, address(lm));
        emit ILoanManager.Claimed(treasury, penalty, 0);
        vm.prank(treasury);
        (uint256 musdOut, uint256 btcOut) = lm.claim();
        assertEq(musdOut, penalty);
        assertEq(btcOut, 0);
        assertEq(musd.balanceOf(treasury) - treasuryBefore, penalty);
        assertEq(musd.balanceOf(address(lm)), lm.totalClaimableMusd(), "only the borrower's share is left");
    }

    function test_TreasuryCollectsTheBtcPenaltyThroughClaim() public {
        uint256 owed = _openLoan();
        vm.warp(m1 + 1);
        lm.startAuction(TOKEN);
        vm.warp(m3 + 1);
        lm.settle(TOKEN);
        uint256 penaltyBtc = (owed * PENALTY / BPS) * 1e18 / PRICE;
        assertEq(btc.balanceOf(treasury), 0, "nothing is sent to the treasury during the settle");
        assertEq(lm.claimableBtc(treasury), penaltyBtc);
        assertEq(btc.balanceOf(address(lm)), lm.totalClaimableBtc(), "LoanManager holds exactly the claimables");

        vm.prank(treasury);
        (uint256 musdOut, uint256 btcOut) = lm.claim();
        assertEq(musdOut, 0);
        assertEq(btcOut, penaltyBtc);
        assertEq(btc.balanceOf(treasury), penaltyBtc);
    }

    function test_RenounceOwnershipRevertsOnBothContracts() public {
        address[2] memory callers = [owner, bob];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(ILoanManager.RenounceDisabled.selector);
            vm.prank(callers[i]);
            lm.renounceOwnership();
            vm.expectRevert(ICreditMarkets.RenounceDisabled.selector);
            vm.prank(callers[i]);
            cm.renounceOwnership();
        }
        assertEq(lm.owner(), owner, "LoanManager keeps its owner");
        assertEq(cm.owner(), owner, "CreditMarkets keeps its owner");
    }
}
