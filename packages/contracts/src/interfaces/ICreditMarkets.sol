// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICreditMarkets
/// @notice Fixed-rate MUSD offers and one credit market per Thursday maturity. Lenders hold ERC-1155
///         credit units whose token id is the maturity; one unit is one MUSD due on that date.
interface ICreditMarkets {
    /// @dev `parked` is fixed at posting: a parked offer's unfilled MUSD waits in the sMUSD vault, a plain one's in
    ///      this contract. A parked offer stays parked for good, but after a pullOut of its parking era its MUSD is
    ///      back in this contract and it fills and cancels like a plain offer.
    struct Offer {
        address maker;
        uint64 maturity;
        uint16 aprBps;
        uint128 remaining;
        bool parked;
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

    /// @dev A lender's early-payout account at one maturity: the units moved into it with withdrawCollected and
    ///      the MUSD and BTC already paid against them. It belongs to that address and cannot be transferred.
    struct Claim {
        uint128 units;
        uint128 musdPaid;
        uint128 btcPaid;
    }

    /// @notice `maker` escrowed `amount` MUSD as an offer for `maturity` at `aprBps`.
    event OfferPosted(
        uint256 indexed offerId, address indexed maker, uint64 indexed maturity, uint16 aprBps, uint128 amount
    );
    /// @notice A new offer's `amount` MUSD was deposited in the sMUSD vault, where it waits until filled or cancelled.
    event OfferParked(uint256 indexed offerId, uint128 amount);
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
    /// @notice `account` moved `unitsAdded` units into its Claim and was paid what was collected for its Claim
    ///         since its last withdrawal.
    event CollectedWithdrawn(
        address indexed account, uint64 indexed maturity, uint256 unitsAdded, uint256 musdOut, uint256 btcOut
    );
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
    /// @notice The owner moved a stray ERC-20 that is not MUSD, BTC or sMUSD.
    event Rescued(address indexed token, address indexed to, uint256 amount);
    /// @notice New offers can no longer be parked; offers already parked stay in the vault.
    event ParkingStopped();
    /// @notice New offers can be parked again, in the current parking era.
    event ParkingResumed();
    /// @notice All `principal` MUSD of parking era `era` came back from the sMUSD vault, and that era's offers
    ///         stopped earning at yield index `index`.
    event PulledOut(uint32 era, uint256 principal, uint256 index);
    /// @notice `maker` was paid `paid` MUSD of offer yield; `stillOwed` stays booked to it until the vault delivers
    ///         enough to pay it.
    event OfferYieldWithdrawn(address indexed maker, uint256 paid, uint256 stillOwed);

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
    /// @notice The account has no units waiting, or no Claim to withdraw against, for this maturity.
    error NothingToClaim(address account, uint64 maturity);
    /// @notice The fee share is above 2000 basis points.
    error FeeShareOutOfBounds(uint16 feeShareBps);
    /// @notice The minimum offer is outside 1 to 1,000,000 MUSD.
    error MinOfferOutOfBounds(uint128 minOffer);
    /// @notice The maximum term is outside 1 to 4 weeks, veBTC's 28-day maximum lock.
    error MaxTermOutOfBounds(uint32 maxTermSeconds);
    /// @notice MUSD and BTC are recorded per market and sMUSD holds parked offers, so none of them is ever rescued.
    error TokenNotRescuable(address token);
    /// @notice The sMUSD vault moved a different amount than asked: sMUSD minted or burned other than `expected`,
    ///         or less than `expected` MUSD returned by a withdraw.
    error VaultShortfall(uint256 expected, uint256 actual);
    /// @notice The sMUSD vault takes another token than this contract's MUSD.
    error VaultTokenMismatch(address vaultToken);
    /// @notice Ownership can never be given up, so the treasury, pause and rescue settings always keep an owner.
    error RenounceDisabled();
    /// @notice Parking is stopped, so a new offer can only be posted plain.
    error ParkingOff();
    /// @notice No parked principal is in the vault, so there is nothing to pull out.
    error NothingParked();

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

