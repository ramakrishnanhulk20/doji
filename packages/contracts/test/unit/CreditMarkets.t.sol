// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Unit tests for CreditMarkets with an ordinary address standing in for LoanManager, so fills and MUSD and
// BTC credits are driven directly. It does NOT cover: the real LoanManager's borrow, repay, auction and settle
// checks (LoanManager.t.sol, Resolution.t.sol), real MUSD, BTC or Mezo state (test/fork), fee-on-transfer
// tokens beyond the exact-arrival check, unit transfers between holders, or randomised sequences of posts,
// fills and redemptions across many maturities (CreditInvariants.t.sol).

import {Test} from "forge-std/Test.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CreditMarkets} from "../../src/CreditMarkets.sol";
import {ICreditMarkets} from "../../src/interfaces/ICreditMarkets.sol";
import {Quote} from "../../src/libraries/Quote.sol";
import {MockMUSD} from "../utils/MockMUSD.sol";
import {MockBTC} from "../utils/MockBTC.sol";
import {RevertingReceiver} from "../utils/RevertingReceiver.sol";

contract CreditMarketsTest is Test {
    uint256 internal constant WEEK = 604_800;
    uint256 internal constant T0 = 2_963 * WEEK + 1 days + 3 hours;
    uint16 internal constant FEE_SHARE = 1_000;
    uint128 internal constant MIN_OFFER = 10e18;
    uint32 internal constant MAX_TERM = uint32(4 * WEEK);

    MockMUSD internal musd;
    MockBTC internal btc;
    CreditMarkets internal cm;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal loanManager = makeAddr("loanManager");
    address internal lender = makeAddr("lender");
    address internal lender2 = makeAddr("lender2");
    address internal borrower = makeAddr("borrower");
    address internal stranger = makeAddr("stranger");

    uint64 internal m1;
    uint64 internal m2;

    function setUp() public {
        vm.warp(T0);
        musd = new MockMUSD();
        btc = new MockBTC();
        cm = new CreditMarkets(
            address(musd), address(btc), loanManager, owner, guardian, treasury, FEE_SHARE, MIN_OFFER, MAX_TERM
        );
        m1 = uint64((T0 / WEEK + 1) * WEEK);
        m2 = m1 + uint64(WEEK);

        address[3] memory funded = [lender, lender2, loanManager];
        for (uint256 i; i < funded.length; ++i) {
            musd.mint(funded[i], 1_000_000e18);
            vm.prank(funded[i]);
            musd.approve(address(cm), type(uint256).max);
        }
        btc.mint(loanManager, 100e18);
        vm.prank(loanManager);
        btc.approve(address(cm), type(uint256).max);
    }

    function _creditBtc(uint64 maturity, uint256 amount, bool closes) internal {
        vm.prank(loanManager);
        cm.creditBtc(maturity, amount, closes);
    }

    function _post(address maker, uint64 maturity, uint16 aprBps, uint128 amount) internal returns (uint256 id) {
        vm.prank(maker);
        id = cm.postOffer(maturity, aprBps, amount);
    }

    function _fillOne(uint64 maturity, uint256 offerId, uint128 amount)
        internal
        returns (uint256 principal, uint256 face)
    {
        uint256[] memory ids = new uint256[](1);
        uint128[] memory amounts = new uint128[](1);
        ids[0] = offerId;
        amounts[0] = amount;
        vm.prank(loanManager);
        return cm.fill(maturity, ids, amounts, 5_000, borrower);
    }

    function _credit(uint64 maturity, uint256 amount, bool closes) internal {
        vm.prank(loanManager);
        cm.credit(maturity, amount, closes);
    }

    function _repaidMarket(uint128 amount) internal returns (uint256 face) {
        uint256 id = _post(lender, m1, 800, amount);
        (, face) = _fillOne(m1, id, amount);
        _credit(m1, face, true);
        vm.warp(m1 + 1);
        cm.finalize(m1);
    }

    function test_Constructor_SetsState() public view {
        assertEq(cm.musd(), address(musd));
        assertEq(cm.btc(), address(btc));
        assertEq(cm.loanManager(), loanManager);
        assertEq(cm.owner(), owner);
        assertEq(cm.guardian(), guardian);
        assertEq(cm.treasury(), treasury);
        assertEq(cm.feeShareBps(), FEE_SHARE);
        assertEq(cm.minOffer(), MIN_OFFER);
        assertEq(cm.maxTermSeconds(), MAX_TERM);
        assertEq(cm.nextOfferId(), 1);
        assertFalse(cm.offersPaused());
    }

    function test_RevertWhen_ConstructorZeroAddress() public {
        address b = address(btc);
        vm.expectRevert(ICreditMarkets.ZeroAddress.selector);
        new CreditMarkets(address(0), b, loanManager, owner, guardian, treasury, FEE_SHARE, MIN_OFFER, MAX_TERM);
        vm.expectRevert(ICreditMarkets.ZeroAddress.selector);
        new CreditMarkets(address(musd), address(0), loanManager, owner, guardian, treasury, FEE_SHARE, MIN_OFFER, MAX_TERM);
        vm.expectRevert(ICreditMarkets.ZeroAddress.selector);
        new CreditMarkets(address(musd), b, address(0), owner, guardian, treasury, FEE_SHARE, MIN_OFFER, MAX_TERM);
        vm.expectRevert(ICreditMarkets.ZeroAddress.selector);
        new CreditMarkets(address(musd), b, loanManager, owner, address(0), treasury, FEE_SHARE, MIN_OFFER, MAX_TERM);
        vm.expectRevert(ICreditMarkets.ZeroAddress.selector);
        new CreditMarkets(address(musd), b, loanManager, owner, guardian, address(0), FEE_SHARE, MIN_OFFER, MAX_TERM);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CreditMarkets(address(musd), b, loanManager, address(0), guardian, treasury, FEE_SHARE, MIN_OFFER, MAX_TERM);
    }

    function test_RevertWhen_ConstructorParamsOutOfBounds() public {
        address b = address(btc);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.FeeShareOutOfBounds.selector, 2_001));
        new CreditMarkets(address(musd), b, loanManager, owner, guardian, treasury, 2_001, MIN_OFFER, MAX_TERM);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.MinOfferOutOfBounds.selector, 1e18 - 1));
        new CreditMarkets(address(musd), b, loanManager, owner, guardian, treasury, FEE_SHARE, 1e18 - 1, MAX_TERM);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.MaxTermOutOfBounds.selector, uint32(WEEK - 1)));
        new CreditMarkets(address(musd), b, loanManager, owner, guardian, treasury, FEE_SHARE, MIN_OFFER, uint32(WEEK - 1));
    }

    function test_PostOffer_EscrowsAndRecords() public {
        uint256 before = musd.balanceOf(lender);
        vm.expectEmit(true, true, true, true, address(cm));
        emit ICreditMarkets.OfferPosted(1, lender, m1, 800, 1_000e18);
        uint256 id = _post(lender, m1, 800, 1_000e18);

        assertEq(id, 1);
        assertEq(cm.nextOfferId(), 2);
        assertEq(musd.balanceOf(lender), before - 1_000e18);
        assertEq(musd.balanceOf(address(cm)), 1_000e18);
        ICreditMarkets.Offer memory offer = cm.offerOf(id);
        assertEq(offer.maker, lender);
        assertEq(offer.maturity, m1);
        assertEq(offer.aprBps, 800);
        assertEq(offer.remaining, 1_000e18);
        assertEq(_post(lender, m1, 5_000, MIN_OFFER), 2, "max APR and min offer accepted");
    }

    function test_RevertWhen_PostOfferPaused() public {
        vm.prank(guardian);
        cm.setOffersPaused(true);
        vm.expectRevert(ICreditMarkets.OffersPaused.selector);
        _post(lender, m1, 800, 100e18);
    }

    function test_RevertWhen_PostOfferInvalidMaturity() public {
        uint64[3] memory bad = [m1 + 1, m1 - uint64(WEEK), m1 + uint64(4 * WEEK)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.InvalidMaturity.selector, bad[i]));
            _post(lender, bad[i], 800, 100e18);
        }
    }

    function test_RevertWhen_PostOfferAprTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.AprTooHigh.selector, 5_001));
        _post(lender, m1, 5_001, 100e18);
    }

    function test_RevertWhen_PostOfferTooSmall() public {
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.OfferTooSmall.selector, MIN_OFFER - 1, MIN_OFFER));
        _post(lender, m1, 800, MIN_OFFER - 1);
    }

    function test_C16_CancelRefundsExactlyRemaining() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        _fillOne(m1, id, 300e18);
        uint256 before = musd.balanceOf(lender);

        vm.expectEmit(true, true, false, true, address(cm));
        emit ICreditMarkets.OfferCancelled(id, lender, 700e18);
        vm.prank(lender);
        cm.cancelOffer(id);

        assertEq(musd.balanceOf(lender), before + 700e18);
        assertEq(cm.offerOf(id).remaining, 0);
        assertEq(cm.offerOf(id).maker, lender, "maker kept so the id is never reused");
    }

    function test_C16_OnlyMakerCancels() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        address[3] memory others = [stranger, owner, loanManager];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.NotMaker.selector, id));
            vm.prank(others[i]);
            cm.cancelOffer(id);
        }
    }

    function test_C16_CancelWorksWhileOffersPaused() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        vm.prank(guardian);
        cm.setOffersPaused(true);
        vm.prank(lender);
        cm.cancelOffer(id);
        assertEq(cm.offerOf(id).remaining, 0);
    }

    function test_RevertWhen_CancelUnknownOffer() public {
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.OfferNotFound.selector, 99));
        vm.prank(lender);
        cm.cancelOffer(99);
    }

    function test_RevertWhen_CancelEmptyOffer() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        vm.startPrank(lender);
        cm.cancelOffer(id);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.OfferEmpty.selector, id));
        cm.cancelOffer(id);
        vm.stopPrank();
    }

    function test_Fill_RecordsUnitsAndPaysRecipient() public {
        uint256 idA = _post(lender, m1, 800, 1_000e18);
        uint256 idB = _post(lender2, m1, 600, 1_000e18);
        uint256 secondsLeft = m1 - block.timestamp;
        (uint256 faceA, uint256 makerA, uint256 feeA) = Quote.quote(400e18, 800, secondsLeft, FEE_SHARE);
        (uint256 faceB, uint256 makerB, uint256 feeB) = Quote.quote(250e18, 600, secondsLeft, FEE_SHARE);

        uint256[] memory ids = new uint256[](2);
        uint128[] memory amounts = new uint128[](2);
        (ids[0], ids[1]) = (idA, idB);
        (amounts[0], amounts[1]) = (400e18, 250e18);

        vm.expectEmit(true, true, true, true, address(cm));
        emit ICreditMarkets.Filled(idA, lender, m1, 400e18, faceA);
        vm.expectEmit(true, true, true, true, address(cm));
        emit ICreditMarkets.Filled(idB, lender2, m1, 250e18, faceB);
        vm.prank(loanManager);
        (uint256 principal, uint256 face) = cm.fill(m1, ids, amounts, 800, borrower);

        assertEq(principal, 650e18);
        assertEq(face, faceA + faceB);
        assertEq(musd.balanceOf(borrower), 650e18);
        assertEq(cm.offerOf(idA).remaining, 600e18);
        assertEq(cm.offerOf(idB).remaining, 750e18);
        assertEq(cm.pendingUnits(lender, m1), makerA);
        assertEq(cm.pendingUnits(lender2, m1), makerB);
        assertEq(cm.pendingUnits(treasury, m1), feeA + feeB);
        ICreditMarkets.Market memory market = cm.marketOf(m1);
        assertEq(market.faceTotal, face);
        assertEq(market.openLoans, 1);
        assertEq(cm.balanceOf(lender, m1), 0, "fill mints nothing");
    }

    function test_C8_UnitsEqualFace() public {
        uint256 id = _post(lender, m1, 1_234, 1_000e18);
        (, uint256 face) = _fillOne(m1, id, 777e18);
        assertEq(cm.pendingUnits(lender, m1) + cm.pendingUnits(treasury, m1), face);
        assertEq(cm.marketOf(m1).faceTotal, face);
    }

    function test_Fill_OpenLoansRisesOncePerCall() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        _fillOne(m1, id, 100e18);
        _fillOne(m1, id, 100e18);
        assertEq(cm.marketOf(m1).openLoans, 2);
    }

    function test_Fill_UsesCurrentFeeShare() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        vm.prank(owner);
        cm.setFeeShareBps(2_000);
        (uint256 expectedFace,, uint256 expectedFee) = Quote.quote(500e18, 800, m1 - block.timestamp, 2_000);
        (, uint256 face) = _fillOne(m1, id, 500e18);
        assertEq(face, expectedFace);
        assertEq(cm.pendingUnits(treasury, m1), expectedFee);
    }

    function test_C27_FillOnlyLoanManager() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        uint256[] memory ids = new uint256[](1);
        uint128[] memory amounts = new uint128[](1);
        (ids[0], amounts[0]) = (id, 100e18);
        address[3] memory others = [stranger, owner, lender];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(ICreditMarkets.NotLoanManager.selector);
            vm.prank(others[i]);
            cm.fill(m1, ids, amounts, 5_000, others[i]);
        }
    }

    function test_RevertWhen_FillBadCount() public {
        vm.startPrank(loanManager);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.BadFillCount.selector, 0));
        cm.fill(m1, new uint256[](0), new uint128[](0), 5_000, borrower);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.BadFillCount.selector, 9));
        cm.fill(m1, new uint256[](9), new uint128[](9), 5_000, borrower);
        vm.stopPrank();
    }

    function test_RevertWhen_FillLengthMismatch() public {
        vm.expectRevert(ICreditMarkets.LengthMismatch.selector);
        vm.prank(loanManager);
        cm.fill(m1, new uint256[](2), new uint128[](1), 5_000, borrower);
    }

    function test_RevertWhen_FillZeroRecipient() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        uint256[] memory ids = new uint256[](1);
        uint128[] memory amounts = new uint128[](1);
        (ids[0], amounts[0]) = (id, 100e18);
        vm.expectRevert(ICreditMarkets.ZeroAddress.selector);
        vm.prank(loanManager);
        cm.fill(m1, ids, amounts, 5_000, address(0));
    }

    function test_RevertWhen_FillInvalidMaturity() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        vm.warp(m1);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.InvalidMaturity.selector, m1));
        _fillOne(m1, id, 100e18);
    }

    function test_C8_FillRejectsOfferForOtherMaturity() public {
        uint256 id = _post(lender, m2, 800, 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.WrongMaturity.selector, id, m2, m1));
        _fillOne(m1, id, 100e18);
    }

    function test_C8_FillRejectsAprAboveMax() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        uint256[] memory ids = new uint256[](1);
        uint128[] memory amounts = new uint128[](1);
        (ids[0], amounts[0]) = (id, 100e18);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.AprAboveMax.selector, id, 800, 799));
        vm.prank(loanManager);
        cm.fill(m1, ids, amounts, 799, borrower);
    }

    function test_C8_FillRejectsShortRemaining() public {
        uint256 id = _post(lender, m1, 800, 100e18);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.InsufficientRemaining.selector, id, 100e18, 100e18 + 1));
        _fillOne(m1, id, 100e18 + 1);
    }

    function test_RevertWhen_FillZeroAmount() public {
        uint256 id = _post(lender, m1, 800, 100e18);
        vm.expectRevert(ICreditMarkets.ZeroAmount.selector);
        _fillOne(m1, id, 0);
    }

    function test_RevertWhen_FillUnknownOffer() public {
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.OfferNotFound.selector, 42));
        _fillOne(m1, 42, 100e18);
    }

    function test_C23_FillCallsNoMakerCode() public {
        RevertingReceiver maker = new RevertingReceiver();
        musd.mint(address(maker), 1_000e18);
        uint256 id = maker.postOffer(cm, musd, m1, 800, 1_000e18);

        (, uint256 face) = _fillOne(m1, id, 500e18);

        assertGt(cm.pendingUnits(address(maker), m1), 0);
        assertEq(cm.balanceOf(address(maker), m1), 0);
        assertEq(musd.balanceOf(borrower), 500e18);
        assertEq(cm.marketOf(m1).faceTotal, face);
        vm.expectRevert(RevertingReceiver.Refused.selector);
        maker.claimUnits(cm, m1);
    }

    function test_Credit_BooksAmountAndEmits() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        _fillOne(m1, id, 500e18);
        vm.expectEmit(true, false, false, true, address(cm));
        emit ICreditMarkets.Credited(m1, 200e18, false);
        _credit(m1, 200e18, false);

        ICreditMarkets.Market memory market = cm.marketOf(m1);
        assertEq(market.collectedMusd, 200e18);
        assertEq(market.openLoans, 1);
    }

    function test_Credit_ClosingLowersOpenLoansOnce() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        (, uint256 face) = _fillOne(m1, id, 500e18);
        _fillOne(m1, id, 100e18);
        _credit(m1, face, true);
        assertEq(cm.marketOf(m1).openLoans, 1);
    }

    function test_Credit_ZeroAmountMayCloseALoan() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        _fillOne(m1, id, 500e18);
        _credit(m1, 0, true);
        assertEq(cm.marketOf(m1).openLoans, 0);
        assertEq(cm.marketOf(m1).collectedMusd, 0);
    }

    function test_C27_CreditOnlyLoanManager() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        _fillOne(m1, id, 500e18);
        address[3] memory others = [stranger, owner, lender];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(ICreditMarkets.NotLoanManager.selector);
            vm.prank(others[i]);
            cm.credit(m1, 1e18, true);
        }
    }

    function test_RevertWhen_CreditNoOpenLoans() public {
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.NoOpenLoans.selector, m1));
        _credit(m1, 1e18, false);
    }

    function test_RevertWhen_CreditZeroWithoutClose() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        _fillOne(m1, id, 500e18);
        vm.expectRevert(ICreditMarkets.ZeroAmount.selector);
        _credit(m1, 0, false);
    }

    function test_RevertWhen_CreditFinalMarket() public {
        _repaidMarket(500e18);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.MarketIsFinal.selector, m1));
        _credit(m1, 1e18, false);
    }

    function test_ClaimUnits_MintsPending() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        _fillOne(m1, id, 500e18);
        uint256 pending = cm.pendingUnits(lender, m1);

        vm.expectEmit(true, true, false, true, address(cm));
        emit ICreditMarkets.UnitsClaimed(lender, m1, pending);
        vm.prank(lender);
        uint256 minted = cm.claimUnits(m1);

        assertEq(minted, pending);
        assertEq(cm.balanceOf(lender, m1), pending);
        assertEq(cm.pendingUnits(lender, m1), 0);
    }

    function test_RevertWhen_ClaimNothing() public {
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.NothingToClaim.selector, stranger, m1));
        vm.prank(stranger);
        cm.claimUnits(m1);
    }

    function test_Finalize_Snapshots() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        (, uint256 face) = _fillOne(m1, id, 500e18);
        _credit(m1, face, true);
        vm.warp(m1 + 1);

        vm.expectEmit(true, false, false, true, address(cm));
        emit ICreditMarkets.MarketFinalized(m1, face, face);
        vm.prank(stranger);
        cm.finalize(m1);

        ICreditMarkets.Market memory market = cm.marketOf(m1);
        assertTrue(market.isFinal);
        assertEq(market.unitsAtFinal, face);
        assertEq(market.musdAtFinal, face);
    }

    function test_C15_FinalizeRevertsBeforeMaturityPasses() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        (, uint256 face) = _fillOne(m1, id, 500e18);
        _credit(m1, face, true);
        vm.warp(m1);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.NotMatured.selector, m1));
        cm.finalize(m1);
    }

    function test_C15_FinalizeRevertsWithOpenLoan() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        _fillOne(m1, id, 500e18);
        vm.warp(m1 + 1);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.LoansStillOpen.selector, m1, 1));
        cm.finalize(m1);
    }

    function test_RevertWhen_FinalizeTwice() public {
        _repaidMarket(500e18);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.MarketIsFinal.selector, m1));
        cm.finalize(m1);
    }

    function test_RevertWhen_FinalizeEmptyMarket() public {
        vm.warp(m1 + 1);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.EmptyMarket.selector, m1));
        cm.finalize(m1);
    }

    function test_Redeem_PaysFullFaceWhenRepaid() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        (, uint256 face) = _fillOne(m1, id, 500e18);
        _credit(m1, face, true);
        vm.warp(m1 + 1);
        cm.finalize(m1);

        vm.prank(lender);
        uint256 lenderUnits = cm.claimUnits(m1);
        vm.prank(treasury);
        uint256 treasuryUnits = cm.claimUnits(m1);
        uint256 lenderBefore = musd.balanceOf(lender);

        vm.expectEmit(true, true, false, true, address(cm));
        emit ICreditMarkets.Redeemed(lender, m1, lenderUnits, lenderUnits, 0);
        vm.prank(lender);
        (uint256 lenderOut,) = cm.redeem(m1, lenderUnits);
        vm.prank(treasury);
        (uint256 treasuryOut,) = cm.redeem(m1, treasuryUnits);

        assertEq(lenderOut, lenderUnits);
        assertEq(treasuryOut, treasuryUnits);
        assertEq(lenderOut + treasuryOut, face);
        assertEq(musd.balanceOf(lender), lenderBefore + lenderOut);
        assertEq(cm.balanceOf(lender, m1), 0);
        assertEq(musd.balanceOf(address(cm)), 500e18, "only the unfilled escrow is left");
    }

    function test_Redeem_PaysProRataOnShortfall() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        (, uint256 face) = _fillOne(m1, id, 500e18);
        _credit(m1, face / 2, true);
        vm.warp(m1 + 1);
        cm.finalize(m1);

        vm.startPrank(lender);
        uint256 units = cm.claimUnits(m1);
        (uint256 out,) = cm.redeem(m1, units);
        vm.stopPrank();
        assertEq(out, units * (face / 2) / face);
        assertLt(out, units);
    }

    function test_C15_RedeemBeforeFinalReverts() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        (, uint256 face) = _fillOne(m1, id, 500e18);
        _credit(m1, face, true);
        vm.startPrank(lender);
        uint256 units = cm.claimUnits(m1);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.NotFinal.selector, m1));
        cm.redeem(m1, units);
        vm.stopPrank();
    }

    function test_C15_RedeemNeverPaysAboveOnePerUnit() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        (, uint256 face) = _fillOne(m1, id, 500e18);
        _credit(m1, face * 2, true);
        vm.warp(m1 + 1);
        cm.finalize(m1);

        vm.startPrank(lender);
        uint256 units = cm.claimUnits(m1);
        (uint256 out,) = cm.redeem(m1, units);
        vm.stopPrank();
        assertEq(out, units);
    }

    function test_RevertWhen_RedeemZero() public {
        _repaidMarket(500e18);
        vm.expectRevert(ICreditMarkets.ZeroAmount.selector);
        vm.prank(lender);
        cm.redeem(m1, 0);
    }

    function test_RevertWhen_RedeemMoreThanHeld() public {
        _repaidMarket(500e18);
        vm.startPrank(lender);
        uint256 units = cm.claimUnits(m1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, lender, units, units + 1, m1)
        );
        cm.redeem(m1, units + 1);
        vm.stopPrank();
    }

    function test_C14_DonationChangesNoMarketOrRedemption() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        (, uint256 face) = _fillOne(m1, id, 500e18);
        musd.mint(address(cm), 12_345e18);
        _credit(m1, face, true);
        musd.mint(address(cm), 6_789e18);

        ICreditMarkets.Market memory market = cm.marketOf(m1);
        assertEq(market.collectedMusd, face);
        assertEq(market.faceTotal, face);

        vm.warp(m1 + 1);
        cm.finalize(m1);
        assertEq(cm.marketOf(m1).musdAtFinal, face);
        vm.startPrank(lender);
        uint256 units = cm.claimUnits(m1);
        (uint256 out,) = cm.redeem(m1, units);
        assertEq(out, units);
        vm.stopPrank();
        assertEq(cm.offerOf(id).remaining, 500e18, "escrow untouched by the donation");
    }

    function test_QuoteFill_MatchesQuote() public view {
        (uint256 face, uint256 makerUnits, uint256 treasuryUnits) = cm.quoteFill(500e18, 800, m1);
        (uint256 expectedFace, uint256 expectedMaker, uint256 expectedFee) =
            Quote.quote(500e18, 800, m1 - block.timestamp, FEE_SHARE);
        assertEq(face, expectedFace);
        assertEq(makerUnits, expectedMaker);
        assertEq(treasuryUnits, expectedFee);
    }

    function test_RevertWhen_QuoteFillInvalidMaturity() public {
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.InvalidMaturity.selector, m1 + 1));
        cm.quoteFill(500e18, 800, m1 + 1);
    }

    function test_IsValidMaturity() public {
        assertTrue(cm.isValidMaturity(m1));
        assertTrue(cm.isValidMaturity(m1 + uint64(3 * WEEK)), "inside the 4 week term");
        assertFalse(cm.isValidMaturity(m1 + 1), "not a Thursday");
        assertFalse(cm.isValidMaturity(m1 - uint64(WEEK)), "in the past");
        assertFalse(cm.isValidMaturity(m1 + uint64(4 * WEEK)), "beyond the term");
        vm.warp(m1);
        assertFalse(cm.isValidMaturity(m1), "closes at the maturity instant");
    }

    function test_Setters_UpdateAndEmit() public {
        address newTreasury = makeAddr("newTreasury");
        address newGuardian = makeAddr("newGuardian");
        vm.startPrank(owner);
        vm.expectEmit(address(cm));
        emit ICreditMarkets.FeeShareBpsSet(2_000);
        cm.setFeeShareBps(2_000);
        vm.expectEmit(address(cm));
        emit ICreditMarkets.MinOfferSet(1_000_000e18);
        cm.setMinOffer(1_000_000e18);
        vm.expectEmit(address(cm));
        emit ICreditMarkets.MaxTermSecondsSet(uint32(12 * WEEK));
        cm.setMaxTermSeconds(uint32(12 * WEEK));
        vm.expectEmit(address(cm));
        emit ICreditMarkets.TreasurySet(newTreasury);
        cm.setTreasury(newTreasury);
        vm.expectEmit(address(cm));
        emit ICreditMarkets.GuardianSet(newGuardian);
        cm.setGuardian(newGuardian);
        vm.stopPrank();

        assertEq(cm.feeShareBps(), 2_000);
        assertEq(cm.minOffer(), 1_000_000e18);
        assertEq(cm.maxTermSeconds(), 12 * WEEK);
        assertEq(cm.treasury(), newTreasury);
        assertEq(cm.guardian(), newGuardian);
    }

    function test_RevertWhen_SettersOutOfBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.FeeShareOutOfBounds.selector, 2_001));
        cm.setFeeShareBps(2_001);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.MinOfferOutOfBounds.selector, 1_000_000e18 + 1));
        cm.setMinOffer(1_000_000e18 + 1);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.MaxTermOutOfBounds.selector, uint32(12 * WEEK + 1)));
        cm.setMaxTermSeconds(uint32(12 * WEEK + 1));
        vm.expectRevert(ICreditMarkets.ZeroAddress.selector);
        cm.setTreasury(address(0));
        vm.expectRevert(ICreditMarkets.ZeroAddress.selector);
        cm.setGuardian(address(0));
        vm.stopPrank();
    }

    function test_RevertWhen_SettersNotOwner() public {
        bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian);
        vm.startPrank(guardian);
        vm.expectRevert(notOwner);
        cm.setFeeShareBps(0);
        vm.expectRevert(notOwner);
        cm.setMinOffer(1e18);
        vm.expectRevert(notOwner);
        cm.setMaxTermSeconds(uint32(WEEK));
        vm.expectRevert(notOwner);
        cm.setTreasury(guardian);
        vm.expectRevert(notOwner);
        cm.setGuardian(guardian);
        vm.stopPrank();
    }

    function test_SetOffersPaused_GuardianOrOwnerOnly() public {
        vm.expectEmit(address(cm));
        emit ICreditMarkets.OffersPausedSet(true);
        vm.prank(guardian);
        cm.setOffersPaused(true);
        assertTrue(cm.offersPaused());
        vm.prank(owner);
        cm.setOffersPaused(false);
        assertFalse(cm.offersPaused());
        vm.expectRevert(ICreditMarkets.NotGuardianOrOwner.selector);
        vm.prank(stranger);
        cm.setOffersPaused(true);
    }

    function test_OwnershipMovesInTwoSteps() public {
        address next = makeAddr("nextOwner");
        vm.prank(owner);
        cm.transferOwnership(next);
        assertEq(cm.owner(), owner);
        vm.prank(next);
        cm.acceptOwnership();
        assertEq(cm.owner(), next);
    }

    function test_C18_RejectsNativeBTC() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(cm).call{value: 1}("");
        assertFalse(ok);
    }

    function test_CreditBtc_BooksAmountAndEmits() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        _fillOne(m1, id, 500e18);
        vm.expectEmit(true, false, false, true, address(cm));
        emit ICreditMarkets.CreditedBtc(m1, 0.25e18, true);
        _creditBtc(m1, 0.25e18, true);

        ICreditMarkets.Market memory market = cm.marketOf(m1);
        assertEq(market.collectedBtc, 0.25e18);
        assertEq(market.collectedMusd, 0);
        assertEq(market.openLoans, 0);
        assertEq(btc.balanceOf(address(cm)), 0.25e18);
    }

    function test_CreditBtc_ClosingLowersOpenLoansOnce() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        _fillOne(m1, id, 500e18);
        _fillOne(m1, id, 100e18);
        _creditBtc(m1, 0.1e18, false);
        assertEq(cm.marketOf(m1).openLoans, 2, "a non-closing credit leaves the count");
        _creditBtc(m1, 0.1e18, true);
        assertEq(cm.marketOf(m1).openLoans, 1);
        assertEq(cm.marketOf(m1).collectedBtc, 0.2e18);
    }

    function test_CreditBtc_ZeroAmountMayCloseALoan() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        _fillOne(m1, id, 500e18);
        _creditBtc(m1, 0, true);
        assertEq(cm.marketOf(m1).openLoans, 0);
        assertEq(cm.marketOf(m1).collectedBtc, 0);
    }

    function test_C27_CreditBtcOnlyLoanManager() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        _fillOne(m1, id, 500e18);
        address[3] memory others = [stranger, owner, lender];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(ICreditMarkets.NotLoanManager.selector);
            vm.prank(others[i]);
            cm.creditBtc(m1, 1e18, true);
        }
    }

    function test_RevertWhen_CreditBtcNoOpenLoans() public {
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.NoOpenLoans.selector, m1));
        _creditBtc(m1, 1e18, true);
    }

    function test_RevertWhen_CreditBtcZeroWithoutClose() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        _fillOne(m1, id, 500e18);
        vm.expectRevert(ICreditMarkets.ZeroAmount.selector);
        _creditBtc(m1, 0, false);
    }

    function test_RevertWhen_CreditBtcFinalMarket() public {
        _repaidMarket(500e18);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.MarketIsFinal.selector, m1));
        _creditBtc(m1, 1e18, false);
    }

    function test_Finalize_SnapshotsBtc() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        (, uint256 face) = _fillOne(m1, id, 500e18);
        _fillOne(m1, id, 100e18);
        _credit(m1, 100e18, true);
        _creditBtc(m1, 0.3e18, true);
        vm.warp(m1 + 1);
        cm.finalize(m1);
        ICreditMarkets.Market memory market = cm.marketOf(m1);
        assertEq(market.btcAtFinal, 0.3e18);
        assertEq(market.musdAtFinal, 100e18);
        assertGt(market.unitsAtFinal, face);
    }

    function test_C15_RedeemPaysMusdAndBtcProRata() public {
        uint256 idA = _post(lender, m1, 800, 1_000e18);
        uint256 idB = _post(lender2, m1, 800, 1_000e18);
        (, uint256 faceA) = _fillOne(m1, idA, 600e18);
        _credit(m1, faceA, true);
        _fillOne(m1, idB, 400e18);
        _creditBtc(m1, 0.005e18 + 7, true);
        vm.warp(m1 + 1);
        cm.finalize(m1);
        ICreditMarkets.Market memory market = cm.marketOf(m1);

        address[3] memory holders = [lender, lender2, treasury];
        uint256 paidMusd;
        uint256 paidBtc;
        for (uint256 i; i < holders.length; ++i) {
            vm.startPrank(holders[i]);
            uint256 units = cm.claimUnits(m1);
            if (i == 0) {
                vm.expectEmit(true, true, false, true, address(cm));
                emit ICreditMarkets.Redeemed(
                    lender,
                    m1,
                    units,
                    units * market.musdAtFinal / market.unitsAtFinal,
                    units * market.btcAtFinal / market.unitsAtFinal
                );
            }
            (uint256 musdOut, uint256 btcOut) = cm.redeem(m1, units);
            vm.stopPrank();
            assertLe(musdOut, units, "never above one MUSD per unit");
            assertEq(btcOut, units * market.btcAtFinal / market.unitsAtFinal, "BTC rounded down");
            assertEq(btc.balanceOf(holders[i]), btcOut);
            paidMusd += musdOut;
            paidBtc += btcOut;
        }
        assertLe(paidMusd, market.musdAtFinal);
        assertLe(paidBtc, market.btcAtFinal);
        assertEq(btc.balanceOf(address(cm)), market.btcAtFinal - paidBtc, "only rounding dust stays");
    }

    function test_C14_BtcDonationChangesNothing() public {
        uint256 id = _post(lender, m1, 800, 1_000e18);
        _fillOne(m1, id, 500e18);
        btc.mint(address(cm), 3e18);
        _creditBtc(m1, 0.2e18, true);
        assertEq(cm.marketOf(m1).collectedBtc, 0.2e18);
        vm.warp(m1 + 1);
        cm.finalize(m1);
        assertEq(cm.marketOf(m1).btcAtFinal, 0.2e18, "the stray 3 BTC reaches no market");
    }
}
