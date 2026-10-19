// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICreditMarkets
/// @notice Fixed-rate MUSD offers and one credit market per Thursday maturity. Lenders hold ERC-1155
///         credit units whose token id is the maturity; one unit is one MUSD due on that date.
interface ICreditMarkets {
    struct Offer {
        address maker;
        uint64 maturity;
        uint16 aprBps;
        uint128 remaining;
    }

    struct Market {
        uint128 faceTotal;
        uint128 collectedMusd;
        uint64 openLoans;
        bool isFinal;
        uint128 unitsAtFinal;
        uint128 musdAtFinal;
        uint128 collectedBtc;
        uint128 btcAtFinal;
    }

    /// @notice `maker` escrowed `amount` MUSD as an offer for `maturity` at `aprBps`.
    event OfferPosted(
        uint256 indexed offerId, address indexed maker, uint64 indexed maturity, uint16 aprBps, uint128 amount
    );
    /// @notice An offer's unfilled MUSD went back to its maker.
    event OfferCancelled(uint256 indexed offerId, address indexed maker, uint128 refunded);
    /// @notice An offer lent `principal` MUSD to a loan owing `face` at `maturity`.
    event Filled(uint256 indexed offerId, address indexed maker, uint64 indexed maturity, uint256 principal, uint256 face);
    /// @notice A market received `musdAmount` MUSD from LoanManager.
    event Credited(uint64 indexed maturity, uint256 musdAmount, bool closesLoan);
    /// @notice A market received `btcAmount` BTC from a settled loan.
    event CreditedBtc(uint64 indexed maturity, uint256 btcAmount, bool closesLoan);
    /// @notice `account` minted its recorded credit units for `maturity`.
    event UnitsClaimed(address indexed account, uint64 indexed maturity, uint256 units);
    /// @notice A market closed for good; redemptions pay from these snapshots.
    event MarketFinalized(uint64 indexed maturity, uint256 unitsAtFinal, uint256 musdAtFinal, uint256 btcAtFinal);
    /// @notice `account` burned `units` and received its share of the market's MUSD and BTC.
    event Redeemed(address indexed account, uint64 indexed maturity, uint256 units, uint256 musdOut, uint256 btcOut);
    /// @notice New fills will use this treasury share of interest.
    event FeeShareBpsSet(uint16 feeShareBps);
    /// @notice New offers need at least this amount.
    event MinOfferSet(uint128 minOffer);
    /// @notice Maturities may now be at most this far away.
    event MaxTermSecondsSet(uint32 maxTermSeconds);
    /// @notice Future fee units go to this treasury.
    event TreasurySet(address indexed treasury);
    /// @notice The address that may pause new offers changed.
    event GuardianSet(address indexed guardian);
    /// @notice New offers were paused or resumed.
    event OffersPausedSet(bool paused);
    /// @notice The metadata URI for every credit unit changed; clients replace {id} with the maturity.
    event UriSet(string uri);
    /// @notice The owner moved a stray ERC-20 that is neither MUSD nor BTC.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @notice An address argument or setting was the zero address.
    error ZeroAddress();
    /// @notice An amount was zero where it must be positive.
    error ZeroAmount();
    /// @notice Only LoanManager may fill offers and credit markets.
    error NotLoanManager();
    /// @notice Only the offer's maker may cancel it.
    error NotMaker(uint256 offerId);
    /// @notice Only the guardian or the owner may pause.
    error NotGuardianOrOwner();
    /// @notice New offers are paused.
    error OffersPaused();
    /// @notice The maturity is not a valid, open Thursday within the maximum term.
    error InvalidMaturity(uint64 maturity);
    /// @notice The rate is above the hard-coded cap.
    error AprTooHigh(uint16 aprBps);
    /// @notice The offer is below the minimum offer.
    error OfferTooSmall(uint128 amount, uint128 minOffer);
    /// @notice No offer has this id.
    error OfferNotFound(uint256 offerId);
    /// @notice The offer has nothing left to cancel.
    error OfferEmpty(uint256 offerId);
    /// @notice A fill must list 1 to MAX_FILLS offers.
    error BadFillCount(uint256 count);
    /// @notice Two arrays that pair up have different lengths.
    error LengthMismatch();
    /// @notice A listed offer is for a different maturity.
    error WrongMaturity(uint256 offerId, uint64 offerMaturity, uint64 maturity);
    /// @notice A listed offer's rate is above the borrower's maximum.
    error AprAboveMax(uint256 offerId, uint16 aprBps, uint16 maxAprBps);
    /// @notice A listed offer has less left than the listed amount.
    error InsufficientRemaining(uint256 offerId, uint128 remaining, uint128 amount);
    /// @notice The measured arrival differs from the amount pulled.
    error TransferMismatch(uint256 expected, uint256 received);
    /// @notice The market has no open loan to credit.
    error NoOpenLoans(uint64 maturity);
    /// @notice The market is already final.
    error MarketIsFinal(uint64 maturity);
    /// @notice The market is not final yet.
    error NotFinal(uint64 maturity);
    /// @notice The maturity has not passed.
    error NotMatured(uint64 maturity);
    /// @notice The market still has open loans.
    error LoansStillOpen(uint64 maturity, uint64 openLoans);
    /// @notice The market never had a loan.
    error EmptyMarket(uint64 maturity);
    /// @notice The account has no units waiting for this maturity.
    error NothingToClaim(address account, uint64 maturity);
    /// @notice The fee share is above 2000 basis points.
    error FeeShareOutOfBounds(uint16 feeShareBps);
    /// @notice The minimum offer is outside 1 to 1,000,000 MUSD.
    error MinOfferOutOfBounds(uint128 minOffer);
    /// @notice The maximum term is outside 1 to 12 weeks.
    error MaxTermOutOfBounds(uint32 maxTermSeconds);
    /// @notice MUSD and BTC are recorded per market, so they are never rescued.
    error TokenNotRescuable(address token);