    /// @notice Escrows `amount` MUSD from the caller as a fixed-rate offer for `maturity` and deposits it in the
    ///         sMUSD vault until it is filled or cancelled.
    /// @dev Same checks, pull and OfferPosted event as postOffer, then adds `amount` to parkedPrincipal, emits
    ///      OfferParked, approves the vault for exactly `amount`, deposits, and resets the approval to zero. After
    ///      the deposit it records the vault's yieldIndex and the current parking era as the offer's yield
    ///      snapshot, so the offer earns from that moment only. MUSD the vault pays out during the deposit counts
    ///      as delivered yield. Fills and cancels of a parked offer withdraw from the vault while its era lasts,
    ///      so they need the vault to work; the borrower is paid exactly the principal and never the yield.
    ///      Reverts ParkingOff while parking is stopped, like postOffer otherwise, and VaultShortfall unless this
    ///      contract's sMUSD balance rose by exactly `amount`. A vault whose deposit or yieldIndex reverts makes
    ///      this revert too. Emits OfferPosted and OfferParked.
    /// @param maturity Thursday 00:00 UTC timestamp the loans repay on.
    /// @param aprBps Yearly rate in basis points.
    /// @param amount MUSD to lend, 18 decimals.
    /// @return offerId New offer id, from the same sequence as postOffer.
    function postParkedOffer(uint64 maturity, uint16 aprBps, uint128 amount) external returns (uint256 offerId);

    /// @notice Refunds the unfilled part of an offer to its maker. Works at any time and is never paused. A parked
    ///         offer still in the vault has its refund withdrawn from the vault first, so it also needs the vault
    ///         to pay.
    /// @dev Reverts OfferNotFound, NotMaker, or OfferEmpty if nothing is left. A parked offer first books its
    ///      yield on the whole remainder to the maker (see pendingOfferYield). For an offer still in the vault the
    ///      remainder is then cut and parkedPrincipal lowered before the vault is called, and it reverts
    ///      VaultShortfall unless the withdraw burned exactly the refund in sMUSD and returned at least the refund
    ///      in MUSD; MUSD above the refund counts as delivered yield. A parked offer from an era already pulled
    ///      out refunds from this contract's MUSD and never calls the vault. Emits OfferCancelled.
    /// @param offerId Offer to cancel.
    function cancelOffer(uint256 offerId) external;

    /// @notice Fills the listed offers for one loan and sends the total principal to `recipient`.
    /// @dev Only LoanManager. Every offer must exist, be for exactly `maturity`, charge at most `maxAprBps`
    ///      and have at least the listed amount left; each amount must be above zero. A parked offer books its
    ///      yield on the remainder as it stood, then every remainder is cut, all before any vault withdraw. Units
    ///      are recorded in storage and minted later by claimUnits, so no maker code runs here. Adds one open
    ///      loan to the market. The amounts taken from offers still in the vault are then withdrawn in one
    ///      call, which reverts VaultShortfall unless it burned exactly that sum in sMUSD and returned at least
    ///      that sum in MUSD; MUSD above it counts as delivered yield. Plain offers, and parked offers from an era
    ///      already pulled out, never call the vault. The recipient gets exactly the principal and never the
    ///      vault's yield. Emits Filled once per offer.
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
    ///      units * btcAtFinal / unitsAtFinal BTC, both rounded down, and adds both to paidOutOf(maturity). A
    ///      zero part is not transferred. Never paused. Reverts NotFinal, ZeroAmount, or if the caller holds
    ///      fewer units. Emits Redeemed.
    /// @param maturity Market to redeem from.
    /// @param units Units to burn.
    /// @return musdOut MUSD paid.
    /// @return btcOut BTC paid.
    function redeem(uint64 maturity, uint256 units) external returns (uint256 musdOut, uint256 btcOut);

    /// @notice After the maturity has passed, pays the caller its share of what the market has collected so far,
    ///         and on later calls whatever has been collected since, without waiting for every loan to close.
    /// @dev Never paused. Reverts NotMatured while now <= maturity: from then on no fill can add units, so a
    ///      unit's share only grows. Reverts EmptyMarket if the market never had a loan. A nonzero `units` is
    ///      burned from the caller first and added to the caller's Claim. A Claim cannot be transferred, so
    ///      units moved into it can no longer be sold. Reverts NothingToClaim if the Claim then holds no units.
    ///      The Claim is owed min(units, units x collectedMusd / faceTotal) MUSD and units x collectedBtc /
    ///      faceTotal BTC, both rounded down, which is redeem's formula on the running totals (after finalize
    ///      the totals equal the final snapshot, because markets refuse credits once final). It is paid what is
    ///      owed minus what it was already paid, both are recorded, and paidOutOf(maturity) rises by the same
    ///      amounts. Whichever path and timing a unit takes, early withdrawals, a late redeem or a mix, its
    ///      total is the same within rounding of a few wei. A zero `units` just pays an existing Claim what
    ///      arrived since its last withdrawal. Reverts if the caller holds fewer than `units`. Emits
    ///      CollectedWithdrawn, then sends the MUSD and BTC, skipping a zero amount.
    /// @param maturity Market to withdraw from.
    /// @param units Units to move from the caller's balance into its Claim; may be zero.
    /// @return musdOut MUSD paid by this call.
    /// @return btcOut BTC paid by this call.
    function withdrawCollected(uint64 maturity, uint256 units) external returns (uint256 musdOut, uint256 btcOut);

