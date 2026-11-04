// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Unit and fuzz tests for UnitMarket, the market for selling credit units before their date. Listing happens only
// through the holder's own single transfer of real CreditMarkets units with the terms in the data, and the seller is
// always the transfer's from (C43); a listing's terms and fee rate never change (C44); a buy fills exactly, costs
// at least 1 wei, splits the cost exactly into seller amount and fee, and a re-entering buyer cannot take more
// than is left (C45); cancel and returnExpired work whatever the pause, fee or expiry, fees are a claimable, and
// rescue refuses MUSD and units (C46). Units come from a real borrow on the LoanFixture contracts and claimUnits.
// It does NOT cover: real Mezo contracts (test/fork), the old CreditMarkets pair, fee-on-transfer MUSD (MUSD is
// plain), a seller contract whose own receiver hook refuses its returned units, randomised sequences
// (UnitMarketInvariants.t.sol), or any price a listing should ask (a non-goal: UnitMarket gives no price).

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UnitMarket} from "../../src/UnitMarket.sol";
import {IUnitMarket} from "../../src/interfaces/IUnitMarket.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";
import {MockToken} from "../utils/MockToken.sol";

/// @notice An ERC-1155 anyone can mint, with the same ids as CreditMarkets, standing in for a look-alike or an
///         old-pair units contract. Its musd() reports zero so the constructor's MUSD check can be reached.
contract LookalikeUnits is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    function musd() external pure returns (address) {
        return address(0);
    }
}

/// @notice A buyer whose receiver hook calls buy again on the same listing, once. With `catchInner` it swallows the
///         inner revert so the outer buy can finish; without it the inner revert undoes the whole buy.
contract ReenteringBuyer {
    UnitMarket internal immutable market;
    uint256 internal listingId;
    uint128 internal units;
    bool internal catchInner;
    bool internal entered;
    bool public innerSucceeded;
    bytes public innerError;

    constructor(UnitMarket market_, IERC20 musd_) {
        market = market_;
        musd_.approve(address(market_), type(uint256).max);
    }

    function buy(uint256 listingId_, uint128 units_, bool catchInner_) external returns (uint256) {
        (listingId, units, catchInner) = (listingId_, units_, catchInner_);
        return market.buy(listingId_, units_, type(uint128).max);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        if (!entered) {
            entered = true;
            if (catchInner) {
                try market.buy(listingId, units, type(uint128).max) {
                    innerSucceeded = true;
                } catch (bytes memory reason) {
                    innerError = reason;
                }
            } else {
                market.buy(listingId, units, type(uint128).max);
            }
        }
        return this.onERC1155Received.selector;
    }
}