    /// @notice Escrows `amount` MUSD from the caller as a fixed-rate offer for `maturity`.
    /// @dev Pulls exactly `amount` with transferFrom, so the caller approves this contract first.
    ///      Reverts OffersPaused, InvalidMaturity (not a Thursday 00:00 UTC, not in the future, or beyond the
    ///      maximum term), AprTooHigh (above 5000), OfferTooSmall, or TransferMismatch if the measured
    ///      balance increase is not exactly `amount`. Emits OfferPosted.
    /// @param maturity Thursday 00:00 UTC timestamp the loans repay on.
    /// @param aprBps Yearly rate in basis points.
    /// @param amount MUSD to lend, 18 decimals.
    /// @return offerId New offer id. Ids start at 1 and are never reused.
    function postOffer(uint64 maturity, uint16 aprBps, uint128 amount) external returns (uint256 offerId);

    /// @notice Refunds the unfilled part of an offer to its maker. Works at any time and is never paused.
    /// @dev Reverts OfferNotFound, NotMaker, or OfferEmpty if nothing is left. Emits OfferCancelled.
    /// @param offerId Offer to cancel.
    function cancelOffer(uint256 offerId) external;

    /// @notice Fills the listed offers for one loan and sends the total principal to `recipient`.
    /// @dev Only LoanManager. Every offer must exist, be for exactly `maturity`, charge at most `maxAprBps`
    ///      and have at least the listed amount left; each amount must be above zero. The remainder is cut
    ///      before anything else. Units are recorded in storage and minted later by claimUnits, so no maker
    ///      code runs here. Adds one open loan to the market. Emits Filled once per offer.
    /// @param maturity The loan's maturity.
    /// @param offerIds Offers to take, 1 to MAX_FILLS entries.
    /// @param amounts MUSD to take from each offer, same length as `offerIds`.
    /// @param maxAprBps Highest rate the borrower accepts on any listed offer.
    /// @param recipient Receiver of the principal.
    /// @return principal Total MUSD lent.
    /// @return face Total MUSD owed at maturity.
    function fill(
        uint64 maturity,
        uint256[] calldata offerIds,
        uint128[] calldata amounts,
        uint16 maxAprBps,
        address recipient
    ) external returns (uint256 principal, uint256 face);