    /// @notice Prices a fill at the current time and fee share.
    /// @dev Reverts InvalidMaturity.
    /// @return face MUSD owed at maturity.
    /// @return makerUnits Units the lender would receive.
    /// @return treasuryUnits Units the treasury would receive.
    function quoteFill(uint128 principal, uint16 aprBps, uint64 maturity)
        external
        view
        returns (uint256 face, uint256 makerUnits, uint256 treasuryUnits);

    /// @notice An offer's maker, maturity, rate, unfilled amount and whether it is parked in the sMUSD vault. A
    ///         zero maker means no such offer.
    function offerOf(uint256 offerId) external view returns (Offer memory);

    /// @notice A market's totals and finalization snapshot.
    function marketOf(uint64 maturity) external view returns (Market memory);

    /// @notice Units recorded to `account` for `maturity` and not yet minted.
    function pendingUnits(address account, uint64 maturity) external view returns (uint256);

    /// @notice `account`'s Claim at `maturity`: units moved into it and the MUSD and BTC already paid. All zero
    ///         when it never withdrew early.
    function claimOf(address account, uint64 maturity) external view returns (Claim memory);

    /// @notice MUSD and BTC paid out of `maturity`'s market so far, by redeem and withdrawCollected together.
    ///         Never more than the market collected.
    /// @return musd MUSD paid out.
    /// @return btc BTC paid out.
    function paidOutOf(uint64 maturity) external view returns (uint256 musd, uint256 btc);

    /// @notice True when `maturity` is a Thursday 00:00 UTC, is in the future, and is within the maximum term.
    function isValidMaturity(uint64 maturity) external view returns (bool);

    /// @notice The only address allowed to fill offers and credit markets, fixed at deployment.
    function loanManager() external view returns (address);

    /// @notice The MUSD token, fixed at deployment.
    function musd() external view returns (address);

    /// @notice The BTC ERC-20 that settled loans pay markets in, fixed at deployment.
    function btc() external view returns (address);

    /// @notice Mezo's sMUSD vault that parked offers wait in, fixed at deployment. Its musdToken() is musd().
    function savingsVault() external view returns (address);

    /// @notice MUSD principal still in the sMUSD vault: the sum of the remaining amounts of parked offers posted in
    ///         the current parking era. This contract's sMUSD balance is always at least this; sMUSD sent here
    ///         unasked is never counted.
    function parkedPrincipal() external view returns (uint256);

    /// @notice True while new offers may be parked. True at deployment.
    function parkingOn() external view returns (bool);

    /// @notice The parking era new parked offers join. Starts at 1 and goes up by one at every pullOut; only offers
    ///         of the current era are in the vault.
    function parkingEra() external view returns (uint32);

    /// @notice The vault's yield index recorded when `era` was pulled out, where that era's offers stopped
    ///         earning. Zero for an era not pulled out yet.
    function eraEndIndex(uint32 era) external view returns (uint256);

    /// @notice Offer yield booked to `maker` and not yet paid.
    function yieldOwedOf(address maker) external view returns (uint256);

    /// @notice MUSD this contract has measured arriving from the vault above the principal it asked for: withdraw
    ///         surpluses, MUSD paid during a deposit, and claimYield. The most offer yield can ever pay out.
    function yieldDelivered() external view returns (uint256);

    /// @notice Offer yield paid out by withdrawOfferYield so far. Never above yieldDelivered.
    function yieldPaid() external view returns (uint256);

    /// @notice The yield `offerId` would book to its maker if it were booked now, in MUSD. Zero for a plain or
    ///         empty offer, and when the vault's index cannot be read, has fallen or is too large to multiply.
    /// @dev Remaining amount times the index rise since the offer's snapshot, divided by 1e18 and rounded down.
    ///      The index used is the vault's live yieldIndex while the offer's era lasts, and the era's recorded end
    ///      index once it has been pulled out. This is booked yield, not what withdrawOfferYield can pay right now.
    /// @param offerId Offer to price.
    function pendingOfferYield(uint256 offerId) external view returns (uint256);

