// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Unit and fuzz tests for how a Doji loan ends when it goes wrong: auction start, the price curve, cancel,
// purchase, settle and its preparation, write-off, repayment during an auction, borrower claims, and the
// auction settings, on the real CreditMarkets with mocks for veBTC, PriceFeed, PoolsVoter, MUSD and BTC.
// It does NOT cover: the real veBTC withdraw, the real PoolsVoter or Mezo's BTC precompile
// (test/fork/ResolutionFork.t.sol), roll (Roll.t.sol), randomised sequences across maturities
// (CreditInvariants.t.sol), tokens that charge a fee on transfer, or votes cast through LoanManager (M2b).

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CreditMarkets} from "../../src/CreditMarkets.sol";
import {LoanManager} from "../../src/LoanManager.sol";
import {ICreditMarkets} from "../../src/interfaces/ICreditMarkets.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {IPoolsVoter} from "../../src/interfaces/IPoolsVoter.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";
import {MockBTC} from "../utils/MockBTC.sol";
import {MockPoolsVoter} from "../utils/MockPoolsVoter.sol";
import {RevertingReceiver} from "../utils/RevertingReceiver.sol";

contract ResolutionTest is LoanFixture {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant TOKEN_B = 8;

    struct Balances {
        uint256 collectedMusd;
        uint256 collectedBtc;
        uint256 treasuryMusd;
        uint256 treasuryBtc;
        uint256 claimMusd;
        uint256 claimBtc;
    }

    function _snapshot(uint64 maturity, address borrower) internal view returns (Balances memory b) {
        ICreditMarkets.Market memory market = cm.marketOf(maturity);
        b.collectedMusd = market.collectedMusd;
        b.collectedBtc = market.collectedBtc;
        b.treasuryMusd = musd.balanceOf(treasury);
        b.treasuryBtc = btc.balanceOf(treasury);
        b.claimMusd = lm.claimableMusd(borrower);
        b.claimBtc = lm.claimableBtc(borrower);
    }

    function _auctionUnsafe() internal returns (uint256 face) {
        face = _openLoan();
        _makeUnsafe(TOKEN);
        lm.startAuction(TOKEN);
    }

    function _auctionOverdue() internal returns (uint256 face) {
        face = _openLoan();
        vm.warp(m1 + 1);
        lm.startAuction(TOKEN);
    }

    /// @dev An overdue auction past its floor time and past TOKEN's lock end, ready to settle.
    function _readyToSettle() internal returns (uint256 face) {
        face = _auctionOverdue();
        vm.warp(m3 + 1);
    }

    function _buy(address who) internal returns (uint256) {
        vm.prank(who);
        return lm.purchase(TOKEN, type(uint256).max, vm.getBlockTimestamp());
    }

    function _floorTime(uint256 tokenId) internal view returns (uint256) {
        ILoanManager.Auction memory a = lm.auctionOf(tokenId);
        return uint256(a.startTime) + a.duration;
    }

    /// @dev After any ending, every other ending and every auction step must revert, and the market's open-loan
    ///      count must not move again (C9).
    function _assertNoOtherEnding(uint256 tokenId, uint64 maturity) internal {
        uint64 openBefore = cm.marketOf(maturity).openLoans;
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NoActiveLoan.selector, tokenId));
        vm.prank(alice);
        lm.repay(tokenId, 1e18);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NoAuction.selector, tokenId));
        vm.prank(buyer);
        lm.purchase(tokenId, type(uint256).max, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NoAuction.selector, tokenId));
        lm.settle(tokenId);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NoAuction.selector, tokenId));
        lm.prepareSettle(tokenId);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NoActiveLoan.selector, tokenId));
        lm.writeOff(tokenId);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LoanNotActive.selector, tokenId));
        lm.startAuction(tokenId);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NoAuction.selector, tokenId));
        lm.cancelAuction(tokenId);
        assertEq(cm.marketOf(maturity).openLoans, openBefore, "open loans moved again");
        assertEq(uint8(lm.loanOf(tokenId).state), uint8(ILoanManager.LoanState.None));
        assertEq(lm.auctionOf(tokenId).startTime, 0);
    }

    function test_Constructor_WiresResolution() public view {
        assertEq(address(lm.btc()), address(btc));
        assertEq(address(lm.poolsVoter()), address(voter));
        assertEq(lm.penaltyBps(), PENALTY);
        assertEq(lm.auctionFloorBps(), FLOOR);
        assertEq(lm.auctionDuration(), DURATION);
        assertEq(lm.totalClaimableMusd(), 0);
        assertEq(lm.totalClaimableBtc(), 0);
        assertEq(btc.allowance(address(lm), address(cm)), 0, "no standing BTC allowance");
    }

    function test_RevertWhen_ConstructorBtcMismatch() public {
        MockBTC other = new MockBTC();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        CreditMarkets markets = new CreditMarkets(
            address(musd), address(other), predicted, owner, guardian, treasury, FEE_SHARE, 10e18, uint32(WEEK), ""
        );
        vm.expectRevert(ILoanManager.BtcMismatch.selector);
        new LoanManager(address(ve), address(feed), address(musd), address(btc), address(voter), address(markets), 4, _settings());
    }

    function test_RevertWhen_ConstructorZeroBtcOrVoter() public {
        vm.expectRevert(ILoanManager.ZeroAddress.selector);
        this.deployManager(address(0), address(voter), address(cm), _settings());
        vm.expectRevert(ILoanManager.ZeroAddress.selector);
        this.deployManager(address(btc), address(0), address(cm), _settings());
    }

    function test_RevertWhen_ConstructorAuctionParamsOutOfBounds() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        CreditMarkets markets = new CreditMarkets(
            address(musd), address(btc), predicted, owner, guardian, treasury, FEE_SHARE, 10e18, uint32(WEEK), ""
        );
        ILoanManager.Settings memory settings = _settings();
        settings.penaltyBps = 1_001;
        vm.expectRevert(
            abi.encodeWithSelector(ILoanManager.AuctionParamsOutOfBounds.selector, 1_001, FLOOR, DURATION)
        );
        new LoanManager(address(ve), address(feed), address(musd), address(btc), address(voter), address(markets), 4, settings);
    }

    function test_SetAuctionParams_UpdatesAndEmits() public {
        vm.startPrank(owner);
        vm.expectEmit(address(lm));
        emit ILoanManager.AuctionParamsSet(1_000, 9_500, 7 days);
        lm.setAuctionParams(1_000, 9_500, 7 days);
        assertEq(lm.penaltyBps(), 1_000);
        assertEq(lm.auctionFloorBps(), 9_500);
        assertEq(lm.auctionDuration(), 7 days);
        lm.setAuctionParams(0, LIQ_LTV + 1, 1 hours);
        assertEq(lm.penaltyBps(), 0);
        assertEq(lm.auctionFloorBps(), LIQ_LTV + 1);
        assertEq(lm.auctionDuration(), 1 hours);
        vm.stopPrank();
    }

    function test_RevertWhen_AuctionParamsOutOfBounds() public {
        uint16[6] memory penalties = [uint16(1_001), PENALTY, PENALTY, PENALTY, PENALTY, PENALTY];
        uint16[6] memory floors = [FLOOR, uint16(4_999), uint16(9_501), LIQ_LTV, FLOOR, FLOOR];
        uint32[6] memory durations = [DURATION, DURATION, DURATION, DURATION, uint32(1 hours - 1), uint32(7 days + 1)];
        vm.startPrank(owner);
        for (uint256 i; i < penalties.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ILoanManager.AuctionParamsOutOfBounds.selector, penalties[i], floors[i], durations[i]
                )
            );
            lm.setAuctionParams(penalties[i], floors[i], durations[i]);
        }
        vm.stopPrank();
    }

    function test_RevertWhen_RiskLineReachesFloor() public {
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.RiskParamsOutOfBounds.selector, MAX_LTV, FLOOR));
        vm.prank(owner);
        lm.setRiskParams(MAX_LTV, FLOOR);
    }

    function test_RevertWhen_SetAuctionParamsNotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vm.prank(guardian);
        lm.setAuctionParams(PENALTY, FLOOR, DURATION);
    }

    function test_Views_IsOverdueAndIsUnsafe() public {
        assertFalse(lm.isOverdue(TOKEN));
        assertFalse(lm.isUnsafe(TOKEN));
        _openLoan();
        assertFalse(lm.isOverdue(TOKEN));
        assertFalse(lm.isUnsafe(TOKEN));
        _makeUnsafe(TOKEN);
        assertTrue(lm.isUnsafe(TOKEN));
        vm.warp(m1);
        assertFalse(lm.isOverdue(TOKEN), "on time at the maturity instant");
        vm.warp(m1 + 1);
        assertTrue(lm.isOverdue(TOKEN));
    }

    function test_C7_IsUnsafeRevertsWhenPriceUnavailable() public {
        feed.setStale(true);
        assertFalse(lm.isUnsafe(TOKEN), "no loan needs no price");
        feed.setStale(false);
        _openLoan();
        feed.setStale(true);
        vm.expectRevert(ILoanManager.PriceUnavailable.selector);
        lm.isUnsafe(TOKEN);
    }

    function test_StartAuction_UnsafeSnapshotsCurve() public {
        uint256 face = _openLoan();
        _makeUnsafe(TOKEN);
        uint256 value = _usdValue(TOKEN);
        uint256 floorPrice = Math.max(value * FLOOR / BPS, Math.min(face, value));

        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.AuctionStarted(TOKEN, m1, false, face, value, floorPrice, DURATION, PENALTY);
        vm.prank(bob);
        lm.startAuction(TOKEN);

        ILoanManager.Auction memory a = lm.auctionOf(TOKEN);
        assertEq(a.startTime, block.timestamp);
        assertEq(a.duration, DURATION);
        assertEq(a.penaltyBps, PENALTY);
        assertEq(a.startValue, value);
        assertEq(a.floorPrice, floorPrice);
        assertEq(uint8(lm.loanOf(TOKEN).state), uint8(ILoanManager.LoanState.Auction));
        assertEq(cm.marketOf(m1).openLoans, 1, "an auction does not close the loan");
    }

    function test_StartAuction_OverdueEvenWhenSafe() public {
        uint256 face = _openLoan();
        vm.warp(m1 + 1);
        assertFalse(lm.isUnsafe(TOKEN));
        uint256 value = _usdValue(TOKEN);
        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.AuctionStarted(TOKEN, m1, true, face, value, value * FLOOR / BPS, DURATION, PENALTY);
        lm.startAuction(TOKEN);
    }

    function test_RevertWhen_StartAuctionSafeAndOnTime() public {
        _openLoan();
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotLiquidatable.selector, TOKEN));
        lm.startAuction(TOKEN);
        vm.warp(m1);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotLiquidatable.selector, TOKEN));
        lm.startAuction(TOKEN);
    }

    function test_RevertWhen_StartAuctionWithoutActiveLoan() public {
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LoanNotActive.selector, TOKEN));
        lm.startAuction(TOKEN);
        _auctionUnsafe();
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LoanNotActive.selector, TOKEN));
        lm.startAuction(TOKEN);
    }

    function test_C7_StartAuctionRevertsWhenPriceUnavailable() public {
        _openLoan();
        vm.warp(m1 + 1);
        feed.setStale(true);
        vm.expectRevert(ILoanManager.PriceUnavailable.selector);
        lm.startAuction(TOKEN);
    }

    function test_C2_StartAuctionRevertsWhenCustodyLost() public {
        _openLoan();
        vm.warp(m1 + 1);
        ve.forceTransfer(address(lm), bob, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotInCustody.selector, TOKEN));
        lm.startAuction(TOKEN);
    }

    function test_AuctionPrice_FallsLinearlyThenFlat() public {
        _auctionUnsafe();
        ILoanManager.Auction memory a = lm.auctionOf(TOKEN);
        uint256 drop = uint256(a.startValue) - a.floorPrice;
        assertEq(lm.auctionPrice(TOKEN), a.startValue, "starts at the full value");
        vm.warp(block.timestamp + DURATION / 4);
        assertEq(lm.auctionPrice(TOKEN), a.startValue - drop / 4);
        vm.warp(a.startTime + DURATION / 2);
        assertEq(lm.auctionPrice(TOKEN), a.startValue - drop / 2);
        vm.warp(a.startTime + DURATION);
        assertEq(lm.auctionPrice(TOKEN), a.floorPrice);
        vm.warp(a.startTime + DURATION + 30 days);
        assertEq(lm.auctionPrice(TOKEN), a.floorPrice, "flat after the floor time");
    }

    function test_RevertWhen_AuctionPriceWithoutAuction() public {
        _openLoan();
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NoAuction.selector, TOKEN));
        lm.auctionPrice(TOKEN);
    }

    function test_C11_RecoveredLoanCannotBeBoughtAndCanBeCancelled() public {
        uint256 face = _auctionUnsafe();
        feed.setPrice(PRICE);

        vm.expectRevert(abi.encodeWithSelector(ILoanManager.StillSafe.selector, TOKEN));
        _buy(buyer);

        vm.expectEmit(true, false, false, true, address(lm));
        emit ILoanManager.AuctionCancelled(TOKEN, face, _usdValue(TOKEN));
        vm.prank(bob);
        lm.cancelAuction(TOKEN);
        assertEq(uint8(lm.loanOf(TOKEN).state), uint8(ILoanManager.LoanState.Active));
        assertEq(lm.auctionOf(TOKEN).startTime, 0);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        _makeUnsafe(TOKEN);
        lm.startAuction(TOKEN);
        ILoanManager.Auction memory fresh = lm.auctionOf(TOKEN);
        assertEq(fresh.startTime, block.timestamp, "the next trigger starts a new auction");
        assertEq(fresh.startValue, _usdValue(TOKEN), "from a fresh value");
    }

    function test_RevertWhen_CancelStillUnsafe() public {
        _auctionUnsafe();
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.StillUnsafe.selector, TOKEN));
        lm.cancelAuction(TOKEN);
    }

    function test_RevertWhen_CancelOverdue() public {
        _auctionOverdue();
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LoanOverdue.selector, TOKEN));
        lm.cancelAuction(TOKEN);
    }

    function test_RevertWhen_CancelWithoutAuction() public {
        _openLoan();
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NoAuction.selector, TOKEN));
        lm.cancelAuction(TOKEN);
    }

    function test_C11_PurchaseSplitsSumToPrice() public {
        uint256 face = _auctionUnsafe();
        uint256 price = lm.auctionPrice(TOKEN);
        uint256 penalty = face * PENALTY / BPS;
        Balances memory before = _snapshot(m1, alice);
        uint256 buyerBefore = musd.balanceOf(buyer);

        vm.expectEmit(true, true, true, true, address(lm));
        emit ILoanManager.Purchased(TOKEN, buyer, alice, price, face, penalty, price - face - penalty);
        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.LoanClosed(TOKEN, m1);
        uint256 paid = _buy(buyer);

        Balances memory afterB = _snapshot(m1, alice);
        uint256 toMarket = afterB.collectedMusd - before.collectedMusd;
        uint256 toTreasury = afterB.treasuryMusd - before.treasuryMusd;
        uint256 toBorrower = afterB.claimMusd - before.claimMusd;
        assertEq(paid, price);
        assertEq(buyerBefore - musd.balanceOf(buyer), paid, "buyer paid exactly the price");
        assertEq(toMarket + toTreasury + toBorrower, paid, "splits sum to P");
        assertEq(toMarket, face, "market gets the debt");
        assertEq(toTreasury, penalty);
        assertEq(musd.balanceOf(address(lm)), lm.totalClaimableMusd(), "LoanManager holds exactly the claimables");
        assertEq(ve.ownerOf(TOKEN), buyer);
        assertEq(cm.marketOf(m1).openLoans, 0);
    }

    function test_C11_BorrowerGetsTheRest() public {
        uint256 face = _auctionUnsafe();
        vm.warp(vm.getBlockTimestamp() + DURATION / 3);
        uint256 price = lm.auctionPrice(TOKEN);
        _buy(buyer);
        uint256 rest = price - face - face * PENALTY / BPS;
        assertGt(rest, 0);
        assertEq(lm.claimableMusd(alice), rest, "the borrower keeps everything above debt and penalty");
        assertEq(lm.claimableMusd(buyer), 0);
        assertEq(lm.totalClaimableMusd(), rest);
    }

    function test_C11_PurchaseAtFloorPaysPenaltyOnlyFromSurplus() public {
        uint256 face = _auctionUnsafe();
        vm.warp(_floorTime(TOKEN));
        uint256 price = lm.auctionPrice(TOKEN);
        assertEq(price, lm.auctionOf(TOKEN).floorPrice);
        uint256 treasuryBefore = musd.balanceOf(treasury);
        _buy(buyer);
        uint256 toTreasury = musd.balanceOf(treasury) - treasuryBefore;
        assertEq(cm.marketOf(m1).collectedMusd, face);
        assertEq(toTreasury, Math.min(face * PENALTY / BPS, price - face));
        assertEq(lm.claimableMusd(alice), price - face - toTreasury);
    }

    function test_C29_BorrowerBuyingOwnPositionPaysAtLeastDebt() public {
        uint256 face = _openLoan();
        // 80% LTV: value * 70% is below the debt, so the floor is lifted to the debt itself.
        feed.setPrice(_priceAtLtv(TOKEN, 8_000));
        lm.startAuction(TOKEN);
        ILoanManager.Auction memory a = lm.auctionOf(TOKEN);
        assertLt(uint256(a.startValue) * FLOOR / BPS, face);
        assertEq(a.floorPrice, face, "floor = min(debt, start value) = debt");

        vm.warp(_floorTime(TOKEN));
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.PriceAboveMax.selector, face, face - 1));
        vm.prank(alice);
        lm.purchase(TOKEN, face - 1, block.timestamp);

        vm.prank(alice);
        uint256 paid = lm.purchase(TOKEN, face, block.timestamp);
        assertEq(paid, face, "cannot pay below the debt");
        assertEq(cm.marketOf(m1).collectedMusd, face, "market receives the full debt");
        assertEq(ve.ownerOf(TOKEN), alice);

        vm.warp(m1 + 1);
        cm.finalize(m1);
        vm.startPrank(lender);
        uint256 units = cm.claimUnits(m1);
        (uint256 musdOut,) = cm.redeem(m1, units);
        vm.stopPrank();
        assertEq(musdOut, units, "lender is paid one MUSD per unit");
    }

    function test_C29_UnderwaterSalePaysMarketTheStartValue() public {
        uint256 face = _openLoan();
        feed.setPrice(_priceAtLtv(TOKEN, 12_000));
        lm.startAuction(TOKEN);
        uint256 startValue = lm.auctionOf(TOKEN).startValue;
        assertLt(startValue, face);
        assertEq(lm.auctionOf(TOKEN).floorPrice, startValue, "flat at the start value");
        vm.warp(_floorTime(TOKEN));
        assertEq(_buy(buyer), startValue);
        assertEq(cm.marketOf(m1).collectedMusd, startValue);
        assertEq(lm.claimableMusd(alice), 0);
    }

    function test_C13_BuyerThatRejectsNftHooksStillReceivesIt() public {
        _auctionUnsafe();
        RevertingReceiver hostile = new RevertingReceiver();
        uint256 price = lm.auctionPrice(TOKEN);
        musd.mint(address(hostile), price);
        vm.prank(address(hostile));
        musd.approve(address(lm), price);

        vm.prank(address(hostile));
        lm.purchase(TOKEN, price, block.timestamp);
        assertEq(ve.ownerOf(TOKEN), address(hostile), "transferFrom runs no receiver hook");
    }

    function test_Purchase_OverdueSellsWithoutAPrice() public {
        uint256 face = _auctionOverdue();
        feed.setStale(true);
        uint256 paid = _buy(buyer);
        assertEq(cm.marketOf(m1).collectedMusd, face);
        assertGt(paid, face);
    }

    function test_RevertWhen_PurchaseAfterDeadline() public {
        _auctionUnsafe();
        uint256 deadline = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.DeadlinePassed.selector, deadline));
        vm.prank(buyer);
        lm.purchase(TOKEN, type(uint256).max, deadline);
    }

    function test_RevertWhen_PurchaseAboveMaxPay() public {
        _auctionUnsafe();
        uint256 price = lm.auctionPrice(TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.PriceAboveMax.selector, price, price - 1));
        vm.prank(buyer);
        lm.purchase(TOKEN, price - 1, block.timestamp);
    }

    function test_RevertWhen_PurchaseWithoutAuction() public {
        _openLoan();
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NoAuction.selector, TOKEN));
        _buy(buyer);
    }

    function test_C2_PurchaseRevertsWhenCustodyLost() public {
        _auctionUnsafe();
        ve.forceTransfer(address(lm), bob, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotInCustody.selector, TOKEN));
        _buy(buyer);
    }

    function test_RevertWhen_PrepareSettleBeforeFloorTime() public {
        _auctionOverdue();
        uint256 floorTime = _floorTime(TOKEN);
        vm.warp(floorTime - 1);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.FloorTimeNotReached.selector, TOKEN, floorTime));
        lm.prepareSettle(TOKEN);
    }

    function test_RevertWhen_PrepareSettleNothingToPrepare() public {
        _auctionOverdue();
        vm.warp(_floorTime(TOKEN));
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NothingToPrepare.selector, TOKEN));
        lm.prepareSettle(TOKEN);
    }

    function test_PrepareSettle_ResetsVoteAfterTheEpochTurns() public {
        voter.vote(TOKEN);
        _auctionOverdue();
        vm.warp(_floorTime(TOKEN));

        vm.expectEmit(true, false, false, true, address(lm));
        emit ILoanManager.SettlePrepared(TOKEN, true, false, false);
        vm.expectCall(address(voter), abi.encodeCall(IPoolsVoter.reset, (TOKEN)));
        vm.prank(bob);
        lm.prepareSettle(TOKEN);
        assertFalse(ve.voted(TOKEN));
    }

    function test_PrepareSettle_SurfacesTheVoterEpochRules() public {
        voter.vote(TOKEN);
        _openLoan();
        vm.prank(owner);
        lm.setAuctionParams(PENALTY, FLOOR, 1 hours);
        _makeUnsafe(TOKEN);
        lm.startAuction(TOKEN);
        vm.warp(_floorTime(TOKEN));

        vm.expectRevert(MockPoolsVoter.AlreadyVotedOrDeposited.selector);
        lm.prepareSettle(TOKEN);
        uint256 nextEpoch = (vm.getBlockTimestamp() / WEEK + 1) * WEEK;
        vm.warp(nextEpoch + 30 minutes);
        vm.expectRevert(MockPoolsVoter.DistributeWindow.selector);
        lm.prepareSettle(TOKEN);
        vm.warp(nextEpoch + 1 hours + 1);
        lm.prepareSettle(TOKEN);
        assertFalse(ve.voted(TOKEN));
    }

    function test_PrepareSettle_UnlocksPermanentLockThenSettleRuns() public {
        ve.setLock(TOKEN, LOCK_BTC, 0, true);
        voter.vote(TOKEN);
        uint256 face = _auctionOverdue();
        vm.warp(_floorTime(TOKEN));
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LockIsPermanent.selector, TOKEN));
        lm.settle(TOKEN);

        vm.expectEmit(true, false, false, true, address(lm));
        emit ILoanManager.SettlePrepared(TOKEN, true, false, true);
        lm.prepareSettle(TOKEN);
        (, uint256 end, bool isPermanent) = lm.lockOf(TOKEN);
        assertFalse(isPermanent);
        assertEq(end, (block.timestamp + 28 days) / WEEK * WEEK);

        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LockNotEnded.selector, TOKEN, end));
        lm.settle(TOKEN);
        vm.warp(end);
        lm.settle(TOKEN);
        assertEq(cm.marketOf(m1).collectedBtc, Math.mulDiv(face, 1e18, PRICE, Math.Rounding.Ceil));
        cm.finalize(m1);
    }

    function test_C12_SettleSplitsSumToMeasuredBtc() public {
        uint256 face = _readyToSettle();
        uint256 received = uint256(int256(LOCK_BTC));
        uint256 toMarket = Math.mulDiv(face, 1e18, PRICE, Math.Rounding.Ceil);
        uint256 toTreasury = (face * PENALTY / BPS) * 1e18 / PRICE;
        uint256 toBorrower = received - toMarket - toTreasury;
        Balances memory before = _snapshot(m1, alice);

        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.Settled(TOKEN, alice, received, PRICE, toMarket, toTreasury, toBorrower);
        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.LoanClosed(TOKEN, m1);
        vm.prank(bob);
        lm.settle(TOKEN);

        Balances memory afterB = _snapshot(m1, alice);
        uint256 sum = (afterB.collectedBtc - before.collectedBtc) + (afterB.treasuryBtc - before.treasuryBtc)
            + (afterB.claimBtc - before.claimBtc);
        assertEq(sum, received, "splits sum to the BTC received");
        assertEq(afterB.collectedBtc, toMarket);
        assertEq(afterB.claimBtc, toBorrower);
        assertEq(btc.balanceOf(address(cm)), toMarket);
        assertEq(btc.balanceOf(address(lm)), lm.totalClaimableBtc(), "LoanManager holds exactly the claimables");
        assertEq(btc.allowance(address(lm), address(cm)), 0, "approval spent in the same call");
        assertEq(ve.ownerOf(TOKEN), address(0), "NFT burned by withdraw");
        assertEq(cm.marketOf(m1).openLoans, 0);
    }

    function test_C12_SettleUsesMeasuredBtcNotLockedAmount() public {
        uint256 face = _readyToSettle();
        btc.mint(address(lm), 5e18);
        ve.setWithdrawPayout(TOKEN, 0.9e18);

        lm.settle(TOKEN);
        uint256 toMarket = Math.mulDiv(face, 1e18, PRICE, Math.Rounding.Ceil);
        uint256 toTreasury = btc.balanceOf(treasury);
        assertEq(cm.marketOf(m1).collectedBtc, toMarket);
        assertEq(toMarket + toTreasury + lm.claimableBtc(alice), 0.9e18, "split the 0.9 BTC that arrived");
        assertEq(btc.balanceOf(address(lm)), lm.totalClaimableBtc() + 5e18, "the stray 5 BTC belongs to nobody");
    }

    function test_C12_SettleRevertsBeforeFloorTime() public {
        _auctionOverdue();
        uint256 floorTime = _floorTime(TOKEN);
        vm.warp(floorTime - 1);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.FloorTimeNotReached.selector, TOKEN, floorTime));
        lm.settle(TOKEN);
    }

    function test_C12_SettleRevertsBeforeLockEnd() public {
        _auctionOverdue();
        vm.warp(_floorTime(TOKEN));
        assertLt(block.timestamp, m3);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LockNotEnded.selector, TOKEN, uint256(m3)));
        lm.settle(TOKEN);
    }

    function test_C12_SettleRevertsOnPermanentLock() public {
        ve.setLock(TOKEN, LOCK_BTC, 0, true);
        _auctionOverdue();
        vm.warp(m3 + 1);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LockIsPermanent.selector, TOKEN));
        lm.settle(TOKEN);
    }

    function test_C12_SettleRevertsWhileVoted() public {
        _readyToSettle();
        ve.setVoted(TOKEN, true);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.StillVoted.selector, TOKEN));
        lm.settle(TOKEN);
    }

    function test_C7_SettleRevertsWhenPriceUnavailable() public {
        _readyToSettle();
        feed.setStale(true);
        vm.expectRevert(ILoanManager.PriceUnavailable.selector);
        lm.settle(TOKEN);
    }

    function test_C2_SettleRevertsWhenCustodyLost() public {
        _readyToSettle();
        ve.forceTransfer(address(lm), bob, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotInCustody.selector, TOKEN));
        lm.settle(TOKEN);
    }

    function test_Settle_UnderwaterGivesMarketEveryBtc() public {
        uint256 face = _readyToSettle();
        uint256 lowPrice = face / 2;
        feed.setPrice(lowPrice);
        lm.settle(TOKEN);
        assertEq(cm.marketOf(m1).collectedBtc, uint256(int256(LOCK_BTC)));
        assertEq(btc.balanceOf(treasury), 0);
        assertEq(lm.claimableBtc(alice), 0);
    }

    function test_FullCycle_LenderRedeemsBtcAfterSettle() public {
        _readyToSettle();
        lm.settle(TOKEN);
        cm.finalize(m1);
        ICreditMarkets.Market memory market = cm.marketOf(m1);
        assertEq(market.btcAtFinal, market.collectedBtc);
        assertEq(market.musdAtFinal, 0);

        vm.startPrank(lender);
        uint256 units = cm.claimUnits(m1);
        (uint256 musdOut, uint256 btcOut) = cm.redeem(m1, units);
        vm.stopPrank();
        vm.startPrank(treasury);
        (, uint256 feeBtc) = cm.redeem(m1, cm.claimUnits(m1));
        vm.stopPrank();

        assertEq(musdOut, 0);
        assertEq(btcOut, Math.mulDiv(units, market.btcAtFinal, market.unitsAtFinal));
        assertEq(btc.balanceOf(lender), btcOut, "lender holds the Bitcoin");
        assertLe(btcOut + feeBtc, market.btcAtFinal);
    }

    function test_C2_WriteOffAfterCustodyLoss() public {
        uint256 face = _openLoan();
        ve.forceTransfer(address(lm), bob, TOKEN);

        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.WrittenOff(TOKEN, m1, face);
        vm.prank(bob);
        lm.writeOff(TOKEN);

        assertEq(cm.marketOf(m1).openLoans, 0);
        assertEq(cm.marketOf(m1).collectedMusd, 0, "zero recovery");
        assertEq(lm.positionOf(TOKEN).borrower, address(0));
        vm.warp(m1 + 1);
        cm.finalize(m1);
        assertTrue(cm.marketOf(m1).isFinal, "the market can still become final");
    }

    function test_C2_WriteOffDuringAuction() public {
        _auctionUnsafe();
        ve.forceTransfer(address(lm), bob, TOKEN);
        lm.writeOff(TOKEN);
        assertEq(lm.auctionOf(TOKEN).startTime, 0);
        assertEq(cm.marketOf(m1).openLoans, 0);
    }

    function test_RevertWhen_WriteOffStillInCustody() public {
        _auctionUnsafe();
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.StillInCustody.selector, TOKEN));
        lm.writeOff(TOKEN);
    }

    function test_RevertWhen_WriteOffWithoutLoan() public {
        _deposit(alice, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NoActiveLoan.selector, TOKEN));
        lm.writeOff(TOKEN);
    }

    function test_C9_PartialRepayDuringAuctionKeepsTheAuction() public {
        uint256 face = _auctionUnsafe();
        vm.prank(alice);
        lm.repay(TOKEN, face / 2);
        assertEq(uint8(lm.loanOf(TOKEN).state), uint8(ILoanManager.LoanState.Auction));
        assertEq(cm.marketOf(m1).collectedMusd, face / 2);
        assertFalse(lm.isUnsafe(TOKEN), "half the debt is under the line");
        lm.cancelAuction(TOKEN);
        assertEq(uint8(lm.loanOf(TOKEN).state), uint8(ILoanManager.LoanState.Active));
    }

    function test_C9_FullRepayDuringAuctionEndsItAndKeepsThePosition() public {
        uint256 face = _auctionUnsafe();
        vm.prank(alice);
        lm.repay(TOKEN, face);
        assertEq(uint8(lm.loanOf(TOKEN).state), uint8(ILoanManager.LoanState.None));
        assertEq(lm.auctionOf(TOKEN).startTime, 0, "auction deleted");
        assertEq(lm.positionOf(TOKEN).borrower, alice, "the NFT stays in the borrower's position");
        _assertNoOtherEnding(TOKEN, m1);
        vm.prank(alice);
        lm.withdrawCollateral(TOKEN);
        assertEq(ve.ownerOf(TOKEN), alice);
    }

    function test_C9_OnlyOneEndingAfterPurchase() public {
        _auctionUnsafe();
        _buy(buyer);
        _assertNoOtherEnding(TOKEN, m1);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotBorrower.selector, TOKEN));
        vm.prank(alice);
        lm.withdrawCollateral(TOKEN);
    }

    function test_C9_OnlyOneEndingAfterSettle() public {
        _readyToSettle();
        lm.settle(TOKEN);
        _assertNoOtherEnding(TOKEN, m1);
        assertEq(lm.positionOf(TOKEN).borrower, address(0));
    }

    function test_C9_OnlyOneEndingAfterWriteOff() public {
        _auctionUnsafe();
        ve.forceTransfer(address(lm), bob, TOKEN);
        lm.writeOff(TOKEN);
        _assertNoOtherEnding(TOKEN, m1);
    }

    function test_C9_OnlyOneEndingAfterFullRepay() public {
        uint256 face = _openLoan();
        vm.prank(alice);
        lm.repay(TOKEN, face);
        _assertNoOtherEnding(TOKEN, m1);
    }

    function test_C9_ReturningTokenStartsEmpty() public {
        _auctionUnsafe();
        _buy(buyer);
        uint256 aliceClaim = lm.claimableMusd(alice);

        feed.setPrice(PRICE);
        _deposit(buyer, TOKEN);
        assertEq(lm.positionOf(TOKEN).borrower, buyer);
        assertEq(uint8(lm.loanOf(TOKEN).state), uint8(ILoanManager.LoanState.None));
        assertEq(lm.auctionOf(TOKEN).startTime, 0);
        assertEq(lm.owedOf(TOKEN), 0);
        _borrow(buyer, TOKEN, m2, offerM2, 1_000e18);
        assertEq(lm.loanOf(TOKEN).face, cm.marketOf(m2).faceTotal);
        assertEq(lm.claimableMusd(alice), aliceClaim, "the old borrower's claim is untouched");
    }

    function test_C19_AuctionParamChangeDoesNotTouchRunningAuctionOrLiveLoan() public {
        uint256 face = _auctionUnsafe();
        ve.mint(bob, TOKEN_B, LOCK_BTC, m3, false);
        _deposit(bob, TOKEN_B);
        feed.setPrice(PRICE);
        _borrow(bob, TOKEN_B, m1, offerM1, PRINCIPAL);
        _makeUnsafe(TOKEN);
        ILoanManager.Auction memory snapshot = lm.auctionOf(TOKEN);

        vm.startPrank(owner);
        lm.setAuctionParams(1_000, 9_500, 1 hours);
        lm.setRiskParams(1_000, 2_000);
        vm.stopPrank();

        ILoanManager.Auction memory still = lm.auctionOf(TOKEN);
        assertEq(abi.encode(still), abi.encode(snapshot), "running auction unchanged");
        vm.warp(snapshot.startTime + DURATION / 2);
        uint256 expected = snapshot.startValue - (uint256(snapshot.startValue) - snapshot.floorPrice) / 2;
        assertEq(lm.auctionPrice(TOKEN), expected, "still on the old 72-hour curve");
        uint256 treasuryBefore = musd.balanceOf(treasury);
        _buy(buyer);
        assertEq(musd.balanceOf(treasury) - treasuryBefore, face * PENALTY / BPS, "old 5% penalty");

        assertEq(lm.loanOf(TOKEN_B).liqLtvBps, LIQ_LTV, "live loan keeps its line");
        feed.setPrice(_priceAtLtv(TOKEN_B, 5_000));
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotLiquidatable.selector, TOKEN_B));
        lm.startAuction(TOKEN_B);
    }

    function test_C19_ResolutionStepsAreNeverPaused() public {
        ve.mint(alice, TOKEN_B, LOCK_BTC, m2, false);
        _openLoan();
        _deposit(alice, TOKEN_B);
        _borrow(alice, TOKEN_B, m1, offerM1, 1_000e18);
        vm.startPrank(guardian);
        lm.setBorrowsPaused(true);
        cm.setOffersPaused(true);
        vm.stopPrank();

        vm.warp(m1 + 1);
        lm.startAuction(TOKEN);
        lm.startAuction(TOKEN_B);
        _buy(buyer);
        vm.warp(m2 + 1);
        lm.settle(TOKEN_B);
        vm.prank(alice);
        lm.claim();
        cm.finalize(m1);
        assertTrue(cm.marketOf(m1).isFinal);
    }

    function test_C28_ClaimPaysOnceAndTotalsMatch() public {
        ve.mint(alice, TOKEN_B, LOCK_BTC, m2, false);
        _openLoan();
        _deposit(alice, TOKEN_B);
        _borrow(alice, TOKEN_B, m1, offerM1, 1_000e18);
        vm.warp(m1 + 1);
        lm.startAuction(TOKEN);
        lm.startAuction(TOKEN_B);
        _buy(buyer);
        vm.warp(m2 + 1);
        lm.settle(TOKEN_B);

        uint256 musdOwed = lm.claimableMusd(alice);
        uint256 btcOwed = lm.claimableBtc(alice);
        assertGt(musdOwed, 0);
        assertGt(btcOwed, 0);
        assertEq(lm.totalClaimableMusd(), musdOwed);
        assertEq(lm.totalClaimableBtc(), btcOwed);
        assertEq(musd.balanceOf(address(lm)), musdOwed);
        assertEq(btc.balanceOf(address(lm)), btcOwed);

        uint256 musdBefore = musd.balanceOf(alice);
        vm.expectEmit(true, false, false, true, address(lm));
        emit ILoanManager.Claimed(alice, musdOwed, btcOwed);
        vm.prank(alice);
        (uint256 musdOut, uint256 btcOut) = lm.claim();
        assertEq(musdOut, musdOwed);
        assertEq(btcOut, btcOwed);
        assertEq(musd.balanceOf(alice) - musdBefore, musdOwed);
        assertEq(btc.balanceOf(alice), btcOwed);
        assertEq(lm.totalClaimableMusd(), 0);
        assertEq(lm.totalClaimableBtc(), 0);

        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NothingToClaim.selector, alice));
        vm.prank(alice);
        lm.claim();
    }

    function test_RevertWhen_ClaimNothing() public {
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NothingToClaim.selector, bob));
        vm.prank(bob);
        lm.claim();
    }

    function testFuzz_PurchaseSplitSumsToPrice(
        uint256 lockBtc,
        uint256 principal,
        uint256 ltvAtAuction,
        uint256 penalty,
        uint256 elapsed
    ) public {
        lockBtc = bound(lockBtc, 0.01e18, 5e18);
        ve.setLock(TOKEN, int128(int256(lockBtc)), m3, false);
        principal = bound(principal, MIN_LOAN, Math.min(lockBtc * PRICE / 1e18 * 39 / 100, OFFER));
        penalty = bound(penalty, 0, 1_000);
        vm.prank(owner);
        lm.setAuctionParams(uint16(penalty), FLOOR, DURATION);
        _deposit(alice, TOKEN);
        (, uint256 face) = _borrow(alice, TOKEN, m1, offerM1, uint128(principal));

        feed.setPrice(_priceAtLtv(TOKEN, bound(ltvAtAuction, 6_600, 40_000)));
        lm.startAuction(TOKEN);
        vm.warp(block.timestamp + bound(elapsed, 0, 2 * uint256(DURATION)));
        uint256 startValue = lm.auctionOf(TOKEN).startValue;

        Balances memory before = _snapshot(m1, alice);
        uint256 paid = _buy(buyer);
        Balances memory afterB = _snapshot(m1, alice);
        uint256 toMarket = afterB.collectedMusd - before.collectedMusd;
        uint256 toTreasury = afterB.treasuryMusd - before.treasuryMusd;
        uint256 toBorrower = afterB.claimMusd - before.claimMusd;

        assertEq(toMarket + toTreasury + toBorrower, paid, "splits sum to P");
        assertEq(toMarket, Math.min(paid, face));
        assertEq(toTreasury, Math.min(face * penalty / BPS, paid - toMarket));
        assertGe(paid, Math.min(face, startValue), "C29 floor");
        assertEq(musd.balanceOf(address(lm)), lm.totalClaimableMusd());
    }

    function testFuzz_SettleSplitSumsToReceived(
        uint256 lockBtc,
        uint256 principal,
        uint256 settlePrice,
        uint256 penalty,
        uint256 payout
    ) public {
        lockBtc = bound(lockBtc, 0.01e18, 5e18);
        ve.setLock(TOKEN, int128(int256(lockBtc)), m3, false);
        principal = bound(principal, MIN_LOAN, Math.min(lockBtc * PRICE / 1e18 * 39 / 100, OFFER));
        penalty = bound(penalty, 0, 1_000);
        vm.prank(owner);
        lm.setAuctionParams(uint16(penalty), FLOOR, DURATION);
        _deposit(alice, TOKEN);
        (, uint256 face) = _borrow(alice, TOKEN, m1, offerM1, uint128(principal));
        vm.warp(m1 + 1);
        lm.startAuction(TOKEN);
        vm.warp(m3 + 1);

        settlePrice = bound(settlePrice, 1e18, 10_000_000e18);
        feed.setPrice(settlePrice);
        payout = bound(payout, 0, 2 * lockBtc);
        ve.setWithdrawPayout(TOKEN, payout);

        Balances memory before = _snapshot(m1, alice);
        lm.settle(TOKEN);
        Balances memory afterB = _snapshot(m1, alice);
        uint256 toMarket = afterB.collectedBtc - before.collectedBtc;
        uint256 toTreasury = afterB.treasuryBtc - before.treasuryBtc;
        uint256 toBorrower = afterB.claimBtc - before.claimBtc;

        assertEq(toMarket + toTreasury + toBorrower, payout, "splits sum to the BTC measured");
        assertEq(toMarket, Math.min(payout, Math.mulDiv(face, 1e18, settlePrice, Math.Rounding.Ceil)));
        assertEq(toTreasury, Math.min(payout - toMarket, (face * penalty / BPS) * 1e18 / settlePrice));
        assertEq(btc.balanceOf(address(lm)), lm.totalClaimableBtc());
        assertEq(btc.balanceOf(address(cm)), afterB.collectedBtc);
    }
}
