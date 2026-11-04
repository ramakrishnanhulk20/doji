// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IUnitMarket
/// @notice A market for Doji credit units before their date. A holder lists units of the one CreditMarkets fixed at
///         deployment by sending them here with safeTransferFrom and the terms in the transfer data:
///         abi.encode(uint128 pricePerUnit, uint64 expiry). Buyers take all or part of a listing for MUSD; the
///         seller can take unsold units back at any time, and after expiry anyone can send them back to the seller.
///         A listing price is the seller's ask, never a value of the unit.
interface IUnitMarket {
    /// @dev Every field but `unitsLeft` is fixed when the listing is created. `maturity` is the CreditMarkets token
    ///      id. `feeBps` is the market fee rate snapshotted at listing. `pricePerUnit` is MUSD wei per 1e18 unit wei,
    ///      so 1e18 is par. A zero seller means no such listing; zero `unitsLeft` means it is closed.
    struct Listing {
        address seller;
        uint64 maturity;
        uint64 expiry;
        uint16 feeBps;
        uint128 unitsLeft;
        uint128 pricePerUnit;
    }

    /// @notice `seller` listed `units` units of `maturity` at `pricePerUnit` until `expiry`, at fee rate `feeBps`.
    event Listed(
        uint256 indexed listingId,
        address indexed seller,
        uint64 indexed maturity,
        uint128 units,
        uint128 pricePerUnit,
        uint64 expiry,
        uint16 feeBps
    );
    /// @notice `buyer` bought `units` from a listing for `cost` MUSD, of which `fee` is owed to the treasury and the
    ///         rest went to the seller.
    event Bought(uint256 indexed listingId, address indexed buyer, uint128 units, uint256 cost, uint256 fee);
    /// @notice The seller took the `units` still unsold back and closed the listing.
    event Cancelled(uint256 indexed listingId, address indexed seller, uint128 units);
    /// @notice An expired listing's `units` still unsold went back to its seller and the listing closed.
    event Returned(uint256 indexed listingId, address indexed seller, uint128 units);
    /// @notice The treasury collected `amount` MUSD of fees.
    event FeesClaimed(address indexed treasury, uint256 amount);
    /// @notice Listings created from now on snapshot this fee rate.
    event FeeBpsSet(uint16 feeBps);
    /// @notice Fees owed from now on are claimed by this treasury.
    event TreasurySet(address indexed treasury);
    /// @notice The address that may pause listing and buying, alongside the owner, changed.
    event GuardianSet(address indexed guardian);
    /// @notice Listing and buying were paused or resumed.
    event PausedSet(bool paused);
    /// @notice The owner moved a stray ERC-20 that is not MUSD.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @notice An address argument, setting or transfer sender was the zero address.
    error ZeroAddress();
    /// @notice An amount or unit count was zero where it must be positive.
    error ZeroAmount();
    /// @notice Units arrived from a contract other than the fixed CreditMarkets.
    error NotCreditMarkets(address sender);
    /// @notice Batch transfers never create listings, so they are refused.
    error BatchNotAccepted();
    /// @notice The transfer data is not exactly abi.encode(uint128 pricePerUnit, uint64 expiry).
    error BadListingData();
    /// @notice The price is zero or above par (1e18 MUSD wei per 1e18 unit wei).
    error BadPrice(uint128 pricePerUnit);
    /// @notice The expiry is not in the future.
    error BadExpiry(uint64 expiry);
    /// @notice Listing and buying are paused.
    error MarketPaused();
    /// @notice No listing has this id.
    error ListingNotFound(uint256 listingId);
    /// @notice The listing has fewer units left than asked for.
    error NotEnoughUnits(uint256 listingId, uint128 unitsLeft, uint128 units);
    /// @notice The listing's expiry has been reached, so it can no longer be bought from.
    error ListingExpired(uint256 listingId, uint64 expiry);
    /// @notice The listing's price is above the buyer's maximum.
    error PriceAboveMax(uint256 listingId, uint128 pricePerUnit, uint128 maxPricePerUnit);
    /// @notice A buy would cost nothing.
    error ZeroCost();
    /// @notice The measured MUSD arrival differs from the cost pulled.
    error TransferMismatch(uint256 expected, uint256 received);
    /// @notice Only the listing's seller may cancel it.
    error NotSeller(uint256 listingId);
    /// @notice The listing's expiry has not been reached yet.
    error NotExpired(uint256 listingId, uint64 expiry);
    /// @notice The listing has no units left: it was sold out, cancelled or returned.
    error ListingEmpty(uint256 listingId);
    /// @notice Only the treasury may claim fees.
    error NotTreasury();
    /// @notice No fees are owed.
    error NothingToClaim();
    /// @notice The fee rate is above MAX_FEE_BPS.
    error FeeTooHigh(uint16 feeBps);
    /// @notice Only the guardian or the owner may pause.
    error NotGuardianOrOwner();
    /// @notice Ownership can never be given up, so the fee, treasury, pause and rescue settings always keep an owner.
    error RenounceDisabled();
    /// @notice MUSD is owed to the treasury and units are held for listings, so neither is ever rescued.
    error TokenNotRescuable(address token);

