// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Unit tests for LoanManager's M1 surface (custody, borrow, repay, withdraw, views, settings) wired to a real
// CreditMarkets, with mocks for veBTC, PriceFeed and MUSD. It does NOT cover: real veBTC behaviour such as
// transfer rules, vote state or Mezo upgrades (test/fork does that for real positions), auctions, settle,
// write-offs and claims (Resolution.t.sol), roll (Roll.t.sol), reward pass-through (milestone 2b), or
// randomised sequences (CreditInvariants.t.sol).

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {CreditMarkets} from "../../src/CreditMarkets.sol";
import {LoanManager} from "../../src/LoanManager.sol";
import {ICreditMarkets} from "../../src/interfaces/ICreditMarkets.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {LockReader} from "../../src/libraries/LockReader.sol";
import {Quote} from "../../src/libraries/Quote.sol";
import {MockMUSD} from "../utils/MockMUSD.sol";
import {MockBTC} from "../utils/MockBTC.sol";
import {MockVeBTC} from "../utils/MockVeBTC.sol";
import {MockPriceFeed} from "../utils/MockPriceFeed.sol";
import {MockPoolsVoter} from "../utils/MockPoolsVoter.sol";
import {RevertingReceiver} from "../utils/RevertingReceiver.sol";

contract LoanManagerTest is Test {
    uint256 internal constant WEEK = 604_800;
    uint256 internal constant T0 = 2_963 * WEEK + 1 days + 3 hours;
    uint256 internal constant PRICE = 80_000e18;
    uint256 internal constant TOKEN = 7;
    int128 internal constant LOCK_BTC = 1e18;
    uint16 internal constant MAX_LTV = 5_000;
    uint16 internal constant LIQ_LTV = 6_500;
    uint128 internal constant MIN_LOAN = 10e18;
    uint16 internal constant FEE_SHARE = 1_000;
    // The M1 setter tests move the line up to 9000, so these tests keep the floor at its 9500 ceiling.
    uint16 internal constant AUCTION_FLOOR = 9_500;

    MockMUSD internal musd;
    MockBTC internal btc;
    MockVeBTC internal ve;
    MockPriceFeed internal feed;
    MockPoolsVoter internal voter;
    CreditMarkets internal cm;
    LoanManager internal lm;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal lender = makeAddr("lender");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint64 internal m1;
    uint64 internal m2;
    uint256 internal offerM1;
    uint256 internal offerM2;

    function setUp() public {
        vm.warp(T0);
        m1 = uint64((T0 / WEEK + 1) * WEEK);
        m2 = m1 + uint64(WEEK);

        musd = new MockMUSD();
        btc = new MockBTC();
        ve = new MockVeBTC(4, btc);
        voter = new MockPoolsVoter(ve);
        feed = new MockPriceFeed(PRICE);
        (cm, lm) = _deploy(4);

        musd.mint(lender, 1_000_000e18);
        vm.startPrank(lender);
        musd.approve(address(cm), type(uint256).max);
        offerM1 = cm.postOffer(m1, 800, 100_000e18);
        offerM2 = cm.postOffer(m2, 800, 100_000e18);
        vm.stopPrank();

        ve.mint(alice, TOKEN, LOCK_BTC, m2, false);
        for (uint256 i; i < 2; ++i) {
            address payer = i == 0 ? alice : bob;
            musd.mint(payer, 100_000e18);
            vm.prank(payer);
            musd.approve(address(lm), type(uint256).max);
        }
    }

    function _deploy(uint256 layoutWords) internal returns (CreditMarkets markets, LoanManager manager) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        markets = new CreditMarkets(
            address(musd), address(btc), predicted, owner, guardian, treasury, FEE_SHARE, 10e18, uint32(4 * WEEK)
        );
        manager = _newManager(address(ve), address(feed), address(musd), address(markets), layoutWords, _settings());
        assertEq(address(manager), predicted);
    }

    function _marketsForNextDeploy() internal returns (CreditMarkets) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        return new CreditMarkets(
            address(musd), address(btc), predicted, owner, guardian, treasury, FEE_SHARE, 10e18, uint32(4 * WEEK)
        );
    }

    function _settings() internal view returns (ILoanManager.Settings memory) {
        return _settings(guardian, MAX_LTV, LIQ_LTV, MIN_LOAN);
    }

    function _settings(address guardian_, uint16 maxLtv, uint16 liqLtv, uint128 minLoan)
        internal
        view
        returns (ILoanManager.Settings memory)
    {
        return ILoanManager.Settings({
            owner: owner,
            guardian: guardian_,
            maxLtvBps: maxLtv,
            liqLtvBps: liqLtv,
            minLoan: minLoan,
            penaltyBps: 500,
            auctionFloorBps: AUCTION_FLOOR,
            auctionDuration: 72 hours
        });
    }

    function _newManager(
        address veBTC_,
        address feed_,
        address musd_,
        address markets,
        uint256 layoutWords,
        ILoanManager.Settings memory settings
    ) internal returns (LoanManager) {
        return new LoanManager(veBTC_, feed_, musd_, address(btc), address(voter), markets, layoutWords, settings);
    }

    function _deposit(address who, uint256 tokenId) internal {
        vm.startPrank(who);
        ve.approve(address(lm), tokenId);
        lm.deposit(tokenId);
        vm.stopPrank();
    }

    function _one(uint256 offerId, uint128 amount) internal pure returns (uint256[] memory ids, uint128[] memory amounts) {
        ids = new uint256[](1);
        amounts = new uint128[](1);
        ids[0] = offerId;
        amounts[0] = amount;
    }

    function _borrow(address who, uint256 tokenId, uint64 maturity, uint256 offerId, uint128 amount)
        internal
        returns (uint256 principal, uint256 face)
    {
        (uint256[] memory ids, uint128[] memory amounts) = _one(offerId, amount);
        vm.prank(who);
        return lm.borrow(tokenId, maturity, ids, amounts, 5_000);
    }

    function test_Constructor_WiresEverything() public view {
        assertEq(address(lm.veBTC()), address(ve));
        assertEq(address(lm.priceFeed()), address(feed));
        assertEq(address(lm.musd()), address(musd));
        assertEq(address(lm.creditMarkets()), address(cm));
        assertEq(lm.lockLayoutWords(), 4);
        assertEq(lm.owner(), owner);
        assertEq(lm.guardian(), guardian);
        assertEq(lm.maxLtvBps(), MAX_LTV);
        assertEq(lm.liqLtvBps(), LIQ_LTV);
        assertEq(lm.minLoan(), MIN_LOAN);
        assertEq(musd.allowance(address(lm), address(cm)), type(uint256).max);
        assertEq(ve.getApproved(TOKEN), address(0));
        assertFalse(ve.isApprovedForAll(address(lm), alice));
    }

    function test_C27_ConstructorRevertsWhenMarketsPointElsewhere() public {
        CreditMarkets elsewhere = new CreditMarkets(
            address(musd), address(btc), makeAddr("someoneElse"), owner, guardian, treasury, FEE_SHARE, 10e18, uint32(WEEK)
        );
        vm.expectRevert(ILoanManager.CreditMarketsMismatch.selector);
        _newManager(address(ve), address(feed), address(musd), address(elsewhere), 4, _settings());
    }

    function test_RevertWhen_ConstructorMusdMismatch() public {
        MockMUSD other = new MockMUSD();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        CreditMarkets markets = new CreditMarkets(
            address(other), address(btc), predicted, owner, guardian, treasury, FEE_SHARE, 10e18, uint32(WEEK)
        );
        vm.expectRevert(ILoanManager.MusdMismatch.selector);
        _newManager(address(ve), address(feed), address(musd), address(markets), 4, _settings());
    }

    function test_RevertWhen_ConstructorBadLayout() public {
        uint256[2] memory bad = [uint256(2), 5];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ILoanManager.BadLockLayout.selector, bad[i]));
            _newManager(address(ve), address(feed), address(musd), address(cm), bad[i], _settings());
        }
    }

    function test_RevertWhen_ConstructorZeroAddress() public {
        vm.expectRevert(ILoanManager.ZeroAddress.selector);
        _newManager(address(0), address(feed), address(musd), address(cm), 4, _settings());
        vm.expectRevert(ILoanManager.ZeroAddress.selector);
        _newManager(address(ve), address(0), address(musd), address(cm), 4, _settings());
        vm.expectRevert(ILoanManager.ZeroAddress.selector);
        _newManager(address(ve), address(feed), address(0), address(cm), 4, _settings());
        vm.expectRevert(ILoanManager.ZeroAddress.selector);
        _newManager(address(ve), address(feed), address(musd), address(0), 4, _settings());

        CreditMarkets markets = _marketsForNextDeploy();
        vm.expectRevert(ILoanManager.ZeroAddress.selector);
        _newManager(address(ve), address(feed), address(musd), address(markets), 4, _settings(address(0), MAX_LTV, LIQ_LTV, MIN_LOAN));
    }

    function test_RevertWhen_ConstructorParamsOutOfBounds() public {
        CreditMarkets markets = _marketsForNextDeploy();
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.RiskParamsOutOfBounds.selector, 6_500, 6_500));
        _newManager(address(ve), address(feed), address(musd), address(markets), 4, _settings(guardian, 6_500, 6_500, MIN_LOAN));

        markets = _marketsForNextDeploy();
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.MinLoanOutOfBounds.selector, 0));
        _newManager(address(ve), address(feed), address(musd), address(markets), 4, _settings(guardian, MAX_LTV, LIQ_LTV, 0));
    }

    function test_Deposit_TakesCustodyAndRecordsBorrower() public {
        vm.prank(alice);
        ve.approve(address(lm), TOKEN);
        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.Deposited(TOKEN, alice);
        vm.prank(alice);
        lm.deposit(TOKEN);

        assertEq(ve.ownerOf(TOKEN), address(lm));
        assertEq(lm.positionOf(TOKEN).borrower, alice);
        assertEq(uint8(lm.loanOf(TOKEN).state), uint8(ILoanManager.LoanState.None));
    }

    function test_RevertWhen_DepositByNonOwner() public {
        vm.prank(alice);
        ve.approve(address(lm), TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotTokenOwner.selector, TOKEN));
        vm.prank(bob);
        lm.deposit(TOKEN);
    }

    function test_RevertWhen_DepositMissingToken() public {
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotTokenOwner.selector, 999));
        vm.prank(alice);
        lm.deposit(999);
    }

    function test_RevertWhen_DepositWithoutApproval() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(lm), TOKEN)
        );
        vm.prank(alice);
        lm.deposit(TOKEN);
    }

    function test_RevertWhen_DepositTransferDoesNotArrive() public {
        ve.setTransfersIgnored(true);
        vm.startPrank(alice);
        ve.approve(address(lm), TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.CustodyCheckFailed.selector, TOKEN));
        lm.deposit(TOKEN);
        vm.stopPrank();
    }

    function test_C2_DepositRefusesManagedOrLockedEscrow() public {
        vm.prank(alice);
        ve.approve(address(lm), TOKEN);
        for (uint8 kind = 1; kind <= 2; ++kind) {
            ve.setEscrowType(TOKEN, kind);
            vm.expectRevert(abi.encodeWithSelector(ILoanManager.CollateralNotAccepted.selector, TOKEN));
            vm.prank(alice);
            lm.deposit(TOKEN);
        }
    }

    function test_C2_DepositRefusesGrantBackedPosition() public {
        ve.setGrantManager(TOKEN, makeAddr("grantManager"));
        vm.startPrank(alice);
        ve.approve(address(lm), TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.CollateralNotAccepted.selector, TOKEN));
        lm.deposit(TOKEN);
        vm.stopPrank();
    }

    function test_C1_PlainTransferNeverBecomesAPosition() public {
        vm.prank(alice);
        ve.transferFrom(alice, address(lm), TOKEN);
        assertEq(ve.ownerOf(TOKEN), address(lm));

        address[2] memory callers = [bob, alice];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotTokenOwner.selector, TOKEN));
            lm.deposit(TOKEN);
            (uint256[] memory ids, uint128[] memory amounts) = _one(offerM1, 100e18);
            vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotBorrower.selector, TOKEN));
            lm.borrow(TOKEN, m1, ids, amounts, 5_000);
            vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotBorrower.selector, TOKEN));
            lm.withdrawCollateral(TOKEN);
            vm.expectRevert(abi.encodeWithSelector(ILoanManager.NoActiveLoan.selector, TOKEN));
            lm.repay(TOKEN, 1e18);
            vm.stopPrank();
        }
        assertEq(lm.positionOf(TOKEN).borrower, address(0));
        assertEq(ve.ownerOf(TOKEN), address(lm));
    }

    function test_C1_SafeTransferIntoLoanManagerReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(lm)));
        vm.prank(alice);
        ve.safeTransferFrom(alice, address(lm), TOKEN);
    }

    function test_Borrow_PaysPrincipalAndRecordsLoan() public {
        _deposit(alice, TOKEN);
        (uint256 expectedFace,,) = Quote.quote(10_000e18, 800, m1 - block.timestamp, FEE_SHARE);
        uint256 before = musd.balanceOf(alice);

        vm.expectEmit(true, true, true, true, address(lm));
        emit ILoanManager.Borrowed(TOKEN, alice, m1, 10_000e18, expectedFace);
        (uint256 principal, uint256 face) = _borrow(alice, TOKEN, m1, offerM1, 10_000e18);

        assertEq(principal, 10_000e18);
        assertEq(face, expectedFace);
        assertEq(musd.balanceOf(alice), before + 10_000e18);
        ILoanManager.Loan memory loan = lm.loanOf(TOKEN);
        assertEq(loan.maturity, m1);
        assertEq(loan.face, face);
        assertEq(loan.repaid, 0);
        assertEq(loan.maxLtvBps, MAX_LTV);
        assertEq(loan.liqLtvBps, LIQ_LTV);
        assertEq(uint8(loan.state), uint8(ILoanManager.LoanState.Active));
        assertEq(lm.owedOf(TOKEN), face);
        assertEq(cm.marketOf(m1).openLoans, 1);
    }

    function test_C8_UnitsEqualFace() public {
        _deposit(alice, TOKEN);
        (, uint256 face) = _borrow(alice, TOKEN, m1, offerM1, 12_345e18);
        assertEq(cm.pendingUnits(lender, m1) + cm.pendingUnits(treasury, m1), face);
        assertEq(cm.marketOf(m1).faceTotal, face);
        assertEq(lm.loanOf(TOKEN).face, face);
    }

    function test_Borrow_SnapshotsRiskParams() public {
        _deposit(alice, TOKEN);
        _borrow(alice, TOKEN, m1, offerM1, 1_000e18);
        vm.prank(owner);
        lm.setRiskParams(2_000, 3_000);
        ILoanManager.Loan memory loan = lm.loanOf(TOKEN);
        assertEq(loan.maxLtvBps, MAX_LTV);
        assertEq(loan.liqLtvBps, LIQ_LTV);
    }

    function test_C4_NonBorrowerCannotBorrow() public {
        _deposit(alice, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotBorrower.selector, TOKEN));
        _borrow(bob, TOKEN, m1, offerM1, 1_000e18);
    }

    function test_C4_NonBorrowerCannotWithdraw() public {
        _deposit(alice, TOKEN);
        address[3] memory others = [bob, owner, guardian];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotBorrower.selector, TOKEN));
            vm.prank(others[i]);
            lm.withdrawCollateral(TOKEN);
        }
    }

    function test_C2_BorrowRefusesCollateralThatChanged() public {
        _deposit(alice, TOKEN);
        ve.setEscrowType(TOKEN, 2);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.CollateralNotAccepted.selector, TOKEN));
        _borrow(alice, TOKEN, m1, offerM1, 1_000e18);

        ve.setEscrowType(TOKEN, 0);
        ve.setGrantManager(TOKEN, makeAddr("grantManager"));
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.CollateralNotAccepted.selector, TOKEN));
        _borrow(alice, TOKEN, m1, offerM1, 1_000e18);
    }

    function test_C8_BorrowRejectsOfferForOtherMaturity() public {
        _deposit(alice, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.WrongMaturity.selector, offerM2, m2, m1));
        _borrow(alice, TOKEN, m1, offerM2, 1_000e18);
    }

    function test_C8_BorrowRejectsAprAboveMax() public {
        _deposit(alice, TOKEN);
        (uint256[] memory ids, uint128[] memory amounts) = _one(offerM1, 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(ICreditMarkets.AprAboveMax.selector, offerM1, 800, 700));
        vm.prank(alice);
        lm.borrow(TOKEN, m1, ids, amounts, 700);
    }

    function test_C8_BorrowRejectsShortRemaining() public {
        _deposit(alice, TOKEN);
        vm.expectRevert(
            abi.encodeWithSelector(ICreditMarkets.InsufficientRemaining.selector, offerM1, 100_000e18, 100_000e18 + 1)
        );
        _borrow(alice, TOKEN, m1, offerM1, 100_000e18 + 1);
    }

    function test_C8_BorrowRejectsLtvAboveMax() public {
        _deposit(alice, TOKEN);
        uint256 maxFace = uint256(int256(LOCK_BTC)) * PRICE / 1e18 * MAX_LTV / 10_000;
        (uint256 face,,) = Quote.quote(40_000e18, 800, m1 - block.timestamp, FEE_SHARE);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LtvTooHigh.selector, face, maxFace));
        _borrow(alice, TOKEN, m1, offerM1, 40_000e18);
    }

    function test_C8_BorrowRejectsPrincipalBelowMinLoan() public {
        _deposit(alice, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.BelowMinLoan.selector, MIN_LOAN - 1, MIN_LOAN));
        _borrow(alice, TOKEN, m1, offerM1, MIN_LOAN - 1);
    }

    function test_C8_BorrowRejectsMaturityAfterLockEnd() public {
        ve.setLock(TOKEN, LOCK_BTC, m1, false);
        _deposit(alice, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.MaturityAfterLockEnd.selector, m2, m1));
        _borrow(alice, TOKEN, m2, offerM2, 1_000e18);
    }

    function test_C8_BorrowRejectsInvalidMaturity() public {
        _deposit(alice, TOKEN);
        uint64[3] memory bad = [m1 + 1, m1 - uint64(WEEK), m1 + uint64(4 * WEEK)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ILoanManager.InvalidMaturity.selector, bad[i]));
            _borrow(alice, TOKEN, bad[i], offerM1, 1_000e18);
        }
    }

    function test_RevertWhen_BorrowWithOpenLoan() public {
        _deposit(alice, TOKEN);
        _borrow(alice, TOKEN, m1, offerM1, 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LoanOpen.selector, TOKEN));
        _borrow(alice, TOKEN, m1, offerM1, 1_000e18);
    }

    function test_RevertWhen_BorrowPaused() public {
        _deposit(alice, TOKEN);
        vm.prank(guardian);
        lm.setBorrowsPaused(true);
        vm.expectRevert(ILoanManager.BorrowsPaused.selector);
        _borrow(alice, TOKEN, m1, offerM1, 1_000e18);
    }

    function test_RevertWhen_BorrowCollateralLeftCustody() public {
        _deposit(alice, TOKEN);
        ve.forceTransfer(address(lm), bob, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotInCustody.selector, TOKEN));
        _borrow(alice, TOKEN, m1, offerM1, 1_000e18);
    }

    function test_C7_BorrowRevertsWhenPriceUnavailable() public {
        _deposit(alice, TOKEN);
        feed.setStale(true);
        vm.expectRevert(ILoanManager.PriceUnavailable.selector);
        _borrow(alice, TOKEN, m1, offerM1, 1_000e18);

        feed.setStale(false);
        feed.setPrice(0);
        vm.expectRevert(ILoanManager.PriceUnavailable.selector);
        _borrow(alice, TOKEN, m1, offerM1, 1_000e18);
        vm.expectRevert(ILoanManager.PriceUnavailable.selector);
        lm.collateralValue(TOKEN);
    }

    function test_C6_PermanentLockWithEndZeroIsNotExpired() public {
        ve.setLock(TOKEN, LOCK_BTC, 0, true);
        _deposit(alice, TOKEN);
        (uint256 amount, uint256 end, bool isPermanent) = lm.lockOf(TOKEN);
        assertEq(amount, uint256(int256(LOCK_BTC)));
        assertEq(end, 0);
        assertTrue(isPermanent);

        (, uint256 face) = _borrow(alice, TOKEN, m2, offerM2, 1_000e18);
        assertEq(lm.loanOf(TOKEN).face, face);
    }

    function test_C6_ReaderRejectsTheOtherLayout() public {
        (, LoanManager testnetShaped) = _deploy(3);
        vm.expectRevert(LockReader.LockReadFailed.selector);
        testnetShaped.lockOf(TOKEN);
        vm.expectRevert(LockReader.LockReadFailed.selector);
        testnetShaped.collateralValue(TOKEN);

        ve.setLayoutWords(3);
        vm.expectRevert(LockReader.LockReadFailed.selector);
        lm.lockOf(TOKEN);
        (uint256 amount,,) = testnetShaped.lockOf(TOKEN);
        assertEq(amount, uint256(int256(LOCK_BTC)), "matching layout decodes");
    }

    function test_C6_ReaderRejectsZeroOrNegativeAmount() public {
        _deposit(alice, TOKEN);
        int128[2] memory bad = [int128(0), -1];
        for (uint256 i; i < bad.length; ++i) {
            ve.setLock(TOKEN, bad[i], m2, false);
            vm.expectRevert(LockReader.BadLockAmount.selector);
            lm.lockOf(TOKEN);
            vm.expectRevert(LockReader.BadLockAmount.selector);
            _borrow(alice, TOKEN, m1, offerM1, 1_000e18);
        }
    }

    function test_C6_ReaderRejectsMissingLockedFunction() public {
        LoanManager lmOnNothing;
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        CreditMarkets markets = new CreditMarkets(
            address(musd), address(btc), predicted, owner, guardian, treasury, FEE_SHARE, 10e18, uint32(WEEK)
        );
        lmOnNothing = _newManager(makeAddr("noCode"), address(feed), address(musd), address(markets), 4, _settings());
        vm.expectRevert(LockReader.LockReadFailed.selector);
        lmOnNothing.lockOf(TOKEN);
    }

    function test_C23_RevertingMakerDoesNotStopBorrow() public {
        RevertingReceiver maker = new RevertingReceiver();
        musd.mint(address(maker), 5_000e18);
        uint256 hostileOffer = maker.postOffer(cm, musd, m1, 600, 5_000e18);
        _deposit(alice, TOKEN);

        (uint256 principal, uint256 face) = _borrow(alice, TOKEN, m1, hostileOffer, 2_000e18);

        assertEq(principal, 2_000e18);
        assertEq(lm.loanOf(TOKEN).face, face);
        assertGt(cm.pendingUnits(address(maker), m1), 0);
        assertEq(cm.balanceOf(address(maker), m1), 0);
    }

    function test_Repay_PartialKeepsLoanOpen() public {
        _deposit(alice, TOKEN);
        (, uint256 face) = _borrow(alice, TOKEN, m1, offerM1, 1_000e18);

        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.Repaid(TOKEN, alice, 400e18, face - 400e18);
        vm.prank(alice);
        uint256 paid = lm.repay(TOKEN, 400e18);

        assertEq(paid, 400e18);
        assertEq(lm.loanOf(TOKEN).repaid, 400e18);
        assertEq(lm.owedOf(TOKEN), face - 400e18);
        assertEq(cm.marketOf(m1).collectedMusd, 400e18);
        assertEq(cm.marketOf(m1).openLoans, 1);
    }

    function test_C9_LastRepaymentClosesLoanInSameCall() public {
        _deposit(alice, TOKEN);
        (, uint256 face) = _borrow(alice, TOKEN, m1, offerM1, 1_000e18);
        vm.prank(alice);
        lm.repay(TOKEN, 300e18);
        assertEq(cm.marketOf(m1).openLoans, 1);

        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.LoanClosed(TOKEN, m1);
        vm.prank(alice);
        lm.repay(TOKEN, face - 300e18);

        assertEq(cm.marketOf(m1).openLoans, 0, "falls exactly once");
        assertEq(cm.marketOf(m1).collectedMusd, face);
        ILoanManager.Loan memory loan = lm.loanOf(TOKEN);
        assertEq(uint8(loan.state), uint8(ILoanManager.LoanState.None));
        assertEq(loan.face, 0);
        assertEq(lm.owedOf(TOKEN), 0);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NoActiveLoan.selector, TOKEN));
        vm.prank(alice);
        lm.repay(TOKEN, 1);
    }

    function test_Repay_AnyoneMayPayAndOnlyOwedIsPulled() public {
        _deposit(alice, TOKEN);
        (, uint256 face) = _borrow(alice, TOKEN, m1, offerM1, 1_000e18);
        uint256 before = musd.balanceOf(bob);
        vm.prank(bob);
        uint256 paid = lm.repay(TOKEN, face + 5_000e18);
        assertEq(paid, face);
        assertEq(musd.balanceOf(bob), before - face);
        assertEq(musd.balanceOf(address(lm)), 0);
    }

    function test_Repay_WorksWhilePausedAndAfterMaturity() public {
        _deposit(alice, TOKEN);
        (, uint256 face) = _borrow(alice, TOKEN, m1, offerM1, 1_000e18);
        vm.prank(guardian);
        lm.setBorrowsPaused(true);
        vm.warp(m1 + 3 days);
        vm.prank(alice);
        lm.repay(TOKEN, face);
        assertEq(cm.marketOf(m1).openLoans, 0);
    }

    function test_RevertWhen_RepayZero() public {
        _deposit(alice, TOKEN);
        _borrow(alice, TOKEN, m1, offerM1, 1_000e18);
        vm.expectRevert(ILoanManager.ZeroAmount.selector);
        vm.prank(alice);
        lm.repay(TOKEN, 0);
    }

    function test_Withdraw_ReturnsTokenToBorrower() public {
        _deposit(alice, TOKEN);
        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.Withdrawn(TOKEN, alice);
        vm.prank(alice);
        lm.withdrawCollateral(TOKEN);
        assertEq(ve.ownerOf(TOKEN), alice);
        assertEq(lm.positionOf(TOKEN).borrower, address(0));
    }

    function test_RevertWhen_WithdrawWithOpenLoan() public {
        _deposit(alice, TOKEN);
        _borrow(alice, TOKEN, m1, offerM1, 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LoanOpen.selector, TOKEN));
        vm.prank(alice);
        lm.withdrawCollateral(TOKEN);
    }

    function test_Withdraw_WorksWhileBorrowsPaused() public {
        _deposit(alice, TOKEN);
        vm.prank(guardian);
        lm.setBorrowsPaused(true);
        vm.prank(alice);
        lm.withdrawCollateral(TOKEN);
        assertEq(ve.ownerOf(TOKEN), alice);
    }

    function test_C9_ReturningTokenStartsEmpty() public {
        _deposit(alice, TOKEN);
        (, uint256 face) = _borrow(alice, TOKEN, m1, offerM1, 1_000e18);
        vm.startPrank(alice);
        lm.repay(TOKEN, face);
        lm.withdrawCollateral(TOKEN);
        ve.transferFrom(alice, bob, TOKEN);
        vm.stopPrank();

        _deposit(bob, TOKEN);
        assertEq(lm.positionOf(TOKEN).borrower, bob);
        ILoanManager.Loan memory loan = lm.loanOf(TOKEN);
        assertEq(uint8(loan.state), uint8(ILoanManager.LoanState.None));
        assertEq(loan.face, 0);
        assertEq(loan.repaid, 0);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotBorrower.selector, TOKEN));
        _borrow(alice, TOKEN, m1, offerM1, 1_000e18);
        _borrow(bob, TOKEN, m1, offerM1, 1_000e18);
        assertEq(cm.marketOf(m1).openLoans, 1);
    }

    function test_FullCycle_LenderRedeemsFullFace() public {
        _deposit(alice, TOKEN);
        (, uint256 face) = _borrow(alice, TOKEN, m1, offerM1, 10_000e18);
        vm.prank(alice);
        lm.repay(TOKEN, face);
        vm.warp(m1 + 1);
        cm.finalize(m1);

        vm.startPrank(lender);
        uint256 units = cm.claimUnits(m1);
        (uint256 out,) = cm.redeem(m1, units);
        vm.stopPrank();
        vm.startPrank(treasury);
        (uint256 feeOut,) = cm.redeem(m1, cm.claimUnits(m1));
        vm.stopPrank();

        assertEq(out, units);
        assertEq(out + feeOut, face);
        assertEq(musd.balanceOf(address(cm)), 90_000e18 + 100_000e18, "only unfilled escrow remains");
    }

    function test_CollateralValueAndViews() public {
        (uint256 btcAmount, uint256 usdValue) = lm.collateralValue(TOKEN);
        assertEq(btcAmount, 1e18);
        assertEq(usdValue, 80_000e18);
        feed.setPrice(60_000e18);
        (, usdValue) = lm.collateralValue(TOKEN);
        assertEq(usdValue, 60_000e18);
        assertEq(lm.owedOf(TOKEN), 0);
        assertEq(lm.positionOf(TOKEN).borrower, address(0));
    }

    function test_SetRiskParams_UpdatesAndEmits() public {
        vm.expectEmit(address(lm));
        emit ILoanManager.RiskParamsSet(1_000, 9_000);
        vm.prank(owner);
        lm.setRiskParams(1_000, 9_000);
        assertEq(lm.maxLtvBps(), 1_000);
        assertEq(lm.liqLtvBps(), 9_000);
    }

    function test_RevertWhen_RiskParamsOutOfBounds() public {
        uint16[2][4] memory bad = [[uint16(999), 6_500], [uint16(5_000), 5_000], [uint16(5_000), 9_001], [uint16(6_500), 5_000]];
        vm.startPrank(owner);
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ILoanManager.RiskParamsOutOfBounds.selector, bad[i][0], bad[i][1]));
            lm.setRiskParams(bad[i][0], bad[i][1]);
        }
        vm.stopPrank();
    }

    function test_SetMinLoan_BoundsAndEvent() public {
        vm.startPrank(owner);
        vm.expectEmit(address(lm));
        emit ILoanManager.MinLoanSet(100_000e18);
        lm.setMinLoan(100_000e18);
        assertEq(lm.minLoan(), 100_000e18);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.MinLoanOutOfBounds.selector, 100_000e18 + 1));
        lm.setMinLoan(100_000e18 + 1);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.MinLoanOutOfBounds.selector, 1e18 - 1));
        lm.setMinLoan(1e18 - 1);
        vm.stopPrank();
    }

    function test_SetGuardian_OwnerOnlyAndNonZero() public {
        address next = makeAddr("nextGuardian");
        vm.expectEmit(address(lm));
        emit ILoanManager.GuardianSet(next);
        vm.prank(owner);
        lm.setGuardian(next);
        assertEq(lm.guardian(), next);

        vm.expectRevert(ILoanManager.ZeroAddress.selector);
        vm.prank(owner);
        lm.setGuardian(address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        vm.prank(next);
        lm.setGuardian(next);
    }

    function test_RevertWhen_RiskSettersNotOwner() public {
        bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian);
        vm.startPrank(guardian);
        vm.expectRevert(notOwner);
        lm.setRiskParams(2_000, 3_000);
        vm.expectRevert(notOwner);
        lm.setMinLoan(1e18);
        vm.stopPrank();
    }

    function test_SetBorrowsPaused_GuardianOrOwnerOnly() public {
        vm.expectEmit(address(lm));
        emit ILoanManager.BorrowsPausedSet(true);
        vm.prank(guardian);
        lm.setBorrowsPaused(true);
        assertTrue(lm.borrowsPaused());
        vm.prank(owner);
        lm.setBorrowsPaused(false);
        assertFalse(lm.borrowsPaused());
        vm.expectRevert(ILoanManager.NotGuardianOrOwner.selector);
        vm.prank(bob);
        lm.setBorrowsPaused(true);
    }

    function test_C18_RejectsNativeBTC() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (bool ok,) = address(lm).call{value: 1}("");
        assertFalse(ok);
    }
}