    /// @notice Books a repayment into a market, pulling the MUSD from LoanManager.
    /// @dev Only LoanManager. The booked amount is the measured balance increase: the pull reverts
    ///      TransferMismatch unless exactly `musdAmount` arrives, and raw balances are never read as totals.
    ///      A zero amount is allowed only when it closes a loan. Reverts MarketIsFinal, NoOpenLoans or
    ///      ZeroAmount. Emits Credited.
    /// @param maturity Market to credit.
    /// @param musdAmount MUSD to pull from LoanManager.
    /// @param closesLoan True on the payment that closes a loan; lowers the open-loan count by one.
    function credit(uint64 maturity, uint256 musdAmount, bool closesLoan) external;

    /// @notice Books Bitcoin from a settled loan into a market, pulling the BTC from LoanManager.
    /// @dev Only LoanManager, which approves exactly `btcAmount` first. Same rules as credit(): the booked
    ///      amount is the measured balance increase and the pull reverts TransferMismatch unless exactly
    ///      `btcAmount` arrives; a zero amount is allowed only when it closes a loan. Reverts MarketIsFinal,
    ///      NoOpenLoans or ZeroAmount. Emits CreditedBtc.
    /// @param maturity Market to credit.
    /// @param btcAmount BTC to pull from LoanManager, 18 decimals.
    /// @param closesLoan True on the credit that closes a loan; lowers the open-loan count by one.
    function creditBtc(uint64 maturity, uint256 btcAmount, bool closesLoan) external;

    /// @notice Mints the caller's recorded credit units for `maturity` as ERC-1155 tokens.
    /// @dev Reverts NothingToClaim. Emits UnitsClaimed. A contract caller must accept ERC-1155 tokens.
    /// @param maturity Market whose units to mint.
    /// @return minted Units minted.
    function claimUnits(uint64 maturity) external returns (uint256 minted);

    /// @notice Closes a market for good once its date has passed and every loan in it is closed.
    /// @dev Anyone can call. Snapshots the units, MUSD and BTC that redemptions pay from. Reverts MarketIsFinal,
    ///      NotMatured, LoansStillOpen or EmptyMarket. Emits MarketFinalized.
    /// @param maturity Market to finalize.
    function finalize(uint64 maturity) external;

    /// @notice Burns the caller's units and pays their pro-rata share of the market's MUSD and BTC.
    /// @dev Burns first, then pays units * musdAtFinal / unitsAtFinal MUSD, capped at one MUSD per unit, and
    ///      units * btcAtFinal / unitsAtFinal BTC, both rounded down. A zero part is not transferred.
    ///      Reverts NotFinal, ZeroAmount, or if the caller holds fewer units. Emits Redeemed.
    /// @param maturity Market to redeem from.
    /// @param units Units to burn.
    /// @return musdOut MUSD paid.
    /// @return btcOut BTC paid.
    function redeem(uint64 maturity, uint256 units) external returns (uint256 musdOut, uint256 btcOut);

    /// @notice Prices a fill at the current time and fee share.
    /// @dev Reverts InvalidMaturity.
    /// @return face MUSD owed at maturity.
    /// @return makerUnits Units the lender would receive.
    /// @return treasuryUnits Units the treasury would receive.
    function quoteFill(uint128 principal, uint16 aprBps, uint64 maturity)
        external
        view
        returns (uint256 face, uint256 makerUnits, uint256 treasuryUnits);

