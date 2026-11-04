// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICreditMarkets} from "./interfaces/ICreditMarkets.sol";
import {IMUSDSavingsRate} from "./interfaces/IMUSDSavingsRate.sol";
import {Quote} from "./libraries/Quote.sol";

/// @title CreditMarkets
/// @notice Lenders post fixed-rate MUSD offers for a Thursday maturity and LoanManager fills them for
///         borrowers. Every maturity is its own market: lenders receive ERC-1155 credit units (token id =
///         maturity, one unit = one MUSD due) and redeem them pro rata once every loan at that date is closed,
///         for MUSD from repayments and auctions and for BTC from settled loans. Once the date has passed, a
///         lender can also withdraw its share of what has been collected so far and more as each loan closes.
/// @dev All MUSD and BTC sit in this one balance, except the unfilled MUSD of parked offers, which this contract
///      holds as sMUSD in Mezo's savings vault. Yield the vault delivers waits in the same balance until makers
///      withdraw it. Isolation between offers, maturities and yield is bookkeeping, and every inflow is booked from
///      a measured balance change, so a direct donation never reaches any record.
contract CreditMarkets is ICreditMarkets, ERC1155, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant WEEK = 604_800;
    /// @dev A listed offer costs about 60k gas at worst (offer slot, two cold pending-unit slots, one event),
    ///      so 8 offers stay near 0.5M gas against Mezo's 10M block gas limit. A parked offer also books its yield
    ///      (one index read, one snapshot write), and a fill that takes parked offers adds one vault withdraw for
    ///      all of them together (about 240k on mainnet), not one per offer: 8 parked offers measured 622k gas on
    ///      the mock vault, so about 0.85M with the real withdraw.
    uint256 public constant MAX_FILLS = 8;
    uint16 public constant MAX_APR_BPS = 5_000;
    uint16 public constant MAX_FEE_SHARE_BPS = 2_000;
    uint128 public constant MIN_OFFER_FLOOR = 1e18;
    uint128 public constant MIN_OFFER_CEILING = 1_000_000e18;
    uint32 public constant MIN_TERM_SECONDS = 604_800;
    /// @dev veBTC's maximum lock is 28 days, so no loan, permanent lock or not, may run longer than the lock
    ///      unlockPermanent leaves behind.
    uint32 public constant MAX_TERM_CEILING = 4 * 604_800;
    /// @dev The vault's yieldIndex is MUSD per sMUSD scaled by 1e18.
    uint256 private constant INDEX_SCALE = 1e18;

    address public immutable musd;
    address public immutable btc;
    address public immutable loanManager;
    address public immutable savingsVault;

    address public guardian;
    address public treasury;
    uint16 public feeShareBps;
    uint128 public minOffer;
    uint32 public maxTermSeconds;
    bool public offersPaused;
    bool public parkingOn = true;
    uint32 public parkingEra = 1;
    uint256 public nextOfferId = 1;
    uint256 public parkedPrincipal;
    uint256 public yieldDelivered;
    uint256 public yieldPaid;

    /// @dev What one market has paid out through redeem and withdrawCollected together.
    struct PaidOut {
        uint128 musd;
        uint128 btc;
    }

    /// @dev A parked offer's yield clock: the vault index its remainder has been booked up to, and the parking era
    ///      it was posted in. Written at posting, after the deposit, and moved forward at every booking.
    struct OfferYield {
        uint256 indexAt;
        uint32 era;
    }

    mapping(uint32 era => uint256 index) public eraEndIndex;
    mapping(address maker => uint256 owed) public yieldOwedOf;
    mapping(uint256 offerId => OfferYield) private _offerYield;
    mapping(uint256 offerId => Offer) private _offers;
    mapping(uint64 maturity => Market) private _markets;
    mapping(address account => mapping(uint64 maturity => uint256 units)) private _pendingUnits;
    mapping(address account => mapping(uint64 maturity => Claim)) private _claims;
    mapping(uint64 maturity => PaidOut) private _paidOut;

    modifier onlyLoanManager() {
        if (msg.sender != loanManager) revert NotLoanManager();
        _;
    }

    /// @notice Fixes MUSD, BTC, LoanManager and the sMUSD vault for the life of the contract and sets the starting
    ///         parameters.
    /// @dev `loanManager_` is precomputed from the deployer's nonce; LoanManager's own constructor then
    ///      refuses to deploy unless this contract points at it. Reverts ZeroAddress, OwnableInvalidOwner,
    ///      VaultTokenMismatch if the vault takes another token than `musd_`, or a parameter bound error. A vault
    ///      address with no code reverts without data. Emits one event per parameter.
    /// @param musd_ The MUSD token lenders post and borrowers repay in.
    /// @param btc_ The BTC ERC-20 that settled loans pay markets in.
    /// @param loanManager_ The only address allowed to fill offers and credit markets.
    /// @param owner_ Starting owner.
    /// @param guardian_ Address that may pause new offers, stop parking and pull out, alongside the owner.
    /// @param treasury_ Receiver of fee units.
    /// @param feeShareBps_ Treasury's share of interest, at most 2000.
    /// @param minOffer_ Smallest offer, 1 to 1,000,000 MUSD.
    /// @param maxTermSeconds_ Furthest a maturity may be from now, 1 to 4 weeks.
    /// @param uri_ ERC-1155 metadata URI template for the credit units; may be empty until metadata is served.
    /// @param savingsVault_ Mezo's sMUSD vault that parked offers wait in.
    constructor(
        address musd_,
        address btc_,
        address loanManager_,
        address owner_,
        address guardian_,
        address treasury_,
        uint16 feeShareBps_,
        uint128 minOffer_,
        uint32 maxTermSeconds_,
        string memory uri_,
        address savingsVault_
    ) ERC1155(uri_) Ownable(owner_) {
        if (musd_ == address(0) || btc_ == address(0) || loanManager_ == address(0) || savingsVault_ == address(0)) {
            revert ZeroAddress();
        }
        address vaultToken = IMUSDSavingsRate(savingsVault_).musdToken();
        if (vaultToken != musd_) revert VaultTokenMismatch(vaultToken);
        musd = musd_;
        btc = btc_;
        loanManager = loanManager_;
        savingsVault = savingsVault_;
        _setGuardian(guardian_);
        _setTreasury(treasury_);
        _setFeeShareBps(feeShareBps_);
        _setMinOffer(minOffer_);
        _setMaxTermSeconds(maxTermSeconds_);
        emit UriSet(uri_);
    }

    /// @inheritdoc ICreditMarkets
    function postOffer(uint64 maturity, uint16 aprBps, uint128 amount)
        external
        nonReentrant
        returns (uint256 offerId)
    {
        _checkNewOffer(maturity, aprBps, amount);

        offerId = nextOfferId++;
        _offers[offerId] =
            Offer({maker: msg.sender, maturity: maturity, aprBps: aprBps, remaining: amount, parked: false});
        emit OfferPosted(offerId, msg.sender, maturity, aprBps, amount);

        _pullExactly(musd, msg.sender, amount);
    }

    /// @inheritdoc ICreditMarkets
    function postParkedOffer(uint64 maturity, uint16 aprBps, uint128 amount)
        external
        nonReentrant
        returns (uint256 offerId)
    {
        if (!parkingOn) revert ParkingOff();
        _checkNewOffer(maturity, aprBps, amount);

        offerId = nextOfferId++;
        _offers[offerId] =
            Offer({maker: msg.sender, maturity: maturity, aprBps: aprBps, remaining: amount, parked: true});
        parkedPrincipal += amount;
        emit OfferPosted(offerId, msg.sender, maturity, aprBps, amount);
        emit OfferParked(offerId, amount);

        _pullExactly(musd, msg.sender, amount);
        _parkInVault(amount);
        // Read after the deposit, so a lump the deposit itself pulled into the vault is never booked to this offer
        // (C32). Unlike a fill or cancel, nothing is lost if an unreadable index stops a new parked post (C35).
        _offerYield[offerId] = OfferYield({indexAt: IMUSDSavingsRate(savingsVault).yieldIndex(), era: parkingEra});
    }

    /// @inheritdoc ICreditMarkets
    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = _offers[offerId];
        address maker = offer.maker;
        if (maker == address(0)) revert OfferNotFound(offerId);
        if (msg.sender != maker) revert NotMaker(offerId);
        uint128 refund = offer.remaining;
        if (refund == 0) revert OfferEmpty(offerId);

        _bookYield(offerId);
        bool inVault = _inVault(offerId);
        offer.remaining = 0;
        emit OfferCancelled(offerId, maker, refund);

        if (inVault) {
            parkedPrincipal -= refund;
            _takeFromVault(refund);
        }
        IERC20(musd).safeTransfer(maker, refund);
    }

    /// @inheritdoc ICreditMarkets
    function fill(
        uint64 maturity,
        uint256[] calldata offerIds,
        uint128[] calldata amounts,
        uint16 maxAprBps,
        address recipient
    ) external nonReentrant onlyLoanManager returns (uint256 principal, uint256 face) {
        uint256 count = offerIds.length;
        if (count == 0 || count > MAX_FILLS) revert BadFillCount(count);
        if (amounts.length != count) revert LengthMismatch();
        if (recipient == address(0)) revert ZeroAddress();
        if (!isValidMaturity(maturity)) revert InvalidMaturity(maturity);

        uint256 fromVault;
        (principal, face, fromVault) = _takeOffers(maturity, offerIds, amounts, maxAprBps);

        Market storage market = _markets[maturity];
        market.faceTotal = (uint256(market.faceTotal) + face).toUint128();
        market.openLoans += 1;

        // Every yield is booked and every remainder cut, so the one vault withdraw runs on settled books, under
        // the lock (C33).
        if (fromVault != 0) {
            parkedPrincipal -= fromVault;
            _takeFromVault(fromVault);
        }
        IERC20(musd).safeTransfer(recipient, principal);
    }

    /// @inheritdoc ICreditMarkets
    function credit(uint64 maturity, uint256 musdAmount, bool closesLoan) external nonReentrant onlyLoanManager {
        Market storage market = _markets[maturity];
        if (market.isFinal) revert MarketIsFinal(maturity);
        if (market.openLoans == 0) revert NoOpenLoans(maturity);
        if (musdAmount == 0 && !closesLoan) revert ZeroAmount();

        if (closesLoan) market.openLoans -= 1;
        market.collectedMusd = (uint256(market.collectedMusd) + musdAmount).toUint128();
        emit Credited(maturity, musdAmount, closesLoan);

        if (musdAmount != 0) _pullExactly(musd, msg.sender, musdAmount);
    }

    /// @inheritdoc ICreditMarkets
    function creditBtc(uint64 maturity, uint256 btcAmount, bool closesLoan) external nonReentrant onlyLoanManager {
        Market storage market = _markets[maturity];
        if (market.isFinal) revert MarketIsFinal(maturity);
        if (market.openLoans == 0) revert NoOpenLoans(maturity);
        if (btcAmount == 0 && !closesLoan) revert ZeroAmount();

        if (closesLoan) market.openLoans -= 1;
        market.collectedBtc = (uint256(market.collectedBtc) + btcAmount).toUint128();
        emit CreditedBtc(maturity, btcAmount, closesLoan);

        if (btcAmount != 0) _pullExactly(btc, msg.sender, btcAmount);
    }

    /// @inheritdoc ICreditMarkets
    function claimUnits(uint64 maturity) external nonReentrant returns (uint256 minted) {
        minted = _pendingUnits[msg.sender][maturity];
        if (minted == 0) revert NothingToClaim(msg.sender, maturity);
        _pendingUnits[msg.sender][maturity] = 0;

        emit UnitsClaimed(msg.sender, maturity, minted);
        _mint(msg.sender, maturity, minted, "");
    }

    /// @inheritdoc ICreditMarkets
    function finalize(uint64 maturity) external nonReentrant {
        Market storage market = _markets[maturity];
        if (market.isFinal) revert MarketIsFinal(maturity);
        // Maturities are a week apart, so the few seconds a block producer can shift a timestamp do not matter.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= maturity) revert NotMatured(maturity);
        if (market.openLoans != 0) revert LoansStillOpen(maturity, market.openLoans);
        if (market.faceTotal == 0) revert EmptyMarket(maturity);

        market.isFinal = true;
        market.unitsAtFinal = market.faceTotal;
        market.musdAtFinal = market.collectedMusd;
        market.btcAtFinal = market.collectedBtc;

        emit MarketFinalized(maturity, market.unitsAtFinal, market.musdAtFinal, market.btcAtFinal);
    }

    /// @inheritdoc ICreditMarkets
    function redeem(uint64 maturity, uint256 units)
        external
        nonReentrant
        returns (uint256 musdOut, uint256 btcOut)
    {
        Market storage market = _markets[maturity];
        if (!market.isFinal) revert NotFinal(maturity);
        if (units == 0) revert ZeroAmount();

        _burn(msg.sender, maturity, units);

        uint256 unitsAtFinal = market.unitsAtFinal;
        musdOut = Math.mulDiv(units, market.musdAtFinal, unitsAtFinal);
        if (musdOut > units) musdOut = units;
        btcOut = Math.mulDiv(units, market.btcAtFinal, unitsAtFinal);
        _recordPaidOut(maturity, musdOut, btcOut);
        // The only calls above are the internal burn and Math library; the transfers come after this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Redeemed(msg.sender, maturity, units, musdOut, btcOut);

        if (musdOut != 0) IERC20(musd).safeTransfer(msg.sender, musdOut);
        if (btcOut != 0) IERC20(btc).safeTransfer(msg.sender, btcOut);
    }

    /// @inheritdoc ICreditMarkets
    function withdrawCollected(uint64 maturity, uint256 units)
        external
        nonReentrant
        returns (uint256 musdOut, uint256 btcOut)
    {
        // Until the date passes a fill could still add units and dilute the share already paid out.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= maturity) revert NotMatured(maturity);
        Market storage market = _markets[maturity];
        uint256 faceTotal = market.faceTotal;
        if (faceTotal == 0) revert EmptyMarket(maturity);

        Claim storage claim = _claims[msg.sender][maturity];
        if (units != 0) {
            _burn(msg.sender, maturity, units);
            claim.units = (uint256(claim.units) + units).toUint128();
        }
        uint256 held = claim.units;
        if (held == 0) revert NothingToClaim(msg.sender, maturity);

        // Owed is recomputed on the Claim's whole history, so rounding never builds up across withdrawals and
        // the total matches what redeem would pay the same units at the end.
        uint256 musdDue = Math.min(held, Math.mulDiv(held, market.collectedMusd, faceTotal));
        uint256 btcDue = Math.mulDiv(held, market.collectedBtc, faceTotal);
        musdOut = musdDue - claim.musdPaid;
        btcOut = btcDue - claim.btcPaid;
        claim.musdPaid = musdDue.toUint128();
        claim.btcPaid = btcDue.toUint128();
        _recordPaidOut(maturity, musdOut, btcOut);
        // The only calls above are the internal burn and Math library; the transfers come after this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit CollectedWithdrawn(msg.sender, maturity, units, musdOut, btcOut);

        if (musdOut != 0) IERC20(musd).safeTransfer(msg.sender, musdOut);
        if (btcOut != 0) IERC20(btc).safeTransfer(msg.sender, btcOut);
    }

    /// @inheritdoc ICreditMarkets
    /// @dev The list shares MAX_FILLS with fill: each entry costs one index read and one snapshot write, far below
    ///      a listed fill.
    // forge-lint: disable-next-item(require-revert-in-loop)
    function withdrawOfferYield(uint256[] calldata offerIds) external nonReentrant returns (uint256 paid) {
        uint256 count = offerIds.length;
        if (count > MAX_FILLS) revert BadFillCount(count);
        for (uint256 i; i < count; ++i) {
            uint256 offerId = offerIds[i];
            if (_offers[offerId].maker != msg.sender) revert NotMaker(offerId);
            _bookYield(offerId);
        }

        uint256 owed = yieldOwedOf[msg.sender];
        uint256 unpaid = yieldDelivered - yieldPaid;
        if (owed > unpaid) unpaid += _claimFromVault();
        // Delivered minus paid is the only pot yield comes from, so escrow and collected MUSD are never touched
        // however far Doji's bookkeeping drifts above the vault's (C31).
        paid = Math.min(owed, unpaid);
        uint256 stillOwed = owed - paid;
        yieldOwedOf[msg.sender] = stillOwed;
        yieldPaid += paid;
        // The only outside call above is the fixed vault's claimYield, under the lock; the payment comes after.
        // forge-lint: disable-next-line(reentrancy-events)
        emit OfferYieldWithdrawn(msg.sender, paid, stillOwed);

        if (paid != 0) IERC20(musd).safeTransfer(msg.sender, paid);
    }

    /// @inheritdoc ICreditMarkets
    function pendingOfferYield(uint256 offerId) external view returns (uint256 earned) {
        (,, earned) = _yieldDue(offerId);
    }

    /// @inheritdoc ICreditMarkets
    function quoteFill(uint128 principal, uint16 aprBps, uint64 maturity)
        external
        view
        returns (uint256 face, uint256 makerUnits, uint256 treasuryUnits)
    {
        if (!isValidMaturity(maturity)) revert InvalidMaturity(maturity);
        return Quote.quote(principal, aprBps, maturity - block.timestamp, feeShareBps);
    }

    /// @inheritdoc ICreditMarkets
    function offerOf(uint256 offerId) external view returns (Offer memory) {
        return _offers[offerId];
    }

    /// @inheritdoc ICreditMarkets
    function marketOf(uint64 maturity) external view returns (Market memory) {
        return _markets[maturity];
    }

    /// @inheritdoc ICreditMarkets
    function pendingUnits(address account, uint64 maturity) external view returns (uint256) {
        return _pendingUnits[account][maturity];
    }

    /// @inheritdoc ICreditMarkets
    function claimOf(address account, uint64 maturity) external view returns (Claim memory) {
        return _claims[account][maturity];
    }

    /// @inheritdoc ICreditMarkets
    function paidOutOf(uint64 maturity) external view returns (uint256, uint256) {
        PaidOut storage paid = _paidOut[maturity];
        return (paid.musd, paid.btc);
    }

    /// @inheritdoc ICreditMarkets
    function isValidMaturity(uint64 maturity) public view returns (bool) {
        // One clock for the whole system (C24); week-sized windows make timestamp drift irrelevant.
        // forge-lint: disable-next-line(block-timestamp)
        return maturity % WEEK == 0 && block.timestamp < maturity && maturity <= block.timestamp + maxTermSeconds;
    }

    /// @inheritdoc ICreditMarkets
    function setFeeShareBps(uint16 newFeeShareBps) external onlyOwner {
        _setFeeShareBps(newFeeShareBps);
    }

    /// @inheritdoc ICreditMarkets
    function setMinOffer(uint128 newMinOffer) external onlyOwner {
        _setMinOffer(newMinOffer);
    }

    /// @inheritdoc ICreditMarkets
    function setMaxTermSeconds(uint32 newMaxTermSeconds) external onlyOwner {
        _setMaxTermSeconds(newMaxTermSeconds);
    }

    /// @inheritdoc ICreditMarkets
    function setTreasury(address newTreasury) external onlyOwner {
        _setTreasury(newTreasury);
    }

    /// @inheritdoc ICreditMarkets
    function setGuardian(address newGuardian) external onlyOwner {
        _setGuardian(newGuardian);
    }

    /// @inheritdoc ICreditMarkets
    function setOffersPaused(bool paused) external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner();
        offersPaused = paused;
        emit OffersPausedSet(paused);
    }

    /// @inheritdoc ICreditMarkets
    function stopParking() external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner();
        parkingOn = false;
        emit ParkingStopped();
    }

    /// @inheritdoc ICreditMarkets
    function resumeParking() external onlyOwner {
        parkingOn = true;
        emit ParkingResumed();
    }

    /// @inheritdoc ICreditMarkets
    function pullOut() external nonReentrant {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner();
        uint256 principal = parkedPrincipal;
        if (principal == 0) revert NothingParked();

        // Ending the era moves every offer in it out of the vault at once, so no loop over offers is needed (C13,
        // C32). An unreadable index must not trap the principal, so it ends the era at zero and the era's last
        // stretch books nothing (C35).
        uint32 era = parkingEra;
        (, uint256 index) = _readIndex();
        eraEndIndex[era] = index;
        parkedPrincipal = 0;
        parkingOn = false;
        parkingEra = era + 1;
        emit PulledOut(era, principal, index);

        _takeFromVault(principal);
    }

    /// @inheritdoc ICreditMarkets
    function setURI(string calldata newUri) external onlyOwner {
        _setURI(newUri);
        emit UriSet(newUri);
    }

    /// @inheritdoc ICreditMarkets
    function rescueToken(address token, address to, uint256 amount) external nonReentrant onlyOwner {
        if (token == musd || token == btc || token == savingsVault) revert TokenNotRescuable(token);
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        emit Rescued(token, to, amount);
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Always reverts: ownership can never be given up, so the treasury, pause and rescue settings
    ///         always have an owner. Ownership still moves by the two-step transfer.
    /// @dev Reverts RenounceDisabled for every caller.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @dev Takes every listed offer in order and returns the total principal, the total face, and the part of
    ///      the principal that must come back from the vault. Its own function so fill stays within the stack limit.
    function _takeOffers(
        uint64 maturity,
        uint256[] calldata offerIds,
        uint128[] calldata amounts,
        uint16 maxAprBps
    ) private returns (uint256 principal, uint256 face, uint256 fromVault) {
        uint256 secondsToMaturity = maturity - block.timestamp;
        for (uint256 i; i < offerIds.length; ++i) {
            (uint256 fillFace, bool inVault) =
                _takeOffer(offerIds[i], amounts[i], maturity, maxAprBps, secondsToMaturity);
            face += fillFace;
            principal += amounts[i];
            if (inVault) fromVault += amounts[i];
        }
    }

    /// @dev Checks one listed offer against the borrow's terms, books a parked offer's yield on the remainder as it
    ///      stood, then cuts the remainder, and records the maker's and treasury's units in storage. Nothing is
    ///      minted, so no maker code runs. Each listed offer must pass on its own (C8), so its checks run per
    ///      iteration of a loop capped at MAX_FILLS; before the event the only outside call is the vault's
    ///      yieldIndex view, read inside try/catch. Returns whether the offer's MUSD is in the vault, so fill
    ///      knows how much to take back from it.
    // forge-lint: disable-next-item(require-revert-in-loop,reentrancy-events)
    function _takeOffer(
        uint256 offerId,
        uint128 amount,
        uint64 maturity,
        uint16 maxAprBps,
        uint256 secondsToMaturity
    ) private returns (uint256 fillFace, bool inVault) {
        Offer storage offer = _offers[offerId];
        address maker = offer.maker;
        uint16 aprBps = offer.aprBps;
        if (maker == address(0)) revert OfferNotFound(offerId);
        if (offer.maturity != maturity) revert WrongMaturity(offerId, offer.maturity, maturity);
        if (aprBps > maxAprBps) revert AprAboveMax(offerId, aprBps, maxAprBps);
        if (amount == 0) revert ZeroAmount();
        if (offer.remaining < amount) revert InsufficientRemaining(offerId, offer.remaining, amount);
        _bookYield(offerId);
        inVault = _inVault(offerId);
        offer.remaining -= amount;

        uint256 makerUnits;
        uint256 treasuryUnits;
        (fillFace, makerUnits, treasuryUnits) = Quote.quote(amount, aprBps, secondsToMaturity, feeShareBps);
        _pendingUnits[maker][maturity] += makerUnits;
        if (treasuryUnits != 0) _pendingUnits[treasury][maturity] += treasuryUnits;

        emit Filled(offerId, maker, maturity, amount, fillFace);
    }

    /// @dev The one gate for both kinds of offer, so the pause and the bounds can never differ between them (C19).
    function _checkNewOffer(uint64 maturity, uint16 aprBps, uint128 amount) private view {
        if (offersPaused) revert OffersPaused();
        if (!isValidMaturity(maturity)) revert InvalidMaturity(maturity);
        if (aprBps > MAX_APR_BPS) revert AprTooHigh(aprBps);
        if (amount < minOffer) revert OfferTooSmall(amount, minOffer);
    }

    /// @dev Records are written for `amount` before this runs, so the measured arrival must match it exactly.
    ///      Reading the balance change, not the balance, means a donation sitting here changes nothing (C14).
    ///      `asset` is always one of the two immutables, MUSD or BTC.
    function _pullExactly(address asset, address from, uint256 amount) private {
        IERC20 token = IERC20(asset);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert TransferMismatch(amount, received);
    }

    /// @dev The vault's code can change behind its proxy, so its deposit is judged by the sMUSD it actually minted,
    ///      never trusted. The approval covers exactly this deposit and is cleared in the same call, so no standing
    ///      allowance ever reaches the MUSD held here (C34). That exact approval also caps what the deposit can
    ///      take at `amount`, so if MUSD fell by less, the difference is yield the vault paid out (C31).
    function _parkInVault(uint256 amount) private {
        IMUSDSavingsRate vault = IMUSDSavingsRate(savingsVault);
        IERC20 token = IERC20(musd);
        uint256 sharesBefore = vault.balanceOf(address(this));
        uint256 musdBefore = token.balanceOf(address(this));
        token.forceApprove(address(vault), amount);
        vault.deposit(amount);
        token.forceApprove(address(vault), 0);
        uint256 minted = _rise(sharesBefore, vault.balanceOf(address(this)));
        if (minted != amount) revert VaultShortfall(amount, minted);
        yieldDelivered += _rise(musdBefore, token.balanceOf(address(this)) + amount);
    }

    /// @dev Accepted only if exactly `amount` sMUSD was burned and at least `amount` MUSD arrived, so a short
    ///      payment can never be topped up from plain escrow or collected funds (C30). The vault sends accrued
    ///      yield with every withdraw; MUSD above `amount` is that yield and is the only way a withdraw adds to
    ///      yieldDelivered (C31).
    function _takeFromVault(uint256 amount) private {
        IMUSDSavingsRate vault = IMUSDSavingsRate(savingsVault);
        IERC20 token = IERC20(musd);
        uint256 sharesBefore = vault.balanceOf(address(this));
        uint256 musdBefore = token.balanceOf(address(this));
        vault.withdraw(amount);
        uint256 burned = _rise(vault.balanceOf(address(this)), sharesBefore);
        if (burned != amount) revert VaultShortfall(amount, burned);
        uint256 received = _rise(musdBefore, token.balanceOf(address(this)));
        if (received < amount) revert VaultShortfall(amount, received);
        // Each arrival is part of the fill, cancel or pull-out that caused it, and yieldDelivered is a public view.
        // forge-lint: disable-next-line(missing-events-arithmetic)
        yieldDelivered += received - amount;
    }

    /// @dev claimYield's return value is the vault's word, so only the MUSD measured arriving counts as delivered
    ///      (C31). A vault that refuses the claim adds nothing, and the maker is paid from what arrived before.
    function _claimFromVault() private returns (uint256 arrived) {
        IERC20 token = IERC20(musd);
        uint256 musdBefore = token.balanceOf(address(this));
        // The arrival can only be measured after the call; every caller holds the reentrancy lock.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        try IMUSDSavingsRate(savingsVault).claimYield() {} catch {}
        arrived = _rise(musdBefore, token.balanceOf(address(this)));
        yieldDelivered += arrived;
    }

    /// @dev How far `later` is above `earlier`, or zero if it is not, so a balance that moved the wrong way fails
    ///      the caller's exact check with VaultShortfall instead of an arithmetic panic.
    function _rise(uint256 earlier, uint256 later) private pure returns (uint256) {
        return later > earlier ? later - earlier : 0;
    }

    /// @dev A vault that refuses to report its index must not stop a principal movement, so the caller decides what
    ///      a failed read means (C35).
    function _readIndex() private view returns (bool ok, uint256 index) {
        // A view of the one fixed vault, inside try/catch, called at most MAX_FILLS times per fill.
        // forge-lint: disable-next-line(calls-loop)
        try IMUSDSavingsRate(savingsVault).yieldIndex() returns (uint256 value) {
            return (true, value);
        } catch {
            return (false, 0);
        }
    }

    /// @dev True only for a parked offer of the current era, the only kind whose MUSD is in the vault. A parked
    ///      offer of an era already pulled out had its principal returned as MUSD, so it is handled as plain.
    function _inVault(uint256 offerId) private view returns (bool) {
        return _offers[offerId].parked && _offerYield[offerId].era == parkingEra;
    }

    /// @dev What booking `offerId` now would add and the index its snapshot would move to; `ok` is false when there
    ///      is nothing to book (a plain or empty offer, or an unreadable index, which leaves the snapshot alone). An
    ///      ended era books only up to its recorded end index, so a later lump never reaches it (C32). The index is
    ///      Mezo's number, so one that falls, or is so large the product would overflow, books zero for that
    ///      stretch instead of reverting the fill or cancel around it (C35).
    function _yieldDue(uint256 offerId) private view returns (bool ok, uint256 end, uint256 earned) {
        Offer storage offer = _offers[offerId];
        uint256 remaining = offer.remaining;
        if (!offer.parked || remaining == 0) return (false, 0, 0);
        OfferYield storage clock = _offerYield[offerId];
        uint32 era = clock.era;
        if (era < parkingEra) {
            end = eraEndIndex[era];
        } else {
            (ok, end) = _readIndex();
            if (!ok) return (false, 0, 0);
        }
        uint256 start = clock.indexAt;
        if (end > start) {
            uint256 delta = end - start;
            if (delta <= type(uint256).max / remaining) earned = remaining * delta / INDEX_SCALE;
        }
        ok = true;
    }

    /// @dev Books the offer's yield on its remainder as it stands and moves its snapshot forward. Callers run it
    ///      before they change the remainder and before any vault withdraw (C33). Booked yield is only a claim:
    ///      withdrawOfferYield pays it out of delivered yield alone (C31).
    function _bookYield(uint256 offerId) private {
        (bool ok, uint256 end, uint256 earned) = _yieldDue(offerId);
        if (!ok) return;
        if (earned != 0) yieldOwedOf[_offers[offerId].maker] += earned;
        // Only forward: an index that dips and recovers must not book the same stretch twice, or one maker's
        // booking could outrun the vault's and be paid from another maker's delivered yield (C31).
        if (end > _offerYield[offerId].indexAt) _offerYield[offerId].indexAt = end;
    }

    /// @dev The one paid-out record, shared by redeem and withdrawCollected, so paidOutOf counts both paths.
    function _recordPaidOut(uint64 maturity, uint256 musdOut, uint256 btcOut) private {
        PaidOut storage paid = _paidOut[maturity];
        paid.musd = (uint256(paid.musd) + musdOut).toUint128();
        paid.btc = (uint256(paid.btc) + btcOut).toUint128();
    }

    function _setFeeShareBps(uint16 newFeeShareBps) private {
        if (newFeeShareBps > MAX_FEE_SHARE_BPS) revert FeeShareOutOfBounds(newFeeShareBps);
        feeShareBps = newFeeShareBps;
        emit FeeShareBpsSet(newFeeShareBps);
    }

    function _setMinOffer(uint128 newMinOffer) private {
        if (newMinOffer < MIN_OFFER_FLOOR || newMinOffer > MIN_OFFER_CEILING) revert MinOfferOutOfBounds(newMinOffer);
        minOffer = newMinOffer;
        emit MinOfferSet(newMinOffer);
    }

    function _setMaxTermSeconds(uint32 newMaxTermSeconds) private {
        if (newMaxTermSeconds < MIN_TERM_SECONDS || newMaxTermSeconds > MAX_TERM_CEILING) {
            revert MaxTermOutOfBounds(newMaxTermSeconds);
        }
        maxTermSeconds = newMaxTermSeconds;
        emit MaxTermSecondsSet(newMaxTermSeconds);
    }

    function _setTreasury(address newTreasury) private {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasurySet(newTreasury);
    }

    function _setGuardian(address newGuardian) private {
        if (newGuardian == address(0)) revert ZeroAddress();
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }
}
