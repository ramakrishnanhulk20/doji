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
import {Quote} from "./libraries/Quote.sol";

/// @title CreditMarkets
/// @notice Lenders post fixed-rate MUSD offers for a Thursday maturity and LoanManager fills them for
///         borrowers. Every maturity is its own market: lenders receive ERC-1155 credit units (token id =
///         maturity, one unit = one MUSD due) and redeem them pro rata once every loan at that date is closed.
/// @dev All MUSD sits in this one balance. Isolation between offers and maturities is bookkeeping, and every
///      inflow is booked from a measured balance change, so a direct donation never reaches any record.
contract CreditMarkets is ICreditMarkets, ERC1155, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant WEEK = 604_800;
    /// @dev A listed offer costs about 60k gas at worst (offer slot, two cold pending-unit slots, one event),
    ///      so 8 offers stay near 0.5M gas against Mezo's 10M block gas limit.
    uint256 public constant MAX_FILLS = 8;
    uint16 public constant MAX_APR_BPS = 5_000;
    uint16 public constant MAX_FEE_SHARE_BPS = 2_000;
    uint128 public constant MIN_OFFER_FLOOR = 1e18;
    uint128 public constant MIN_OFFER_CEILING = 1_000_000e18;
    uint32 public constant MIN_TERM_SECONDS = 604_800;
    uint32 public constant MAX_TERM_CEILING = 12 * 604_800;

    address public immutable musd;
    address public immutable loanManager;

    address public guardian;
    address public treasury;
    uint16 public feeShareBps;
    uint128 public minOffer;
    uint32 public maxTermSeconds;
    bool public offersPaused;
    uint256 public nextOfferId = 1;

    mapping(uint256 offerId => Offer) private _offers;
    mapping(uint64 maturity => Market) private _markets;
    mapping(address account => mapping(uint64 maturity => uint256 units)) private _pendingUnits;

    modifier onlyLoanManager() {
        if (msg.sender != loanManager) revert NotLoanManager();
        _;
    }

    /// @notice Fixes MUSD and LoanManager for the life of the contract and sets the starting parameters.
    /// @dev `loanManager_` is precomputed from the deployer's nonce; LoanManager's own constructor then
    ///      refuses to deploy unless this contract points at it. Reverts ZeroAddress, OwnableInvalidOwner,
    ///      or a parameter bound error. Emits one event per parameter.
    constructor(
        address musd_,
        address loanManager_,
        address owner_,
        address guardian_,
        address treasury_,
        uint16 feeShareBps_,
        uint128 minOffer_,
        uint32 maxTermSeconds_
    ) ERC1155("") Ownable(owner_) {
        if (musd_ == address(0) || loanManager_ == address(0)) revert ZeroAddress();
        musd = musd_;
        loanManager = loanManager_;
        _setGuardian(guardian_);
        _setTreasury(treasury_);
        _setFeeShareBps(feeShareBps_);
        _setMinOffer(minOffer_);
        _setMaxTermSeconds(maxTermSeconds_);
    }

    /// @inheritdoc ICreditMarkets
    function postOffer(uint64 maturity, uint16 aprBps, uint128 amount)
        external
        nonReentrant
        returns (uint256 offerId)
    {
        if (offersPaused) revert OffersPaused();
        if (!isValidMaturity(maturity)) revert InvalidMaturity(maturity);
        if (aprBps > MAX_APR_BPS) revert AprTooHigh(aprBps);
        if (amount < minOffer) revert OfferTooSmall(amount, minOffer);

        offerId = nextOfferId++;
        _offers[offerId] = Offer({maker: msg.sender, maturity: maturity, aprBps: aprBps, remaining: amount});
        emit OfferPosted(offerId, msg.sender, maturity, aprBps, amount);

        _pullExactly(msg.sender, amount);
    }

    /// @inheritdoc ICreditMarkets
    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = _offers[offerId];
        address maker = offer.maker;
        if (maker == address(0)) revert OfferNotFound(offerId);
        if (msg.sender != maker) revert NotMaker(offerId);
        uint128 refund = offer.remaining;
        if (refund == 0) revert OfferEmpty(offerId);

        offer.remaining = 0;
        emit OfferCancelled(offerId, maker, refund);

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

        uint256 secondsToMaturity = maturity - block.timestamp;
        for (uint256 i; i < count; ++i) {
            face += _takeOffer(offerIds[i], amounts[i], maturity, maxAprBps, secondsToMaturity);
            principal += amounts[i];
        }

        Market storage market = _markets[maturity];
        market.faceTotal = (uint256(market.faceTotal) + face).toUint128();
        market.openLoans += 1;

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

        if (musdAmount != 0) _pullExactly(msg.sender, musdAmount);
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

        emit MarketFinalized(maturity, market.unitsAtFinal, market.musdAtFinal);
    }

    /// @inheritdoc ICreditMarkets
    function redeem(uint64 maturity, uint256 units) external nonReentrant returns (uint256 musdOut) {
        Market storage market = _markets[maturity];
        if (!market.isFinal) revert NotFinal(maturity);
        if (units == 0) revert ZeroAmount();

        _burn(msg.sender, maturity, units);

        musdOut = Math.mulDiv(units, market.musdAtFinal, market.unitsAtFinal);
        if (musdOut > units) musdOut = units;
        // The only calls above are the internal burn and Math library; the MUSD transfer comes after this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Redeemed(msg.sender, maturity, units, musdOut);

        IERC20(musd).safeTransfer(msg.sender, musdOut);
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

    /// @dev Checks one listed offer against the borrow's terms, cuts its remainder before anything else, and
    ///      records the maker's and treasury's units in storage. Nothing is minted, so no maker code runs.
    ///      Each listed offer must pass on its own (C8), so its checks run per iteration of a loop capped at
    ///      MAX_FILLS; the only call before the event is the internal Quote library, not an outside contract.
    // forge-lint: disable-next-item(require-revert-in-loop,reentrancy-events)
    function _takeOffer(
        uint256 offerId,
        uint128 amount,
        uint64 maturity,
        uint16 maxAprBps,
        uint256 secondsToMaturity
    ) private returns (uint256 fillFace) {
        Offer storage offer = _offers[offerId];
        address maker = offer.maker;
        uint16 aprBps = offer.aprBps;
        if (maker == address(0)) revert OfferNotFound(offerId);
        if (offer.maturity != maturity) revert WrongMaturity(offerId, offer.maturity, maturity);
        if (aprBps > maxAprBps) revert AprAboveMax(offerId, aprBps, maxAprBps);
        if (amount == 0) revert ZeroAmount();
        if (offer.remaining < amount) revert InsufficientRemaining(offerId, offer.remaining, amount);
        offer.remaining -= amount;

        uint256 makerUnits;
        uint256 treasuryUnits;
        (fillFace, makerUnits, treasuryUnits) = Quote.quote(amount, aprBps, secondsToMaturity, feeShareBps);
        _pendingUnits[maker][maturity] += makerUnits;
        if (treasuryUnits != 0) _pendingUnits[treasury][maturity] += treasuryUnits;

        emit Filled(offerId, maker, maturity, amount, fillFace);
    }

    /// @dev Records are written for `amount` before this runs, so the measured arrival must match it exactly.
    ///      Reading the balance change, not the balance, means a donation sitting here changes nothing (C14).
    function _pullExactly(address from, uint256 amount) private {
        IERC20 token = IERC20(musd);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert TransferMismatch(amount, received);
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