    /// @notice An offer's maker, maturity, rate and unfilled amount. A zero maker means no such offer.
    function offerOf(uint256 offerId) external view returns (Offer memory);

    /// @notice A market's totals and finalization snapshot.
    function marketOf(uint64 maturity) external view returns (Market memory);

    /// @notice Units recorded to `account` for `maturity` and not yet minted.
    function pendingUnits(address account, uint64 maturity) external view returns (uint256);

    /// @notice True when `maturity` is a Thursday 00:00 UTC, is in the future, and is within the maximum term.
    function isValidMaturity(uint64 maturity) external view returns (bool);

    /// @notice The only address allowed to fill offers and credit markets, fixed at deployment.
    function loanManager() external view returns (address);

    /// @notice The MUSD token, fixed at deployment.
    function musd() external view returns (address);

    /// @notice The BTC ERC-20 that settled loans pay markets in, fixed at deployment.
    function btc() external view returns (address);

    /// @notice Furthest a maturity may be from now, in seconds.
    function maxTermSeconds() external view returns (uint32);

    /// @notice Share of interest paid to the treasury as units, in basis points (at most 2000).
    function feeShareBps() external view returns (uint16);

    /// @notice Smallest offer accepted, in MUSD wei.
    function minOffer() external view returns (uint128);

    /// @notice Receiver of fee units.
    function treasury() external view returns (address);

    /// @notice Address that may pause new offers alongside the owner.
    function guardian() external view returns (address);

    /// @notice True while new offers are paused.
    function offersPaused() external view returns (bool);

    /// @notice Id the next posted offer will get.
    function nextOfferId() external view returns (uint256);

    /// @notice Owner only. Sets the fee share for future fills. Reverts FeeShareOutOfBounds above 2000.
    /// Emits FeeShareBpsSet.
    function setFeeShareBps(uint16 newFeeShareBps) external;

    /// @notice Owner only. Sets the minimum offer. Reverts MinOfferOutOfBounds outside 1 to 1,000,000 MUSD.
    /// Emits MinOfferSet.
    function setMinOffer(uint128 newMinOffer) external;

    /// @notice Owner only. Sets the maximum term. Reverts MaxTermOutOfBounds outside 1 to 12 weeks.
    /// Emits MaxTermSecondsSet.
    function setMaxTermSeconds(uint32 newMaxTermSeconds) external;

    /// @notice Owner only. Sets the receiver of future fee units. Reverts ZeroAddress. Emits TreasurySet.
    function setTreasury(address newTreasury) external;

    /// @notice Owner only. Sets the guardian. Reverts ZeroAddress. Emits GuardianSet.
    function setGuardian(address newGuardian) external;

    /// @notice Guardian or owner. Pauses or resumes postOffer only; cancel, fills, credits, claims,
    /// finalize and redeem are never paused. Reverts NotGuardianOrOwner. Emits OffersPausedSet.
    function setOffersPaused(bool paused) external;

    /// @notice Owner only. Sets the ERC-1155 metadata URI shared by every maturity's credit units.
    /// @dev Clients replace {id} with the maturity as 64 lowercase hex characters, per ERC-1155. Reverts
    ///      OwnableUnauthorizedAccount. Emits UriSet.
    /// @param newUri The new URI template.
    function setURI(string calldata newUri) external;

    /// @notice Owner only. Sends a stray ERC-20 that is neither MUSD nor BTC.
    /// @dev MUSD and BTC are refused outright: their records are per offer and per market, so a share of
    ///      them is never free to move. CreditMarkets keeps no record in any other token. Reverts
    ///      OwnableUnauthorizedAccount, ZeroAddress, ZeroAmount or TokenNotRescuable. Emits Rescued.
    /// @param token ERC-20 to send.
    /// @param to Receiver.
    /// @param amount Amount to send.
    function rescueToken(address token, address to, uint256 amount) external;
}