    /// @notice Books the yield of the listed offers to the caller and pays the caller as much of its booked
    ///         yield as the vault has delivered and nobody has been paid yet. Never paused.
    /// @dev Every listed id must be an offer the caller made, at most MAX_FILLS of them; an empty list just pays
    ///      what is already booked. If the caller is owed more than delivered minus paid, it first asks the vault
    ///      for this contract's accrued yield with claimYield inside try/catch and counts only the MUSD measured
    ///      arriving. Pays min(owed, delivered minus paid); the rest stays booked to the caller. Never pays from
    ///      offer escrow or market collections. Reverts BadFillCount above MAX_FILLS ids or NotMaker. Emits
    ///      OfferYieldWithdrawn, then sends the MUSD, skipping a zero payment.
    /// @param offerIds The caller's offers to book first, 0 to MAX_FILLS entries.
    /// @return paid MUSD paid to the caller.
    function withdrawOfferYield(uint256[] calldata offerIds) external returns (uint256 paid);

    /// @notice Guardian or owner. Refuses new parked offers from now on; offers already parked stay in the vault
    ///         and fill, cancel and earn as before.
    /// @dev Reverts NotGuardianOrOwner. Emits ParkingStopped.
    function stopParking() external;

    /// @notice Owner only. Lets new offers be parked again, in the current parking era. Offers of an era already
    ///         pulled out stay out of the vault.
    /// @dev Reverts OwnableUnauthorizedAccount. Emits ParkingResumed.
    function resumeParking() external;

    /// @notice Guardian or owner. Takes every parked dollar out of the sMUSD vault in one fixed-cost call and stops
    ///         parking, for when the vault misbehaves.
    /// @dev Records the vault's yieldIndex as the current era's end index (zero if it cannot be read, so that
    ///      era's last stretch books nothing), withdraws exactly parkedPrincipal, never the raw sMUSD balance,
    ///      sets parkedPrincipal to zero, stops parking and starts the next era. No loop over offers: every offer
    ///      of the ended era books yield only up to the recorded index and fills and cancels from this
    ///      contract's MUSD from then on. Reverts NotGuardianOrOwner, NothingParked when parkedPrincipal is zero,
    ///      and VaultShortfall unless the withdraw burned exactly parkedPrincipal in sMUSD and returned at least
    ///      that in MUSD; MUSD above it counts as delivered yield. Emits PulledOut.
    function pullOut() external;

    /// @notice Furthest a maturity may be from now, in seconds.
    function maxTermSeconds() external view returns (uint32);

    /// @notice Share of interest paid to the treasury as units, in basis points (at most 2000).
    function feeShareBps() external view returns (uint16);

    /// @notice Smallest offer accepted, in MUSD wei.
    function minOffer() external view returns (uint128);

    /// @notice Receiver of fee units.
    function treasury() external view returns (address);

    /// @notice Address that may pause new offers, stop parking and pull parked MUSD out of the vault, alongside the
    ///         owner.
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

    /// @notice Owner only. Sets the maximum term. Reverts MaxTermOutOfBounds outside 1 to 4 weeks.
    /// Emits MaxTermSecondsSet.
    function setMaxTermSeconds(uint32 newMaxTermSeconds) external;

    /// @notice Owner only. Sets the receiver of future fee units. Reverts ZeroAddress. Emits TreasurySet.
    function setTreasury(address newTreasury) external;

    /// @notice Owner only. Sets the guardian. Reverts ZeroAddress. Emits GuardianSet.
    function setGuardian(address newGuardian) external;

    /// @notice Guardian or owner. Pauses or resumes postOffer and postParkedOffer only; cancel, fills, credits, claims,
    /// finalize, redeem and withdrawOfferYield are never paused. Reverts NotGuardianOrOwner. Emits OffersPausedSet.
    function setOffersPaused(bool paused) external;

    /// @notice Owner only. Sets the ERC-1155 metadata URI shared by every maturity's credit units.
    /// @dev Clients replace {id} with the maturity as 64 lowercase hex characters, per ERC-1155. Reverts
    ///      OwnableUnauthorizedAccount. Emits UriSet.
    /// @param newUri The new URI template.
    function setURI(string calldata newUri) external;

    /// @notice Owner only. Sends a stray ERC-20 that is not MUSD, BTC or sMUSD.
    /// @dev MUSD, BTC and the sMUSD vault's token are refused outright: their records are per offer and per
    ///      market, and sMUSD stands for every parked offer, so a share of them is never free to move. CreditMarkets
    ///      keeps no record in any other token. Reverts OwnableUnauthorizedAccount, ZeroAddress, ZeroAmount or
    ///      TokenNotRescuable. Emits Rescued.
    /// @param token ERC-20 to send.
    /// @param to Receiver.
    /// @param amount Amount to send.
    function rescueToken(address token, address to, uint256 amount) external;
}