contract UnitMarketTest is LoanFixture {
    uint16 internal constant FEE_BPS = 25;
    uint128 internal constant PAR = 1e18;
    uint128 internal constant ASK = 0.97e18;

    UnitMarket internal um;
    uint256 internal lenderUnits;
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        um = new UnitMarket(address(cm), owner, guardian, treasury, FEE_BPS);
        _openLoan();
        vm.prank(lender);
        lenderUnits = cm.claimUnits(m1);
        vm.prank(buyer);
        musd.approve(address(um), type(uint256).max);
    }

    function _expiry() internal view returns (uint64) {
        return uint64(vm.getBlockTimestamp() + 3 days);
    }

    function _terms(uint128 price, uint64 expiry) internal pure returns (bytes memory) {
        return abi.encode(price, expiry);
    }

    function _list(uint256 units, uint128 price, uint64 expiry) internal returns (uint256 listingId) {
        listingId = um.nextListingId();
        vm.prank(lender);
        cm.safeTransferFrom(lender, address(um), m1, units, _terms(price, expiry));
    }

    function _buy(uint256 listingId, uint128 units) internal returns (uint256 cost) {
        vm.prank(buyer);
        cost = um.buy(listingId, units, type(uint128).max);
    }

    /// @dev Ceiling division written out by hand, so the test does not reuse the contract's Math call.
    function _cost(uint256 units, uint256 price) internal pure returns (uint256) {
        return (units * price + PAR - 1) / PAR;
    }

    function _expectListRevert(bytes memory data, bytes memory reason) internal {
        vm.expectRevert(reason);
        vm.prank(lender);
        cm.safeTransferFrom(lender, address(um), m1, 1e18, data);
    }

    function test_Constructor_FixesCreditMarketsAndRefusesBadSettings() public {
        assertEq(um.creditMarkets(), address(cm));
        assertEq(um.musd(), address(musd));
        assertEq(um.owner(), owner);
        assertEq(um.guardian(), guardian);
        assertEq(um.treasury(), treasury);
        assertEq(um.feeBps(), FEE_BPS);
        assertEq(um.nextListingId(), 1);
        assertTrue(um.supportsInterface(type(IERC1155Receiver).interfaceId));

        bytes memory zero = abi.encodeWithSelector(IUnitMarket.ZeroAddress.selector);
        vm.expectRevert(zero);
        new UnitMarket(address(0), owner, guardian, treasury, FEE_BPS);
        vm.expectRevert(zero);
        new UnitMarket(address(cm), address(0), guardian, treasury, FEE_BPS);
        vm.expectRevert(zero);
        new UnitMarket(address(cm), owner, address(0), treasury, FEE_BPS);
        vm.expectRevert(zero);
        new UnitMarket(address(cm), owner, guardian, address(0), FEE_BPS);
        address noMusd = address(new LookalikeUnits());
        vm.expectRevert(zero);
        new UnitMarket(noMusd, owner, guardian, treasury, FEE_BPS);
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.FeeTooHigh.selector, 101));
        new UnitMarket(address(cm), owner, guardian, treasury, 101);
        assertEq(new UnitMarket(address(cm), owner, guardian, treasury, 100).feeBps(), 100);
    }

    function test_C43_ListByTransferRecordsSellerPriceAndExpiry() public {
        uint64 expiry = _expiry();
        vm.expectEmit(true, true, true, true, address(um));
        emit IUnitMarket.Listed(1, lender, m1, 1_000e18, ASK, expiry, FEE_BPS);
        uint256 id = _list(1_000e18, ASK, expiry);

        assertEq(id, 1);
        IUnitMarket.Listing memory l = um.listingOf(id);
        assertEq(l.seller, lender, "seller is the transfer's from");
        assertEq(l.maturity, m1);
        assertEq(l.expiry, expiry);
        assertEq(l.feeBps, FEE_BPS);
        assertEq(l.unitsLeft, 1_000e18);
        assertEq(l.pricePerUnit, ASK);
        assertEq(cm.balanceOf(address(um), m1), 1_000e18);
        assertEq(cm.balanceOf(lender, m1), lenderUnits - 1_000e18);

        // An approved operator moving the lender's units still lists them for the lender, never for itself.
        address operator = makeAddr("operator");
        vm.prank(lender);
        cm.setApprovalForAll(operator, true);
        vm.prank(operator);
        cm.safeTransferFrom(lender, address(um), m1, 5e18, _terms(PAR, expiry));
        assertEq(um.listingOf(2).seller, lender, "seller is never the operator");
        assertEq(um.nextListingId(), 3, "ids are never reused");
    }

    function test_C43_BatchTransferReverts() public {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory values = new uint256[](1);
        (ids[0], values[0]) = (m1, 1e18);
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.BatchNotAccepted.selector));
        vm.prank(lender);
        cm.safeBatchTransferFrom(lender, address(um), ids, values, _terms(ASK, _expiry()));
        assertEq(cm.balanceOf(address(um), m1), 0);
        assertEq(um.nextListingId(), 1);
    }

    function test_C43_UnitsFromAnotherErc1155Revert() public {
        LookalikeUnits fake = new LookalikeUnits();
        fake.mint(lender, m1, 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.NotCreditMarkets.selector, address(fake)));
        vm.prank(lender);
        fake.safeTransferFrom(lender, address(um), m1, 1_000e18, _terms(ASK, _expiry()));

        // Calling the hook directly, as if units had arrived, is refused the same way.
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.NotCreditMarkets.selector, stranger));
        vm.prank(stranger);
        um.onERC1155Received(stranger, stranger, m1, 1e18, _terms(ASK, _expiry()));
        assertEq(um.nextListingId(), 1);
    }

    function test_C43_ListingDataOfTheWrongShapeReverts() public {
        bytes memory bad = abi.encodeWithSelector(IUnitMarket.BadListingData.selector);
        uint64 expiry = _expiry();
        _expectListRevert("", bad);
        _expectListRevert(abi.encode(ASK), bad);
        _expectListRevert(abi.encode(ASK, expiry, uint256(1)), bad);
        _expectListRevert(abi.encodePacked(ASK, expiry), bad);
        // 64 bytes, but a word that does not fit its type is not abi.encode(uint128, uint64).
        _expectListRevert(abi.encode(uint256(type(uint128).max) + 1, expiry), bad);
        _expectListRevert(abi.encode(ASK, uint256(type(uint64).max) + 1), bad);

        // Zero units and a mint (no sender) never create a listing either.
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.ZeroAmount.selector));
        vm.prank(lender);
        cm.safeTransferFrom(lender, address(um), m1, 0, _terms(ASK, expiry));
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.ZeroAddress.selector));
        vm.prank(address(cm));
        um.onERC1155Received(address(cm), address(0), m1, 1e18, _terms(ASK, expiry));
        assertEq(um.nextListingId(), 1);
        assertEq(cm.balanceOf(address(um), m1), 0);
    }

    function test_C43_PriceZeroAndAboveParRevert() public {
        uint64 expiry = _expiry();
        _expectListRevert(_terms(0, expiry), abi.encodeWithSelector(IUnitMarket.BadPrice.selector, 0));
        _expectListRevert(_terms(PAR + 1, expiry), abi.encodeWithSelector(IUnitMarket.BadPrice.selector, PAR + 1));
        assertEq(um.listingOf(_list(1e18, PAR, expiry)).pricePerUnit, PAR, "par itself is allowed");
        assertEq(um.listingOf(_list(1e18, 1, expiry)).pricePerUnit, 1, "one wei per unit is allowed");
    }

    function test_C43_ExpiryInThePastReverts() public {
        uint64 now_ = uint64(vm.getBlockTimestamp());
        _expectListRevert(_terms(ASK, now_), abi.encodeWithSelector(IUnitMarket.BadExpiry.selector, now_));
        _expectListRevert(_terms(ASK, now_ - 1), abi.encodeWithSelector(IUnitMarket.BadExpiry.selector, now_ - 1));
        assertEq(um.listingOf(_list(1e18, ASK, now_ + 1)).expiry, now_ + 1);
    }

    function test_C45_BuyCostRoundsUpFeeRoundsDownAndSplitsExactly() public {
        uint128 price = 0.95e18 + 3;
        uint128 units = 1_234.5e18 + 7;
        uint256 id = _list(2_000e18, price, _expiry());
        uint256 cost = _cost(units, price);
        uint256 fee = cost * FEE_BPS / 10_000;
        assertGt(cost * 1e18, uint256(units) * price, "test needs a cost that rounds");
        (uint256 quoted, uint256 quotedFee) = um.quoteBuy(id, units);
        assertEq(quoted, cost, "quote uses buy's rounding");
        assertEq(quotedFee, fee);

        uint256 buyerBefore = musd.balanceOf(buyer);
        uint256 sellerBefore = musd.balanceOf(lender);
        vm.expectEmit(true, true, false, true, address(um));
        emit IUnitMarket.Bought(id, buyer, units, cost, fee);
        assertEq(_buy(id, units), cost);

        assertEq(buyerBefore - musd.balanceOf(buyer), cost, "buyer paid exactly the cost");
        uint256 sellerGot = musd.balanceOf(lender) - sellerBefore;
        assertEq(sellerGot + fee, cost, "seller amount plus fee is the cost");
        assertEq(um.treasuryOwed(), fee);
        assertEq(musd.balanceOf(address(um)), fee, "MUSD held is the fee owed");
        assertEq(cm.balanceOf(buyer, m1), units, "units went to the caller");
        assertEq(um.listingOf(id).unitsLeft, 2_000e18 - units);
        assertEq(cm.balanceOf(address(um), m1), 2_000e18 - units);
    }

    function testFuzz_C45_DustBuyNeverCostsZero(uint256 priceSeed, uint256 unitsSeed) public {
        uint128 price = uint128(bound(priceSeed, 1, PAR));
        uint128 units = uint128(bound(unitsSeed, 1, 1e6));
        uint256 id = _list(1e18, price, _expiry());
        uint256 before = musd.balanceOf(buyer);
        uint256 cost = _buy(id, units);
        assertGe(cost, 1, "a buy never costs 0 MUSD");
        assertEq(cost, _cost(units, price));
        assertEq(before - musd.balanceOf(buyer), cost);
        assertEq(cm.balanceOf(buyer, m1), units);
    }

    function test_C45_OneWeiBuyCostsOneWei() public {
        uint256 id = _list(1e18, 1, _expiry());
        assertEq(_buy(id, 1), 1, "the cheapest possible buy still pays 1 wei");
        assertEq(cm.balanceOf(buyer, m1), 1);
    }

    function test_C45_BuyMoreThanLeftReverts() public {
        uint256 id = _list(100e18, ASK, _expiry());
        _buy(id, 60e18);
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.NotEnoughUnits.selector, id, 40e18, 40e18 + 1));
        vm.prank(buyer);
        um.buy(id, 40e18 + 1, type(uint128).max);
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.ZeroAmount.selector));
        vm.prank(buyer);
        um.buy(id, 0, type(uint128).max);
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.ListingNotFound.selector, 99));
        vm.prank(buyer);
        um.buy(99, 1e18, type(uint128).max);
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.ListingNotFound.selector, 99));
        um.quoteBuy(99, 1e18);

        _buy(id, 40e18);
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.NotEnoughUnits.selector, id, 0, 1));
        vm.prank(buyer);
        um.buy(id, 1, type(uint128).max);
    }

    function test_C45_BuyAtOrAfterExpiryReverts() public {
        uint64 expiry = _expiry();
        uint256 id = _list(100e18, ASK, expiry);
        vm.warp(expiry - 1);
        _buy(id, 1e18);
        vm.warp(expiry);
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.ListingExpired.selector, id, expiry));
        vm.prank(buyer);
        um.buy(id, 1e18, type(uint128).max);
    }

    function test_C45_BuyAboveMaxPriceReverts() public {
        uint256 id = _list(100e18, ASK, _expiry());
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.PriceAboveMax.selector, id, ASK, ASK - 1));
        vm.prank(buyer);
        um.buy(id, 1e18, ASK - 1);
        vm.prank(buyer);
        um.buy(id, 1e18, ASK);
        assertEq(cm.balanceOf(buyer, m1), 1e18);
    }

    function test_C45_ReenteringBuyerCannotBuyMoreThanUnitsLeft() public {
        uint256 id = _list(100e18, ASK, _expiry());
        ReenteringBuyer swallow = new ReenteringBuyer(um, IERC20(address(musd)));
        musd.mint(address(swallow), 1_000e18);
        uint256 cost = swallow.buy(id, 100e18, true);

        assertFalse(swallow.innerSucceeded(), "the second buy inside the hook never lands");
        assertEq(swallow.innerError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(cm.balanceOf(address(swallow), m1), 100e18, "exactly the units asked for, once");
        assertEq(1_000e18 - musd.balanceOf(address(swallow)), cost, "paid once");
        assertEq(um.listingOf(id).unitsLeft, 0);

        // A hook that lets the inner revert through undoes its own buy and leaves the listing whole.
        uint256 id2 = _list(100e18, ASK, _expiry());
        ReenteringBuyer strict = new ReenteringBuyer(um, IERC20(address(musd)));
        musd.mint(address(strict), 1_000e18);
        vm.expectRevert(abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        strict.buy(id2, 60e18, false);
        assertEq(um.listingOf(id2).unitsLeft, 100e18);
        assertEq(cm.balanceOf(address(strict), m1), 0);
        assertEq(musd.balanceOf(address(strict)), 1_000e18);
    }

    function test_C46_SellerCancelsEvenWhilePausedAndAfterExpiry() public {
        uint64 expiry = _expiry();
        uint256 id1 = _list(100e18, ASK, expiry);
        uint256 id2 = _list(200e18, ASK, expiry);
        _buy(id1, 30e18);
        vm.prank(guardian);
        um.setPaused(true);
        vm.prank(owner);
        um.setFeeBps(100);

        uint256 before = cm.balanceOf(lender, m1);
        vm.expectEmit(true, true, false, true, address(um));
        emit IUnitMarket.Cancelled(id1, lender, 70e18);
        vm.prank(lender);
        um.cancel(id1);
        assertEq(cm.balanceOf(lender, m1) - before, 70e18, "every unsold unit came back while paused");

        vm.warp(expiry + 30 days);
        vm.prank(lender);
        um.cancel(id2);
        assertEq(cm.balanceOf(lender, m1) - before, 270e18, "and after expiry and the date");
        assertEq(cm.balanceOf(address(um), m1), 0);

        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.ListingEmpty.selector, id2));
        vm.prank(lender);
        um.cancel(id2);
    }

    function test_C46_CancelByAnyoneElseReverts() public {
        uint256 id = _list(100e18, ASK, _expiry());
        address[4] memory others = [buyer, owner, guardian, treasury];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IUnitMarket.NotSeller.selector, id));
            vm.prank(others[i]);
            um.cancel(id);
        }
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.NotSeller.selector, 99));
        vm.prank(lender);
        um.cancel(99);
        assertEq(um.listingOf(id).unitsLeft, 100e18);
    }

    function test_C46_ReturnExpiredOnlyAfterExpiryAndToTheSeller() public {
        uint64 expiry = _expiry();
        uint256 id = _list(100e18, ASK, expiry);
        _buy(id, 25e18);
        vm.warp(expiry - 1);
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.NotExpired.selector, id, expiry));
        vm.prank(stranger);
        um.returnExpired(id);
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.ListingNotFound.selector, 99));
        um.returnExpired(99);

        vm.warp(expiry);
        vm.prank(guardian);
        um.setPaused(true);
        uint256 before = cm.balanceOf(lender, m1);
        vm.expectEmit(true, true, false, true, address(um));
        emit IUnitMarket.Returned(id, lender, 75e18);
        vm.prank(stranger);
        um.returnExpired(id);
        assertEq(cm.balanceOf(lender, m1) - before, 75e18, "units went to the seller, not the caller");
        assertEq(cm.balanceOf(stranger, m1), 0);
        assertEq(um.listingOf(id).unitsLeft, 0);

        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.ListingEmpty.selector, id));
        um.returnExpired(id);
    }

    function test_C44_FeeChangeAfterListingKeepsTheListingsFee() public {
        uint64 expiry = _expiry();
        uint256 id = _list(100e18, ASK, expiry);
        vm.expectEmit(false, false, false, true, address(um));
        emit IUnitMarket.FeeBpsSet(100);
        vm.prank(owner);
        um.setFeeBps(100);

        uint256 cost = _buy(id, 10e18);
        assertEq(um.treasuryOwed(), cost * FEE_BPS / 10_000, "the listing kept its 25 bps");
        assertEq(um.listingOf(id).feeBps, FEE_BPS);
        assertEq(um.listingOf(_list(1e18, ASK, expiry)).feeBps, 100, "new listings snapshot the new rate");

        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.FeeTooHigh.selector, 101));
        vm.prank(owner);
        um.setFeeBps(101);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vm.prank(guardian);
        um.setFeeBps(0);
    }

    function test_C46_ClaimFeesPaysTheTreasuryExactlyTheFees() public {
        uint64 expiry = _expiry();
        uint256 id1 = _list(100e18, ASK, expiry);
        vm.prank(owner);
        um.setFeeBps(100);
        uint256 id2 = _list(100e18, 0.9e18 + 1, expiry);
        uint256 fees = _buy(id1, 33e18 + 1) * FEE_BPS / 10_000;
        fees += _buy(id2, 50e18) * 100 / 10_000;
        assertEq(um.treasuryOwed(), fees);

        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.NotTreasury.selector));
        vm.prank(owner);
        um.claimFees();

        vm.prank(guardian);
        um.setPaused(true);
        vm.expectEmit(true, false, false, true, address(um));
        emit IUnitMarket.FeesClaimed(treasury, fees);
        vm.prank(treasury);
        assertEq(um.claimFees(), fees);
        assertEq(musd.balanceOf(treasury), fees, "treasury got exactly the fees, while paused");
        assertEq(um.treasuryOwed(), 0);
        assertEq(musd.balanceOf(address(um)), 0);

        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.NothingToClaim.selector));
        vm.prank(treasury);
        um.claimFees();
    }

    function test_C46_PauseStopsOnlyListingAndBuying() public {
        uint256 id = _list(100e18, ASK, _expiry());
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.NotGuardianOrOwner.selector));
        vm.prank(stranger);
        um.setPaused(true);

        vm.expectEmit(false, false, false, true, address(um));
        emit IUnitMarket.PausedSet(true);
        vm.prank(guardian);
        um.setPaused(true);
        assertTrue(um.paused());
        _expectListRevert(_terms(ASK, _expiry()), abi.encodeWithSelector(IUnitMarket.MarketPaused.selector));
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.MarketPaused.selector));
        vm.prank(buyer);
        um.buy(id, 1e18, type(uint128).max);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vm.prank(guardian);
        um.setPaused(false);
        vm.prank(owner);
        um.setPaused(false);
        _buy(id, 1e18);
        assertEq(cm.balanceOf(buyer, m1), 1e18);
    }

    function test_C46_RescueRefusesMusdAndUnits() public {
        _buy(_list(100e18, ASK, _expiry()), 10e18);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.TokenNotRescuable.selector, address(musd)));
        um.rescueToken(address(musd), owner, 1);
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.TokenNotRescuable.selector, address(cm)));
        um.rescueToken(address(cm), owner, 1);

        MockToken stray = new MockToken("STRAY");
        stray.mint(address(um), 5e18);
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.ZeroAddress.selector));
        um.rescueToken(address(stray), address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.ZeroAmount.selector));
        um.rescueToken(address(stray), owner, 0);
        vm.expectEmit(true, true, false, true, address(um));
        emit IUnitMarket.Rescued(address(stray), owner, 5e18);
        um.rescueToken(address(stray), owner, 5e18);
        vm.stopPrank();
        assertEq(stray.balanceOf(owner), 5e18);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vm.prank(guardian);
        um.rescueToken(address(stray), guardian, 1);
        assertEq(cm.balanceOf(address(um), m1), 90e18, "units for the open listing are still here");
        assertEq(musd.balanceOf(address(um)), um.treasuryOwed(), "MUSD owed is still here");
    }

    function test_OwnerSettersAndRenounce() public {
        address newTreasury = makeAddr("newTreasury");
        address newGuardian = makeAddr("newGuardian");
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, false, address(um));
        emit IUnitMarket.TreasurySet(newTreasury);
        um.setTreasury(newTreasury);
        vm.expectEmit(true, false, false, false, address(um));
        emit IUnitMarket.GuardianSet(newGuardian);
        um.setGuardian(newGuardian);
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.ZeroAddress.selector));
        um.setTreasury(address(0));
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.ZeroAddress.selector));
        um.setGuardian(address(0));
        vm.expectRevert(abi.encodeWithSelector(IUnitMarket.RenounceDisabled.selector));
        um.renounceOwnership();
        um.transferOwnership(stranger);
        vm.stopPrank();
        assertEq(um.owner(), owner, "two-step: nothing moves until accepted");
        vm.prank(stranger);
        um.acceptOwnership();
        assertEq(um.owner(), stranger);
        assertEq(um.treasury(), newTreasury);
        assertEq(um.guardian(), newGuardian);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        um.setTreasury(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        um.setGuardian(owner);
    }
}
