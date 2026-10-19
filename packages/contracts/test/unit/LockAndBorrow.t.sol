// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Unit tests for lockAndDeposit and lockAndBorrow: a new veBTC lock minted straight into LoanManager for the
// caller (C1), the measured BTC pull and the allowance left at zero (C17), the minted id recorded only once
// LoanManager owns it and it passes the collateral test (C17, C2), every borrow check on the one-call path (C8),
// and the pause on lock creation (C19), on the real CreditMarkets and LoanManager with mocks for veBTC, BTC,
// MUSD and PriceFeed.
// It does NOT cover: Mezo's real veBTC or BTC precompile (test/fork/PassThroughFork.t.sol runs lockAndBorrow
// against the testnet veBTC with a stand-in for the precompile), fee-on-transfer BTC, or lock creation inside
// the randomised invariant run.

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ICreditMarkets} from "../../src/interfaces/ICreditMarkets.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {Quote} from "../../src/libraries/Quote.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";
import {MockVeBTC} from "../utils/MockVeBTC.sol";

contract LockAndBorrowTest is LoanFixture {
    uint256 internal constant LOCK = 1e18;

    function setUp() public override {
        super.setUp();
        btc.mint(alice, 10e18);
        vm.prank(alice);
        btc.approve(address(lm), type(uint256).max);
    }

    /// @dev Lock length that ends the lock exactly on `maturity`, given veBTC rounds the end down to a week.
    function _until(uint64 maturity) internal view returns (uint256) {
        return uint256(maturity) - block.timestamp;
    }

    function _lockAndBorrow(address who, uint256 amount, uint256 duration, uint64 maturity, uint256 offerId, uint128 principal)
        internal
        returns (uint256 tokenId, uint256 borrowed, uint256 face)
    {
        (uint256[] memory ids, uint128[] memory amounts) = _one(offerId, principal);
        vm.prank(who);
        return lm.lockAndBorrow(amount, duration, maturity, ids, amounts, 5_000);
    }

    function test_LockAndDeposit_MintsToLoanManagerForTheCaller() public {
        uint256 expectedId = ve.nextTokenId();
        uint256 aliceBefore = btc.balanceOf(alice);

        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.Deposited(expectedId, alice);
        vm.prank(alice);
        uint256 tokenId = lm.lockAndDeposit(LOCK, _until(m2));

        assertEq(tokenId, expectedId);
        assertEq(ve.ownerOf(tokenId), address(lm), "minted straight into custody");
        assertEq(lm.positionOf(tokenId).borrower, alice, "C1: the caller is the borrower");
        (uint256 amount, uint256 end, bool isPermanent) = lm.lockOf(tokenId);
        assertEq(amount, LOCK);
        assertEq(end, m2);
        assertFalse(isPermanent);
        assertEq(aliceBefore - btc.balanceOf(alice), LOCK, "pulled exactly the amount");
        assertEq(btc.balanceOf(address(ve)), LOCK, "all of it locked");
        assertEq(btc.balanceOf(address(lm)), 0);
        assertEq(btc.allowance(address(lm), address(ve)), 0, "C17: no allowance left");
    }

    function test_C17_NoBtcAllowanceLeftEvenWhenVeBTCSpendsLess() public {
        ve.setLockPullBps(5_000);
        vm.prank(alice);
        lm.lockAndDeposit(LOCK, _until(m2));
        assertEq(btc.allowance(address(lm), address(ve)), 0, "C17: reset to zero whatever veBTC spent");
        assertEq(btc.balanceOf(address(lm)), LOCK / 2, "the unspent half is stray BTC");
        assertEq(lm.totalClaimableBtc(), 0, "C18: and credited to nobody");
    }

    function test_C17_RecordsTheIdOnlyOnceLoanManagerOwnsIt() public {
        uint256 expectedId = ve.nextTokenId();
        ve.setMintRecipientOverride(bob);
        uint256 aliceBefore = btc.balanceOf(alice);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.CustodyCheckFailed.selector, expectedId));
        vm.prank(alice);
        lm.lockAndDeposit(LOCK, _until(m2));
        assertEq(lm.positionOf(expectedId).borrower, address(0), "nothing recorded");
        assertEq(btc.balanceOf(alice), aliceBefore, "and the BTC never left");
    }

    function test_C2_LockAndDepositRefusesAMintThatIsNotNormalEscrow() public {
        uint256 expectedId = ve.nextTokenId();
        ve.setMintEscrowType(2);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.CollateralNotAccepted.selector, expectedId));
        vm.prank(alice);
        lm.lockAndDeposit(LOCK, _until(m2));
    }

    function test_C1_TheCallerIsTheOnlyBorrower() public {
        vm.prank(alice);
        uint256 tokenId = lm.lockAndDeposit(LOCK, _until(m2));
        (uint256[] memory ids, uint128[] memory amounts) = _one(offerM1, 1_000e18);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotBorrower.selector, tokenId));
        lm.borrow(tokenId, m1, ids, amounts, 5_000);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotBorrower.selector, tokenId));
        lm.withdrawCollateral(tokenId);
        vm.stopPrank();

        vm.prank(alice);
        lm.withdrawCollateral(tokenId);
        assertEq(ve.ownerOf(tokenId), alice, "the position goes back to whoever locked it");
    }

    function test_LockAndBorrow_OpensALoanInOneCall() public {
        uint256 expectedId = ve.nextTokenId();
        (uint256 expectedFace,,) = Quote.quote(PRINCIPAL, APR, m2 - block.timestamp, FEE_SHARE);
        uint256 musdBefore = musd.balanceOf(alice);

        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.Deposited(expectedId, alice);
        vm.expectEmit(true, true, true, true, address(lm));
        emit ILoanManager.Borrowed(expectedId, alice, m2, PRINCIPAL, expectedFace);
        (uint256 tokenId, uint256 principal, uint256 face) =
            _lockAndBorrow(alice, LOCK, _until(m2), m2, offerM2, PRINCIPAL);

        assertEq(tokenId, expectedId);
        assertEq(principal, PRINCIPAL);
        assertEq(face, expectedFace);
        assertEq(musd.balanceOf(alice) - musdBefore, PRINCIPAL, "principal paid to the caller");
        ILoanManager.Loan memory loan = lm.loanOf(tokenId);
        assertEq(uint8(loan.state), uint8(ILoanManager.LoanState.Active));
        assertEq(loan.maturity, m2);
        assertEq(loan.face, face);
        assertEq(cm.marketOf(m2).openLoans, 1);
        assertEq(cm.marketOf(m2).faceTotal, face, "C8: units equal face");
        assertEq(btc.allowance(address(lm), address(ve)), 0);
    }

    function test_C8_LockAndBorrowRunsEveryBorrowCheck() public {
        uint256 idBefore = ve.nextTokenId();
        uint256 btcBefore = btc.balanceOf(alice);

        vm.expectRevert(abi.encodeWithSelector(ILoanManager.MaturityAfterLockEnd.selector, m3, uint256(m2)));
        _lockAndBorrow(alice, LOCK, _until(m2), m3, offerM3, 1_000e18);

        uint256 maxFace = 0.1e18 * PRICE / 1e18 * MAX_LTV / 10_000;
        (uint256 tooBig,,) = Quote.quote(4_000e18, APR, m2 - block.timestamp, FEE_SHARE);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LtvTooHigh.selector, tooBig, maxFace));
        _lockAndBorrow(alice, 0.1e18, _until(m2), m2, offerM2, 4_000e18);

        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.WrongMaturity.selector, offerM1, m1, m2));
        _lockAndBorrow(alice, LOCK, _until(m2), m2, offerM1, 1_000e18);

        vm.expectRevert(abi.encodeWithSelector(ILoanManager.BelowMinLoan.selector, MIN_LOAN - 1, MIN_LOAN));
        _lockAndBorrow(alice, LOCK, _until(m2), m2, offerM2, MIN_LOAN - 1);

        feed.setStale(true);
        vm.expectRevert(ILoanManager.PriceUnavailable.selector);
        _lockAndBorrow(alice, LOCK, _until(m2), m2, offerM2, 1_000e18);

        assertEq(ve.nextTokenId(), idBefore, "a failed borrow leaves no lock behind");
        assertEq(btc.balanceOf(alice), btcBefore, "and takes no BTC");
    }

    function test_C19_LockCreationIsPausedLikeBorrow() public {
        vm.prank(guardian);
        lm.setBorrowsPaused(true);
        vm.expectRevert(ILoanManager.BorrowsPaused.selector);
        vm.prank(alice);
        lm.lockAndDeposit(LOCK, _until(m2));
        vm.expectRevert(ILoanManager.BorrowsPaused.selector);
        _lockAndBorrow(alice, LOCK, _until(m2), m2, offerM2, 1_000e18);

        vm.prank(owner);
        lm.setBorrowsPaused(false);
        vm.prank(alice);
        lm.lockAndDeposit(LOCK, _until(m2));
    }

    function test_RevertWhen_LockAndDepositInputsAreBad() public {
        vm.startPrank(alice);
        vm.expectRevert(ILoanManager.ZeroAmount.selector);
        lm.lockAndDeposit(0, _until(m2));
        vm.expectRevert(MockVeBTC.LockDurationTooLong.selector);
        lm.lockAndDeposit(LOCK, 5 weeks);
        vm.expectRevert(MockVeBTC.LockDurationNotInFuture.selector);
        lm.lockAndDeposit(LOCK, 1 hours);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(lm), 0, LOCK)
        );
        vm.prank(bob);
        lm.lockAndDeposit(LOCK, _until(m2));
    }

    function test_LockAndBorrow_FullCycleBackToTheBorrower() public {
        (uint256 tokenId,, uint256 face) = _lockAndBorrow(alice, LOCK, _until(m2), m2, offerM2, PRINCIPAL);
        vm.startPrank(alice);
        lm.repay(tokenId, face);
        lm.withdrawCollateral(tokenId);
        vm.stopPrank();
        assertEq(ve.ownerOf(tokenId), alice);
        assertEq(cm.marketOf(m2).collectedMusd, face);
        assertEq(cm.marketOf(m2).openLoans, 0);
    }
}
