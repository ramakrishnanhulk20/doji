// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Unit tests for offer yield and the guardian's exit from the vault: each parked offer books its principal times
// the index rise while its MUSD is in the vault, makers are paid only from yield the vault actually delivered, a
// pull-out ends an era in one call and stops its offers' clocks for good, and an index that is unreadable, falls
// or is absurdly large books zero without stopping any principal (threat model C31, C32, C33, C35). Runs on the
// real CreditMarkets and LoanManager with MockSavingsVault standing in for Mezo's MUSDSavingsRate.
// It does NOT cover: the real vault (test/fork/SavingsFork.t.sol); random sequences of these actions
// (CreditInvariants.t.sol); rounding drift between Doji's per-offer maths and the vault's per-holder maths beyond
// what the invariant run reaches; or the keeper's vault health simulation (C35's
// last sentence), which lives in packages/keeper.

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICreditMarkets} from "../../src/interfaces/ICreditMarkets.sol";
import {IMUSDSavingsRate} from "../../src/interfaces/IMUSDSavingsRate.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";
import {MockSavingsVault} from "../utils/MockSavingsVault.sol";

contract OfferYieldTest is LoanFixture {
    uint128 internal constant PARKED = 50_000e18;

    address internal maker2 = makeAddr("maker2");
    address internal donor = makeAddr("donor");
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        musd.mint(maker2, 1_000_000e18);
        vm.prank(maker2);
        musd.approve(address(cm), type(uint256).max);
        address[2] memory payers = [donor, stranger];
        for (uint256 i; i < payers.length; ++i) {
            musd.mint(payers[i], 1_000_000e18);
            vm.prank(payers[i]);
            musd.approve(address(vault), type(uint256).max);
        }
    }

    function _postParked(address maker, uint64 maturity, uint128 amount) internal returns (uint256 id) {
        vm.prank(maker);
        id = cm.postParkedOffer(maturity, APR, amount);
    }

    /// @dev Another sMUSD holder, so CreditMarkets' share of a lump is a real share and not the whole lump.
    function _holdDirectly(uint256 amount) internal {
        vm.prank(stranger);
        vault.deposit(amount);
    }

    function _lump(uint256 amount) internal {
        vm.prank(donor);
        vault.receiveProtocolYield(amount);
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _withdrawYield(address maker, uint256[] memory ids) internal returns (uint256 paid) {
        vm.prank(maker);
        paid = cm.withdrawOfferYield(ids);
    }

    function test_C31_FillBooksTheMakersShareOfALump() public {
        _holdDirectly(50_000e18);
        uint256 id = _postParked(lender, m1, PARKED);
        _lump(1_000e18);
        assertEq(cm.pendingOfferYield(id), 500e18, "half the sMUSD, half the lump");
        assertEq(cm.pendingOfferYield(offerM1), 0, "a plain offer earns nothing");

        _deposit(alice, TOKEN);
        _borrow(alice, TOKEN, m1, id, PRINCIPAL);
        assertEq(cm.yieldOwedOf(lender), 500e18, "the fill booked the share on the whole remainder");
        assertEq(cm.yieldDelivered(), 500e18, "the withdraw delivered CreditMarkets' share");
        assertEq(cm.pendingOfferYield(id), 0, "booked up to now");

        uint256 lenderBefore = musd.balanceOf(lender);
        vm.expectEmit(true, false, false, true, address(cm));
        emit ICreditMarkets.OfferYieldWithdrawn(lender, 500e18, 0);
        assertEq(_withdrawYield(lender, new uint256[](0)), 500e18);
        assertEq(musd.balanceOf(lender) - lenderBefore, 500e18);
        assertEq(cm.yieldOwedOf(lender), 0);
        assertEq(cm.yieldPaid(), cm.yieldDelivered());
    }

    function test_C31_TwoMakersSplitALumpByPrincipalAndTime() public {
        uint256 a = _postParked(lender, m1, 10_000e18);
        _lump(1_000e18);
        uint256 b = _postParked(maker2, m1, 30_000e18);
        _lump(2_000e18);
        // a held all 10,000 sMUSD for the first lump and a quarter of 40,000 for the second; b only the second.
        assertEq(cm.pendingOfferYield(a), 1_500e18);
        assertEq(cm.pendingOfferYield(b), 1_500e18);

        vm.expectCall(address(vault), abi.encodeCall(IMUSDSavingsRate.claimYield, ()), 1);
        assertEq(_withdrawYield(lender, _ids(a)), 1_500e18, "a's share");
        assertEq(cm.yieldDelivered(), 3_000e18, "the claim delivered both lumps");
        assertEq(_withdrawYield(maker2, _ids(b)), 1_500e18, "b's share, from what is already delivered");
        assertEq(cm.yieldPaid(), 3_000e18);
        assertEq(cm.yieldOwedOf(lender) + cm.yieldOwedOf(maker2), 0);
    }

    function test_C32_PullOutLeavesAnOfferOnlyItsFirstLump() public {
        _holdDirectly(50_000e18);
        uint256 id = _postParked(lender, m1, PARKED);
        _lump(1_000e18);
        uint256 endIndex = vault.yieldIndex();

        vm.expectEmit(false, false, false, true, address(cm));
        emit ICreditMarkets.PulledOut(1, PARKED, endIndex);
        vm.prank(guardian);
        cm.pullOut();
        assertEq(cm.parkedPrincipal(), 0);
        assertEq(vault.balanceOf(address(cm)), 0);
        assertFalse(cm.parkingOn());
        assertEq(cm.parkingEra(), 2);
        assertEq(cm.eraEndIndex(1), endIndex);
        assertEq(cm.yieldDelivered(), 500e18, "the pull-out's surplus is delivered yield");

        _lump(1_000e18);
        vm.expectEmit(false, false, false, true, address(cm));
        emit ICreditMarkets.ParkingResumed();
        vm.prank(owner);
        cm.resumeParking();
        uint256 later = _postParked(maker2, m1, PARKED);
        _lump(1_000e18);
        assertEq(cm.pendingOfferYield(id), 500e18, "the first lump only");
        assertEq(cm.pendingOfferYield(later), 500e18, "the new era's offer earns only the third lump");

        _deposit(alice, TOKEN);
        _borrow(alice, TOKEN, m1, id, PRINCIPAL);
        assertEq(cm.yieldOwedOf(lender), 500e18);
        assertEq(cm.pendingOfferYield(id), 0, "its clock stopped for good");
        assertEq(cm.offerOf(id).remaining, PARKED - PRINCIPAL);
        assertEq(cm.parkedPrincipal(), PARKED, "only the new era's offer is in the vault");
    }

    function test_C32_IsInVaultTrueWhileParked_FalseAfterPullOutAndForPlainOffers() public {
        uint256 id = _postParked(lender, m1, PARKED);
        assertTrue(cm.isInVault(id), "a parked offer of the current era is in the vault");
        assertFalse(cm.isInVault(offerM1), "a plain offer never is");
        assertFalse(cm.isInVault(999), "nor is an id with no offer");

        vm.prank(guardian);
        cm.pullOut();
        assertFalse(cm.isInVault(id), "once its era is pulled out its MUSD is plain again");
        assertTrue(cm.offerOf(id).parked, "although the offer itself still reads parked");

        vm.prank(owner);
        cm.resumeParking();
        uint256 later = _postParked(maker2, m1, PARKED);
        assertTrue(cm.isInVault(later), "an offer of the new era is in the vault");
        assertFalse(cm.isInVault(id), "and the earlier era's offer stays out");

        // The view agrees with what a fill actually does: the earlier offer fills without calling the vault.
        _deposit(alice, TOKEN);
        vm.expectCall(address(vault), abi.encodeCall(IMUSDSavingsRate.withdraw, (uint256(PRINCIPAL))), 0);
        _borrow(alice, TOKEN, m1, id, PRINCIPAL);
        assertEq(cm.parkedPrincipal(), PARKED, "only the new era's principal is in the vault");
    }

    function test_C35_IndexOf2Pow200BooksZeroAndPrincipalStillMoves() public {
        uint256 id = _postParked(lender, m1, PARKED);
        _lump(1_000e18);
        assertEq(_withdrawYield(lender, _ids(id)), 1_000e18, "the real lump is paid");

        vault.reportIndex(2 ** 200);
        assertEq(cm.pendingOfferYield(id), 0, "too large to multiply books zero");
        _deposit(alice, TOKEN);
        uint256 aliceBefore = musd.balanceOf(alice);
        _borrow(alice, TOKEN, m1, id, PRINCIPAL);
        assertEq(musd.balanceOf(alice) - aliceBefore, PRINCIPAL, "the fill still works");
        assertEq(_withdrawYield(lender, _ids(id)), 0, "withdrawOfferYield still works and pays nothing more");

        uint256 lenderBefore = musd.balanceOf(lender);
        vm.prank(lender);
        cm.cancelOffer(id);
        assertEq(musd.balanceOf(lender) - lenderBefore, PARKED - PRINCIPAL, "the cancel still works");
        assertEq(cm.yieldOwedOf(lender), 0);
        assertEq(cm.yieldPaid(), 1_000e18, "payouts stopped at the yield delivered");
        assertLe(cm.yieldPaid(), cm.yieldDelivered());
        assertEq(cm.parkedPrincipal(), 0);
    }

    function test_C35_FallingIndexBooksZero() public {
        _holdDirectly(50_000e18);
        _lump(1_000e18);
        uint256 id = _postParked(lender, m1, PARKED);
        uint256 snapshot = vault.yieldIndex();
        _lump(1_000e18);

        vault.reportIndex(snapshot / 2);
        assertEq(cm.pendingOfferYield(id), 0, "a fall books zero");
        _deposit(alice, TOKEN);
        _borrow(alice, TOKEN, m1, id, PRINCIPAL);
        assertEq(cm.yieldOwedOf(lender), 0, "the fill booked zero and did not revert");
        assertEq(cm.yieldDelivered(), 500e18, "the vault still paid its real yield, credited to nobody");
        assertEq(_withdrawYield(lender, _ids(id)), 0);
        vm.prank(lender);
        cm.cancelOffer(id);
        assertEq(cm.parkedPrincipal(), 0);
    }

    function test_C31_IndexThatDipsAndRecoversBooksEachStretchOnce() public {
        uint256 id = _postParked(lender, m1, PARKED);
        _lump(1_000e18);
        uint256 first = cm.pendingOfferYield(id);
        assertGt(first, 0);
        _withdrawYield(lender, _ids(id));

        uint256 high = vault.yieldIndex();
        vault.reportIndex(high / 2);
        _withdrawYield(lender, _ids(id));
        vault.stopReportingIndex();
        assertEq(cm.pendingOfferYield(id), 0, "back at the old high, nothing new to book");

        _lump(1_000e18);
        assertApproxEqAbs(cm.pendingOfferYield(id), first, 2, "only the new lump, not the dip as well");
    }

    function test_C35_UnreadableIndexBooksNothingAndPrincipalStillMoves() public {
        uint256 id = _postParked(lender, m1, PARKED);
        uint256 other = _postParked(lender, m1, 10_000e18);
        _lump(600e18);
        vault.revertOnIndex(true);
        assertEq(cm.pendingOfferYield(id), 0);

        vm.expectRevert(MockSavingsVault.IndexRefused.selector);
        _postParked(lender, m1, PARKED);
        _deposit(alice, TOKEN);
        _borrow(alice, TOKEN, m1, id, PRINCIPAL);
        assertEq(cm.yieldOwedOf(lender), 0, "nothing booked");
        assertEq(cm.yieldDelivered(), 600e18, "the withdraw still delivered");

        vault.revertOnIndex(false);
        assertEq(
            cm.pendingOfferYield(id), (PARKED - PRINCIPAL) / 100, "the snapshot stayed put, so the rest still books"
        );

        vault.revertOnIndex(true);
        vm.prank(guardian);
        cm.pullOut();
        assertEq(cm.parkedPrincipal(), 0, "an unreadable index does not trap the principal");
        assertEq(cm.eraEndIndex(1), 0);
        vault.revertOnIndex(false);
        assertEq(cm.pendingOfferYield(other), 0, "an era ended on an unreadable index books nothing more");
    }

    function test_C31_WithdrawPaysAtMostDeliveredAndLeavesTheRestOwed() public {
        uint256 id = _postParked(lender, m1, PARKED);
        _lump(1_000e18);
        vault.reportIndex(vault.accrualIndex() + 1e18);

        vm.expectEmit(true, false, false, true, address(cm));
        emit ICreditMarkets.OfferYieldWithdrawn(lender, 1_000e18, 50_000e18);
        assertEq(_withdrawYield(lender, _ids(id)), 1_000e18, "only what the vault delivered");
        assertEq(cm.yieldOwedOf(lender), 50_000e18, "the rest stays owed");
        assertEq(cm.yieldPaid(), cm.yieldDelivered());

        vault.stopReportingIndex();
        _lump(500e18);
        assertEq(_withdrawYield(lender, new uint256[](0)), 500e18, "a later delivery pays more of it");
        assertEq(cm.yieldOwedOf(lender), 49_500e18);

        _lump(500e18);
        vault.revertOnClaim(true);
        assertEq(_withdrawYield(lender, new uint256[](0)), 0, "a refused claim pays nothing and does not revert");
        assertEq(cm.yieldPaid(), cm.yieldDelivered());
    }

    function test_C31_WithdrawNeverPaysFromCollectedOrEscrow() public {
        _deposit(alice, TOKEN);
        (, uint256 face) = _borrow(alice, TOKEN, m1, offerM1, PRINCIPAL);
        vm.prank(alice);
        lm.repay(TOKEN, face);
        uint256 id = _postParked(lender, m2, PARKED);
        _lump(1_000e18);
        vault.reportIndex(vault.accrualIndex() + 10e18);
        assertGt(cm.pendingOfferYield(id), musd.balanceOf(address(cm)), "owed is above everything held");

        uint256 plainEscrow = (OFFER - PRINCIPAL) + OFFER + OFFER;
        uint256 held = musd.balanceOf(address(cm));
        assertEq(held, plainEscrow + face, "the market holds collected MUSD next to the plain escrow");
        assertEq(_withdrawYield(lender, _ids(id)), 1_000e18, "paid only the delivered lump");
        assertEq(_withdrawYield(lender, new uint256[](0)), 0, "nothing more once delivered is used up");

        assertEq(musd.balanceOf(address(cm)), held, "collected and escrow MUSD untouched");
        assertEq(cm.marketOf(m1).collectedMusd, face);
        assertEq(cm.offerOf(offerM2).remaining, OFFER);
        assertGe(
            musd.balanceOf(address(cm)),
            plainEscrow + face + cm.yieldDelivered() - cm.yieldPaid(),
            "C14: the solvency line holds"
        );
        assertGt(cm.yieldOwedOf(lender), 0, "the shortfall stays owed to the maker");
    }

    function test_C31_YieldPaidDuringADepositCountsAsDelivered() public {
        _postParked(lender, m1, PARKED);
        _lump(1_000e18);
        vault.payYieldOnDeposit(true);
        uint256 later = _postParked(maker2, m1, 10_000e18);
        assertEq(cm.yieldDelivered(), 1_000e18, "the lump paid out during the deposit is delivered");
        assertEq(cm.pendingOfferYield(later), 0, "the new offer's snapshot comes after the deposit");
        assertEq(cm.parkedPrincipal(), PARKED + 10_000e18);
    }

    function test_RevertWhen_WithdrawListsAnotherMakersOffer() public {
        uint256 id = _postParked(lender, m1, PARKED);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.NotMaker.selector, id));
        _withdrawYield(maker2, _ids(id));
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.NotMaker.selector, 999));
        _withdrawYield(lender, _ids(999));

        uint256[] memory nine = new uint256[](9);
        for (uint256 i; i < nine.length; ++i) {
            nine[i] = id;
        }
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.BadFillCount.selector, 9));
        _withdrawYield(lender, nine);
    }

    function test_C32_StopParkingRefusesNewParkedOffersOnly() public {
        uint256 id = _postParked(lender, m1, PARKED);
        uint256 other = _postParked(lender, m1, 20_000e18);
        vm.expectRevert(ICreditMarkets.NotGuardianOrOwner.selector);
        vm.prank(stranger);
        cm.stopParking();

        vm.expectEmit(false, false, false, true, address(cm));
        emit ICreditMarkets.ParkingStopped();
        vm.prank(guardian);
        cm.stopParking();
        assertFalse(cm.parkingOn());
        vm.expectRevert(ICreditMarkets.ParkingOff.selector);
        _postParked(lender, m1, PARKED);
        vm.prank(lender);
        cm.postOffer(m1, APR, 1_000e18);

        _deposit(alice, TOKEN);
        vm.expectCall(address(vault), abi.encodeCall(IMUSDSavingsRate.withdraw, (uint256(PRINCIPAL))), 1);
        _borrow(alice, TOKEN, m1, id, PRINCIPAL);
        vm.expectCall(address(vault), abi.encodeCall(IMUSDSavingsRate.withdraw, (uint256(20_000e18))), 1);
        vm.prank(lender);
        cm.cancelOffer(other);
        assertEq(cm.parkedPrincipal(), PARKED - PRINCIPAL, "existing parked offers still fill and cancel");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vm.prank(guardian);
        cm.resumeParking();
        vm.prank(owner);
        cm.resumeParking();
        assertTrue(cm.parkingOn());
        _postParked(lender, m1, 1_000e18);
    }

    function test_RevertWhen_PullOutCallerIsNotGuardianOrOwner() public {
        vm.expectRevert(ICreditMarkets.NothingParked.selector);
        vm.prank(guardian);
        cm.pullOut();

        _postParked(lender, m1, PARKED);
        vm.startPrank(stranger);
        vault.deposit(500e18);
        vault.transfer(address(cm), 500e18);
        vm.stopPrank();
        address[2] memory refused = [stranger, lender];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(ICreditMarkets.NotGuardianOrOwner.selector);
            vm.prank(refused[i]);
            cm.pullOut();
        }

        vm.expectCall(address(vault), abi.encodeCall(IMUSDSavingsRate.withdraw, (uint256(PARKED))), 1);
        vm.prank(owner);
        cm.pullOut();
        assertEq(vault.balanceOf(address(cm)), 500e18, "only parked principal left, the stray sMUSD stays");
        vm.expectRevert(ICreditMarkets.NothingParked.selector);
        vm.prank(guardian);
        cm.pullOut();
    }

    function test_C32_AfterPullOutAnEarlierEraOfferNeverCallsTheVault() public {
        uint256 id = _postParked(lender, m1, PARKED);
        uint256 other = _postParked(lender, m1, 10_000e18);
        vm.prank(guardian);
        cm.pullOut();
        _deposit(alice, TOKEN);
        vault.revertOnWithdraw(true);
        vault.revertOnIndex(true);
        uint256 aliceBefore = musd.balanceOf(alice);
        uint256 lenderBefore = musd.balanceOf(lender);

        // From here to the end of the test nothing may call the vault, this test included.
        vm.expectCall(address(vault), bytes(""), 0);
        _borrow(alice, TOKEN, m1, id, PRINCIPAL);
        vm.prank(lender);
        cm.cancelOffer(other);

        assertEq(musd.balanceOf(alice) - aliceBefore, PRINCIPAL, "filled from the MUSD the pull-out returned");
        assertEq(musd.balanceOf(lender) - lenderBefore, 10_000e18, "cancelled from the same MUSD");
        assertEq(cm.offerOf(id).remaining, PARKED - PRINCIPAL);
        assertEq(cm.parkedPrincipal(), 0);
    }
}
