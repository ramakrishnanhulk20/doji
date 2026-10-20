// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Unit tests for roll: one call that repays a loan's market in full from new offers at a later date, paying
// any excess to the borrower or pulling a capped top-up, on the real CreditMarkets with mocks. It does NOT
// cover: rolling a real mainnet position (test/fork/ResolutionFork.t.sol), auctions and settle
// (Resolution.t.sol), randomised roll sequences (CreditInvariants.t.sol), or fee-on-transfer MUSD.

import {ICreditMarkets} from "../../src/interfaces/ICreditMarkets.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {LockReader} from "../../src/libraries/LockReader.sol";
import {Quote} from "../../src/libraries/Quote.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";

contract RollTest is LoanFixture {
    function _roll(address who, uint64 newMaturity, uint256 offerId, uint128 amount, uint256 maxTopUp)
        internal
        returns (uint256 principal, uint256 face)
    {
        (uint256[] memory ids, uint128[] memory amounts) = _one(offerId, amount);
        vm.prank(who);
        return lm.roll(TOKEN, newMaturity, ids, amounts, 5_000, maxTopUp);
    }

    function test_Roll_PaysExcessToBorrower() public {
        uint256 oldFace = _openLoan();
        uint128 newPrincipal = 31_000e18;
        (uint256 newFace,,) = Quote.quote(newPrincipal, APR, m2 - block.timestamp, FEE_SHARE);
        uint256 excess = newPrincipal - oldFace;
        uint256 aliceBefore = musd.balanceOf(alice);

        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.LoanClosed(TOKEN, m1);
        vm.expectEmit(true, true, true, true, address(lm));
        emit ILoanManager.Borrowed(TOKEN, alice, m2, newPrincipal, newFace);
        vm.expectEmit(true, true, true, true, address(lm));
        emit ILoanManager.Rolled(TOKEN, m1, m2, oldFace, excess, 0);
        (uint256 principal, uint256 face) = _roll(alice, m2, offerM2, newPrincipal, 0);

        assertEq(principal, newPrincipal);
        assertEq(face, newFace);
        assertEq(musd.balanceOf(alice) - aliceBefore, excess, "excess paid out");
        assertEq(musd.balanceOf(address(lm)), 0, "nothing left behind");
        ICreditMarkets.Market memory oldMarket = cm.marketOf(m1);
        assertEq(oldMarket.collectedMusd, oldFace, "old market repaid in full");
        assertEq(oldMarket.openLoans, 0);
        assertEq(cm.marketOf(m2).openLoans, 1);
        assertEq(cm.marketOf(m2).faceTotal, newFace);
        ILoanManager.Loan memory loan = lm.loanOf(TOKEN);
        assertEq(loan.maturity, m2);
        assertEq(loan.face, newFace);
        assertEq(loan.repaid, 0);
        assertEq(uint8(loan.state), uint8(ILoanManager.LoanState.Active));
    }

    function test_Roll_PullsTopUp() public {
        uint256 oldFace = _openLoan();
        uint128 newPrincipal = 20_000e18;
        uint256 topUp = oldFace - newPrincipal;
        uint256 aliceBefore = musd.balanceOf(alice);

        vm.expectEmit(true, true, true, true, address(lm));
        emit ILoanManager.Rolled(TOKEN, m1, m2, oldFace, 0, topUp);
        _roll(alice, m2, offerM2, newPrincipal, topUp);

        assertEq(aliceBefore - musd.balanceOf(alice), topUp, "top-up pulled from the borrower");
        assertEq(cm.marketOf(m1).collectedMusd, oldFace);
        assertEq(musd.balanceOf(address(lm)), 0);
    }

    function test_Roll_ExactCoverMovesNoExtraMusd() public {
        uint256 oldFace = _openLoan();
        uint256 aliceBefore = musd.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(lm));
        emit ILoanManager.Rolled(TOKEN, m1, m2, oldFace, 0, 0);
        _roll(alice, m2, offerM2, uint128(oldFace), 0);
        assertEq(musd.balanceOf(alice), aliceBefore);
    }

    function test_Roll_PartlyRepaidLoanOwesOnlyTheRest() public {
        uint256 oldFace = _openLoan();
        vm.prank(alice);
        lm.repay(TOKEN, 10_000e18);
        uint256 aliceBefore = musd.balanceOf(alice);
        _roll(alice, m2, offerM2, 25_000e18, 0);
        assertEq(musd.balanceOf(alice) - aliceBefore, 25_000e18 - (oldFace - 10_000e18));
        assertEq(cm.marketOf(m1).collectedMusd, oldFace);
    }

    function test_RevertWhen_RollTopUpTooHigh() public {
        uint256 oldFace = _openLoan();
        uint256 topUp = oldFace - 20_000e18;
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.TopUpTooHigh.selector, topUp, topUp - 1));
        _roll(alice, m2, offerM2, 20_000e18, topUp - 1);
    }

    function test_RevertWhen_RollMaturityNotLater() public {
        _openLoan();
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.MaturityNotLater.selector, m1, m1));
        _roll(alice, m1, offerM1, 1_000e18, 0);
        uint64 earlier = m1 - uint64(WEEK);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.MaturityNotLater.selector, m1, earlier));
        _roll(alice, earlier, offerM1, 1_000e18, 0);
    }

    function test_RevertWhen_RollAfterMaturity() public {
        _openLoan();
        vm.warp(m1 + 1);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LoanOverdue.selector, TOKEN));
        _roll(alice, m2, offerM2, 31_000e18, 0);
    }

    function test_Roll_AllowedAtTheMaturityInstant() public {
        _openLoan();
        vm.warp(m1);
        _roll(alice, m2, offerM2, 31_000e18, 0);
        assertEq(lm.loanOf(TOKEN).maturity, m2);
    }

    function test_C19_RollWorksWhileBorrowsPaused() public {
        uint256 oldFace = _openLoan();
        vm.startPrank(guardian);
        lm.setBorrowsPaused(true);
        cm.setOffersPaused(true);
        vm.stopPrank();

        // An exact refinance pays nothing out, so it is not new borrowing and the pause lets it through.
        uint256 aliceBefore = musd.balanceOf(alice);
        _roll(alice, m2, offerM2, uint128(oldFace), 0);
        assertEq(lm.loanOf(TOKEN).maturity, m2, "rolled while paused");
        assertEq(musd.balanceOf(alice), aliceBefore, "no MUSD left the protocol");

        ve.mint(bob, 8, LOCK_BTC, m3, false);
        _deposit(bob, 8);
        vm.expectRevert(ILoanManager.BorrowsPaused.selector);
        _borrow(bob, 8, m2, offerM2, 1_000e18);
    }

    function test_C4_RollOnlyByTheBorrower() public {
        _openLoan();
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotBorrower.selector, TOKEN));
        _roll(bob, m2, offerM2, 31_000e18, type(uint256).max);
    }

    function test_RevertWhen_RollWithoutActiveLoan() public {
        _deposit(alice, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LoanNotActive.selector, TOKEN));
        _roll(alice, m2, offerM2, 1_000e18, 0);

        _borrow(alice, TOKEN, m1, offerM1, PRINCIPAL);
        _makeUnsafe(TOKEN);
        lm.startAuction(TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LoanNotActive.selector, TOKEN));
        _roll(alice, m2, offerM2, 1_000e18, type(uint256).max);
    }

    function test_C8_RollRunsTheBorrowChecks() public {
        _openLoan();
        uint256 maxFace = uint256(int256(LOCK_BTC)) * PRICE / 1e18 * MAX_LTV / 10_000;
        (uint256 tooBigFace,,) = Quote.quote(32_000e18, APR, m2 - block.timestamp, FEE_SHARE);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LtvTooHigh.selector, tooBigFace, maxFace));
        _roll(alice, m2, offerM2, 32_000e18, 0);

        vm.expectRevert(abi.encodeWithSelector(ILoanManager.BelowMinLoan.selector, MIN_LOAN - 1, MIN_LOAN));
        _roll(alice, m2, offerM2, MIN_LOAN - 1, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.WrongMaturity.selector, offerM3, m3, m2));
        _roll(alice, m2, offerM3, 31_000e18, 0);

        (uint256[] memory ids, uint128[] memory amounts) = _one(offerM2, 31_000e18);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.AprAboveMax.selector, offerM2, APR, APR - 1));
        vm.prank(alice);
        lm.roll(TOKEN, m2, ids, amounts, APR - 1, 0);

        ve.setLock(TOKEN, LOCK_BTC, m2, false);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.MaturityAfterLockEnd.selector, m3, uint256(m2)));
        _roll(alice, m3, offerM3, 31_000e18, 0);
        ve.setLock(TOKEN, LOCK_BTC, m3, false);

        ve.setGrantManager(TOKEN, makeAddr("grantManager"));
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.CollateralNotAccepted.selector, TOKEN));
        _roll(alice, m2, offerM2, 31_000e18, 0);
        ve.setGrantManager(TOKEN, address(0));

        ve.setLock(TOKEN, 0, m3, false);
        vm.expectRevert(LockReader.BadLockAmount.selector);
        _roll(alice, m2, offerM2, 31_000e18, 0);
        ve.setLock(TOKEN, LOCK_BTC, m3, false);

        feed.setStale(true);
        vm.expectRevert(ILoanManager.PriceUnavailable.selector);
        _roll(alice, m2, offerM2, 31_000e18, 0);
        feed.setStale(false);

        ve.forceTransfer(address(lm), bob, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotInCustody.selector, TOKEN));
        _roll(alice, m2, offerM2, 31_000e18, 0);
    }

    function test_Roll_TakesFreshSnapshots() public {
        _openLoan();
        vm.prank(owner);
        lm.setRiskParams(3_000, 6_000);
        _roll(alice, m2, offerM2, 20_000e18, type(uint256).max);
        ILoanManager.Loan memory loan = lm.loanOf(TOKEN);
        assertEq(loan.maxLtvBps, 3_000);
        assertEq(loan.liqLtvBps, 6_000);
    }

    function test_C9_RollClosesTheOldMarketExactlyOnce() public {
        uint256 oldFace = _openLoan();
        _roll(alice, m2, offerM2, 31_000e18, 0);
        assertEq(cm.marketOf(m1).openLoans, 0);

        vm.expectRevert(abi.encodeWithSelector(ILoanManager.MaturityNotLater.selector, m2, m2));
        _roll(alice, m2, offerM2, 1_000e18, 0);
        assertEq(cm.marketOf(m1).openLoans, 0, "a second roll cannot touch the old market");

        vm.warp(m1 + 1);
        cm.finalize(m1);
        vm.startPrank(lender);
        uint256 units = cm.claimUnits(m1);
        (uint256 musdOut,) = cm.redeem(m1, units);
        vm.stopPrank();
        assertEq(musdOut, units, "old lenders paid in full");
        assertLe(units, oldFace);

        uint256 newFace = lm.loanOf(TOKEN).face;
        vm.prank(alice);
        lm.repay(TOKEN, newFace);
        assertEq(cm.marketOf(m2).openLoans, 0);
    }
}
