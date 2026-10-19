// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CreditMarkets} from "../../src/CreditMarkets.sol";
import {LoanManager} from "../../src/LoanManager.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {MockMUSD} from "./MockMUSD.sol";
import {MockBTC} from "./MockBTC.sol";
import {MockVeBTC} from "./MockVeBTC.sol";
import {MockPriceFeed} from "./MockPriceFeed.sol";
import {MockPoolsVoter} from "./MockPoolsVoter.sol";
import {MockFeeDistributor} from "./MockFeeDistributor.sol";

/// @notice Shared deployment for the LoanManager resolution and roll tests: the real CreditMarkets and
/// LoanManager on mocks for veBTC, PriceFeed, PoolsVoter, ValidatorsVoter, MUSD and BTC, at the risk study's settings
/// (40% borrow limit, 65% line, 70% floor, 72-hour auction, 5% penalty). One 1 BTC position worth 80,000 MUSD
/// belongs to alice and locks until the third maturity; a lender has 100,000 MUSD on offer at each maturity.
abstract contract LoanFixture is Test {
    uint256 internal constant WEEK = 604_800;
    // A Friday 03:00 UTC, so the first maturity (next Thursday) is six days and 21 hours away.
    uint256 internal constant T0 = 2_963 * WEEK + 1 days + 3 hours;
    uint256 internal constant PRICE = 80_000e18;
    uint256 internal constant TOKEN = 7;
    int128 internal constant LOCK_BTC = 1e18;
    uint16 internal constant MAX_LTV = 4_000;
    uint16 internal constant LIQ_LTV = 6_500;
    uint128 internal constant MIN_LOAN = 10e18;
    uint16 internal constant FEE_SHARE = 1_000;
    uint16 internal constant PENALTY = 500;
    uint16 internal constant FLOOR = 7_000;
    uint32 internal constant DURATION = 72 hours;
    uint16 internal constant APR = 800;
    uint128 internal constant OFFER = 100_000e18;
    uint128 internal constant PRINCIPAL = 30_000e18;

    MockMUSD internal musd;
    MockBTC internal btc;
    MockVeBTC internal ve;
    MockPriceFeed internal feed;
    MockPoolsVoter internal voter;
    MockPoolsVoter internal validators;
    MockFeeDistributor internal dist;
    CreditMarkets internal cm;
    LoanManager internal lm;

    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal lender = makeAddr("lender");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal buyer = makeAddr("buyer");

    uint64 internal m1;
    uint64 internal m2;
    uint64 internal m3;
    uint256 internal offerM1;
    uint256 internal offerM2;
    uint256 internal offerM3;

    function setUp() public virtual {
        vm.warp(T0);
        m1 = uint64((T0 / WEEK + 1) * WEEK);
        m2 = m1 + uint64(WEEK);
        m3 = m2 + uint64(WEEK);

        musd = new MockMUSD();
        btc = new MockBTC();
        ve = new MockVeBTC(4, btc);
        voter = new MockPoolsVoter(ve);
        validators = new MockPoolsVoter(ve);
        dist = new MockFeeDistributor(ve, btc);
        feed = new MockPriceFeed(PRICE);
        (cm, lm) = _deploy();

        musd.mint(lender, 1_000_000e18);
        vm.startPrank(lender);
        musd.approve(address(cm), type(uint256).max);
        offerM1 = cm.postOffer(m1, APR, OFFER);
        offerM2 = cm.postOffer(m2, APR, OFFER);
        offerM3 = cm.postOffer(m3, APR, OFFER);
        vm.stopPrank();

        ve.mint(alice, TOKEN, LOCK_BTC, m3, false);
        address[3] memory payers = [alice, bob, buyer];
        for (uint256 i; i < payers.length; ++i) {
            musd.mint(payers[i], 1_000_000e18);
            vm.prank(payers[i]);
            musd.approve(address(lm), type(uint256).max);
        }
    }

    function _settings() internal view virtual returns (ILoanManager.Settings memory) {
        return ILoanManager.Settings({
            owner: owner,
            guardian: guardian,
            feeDistributor: address(dist),
            validatorsVoter: address(validators),
            maxVotes: 30,
            maxLtvBps: MAX_LTV,
            liqLtvBps: LIQ_LTV,
            minLoan: MIN_LOAN,
            penaltyBps: PENALTY,
            auctionFloorBps: FLOOR,
            auctionDuration: DURATION
        });
    }

    function _deploy() internal returns (CreditMarkets markets, LoanManager manager) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        markets = new CreditMarkets(
            address(musd), address(btc), predicted, owner, guardian, treasury, FEE_SHARE, 10e18, uint32(4 * WEEK), ""
        );
        manager = new LoanManager(
            address(ve), address(feed), address(musd), address(btc), address(voter), address(markets), 4, _settings()
        );
        assertEq(address(manager), predicted);
    }

    /// @dev External so a constructor revert under vm.expectRevert is caught from a real call. LoanManager links
    ///      the PassThrough library, so forge deploys it through vm.deployCode, and a revert there would end the
    ///      test as a pass and skip every case after it.
    function deployManager(address btc_, address voter_, address markets, ILoanManager.Settings memory settings)
        external
        returns (LoanManager)
    {
        return new LoanManager(address(ve), address(feed), address(musd), btc_, voter_, markets, 4, settings);
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

    /// @dev Alice deposits TOKEN and borrows PRINCIPAL due at m1. Returns the face.
    function _openLoan() internal returns (uint256 face) {
        _deposit(alice, TOKEN);
        (, face) = _borrow(alice, TOKEN, m1, offerM1, PRINCIPAL);
    }

    /// @dev A price that puts the loan's debt at `ltvBps` of the position's value. Rounding the price down
    ///      leaves the ratio a hair above `ltvBps`.
    function _priceAtLtv(uint256 tokenId, uint256 ltvBps) internal view returns (uint256) {
        (uint256 btcAmount,,) = lm.lockOf(tokenId);
        return lm.owedOf(tokenId) * 10_000 * 1e18 / (ltvBps * btcAmount);
    }

    /// @dev Drops the price until the loan sits at 66% LTV, just over the 65% line.
    function _makeUnsafe(uint256 tokenId) internal {
        feed.setPrice(_priceAtLtv(tokenId, 6_600));
        assertTrue(lm.isUnsafe(tokenId), "fixture: loan should be unsafe");
    }

    function _usdValue(uint256 tokenId) internal view returns (uint256 usdValue) {
        (, usdValue) = lm.collateralValue(tokenId);
    }
}