    /// @notice Buys exactly `units` from a listing and sends them to the caller.
    /// @dev Pulls the cost from the caller with transferFrom, so the caller approves this contract for at least
    ///      the cost first (quoteBuy gives it). The cost is units x pricePerUnit / 1e18 rounded up, so it is never
    ///      zero; the fee is cost x the listing's fee rate / 10,000 rounded down; the seller receives cost minus fee
    ///      in the same call and the fee is owed to the treasury. The listing and the fee owed are updated first,
    ///      then the cost is pulled and measured, the seller is paid, and the units are sent last, so the caller's
    ///      ERC-1155 receiver hook runs after every state change. Reverts MarketPaused, ListingNotFound, ZeroAmount,
    ///      NotEnoughUnits (never a partial fill), ListingExpired once now >= expiry, PriceAboveMax, ZeroCost,
    ///      TransferMismatch unless exactly the cost arrived, and whatever the caller's receiver hook reverts with.
    ///      Emits Bought.
    /// @param listingId Listing to buy from.
    /// @param units Units to buy, in unit wei (1e18 is one unit).
    /// @param maxPricePerUnit Highest pricePerUnit the caller accepts.
    /// @return cost MUSD paid by the caller.
    function buy(uint256 listingId, uint128 units, uint128 maxPricePerUnit) external returns (uint256 cost);

    /// @notice The seller takes every unsold unit back and closes the listing. Works at any time: never paused, and
    ///         unaffected by expiry, fee changes or the units' market state.
    /// @dev Zeroes unitsLeft before sending the units to the seller with safeTransferFrom, so a seller contract's
    ///      receiver hook runs after the state change; a seller whose own hook refuses the units cannot cancel.
    ///      Reverts NotSeller (also for an id with no listing) or ListingEmpty. Emits Cancelled.
    /// @param listingId Listing to cancel.
    function cancel(uint256 listingId) external;

    /// @notice Once a listing has expired, anyone can send its unsold units back to the seller and close it. Never
    ///         paused, and unaffected by fee changes or the units' market state.
    /// @dev Zeroes unitsLeft before sending the units to the seller with safeTransferFrom. Reverts ListingNotFound,
    ///      NotExpired while now < expiry, or ListingEmpty. Emits Returned.
    /// @param listingId Listing to return.
    function returnExpired(uint256 listingId) external;

    /// @notice Treasury only. Pays the treasury every fee owed. Never paused.
    /// @dev Zeroes treasuryOwed before the transfer. Reverts NotTreasury or NothingToClaim. Emits FeesClaimed.
    /// @return amount MUSD paid to the treasury.
    function claimFees() external returns (uint256 amount);

    /// @notice Owner only. Sets the fee rate that listings created from now on snapshot; open listings keep theirs.
    /// @dev Reverts OwnableUnauthorizedAccount or FeeTooHigh above MAX_FEE_BPS (100). Emits FeeBpsSet.
    /// @param newFeeBps Fee rate in basis points.
    function setFeeBps(uint16 newFeeBps) external;

    /// @notice Owner only. Sets the treasury, which claims every fee owed from then on, including fees already owed.
    /// @dev Reverts OwnableUnauthorizedAccount or ZeroAddress. Emits TreasurySet.
    /// @param newTreasury New treasury.
    function setTreasury(address newTreasury) external;

    /// @notice Owner only. Sets the guardian.
    /// @dev Reverts OwnableUnauthorizedAccount or ZeroAddress. Emits GuardianSet.
    /// @param newGuardian New guardian.
    function setGuardian(address newGuardian) external;

    /// @notice Pauses or resumes new listings and buys only. Cancel, returnExpired and claimFees are never paused.
    /// @dev Pausing needs the guardian or the owner (NotGuardianOrOwner); resuming needs the owner
    ///      (OwnableUnauthorizedAccount). Emits PausedSet.
    /// @param paused_ True to pause.
    function setPaused(bool paused_) external;

    /// @notice Owner only. Sends a stray ERC-20 that is not MUSD.
    /// @dev MUSD is refused outright because every MUSD held here is owed to the treasury, and the CreditMarkets
    ///      token is refused because every unit held here belongs to an open listing. Reverts
    ///      OwnableUnauthorizedAccount, TokenNotRescuable, ZeroAddress or ZeroAmount. Emits Rescued.
    /// @param token ERC-20 to send.
    /// @param to Receiver.
    /// @param amount Amount to send.
    function rescueToken(address token, address to, uint256 amount) external;

    /// @notice A listing's seller, maturity, expiry, fee rate, units left and price. A zero seller means no listing.
    function listingOf(uint256 listingId) external view returns (Listing memory);

    /// @notice What buying `units` from a listing would cost now, with the same rounding as buy: cost rounded up,
    ///         fee rounded down.
    /// @dev Only prices the units; it does not check units left, expiry or pause. Reverts ListingNotFound.
    /// @param listingId Listing to price.
    /// @param units Units to price, in unit wei.
    /// @return cost MUSD the buyer would pay.
    /// @return fee Part of the cost owed to the treasury.
    function quoteBuy(uint256 listingId, uint128 units) external view returns (uint256 cost, uint256 fee);

    /// @notice The only ERC-1155 contract whose units can be listed, fixed at deployment.
    function creditMarkets() external view returns (address);

    /// @notice The MUSD token buys are paid in, read from CreditMarkets at deployment.
    function musd() external view returns (address);

    /// @notice Address that may pause listing and buying, alongside the owner.
    function guardian() external view returns (address);

    /// @notice Address that claims the fees.
    function treasury() external view returns (address);

    /// @notice Fee rate in basis points that new listings snapshot, at most 100.
    function feeBps() external view returns (uint16);

    /// @notice True while new listings and buys are paused.
    function paused() external view returns (bool);

    /// @notice Id the next listing will get. Ids start at 1 and are never reused.
    function nextListingId() external view returns (uint256);

    /// @notice MUSD fees owed to the treasury and not yet claimed. Always equal to the MUSD this contract holds,
    ///         apart from MUSD sent here unasked, which is credited to nobody.
    function treasuryOwed() external view returns (uint256);
}
