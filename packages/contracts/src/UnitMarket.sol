// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICreditMarkets} from "./interfaces/ICreditMarkets.sol";
import {IUnitMarket} from "./interfaces/IUnitMarket.sol";

/// @title UnitMarket
/// @notice Lets a lender sell Doji credit units before their date. The holder lists by sending units of the fixed
///         CreditMarkets here with safeTransferFrom and abi.encode(uint128 pricePerUnit, uint64 expiry) as data, so
///         no setApprovalForAll is ever asked for. Buyers take exactly the units they ask for at the listed price;
///         the seller can always take unsold units back, and after expiry anyone can return them to the seller.
/// @dev Units are held here only for open listings, and MUSD only as fees owed to the treasury: sellers are paid
///      in the buy itself. Nothing here reads a listing or trade price as the worth of a unit (C47).
contract UnitMarket is IUnitMarket, ERC1155Holder, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint16 public constant MAX_FEE_BPS = 100;
    /// @dev pricePerUnit is MUSD wei per 1e18 unit wei. A unit never pays more than one MUSD, so par is the
    ///      highest price a listing may ask.
    uint256 public constant PRICE_SCALE = 1e18;
    uint256 private constant BPS = 10_000;

    address public immutable creditMarkets;
    address public immutable musd;

    address public guardian;
    address public treasury;
    uint16 public feeBps;
    bool public paused;
    uint256 public nextListingId = 1;
    mapping(uint256 listingId => Listing) private _listings;
    uint256 public treasuryOwed;

    /// @notice Fixes the CreditMarkets whose units can be listed, and its MUSD, for the life of the contract.
    /// @dev Reverts ZeroAddress for a zero CreditMarkets, owner, guardian or treasury, or if CreditMarkets reports a
    ///      zero MUSD; reverts FeeTooHigh above MAX_FEE_BPS. A CreditMarkets address with no code reverts without
    ///      data. Emits GuardianSet, TreasurySet and FeeBpsSet.
    /// @param creditMarkets_ The new-pair CreditMarkets (F31: old-pair units are never accepted).
    /// @param owner_ Starting owner.
    /// @param guardian_ Address that may pause listing and buying, alongside the owner.
    /// @param treasury_ Address that claims the fees.
    /// @param feeBps_ Starting fee rate in basis points, at most 100.
    constructor(address creditMarkets_, address owner_, address guardian_, address treasury_, uint16 feeBps_)
        Ownable(_nonZero(owner_))
    {
        if (creditMarkets_ == address(0)) revert ZeroAddress();
        address musd_ = ICreditMarkets(creditMarkets_).musd();
        if (musd_ == address(0)) revert ZeroAddress();
        creditMarkets = creditMarkets_;
        musd = musd_;
        _setGuardian(guardian_);
        _setTreasury(treasury_);
        _setFeeBps(feeBps_);
    }

    /// @notice Creates a listing from units the holder has just sent here. Called by CreditMarkets during the
    ///         holder's own safeTransferFrom; never call it directly.
    /// @dev The units are already in this contract's balance when this runs. Accepts only the fixed CreditMarkets
    ///      as caller (NotCreditMarkets), so a look-alike or old-pair ERC-1155 can never create a listing. The seller
    ///      is `from`, never the operator and never anything in the data, and a mint (zero `from`) is refused with
    ///      ZeroAddress. Reverts MarketPaused, ZeroAmount for zero units, BadListingData unless the data is exactly
    ///      64 bytes whose words fit uint128 and uint64, BadPrice for a zero price or one above par, and BadExpiry
    ///      unless the expiry is in the future. Any revert undoes the whole transfer, so units sent unasked or with
    ///      bad terms never stay here. Snapshots the current fee rate. Emits Listed.
    /// @param from Holder whose units arrived; becomes the seller.
    /// @param id CreditMarkets token id, the maturity.
    /// @param value Units that arrived, in unit wei.
    /// @param data abi.encode(uint128 pricePerUnit, uint64 expiry).
    /// @return The IERC1155Receiver.onERC1155Received selector.
    function onERC1155Received(address, address from, uint256 id, uint256 value, bytes memory data)
        public
        override
        nonReentrant
        returns (bytes4)
    {
        if (msg.sender != creditMarkets) revert NotCreditMarkets(msg.sender);
        if (paused) revert MarketPaused();
        if (from == address(0)) revert ZeroAddress();
        if (value == 0) revert ZeroAmount();
        (uint128 pricePerUnit, uint64 expiry) = _decodeTerms(data);
        if (pricePerUnit == 0 || pricePerUnit > PRICE_SCALE) revert BadPrice(pricePerUnit);
        // An expiry is days or weeks out, so the seconds a block producer can shift a timestamp do not matter.
        // forge-lint: disable-next-line(block-timestamp)
        if (expiry <= block.timestamp) revert BadExpiry(expiry);

        uint128 units = value.toUint128();
        uint64 maturity = id.toUint64();
        uint16 rate = feeBps;
        uint256 listingId = nextListingId++;
        _listings[listingId] = Listing({
            seller: from, maturity: maturity, expiry: expiry, feeBps: rate, unitsLeft: units, pricePerUnit: pricePerUnit
        });
        emit Listed(listingId, from, maturity, units, pricePerUnit, expiry, rate);
        return this.onERC1155Received.selector;
    }

    /// @notice Always reverts: a batch can carry several ids under one set of terms, so it never creates listings.
    /// @dev Reverts BatchNotAccepted for every caller, which undoes the batch transfer.
    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        pure
        override
        returns (bytes4)
    {
        revert BatchNotAccepted();
    }

    /// @inheritdoc IUnitMarket
    function buy(uint256 listingId, uint128 units, uint128 maxPricePerUnit)
        external
        nonReentrant
        returns (uint256 cost)
    {
        if (paused) revert MarketPaused();
        Listing memory listing = _listings[listingId];
        if (listing.seller == address(0)) revert ListingNotFound(listingId);
        if (units == 0) revert ZeroAmount();
        if (units > listing.unitsLeft) revert NotEnoughUnits(listingId, listing.unitsLeft, units);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= listing.expiry) revert ListingExpired(listingId, listing.expiry);
        if (listing.pricePerUnit > maxPricePerUnit) {
            revert PriceAboveMax(listingId, listing.pricePerUnit, maxPricePerUnit);
        }
        uint256 fee;
        (cost, fee) = _price(units, listing.pricePerUnit, listing.feeBps);
        if (cost == 0) revert ZeroCost();

        _listings[listingId].unitsLeft = listing.unitsLeft - units;
        treasuryOwed += fee;
        // The only call above is the Math library; every token moves after this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Bought(listingId, msg.sender, units, cost, fee);

        _pullExactly(msg.sender, cost);
        IERC20(musd).safeTransfer(listing.seller, cost - fee);
        // Last, because it runs the buyer's receiver hook; every record is already final and the lock is held.
        IERC1155(creditMarkets).safeTransferFrom(address(this), msg.sender, listing.maturity, units, "");
    }

    /// @inheritdoc IUnitMarket
    function cancel(uint256 listingId) external nonReentrant {
        Listing storage listing = _listings[listingId];
        address seller = listing.seller;
        if (msg.sender != seller) revert NotSeller(listingId);
        uint64 maturity = listing.maturity;
        uint128 units = _close(listingId, listing);
        emit Cancelled(listingId, seller, units);

        IERC1155(creditMarkets).safeTransferFrom(address(this), seller, maturity, units, "");
    }

    /// @inheritdoc IUnitMarket
    function returnExpired(uint256 listingId) external nonReentrant {
        Listing storage listing = _listings[listingId];
        address seller = listing.seller;
        if (seller == address(0)) revert ListingNotFound(listingId);
        uint64 expiry = listing.expiry;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < expiry) revert NotExpired(listingId, expiry);
        uint64 maturity = listing.maturity;
        uint128 units = _close(listingId, listing);
        emit Returned(listingId, seller, units);

        IERC1155(creditMarkets).safeTransferFrom(address(this), seller, maturity, units, "");
    }

    /// @inheritdoc IUnitMarket
    function claimFees() external nonReentrant returns (uint256 amount) {
        address to = treasury;
        if (msg.sender != to) revert NotTreasury();
        amount = treasuryOwed;
        if (amount == 0) revert NothingToClaim();
        treasuryOwed = 0;
        emit FeesClaimed(to, amount);

        IERC20(musd).safeTransfer(to, amount);
    }

    /// @inheritdoc IUnitMarket
    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        _setFeeBps(newFeeBps);
    }

    /// @inheritdoc IUnitMarket
    function setTreasury(address newTreasury) external onlyOwner {
        _setTreasury(newTreasury);
    }

    /// @inheritdoc IUnitMarket
    function setGuardian(address newGuardian) external onlyOwner {
        _setGuardian(newGuardian);
    }

    /// @inheritdoc IUnitMarket
    function setPaused(bool paused_) external {
        if (paused_) {
            if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner();
        } else {
            _checkOwner();
        }
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @inheritdoc IUnitMarket
    function rescueToken(address token, address to, uint256 amount) external nonReentrant onlyOwner {
        if (token == creditMarkets) revert TokenNotRescuable(token);
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        // The treasury's fees are the only MUSD anyone is owed here, so MUSD above them arrived unasked (C46).
        if (token == musd) {
            uint256 balance = IERC20(token).balanceOf(address(this));
            uint256 owed = treasuryOwed;
            uint256 surplus = balance > owed ? balance - owed : 0;
            if (amount > surplus) revert RescueExceedsSurplus(token, amount, surplus);
        }
        // The only call above is a balance read of the fixed MUSD.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Rescued(token, to, amount);

        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Always reverts: ownership can never be given up, so the fee, treasury, pause and rescue settings
    ///         always have an owner. Ownership still moves by the two-step transfer.
    /// @dev Reverts RenounceDisabled for every caller.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @inheritdoc IUnitMarket
    function listingOf(uint256 listingId) external view returns (Listing memory) {
        return _listings[listingId];
    }

    /// @inheritdoc IUnitMarket
    function quoteBuy(uint256 listingId, uint128 units) external view returns (uint256 cost, uint256 fee) {
        Listing storage listing = _listings[listingId];
        if (listing.seller == address(0)) revert ListingNotFound(listingId);
        return _price(units, listing.pricePerUnit, listing.feeBps);
    }

    /// @dev Decoded as two raw words and range-checked, so data that abi.decode(data, (uint128, uint64)) would
    ///      reject fails here with BadListingData instead of an empty revert, and anything it would accept passes.
    ///      Both casts follow the check against their type's maximum, so neither can truncate.
    // forge-lint: disable-next-item(unsafe-typecast)
    function _decodeTerms(bytes memory data) private pure returns (uint128 pricePerUnit, uint64 expiry) {
        if (data.length != 64) revert BadListingData();
        (uint256 priceWord, uint256 expiryWord) = abi.decode(data, (uint256, uint256));
        if (priceWord > type(uint128).max || expiryWord > type(uint64).max) revert BadListingData();
        pricePerUnit = uint128(priceWord);
        expiry = uint64(expiryWord);
    }

    /// @dev The one pricing rule, shared by buy and quoteBuy so the UI's allowance always matches the pull (C50).
    ///      Rounding the cost up means a dust buy always pays at least 1 wei; rounding the fee down keeps the seller's
    ///      share at least cost minus 1%.
    function _price(uint128 units, uint128 pricePerUnit, uint16 rate) private pure returns (uint256 cost, uint256 fee) {
        cost = Math.mulDiv(units, pricePerUnit, PRICE_SCALE, Math.Rounding.Ceil);
        fee = cost * rate / BPS;
    }

    /// @dev Zeroes a listing's units before the caller sends them out, so its receiver hook sees the listing closed.
    function _close(uint256 listingId, Listing storage listing) private returns (uint128 units) {
        units = listing.unitsLeft;
        if (units == 0) revert ListingEmpty(listingId);
        listing.unitsLeft = 0;
    }

    /// @dev Reading the balance change, not the return value, means a token that moves less than asked is refused,
    ///      and the fee owed always equals the MUSD held.
    function _pullExactly(address from, uint256 amount) private {
        IERC20 token = IERC20(musd);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert TransferMismatch(amount, received);
    }

    function _setFeeBps(uint16 newFeeBps) private {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh(newFeeBps);
        feeBps = newFeeBps;
        emit FeeBpsSet(newFeeBps);
    }

    function _setTreasury(address newTreasury) private {
        treasury = _nonZero(newTreasury);
        emit TreasurySet(newTreasury);
    }

    function _setGuardian(address newGuardian) private {
        guardian = _nonZero(newGuardian);
        emit GuardianSet(newGuardian);
    }

    /// @dev Also used in the Ownable argument, so a zero owner reverts ZeroAddress before Ownable's own check.
    function _nonZero(address account) private pure returns (address) {
        if (account == address(0)) revert ZeroAddress();
        return account;
    }
}
