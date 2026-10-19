// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ILoanManager} from "./interfaces/ILoanManager.sol";
import {ICreditMarkets} from "./interfaces/ICreditMarkets.sol";
import {IVeBTC} from "./interfaces/IVeBTC.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {IPoolsVoter} from "./interfaces/IPoolsVoter.sol";
import {IVeBTCVoter} from "./interfaces/IVeBTCVoter.sol";
import {IFeeDistributor} from "./interfaces/IFeeDistributor.sol";
import {LockReader} from "./libraries/LockReader.sol";
import {Resolution} from "./libraries/Resolution.sol";
import {PassThrough} from "./libraries/PassThrough.sol";

/// @title LoanManager
/// @notice Takes custody of veBTC positions and opens one fixed-term MUSD loan per position from
///         CreditMarkets offers. The borrower repays the fixed face by the maturity, or rolls it to a later
///         one, and takes the position back. An overdue or unsafe loan is sold in a falling-price auction in
///         which the borrower keeps everything above the debt and a penalty; if nobody buys, the Bitcoin is
///         withdrawn once the lock ends and paid to that date's lenders. Doji never sells on a DEX. While a
///         position is held, its borrower keeps voting, claiming fees and incentives and extending the lock
///         through this contract, and a new user can lock BTC and borrow in one transaction.
/// @dev Deliberately has no receive(), no onERC721Received, no payable function, no generic call and no
///      approval on veBTC. veBTC.withdraw pays through the BTC ERC-20 view (live source, and the mainnet
///      fork test), so native BTC never needs receiving (C18). A position can only become collateral through
///      deposit(), which pulls it from the caller, or lockAndDeposit(), which mints it here for the caller, so
///      a token pushed in any other way never gets a borrower; the owner can only send such a token on with
///      rescuePosition. Borrower payouts from resolutions and expired-lock fee claims wait as claimables, which
///      this contract's balances always cover.
contract LoanManager is ILoanManager, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint16 public constant MIN_MAX_LTV_BPS = 1_000;
    uint16 public constant MAX_LIQ_LTV_BPS = 9_000;
    uint16 public constant MAX_PENALTY_BPS = 1_000;
    uint16 public constant MIN_AUCTION_FLOOR_BPS = 5_000;
    uint16 public constant MAX_AUCTION_FLOOR_BPS = 9_500;
    uint32 public constant MIN_AUCTION_DURATION = 1 hours;
    uint32 public constant MAX_AUCTION_DURATION = 7 days;
    uint128 public constant MIN_LOAN_FLOOR = 1e18;
    uint128 public constant MIN_LOAN_CEILING = 100_000e18;
    uint8 public constant ESCROW_NORMAL = 0;
    /// @dev Mezo's PoolsVoter caps a vote at maxVotingNum = 30 pools (live read 2026-10-19).
    uint16 private constant MAX_VOTES_CEILING = 30;
    /// @dev Most tokens one reward claim may list; the gas justification sits with PassThrough.
    uint256 public constant MAX_REWARD_TOKENS = PassThrough.MAX_REWARD_TOKENS;
    uint256 private constant BPS = 10_000;
    uint256 private constant PRICE_SCALE = 1e18;

    IVeBTC public immutable veBTC;
    IPriceFeed public immutable priceFeed;
    IERC20 public immutable musd;
    IERC20 public immutable btc;
    IPoolsVoter public immutable poolsVoter;
    IVeBTCVoter public immutable validatorsVoter;
    IFeeDistributor public immutable feeDistributor;
    ICreditMarkets public immutable creditMarkets;
    uint256 public immutable lockLayoutWords;
    uint16 public immutable maxVotes;

    address public guardian;
    uint16 public maxLtvBps;
    uint16 public liqLtvBps;
    uint128 public minLoan;
    bool public borrowsPaused;
    uint16 public penaltyBps;
    uint16 public auctionFloorBps;
    uint32 public auctionDuration;

    uint256 public totalClaimableMusd;
    uint256 public totalClaimableBtc;

    mapping(uint256 tokenId => Position) private _positions;
    mapping(uint256 tokenId => Loan) private _loans;
    mapping(uint256 tokenId => Auction) private _auctions;
    mapping(address account => uint256) public claimableMusd;
    mapping(address account => uint256) public claimableBtc;

    /// @notice Wires LoanManager to fixed Mezo contracts and to the CreditMarkets deployed for it.
    /// @dev Reverts ZeroAddress, BadLockLayout (not 3 or 4), CreditMarketsMismatch unless CreditMarkets already
    ///      names this contract as its LoanManager, MusdMismatch or BtcMismatch unless both contracts use the
    ///      same tokens, MaxVotesOutOfBounds, DuplicateVoter (ValidatorsVoter equal to PoolsVoter),
    ///      OwnableInvalidOwner, or a bound error. ValidatorsVoter may be zero on a chain whose veBTC has no
    ///      secondary voters; prepareSettle then skips it. Gives CreditMarkets an
    ///      unlimited MUSD allowance; BTC is approved per settle or lock for the exact amount and spent in the
    ///      same call.
    /// @param veBTC_ Mezo's veBTC proxy.
    /// @param priceFeed_ MUSD's BTC PriceFeed.
    /// @param musd_ The MUSD token.
    /// @param btc_ The BTC ERC-20 view that veBTC locks and pays in.
    /// @param poolsVoter_ Mezo's PoolsVoter, veBTC's primary voter.
    /// @param creditMarkets_ The CreditMarkets deployed for this LoanManager.
    /// @param lockLayoutWords_ Words veBTC's locked() returns on this chain: 3 on testnet, 4 on mainnet.
    /// @param settings_ Owner, guardian, fee distributor, ValidatorsVoter, vote cap and starting parameters.
    constructor(
        address veBTC_,
        address priceFeed_,
        address musd_,
        address btc_,
        address poolsVoter_,
        address creditMarkets_,
        uint256 lockLayoutWords_,
        Settings memory settings_
    ) Ownable(settings_.owner) {
        if (
            veBTC_ == address(0) || priceFeed_ == address(0) || musd_ == address(0) || btc_ == address(0)
                || poolsVoter_ == address(0) || creditMarkets_ == address(0) || settings_.feeDistributor == address(0)
        ) revert ZeroAddress();
        if (lockLayoutWords_ != 3 && lockLayoutWords_ != 4) revert BadLockLayout(lockLayoutWords_);
        if (settings_.maxVotes == 0 || settings_.maxVotes > MAX_VOTES_CEILING) {
            revert MaxVotesOutOfBounds(settings_.maxVotes);
        }
        if (settings_.validatorsVoter == poolsVoter_) revert DuplicateVoter();
        if (ICreditMarkets(creditMarkets_).loanManager() != address(this)) revert CreditMarketsMismatch();
        if (ICreditMarkets(creditMarkets_).musd() != musd_) revert MusdMismatch();
        if (ICreditMarkets(creditMarkets_).btc() != btc_) revert BtcMismatch();

        veBTC = IVeBTC(veBTC_);
        priceFeed = IPriceFeed(priceFeed_);
        musd = IERC20(musd_);
        btc = IERC20(btc_);
        poolsVoter = IPoolsVoter(poolsVoter_);
        validatorsVoter = IVeBTCVoter(settings_.validatorsVoter);
        feeDistributor = IFeeDistributor(settings_.feeDistributor);
        creditMarkets = ICreditMarkets(creditMarkets_);
        lockLayoutWords = lockLayoutWords_;
        maxVotes = settings_.maxVotes;

        _setGuardian(settings_.guardian);
        // Auction params first: their floor check reads liqLtvBps, and the risk check then reads the floor.
        _setAuctionParams(settings_.penaltyBps, settings_.auctionFloorBps, settings_.auctionDuration);
        _setRiskParams(settings_.maxLtvBps, settings_.liqLtvBps);
        _setMinLoan(settings_.minLoan);

        IERC20(musd_).forceApprove(creditMarkets_, type(uint256).max);
    }

    /// @inheritdoc ILoanManager
    function deposit(uint256 tokenId) external nonReentrant {
        if (veBTC.ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);
        _requireAcceptedCollateral(tokenId);
        if (_positions[tokenId].borrower != address(0)) revert PositionExists(tokenId);

        // Deposited on the next line records this change.
        // forge-lint: disable-next-line(missing-events-access-control)
        _positions[tokenId].borrower = msg.sender;
        emit Deposited(tokenId, msg.sender);

        veBTC.transferFrom(msg.sender, address(this), tokenId);
        if (veBTC.ownerOf(tokenId) != address(this)) revert CustodyCheckFailed(tokenId);
    }

    /// @inheritdoc ILoanManager
    function lockAndDeposit(uint256 amount, uint256 lockDuration) external nonReentrant returns (uint256 tokenId) {
        return _lockAndDeposit(amount, lockDuration);
    }

    /// @inheritdoc ILoanManager
    function lockAndBorrow(
        uint256 amount,
        uint256 lockDuration,
        uint64 maturity,
        uint256[] calldata offerIds,
        uint128[] calldata amounts,
        uint16 maxAprBps
    ) external nonReentrant returns (uint256 tokenId, uint256 principal, uint256 face) {
        tokenId = _lockAndDeposit(amount, lockDuration);
        (principal, face) = _openLoan(tokenId, maturity, offerIds, amounts, maxAprBps, false);
    }

    /// @inheritdoc ILoanManager
    function borrow(
        uint256 tokenId,
        uint64 maturity,
        uint256[] calldata offerIds,
        uint128[] calldata amounts,
        uint16 maxAprBps
    ) external nonReentrant returns (uint256 principal, uint256 face) {
        return _openLoan(tokenId, maturity, offerIds, amounts, maxAprBps, false);
    }

    /// @inheritdoc ILoanManager
    function roll(
        uint256 tokenId,
        uint64 newMaturity,
        uint256[] calldata offerIds,
        uint128[] calldata amounts,
        uint16 maxAprBps,
        uint256 maxTopUp
    ) external nonReentrant returns (uint256 principal, uint256 face) {
        (uint64 oldMaturity, uint256 owed) = _requireRollable(tokenId, newMaturity);
        // The old loan's record is replaced inside _openLoan, so its closing is announced before the new one.
        emit LoanClosed(tokenId, oldMaturity);
        uint256 musdBefore = musd.balanceOf(address(this));
        (principal, face) = _openLoan(tokenId, newMaturity, offerIds, amounts, maxAprBps, true);
        _repayRolled(tokenId, oldMaturity, newMaturity, owed, musd.balanceOf(address(this)) - musdBefore, maxTopUp);
    }

    /// @inheritdoc ILoanManager
    function repay(uint256 tokenId, uint256 amount) external nonReentrant returns (uint256 paid) {
        Loan storage loan = _loans[tokenId];
        LoanState state = loan.state;
        if (state != LoanState.Active && state != LoanState.Auction) revert NoActiveLoan(tokenId);
        if (amount == 0) revert ZeroAmount();

        uint64 maturity = loan.maturity;
        uint256 face = loan.face;
        uint256 owed = face - loan.repaid;
        paid = amount < owed ? amount : owed;
        uint256 owedAfter = owed - paid;
        bool closes = owedAfter == 0;

        if (closes) {
            delete _loans[tokenId];
            if (state == LoanState.Auction) delete _auctions[tokenId];
        } else {
            loan.repaid = (face - owedAfter).toUint128();
        }
        emit Repaid(tokenId, msg.sender, paid, owedAfter);
        if (closes) emit LoanClosed(tokenId, maturity);

        _pullExact(musd, paid);
        creditMarkets.credit(maturity, paid, closes);
    }

    /// @inheritdoc ILoanManager
    function withdrawCollateral(uint256 tokenId) external nonReentrant {
        _requireBorrower(tokenId);
        if (_loans[tokenId].state != LoanState.None) revert LoanOpen(tokenId);

        // Withdrawn on the next line records this change.
        // forge-lint: disable-next-line(missing-events-access-control)
        delete _positions[tokenId];
        emit Withdrawn(tokenId, msg.sender);

        veBTC.transferFrom(address(this), msg.sender, tokenId);
    }

    /// @inheritdoc ILoanManager
    function vote(uint256 tokenId, address[] calldata, uint256[] calldata) external nonReentrant {
        _requirePassThrough(tokenId, true);
        // The pools and weights are decoded inside PassThrough from this call's own arguments, which keeps
        // LoanManager under the size limit; the id it votes with is the `tokenId` checked just above.
        PassThrough.castVote(poolsVoter, address(veBTC), lockLayoutWords, maxVotes, tokenId, msg.data[4:]);
    }

    /// @inheritdoc ILoanManager
    function resetVotes(uint256 tokenId) external nonReentrant {
        _requirePassThrough(tokenId, false);
        poolsVoter.reset(tokenId);
    }

    /// @inheritdoc ILoanManager
    function claimRewards(uint256 tokenId, address[] calldata, address[][] calldata, address[][] calldata)
        external
        nonReentrant
    {
        _requirePassThrough(tokenId, false);
        // The three lists are decoded inside PassThrough from this call's own arguments, with the same ABI
        // rules, because handing nested calldata arrays over as arguments overflows the stack. The id it claims
        // for is the `tokenId` checked just above.
        PassThrough.forwardRewards(poolsVoter, tokenId, msg.data[4:]);
    }

    /// @inheritdoc ILoanManager
    function claimRebase(uint256 tokenId) external nonReentrant {
        _requirePassThrough(tokenId, false);
        uint256 before = _btcBalance();
        // The distributor's own return figure is ignored on purpose: what is credited is what was measured.
        // slither-disable-next-line unused-return
        // forge-lint: disable-next-line(unused-return)
        feeDistributor.claim(tokenId);
        uint256 credited = _btcBalance() - before;
        if (credited != 0) {
            claimableBtc[msg.sender] += credited;
            totalClaimableBtc += credited;
        }
        // The fee distributor is fixed at deployment and pays BTC through the precompile, which runs no code.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RebaseClaimed(tokenId, msg.sender, credited);
    }

    /// @inheritdoc ILoanManager
    function extendLock(uint256 tokenId, uint256 lockDuration) external nonReentrant {
        _requirePassThrough(tokenId, true);
        veBTC.increaseUnlockTime(tokenId, lockDuration);
    }

    /// @inheritdoc ILoanManager
    function startAuction(uint256 tokenId) external nonReentrant {
        Loan storage loan = _loans[tokenId];
        if (loan.state != LoanState.Active) revert LoanNotActive(tokenId);
        _requireCustody(tokenId);
        (,,, uint256 usdValue) = _collateral(tokenId);
        uint256 owed = uint256(loan.face) - loan.repaid;
        uint64 maturity = loan.maturity;
        // C24: a loan is overdue only once now > maturity; maturities are a week apart, so drift is irrelevant.
        // forge-lint: disable-next-line(block-timestamp)
        bool overdue = block.timestamp > maturity;
        if (!overdue && !Resolution.isUnsafe(owed, usdValue, loan.liqLtvBps)) revert NotLiquidatable(tokenId);

        uint256 floorPrice = Resolution.floorPrice(usdValue, owed, auctionFloorBps);
        uint32 duration = auctionDuration;
        uint16 penalty = penaltyBps;
        loan.state = LoanState.Auction;
        _auctions[tokenId] = Auction({
            startTime: block.timestamp.toUint64(),
            duration: duration,
            penaltyBps: penalty,
            startValue: usdValue.toUint128(),
            floorPrice: floorPrice.toUint128()
        });
        // The only calls above are view reads of veBTC and PriceFeed, which cannot change any state.
        // forge-lint: disable-next-line(reentrancy-events)
        emit AuctionStarted(tokenId, maturity, overdue, owed, usdValue, floorPrice, duration, penalty);
    }

    /// @inheritdoc ILoanManager
    function cancelAuction(uint256 tokenId) external nonReentrant {
        Loan storage loan = _loans[tokenId];
        if (loan.state != LoanState.Auction) revert NoAuction(tokenId);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > loan.maturity) revert LoanOverdue(tokenId);
        _requireCustody(tokenId);
        (,,, uint256 usdValue) = _collateral(tokenId);
        uint256 owed = uint256(loan.face) - loan.repaid;
        if (Resolution.isUnsafe(owed, usdValue, loan.liqLtvBps)) revert StillUnsafe(tokenId);

        loan.state = LoanState.Active;
        delete _auctions[tokenId];
        // The only calls above are view reads of veBTC and PriceFeed, which cannot change any state.
        // forge-lint: disable-next-line(reentrancy-events)
        emit AuctionCancelled(tokenId, owed, usdValue);
    }

    /// @inheritdoc ILoanManager
    function purchase(uint256 tokenId, uint256 maxPay, uint256 deadline)
        external
        nonReentrant
        returns (uint256 paid)
    {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert DeadlinePassed(deadline);
        Loan memory loan = _loans[tokenId];
        if (loan.state != LoanState.Auction) revert NoAuction(tokenId);
        _requireCustody(tokenId);
        uint256 owed = uint256(loan.face) - loan.repaid;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= loan.maturity) {
            (,,, uint256 usdValue) = _collateral(tokenId);
            if (!Resolution.isUnsafe(owed, usdValue, loan.liqLtvBps)) revert StillSafe(tokenId);
        }
        Auction memory auction = _auctions[tokenId];
        paid = _priceOf(auction);
        // The price moves with time by design; maxPay and the deadline bound what a buyer can be charged.
        // forge-lint: disable-next-line(block-timestamp)
        if (paid > maxPay) revert PriceAboveMax(paid, maxPay);
        (uint256 toMarket, uint256 toTreasury, uint256 toBorrower) =
            Resolution.splitSale(paid, owed, auction.penaltyBps);

        address borrower = _close(tokenId);
        if (toBorrower != 0) {
            claimableMusd[borrower] += toBorrower;
            totalClaimableMusd += toBorrower;
        }
        // The only calls above are view reads of veBTC and PriceFeed; every transfer comes after these events.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Purchased(tokenId, msg.sender, borrower, paid, toMarket, toTreasury, toBorrower);
        // forge-lint: disable-next-line(reentrancy-events)
        emit LoanClosed(tokenId, loan.maturity);

        _payOutSale(loan.maturity, paid, toMarket, toTreasury);
        veBTC.transferFrom(address(this), msg.sender, tokenId);
    }

    /// @inheritdoc ILoanManager
    function prepareSettle(uint256 tokenId) external nonReentrant {
        _requireFloorTimeReached(tokenId);
        _requireCustody(tokenId);
        bool poolsVote = _hasLiveVote(poolsVoter, tokenId);
        bool validatorsVote = _hasLiveVote(validatorsVoter, tokenId);
        (,, bool isPermanent) = LockReader.read(address(veBTC), tokenId, lockLayoutWords);
        if (!poolsVote && !validatorsVote && !isPermanent) revert NothingToPrepare(tokenId);
        emit SettlePrepared(tokenId, poolsVote, validatorsVote, isPermanent);

        if (poolsVote) poolsVoter.reset(tokenId);
        if (validatorsVote) validatorsVoter.reset(tokenId);
        if (isPermanent) veBTC.unlockPermanent(tokenId);
    }

    /// @inheritdoc ILoanManager
    function settle(uint256 tokenId) external nonReentrant {
        uint16 penalty = _requireFloorTimeReached(tokenId);
        _requireCustody(tokenId);
        (, uint256 lockEnd, bool isPermanent) = LockReader.read(address(veBTC), tokenId, lockLayoutWords);
        if (isPermanent) revert LockIsPermanent(tokenId);
        // forge-lint: disable-next-line(block-timestamp)
        if (lockEnd > block.timestamp) revert LockNotEnded(tokenId, lockEnd);
        if (veBTC.voted(tokenId)) revert StillVoted(tokenId);
        uint256 btcPrice = _price();

        Loan memory loan = _loans[tokenId];
        address borrower = _close(tokenId);
        uint256 received = _withdrawMeasured(tokenId);
        (uint256 toMarket, uint256 toTreasury, uint256 toBorrower) =
            Resolution.splitSettle(received, uint256(loan.face) - loan.repaid, penalty, btcPrice);
        if (toBorrower != 0) {
            claimableBtc[borrower] += toBorrower;
            totalClaimableBtc += toBorrower;
        }
        // veBTC is fixed at deployment and the only call before these events; the payouts follow them.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Settled(tokenId, borrower, received, btcPrice, toMarket, toTreasury, toBorrower);
        // forge-lint: disable-next-line(reentrancy-events)
        emit LoanClosed(tokenId, loan.maturity);

        if (toMarket != 0) btc.forceApprove(address(creditMarkets), toMarket);
        creditMarkets.creditBtc(loan.maturity, toMarket, true);
        if (toTreasury != 0) btc.safeTransfer(creditMarkets.treasury(), toTreasury);
    }

    /// @inheritdoc ILoanManager
    function writeOff(uint256 tokenId) external nonReentrant {
        Loan storage loan = _loans[tokenId];
        LoanState state = loan.state;
        if (state != LoanState.Active && state != LoanState.Auction) revert NoActiveLoan(tokenId);
        if (veBTC.ownerOf(tokenId) == address(this)) revert StillInCustody(tokenId);
        uint64 maturity = loan.maturity;
        uint256 owed = uint256(loan.face) - loan.repaid;

        _close(tokenId);
        emit WrittenOff(tokenId, maturity, owed);
        emit LoanClosed(tokenId, maturity);

        creditMarkets.credit(maturity, 0, true);
    }

    /// @inheritdoc ILoanManager
    function claim() external nonReentrant returns (uint256 musdOut, uint256 btcOut) {
        musdOut = claimableMusd[msg.sender];
        btcOut = claimableBtc[msg.sender];
        if (musdOut == 0 && btcOut == 0) revert NothingToClaim(msg.sender);
        if (musdOut != 0) {
            claimableMusd[msg.sender] = 0;
            totalClaimableMusd -= musdOut;
        }
        if (btcOut != 0) {
            claimableBtc[msg.sender] = 0;
            totalClaimableBtc -= btcOut;
        }
        emit Claimed(msg.sender, musdOut, btcOut);

        if (musdOut != 0) musd.safeTransfer(msg.sender, musdOut);
        if (btcOut != 0) btc.safeTransfer(msg.sender, btcOut);
    }

    /// @inheritdoc ILoanManager
    function auctionPrice(uint256 tokenId) external view returns (uint256) {
        if (_loans[tokenId].state != LoanState.Auction) revert NoAuction(tokenId);
        return _priceOf(_auctions[tokenId]);
    }

    /// @inheritdoc ILoanManager
    function collateralValue(uint256 tokenId) public view returns (uint256 btcAmount, uint256 usdValue) {
        (btcAmount,,, usdValue) = _collateral(tokenId);
    }

    /// @inheritdoc ILoanManager
    function owedOf(uint256 tokenId) public view returns (uint256) {
        Loan storage loan = _loans[tokenId];
        return uint256(loan.face) - loan.repaid;
    }

    /// @inheritdoc ILoanManager
    function positionOf(uint256 tokenId) external view returns (Position memory) {
        return _positions[tokenId];
    }

    /// @inheritdoc ILoanManager
    function loanOf(uint256 tokenId) external view returns (Loan memory) {
        return _loans[tokenId];
    }

    /// @inheritdoc ILoanManager
    function auctionOf(uint256 tokenId) external view returns (Auction memory) {
        return _auctions[tokenId];
    }

    /// @inheritdoc ILoanManager
    function isOverdue(uint256 tokenId) external view returns (bool) {
        Loan storage loan = _loans[tokenId];
        // forge-lint: disable-next-line(block-timestamp)
        return loan.state != LoanState.None && block.timestamp > loan.maturity;
    }

    /// @inheritdoc ILoanManager
    function isUnsafe(uint256 tokenId) external view returns (bool) {
        Loan storage loan = _loans[tokenId];
        if (loan.state == LoanState.None) return false;
        (,,, uint256 usdValue) = _collateral(tokenId);
        return Resolution.isUnsafe(uint256(loan.face) - loan.repaid, usdValue, loan.liqLtvBps);
    }

    /// @inheritdoc ILoanManager
    function lockOf(uint256 tokenId) external view returns (uint256 amount, uint256 end, bool isPermanent) {
        return LockReader.read(address(veBTC), tokenId, lockLayoutWords);
    }

    /// @inheritdoc ILoanManager
    function setRiskParams(uint16 newMaxLtvBps, uint16 newLiqLtvBps) external onlyOwner {
        _setRiskParams(newMaxLtvBps, newLiqLtvBps);
    }

    /// @inheritdoc ILoanManager
    function setAuctionParams(uint16 newPenaltyBps, uint16 newAuctionFloorBps, uint32 newAuctionDuration)
        external
        onlyOwner
    {
        _setAuctionParams(newPenaltyBps, newAuctionFloorBps, newAuctionDuration);
    }

    /// @inheritdoc ILoanManager
    function setMinLoan(uint128 newMinLoan) external onlyOwner {
        _setMinLoan(newMinLoan);
    }

    /// @inheritdoc ILoanManager
    function setGuardian(address newGuardian) external onlyOwner {
        _setGuardian(newGuardian);
    }

    /// @inheritdoc ILoanManager
    function setBorrowsPaused(bool paused) external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner();
        borrowsPaused = paused;
        emit BorrowsPausedSet(paused);
    }

    /// @inheritdoc ILoanManager
    function rescueToken(address token, address to, uint256 amount) external nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (token == address(veBTC)) revert TokenNotRescuable(token);
        // Only MUSD and BTC carry claimables; for any other token nothing is owed and the whole balance is free.
        uint256 owedOut = 0;
        if (token == address(musd)) owedOut = totalClaimableMusd;
        else if (token == address(btc)) owedOut = totalClaimableBtc;
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 surplus = balance > owedOut ? balance - owedOut : 0;
        if (amount > surplus) revert RescueExceedsSurplus(token, amount, surplus);
        // The only call above is a balance read.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Rescued(token, to, amount);
        IERC20(token).safeTransfer(to, amount);
    }

    /// @inheritdoc ILoanManager
    function rescuePosition(uint256 tokenId, address to) external nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (_positions[tokenId].borrower != address(0)) revert PositionExists(tokenId);
        _requireCustody(tokenId);
        // The only call above is the veBTC ownerOf read.
        // forge-lint: disable-next-line(reentrancy-events)
        emit PositionRescued(tokenId, to);
        veBTC.transferFrom(address(this), to, tokenId);
    }

    /// @dev The one open-loan path (C8), used by borrow and by the borrow half of roll. The pause check lives
    ///      here and is skipped for roll only (C19); roll has already checked the borrower and that its loan is
    ///      Active and on time. The face is only known once CreditMarkets prices the fill, so the loan is
    ///      written after that call. CreditMarkets is fixed at deployment, its only outside call is the MUSD
    ///      transfer of the principal (to the borrower, or here for a roll), and both contracts hold their
    ///      reentrancy locks throughout. Borrowed records the loan write. Maturities are a week apart, so
    ///      timestamp drift does not matter.
    // forge-lint: disable-next-item(reentrancy-no-eth,reentrancy-events)
    function _openLoan(
        uint256 tokenId,
        uint64 maturity,
        uint256[] calldata offerIds,
        uint128[] calldata amounts,
        uint16 maxAprBps,
        bool isRoll
    ) private returns (uint256 principal, uint256 face) {
        if (!isRoll) {
            if (borrowsPaused) revert BorrowsPaused();
            _requireBorrower(tokenId);
            if (_loans[tokenId].state != LoanState.None) revert LoanOpen(tokenId);
        }
        uint256 maxFace = _maxFace(tokenId, maturity);

        (principal, face) =
            creditMarkets.fill(maturity, offerIds, amounts, maxAprBps, isRoll ? address(this) : msg.sender);
        if (principal < minLoan) revert BelowMinLoan(principal, minLoan);
        if (face > maxFace) revert LtvTooHigh(face, maxFace);

        _loans[tokenId] = Loan({
            maturity: maturity,
            face: face.toUint128(),
            repaid: 0,
            maxLtvBps: maxLtvBps,
            liqLtvBps: liqLtvBps,
            state: LoanState.Active
        });

        emit Borrowed(tokenId, msg.sender, maturity, principal, face);
    }

    /// @dev Mints a new lock straight to this contract and records the caller as its borrower (C1). Pausable
    ///      like borrow (C19). The BTC pull is measured and exact; veBTC gets an allowance of exactly `amount`,
    ///      set back to zero right after whatever veBTC spent (C17). The id veBTC returns is recorded only once
    ///      ownerOf confirms this contract holds it and it passes the C2 test (C17). veBTC is fixed at
    ///      deployment and mints without a receiver hook, so no outside code runs before the record is written.
    // forge-lint: disable-next-item(reentrancy-no-eth,reentrancy-events,missing-events-access-control)
    function _lockAndDeposit(uint256 amount, uint256 lockDuration) private returns (uint256 tokenId) {
        if (borrowsPaused) revert BorrowsPaused();
        if (amount == 0) revert ZeroAmount();
        IERC20 coin = btc;
        IVeBTC ve = veBTC;
        _pullExact(coin, amount);

        coin.forceApprove(address(ve), amount);
        tokenId = ve.createLockFor(amount, lockDuration, address(this));
        coin.forceApprove(address(ve), 0);
        if (ve.ownerOf(tokenId) != address(this)) revert CustodyCheckFailed(tokenId);
        _requireAcceptedCollateral(tokenId);
        if (_positions[tokenId].borrower != address(0)) revert PositionExists(tokenId);

        _positions[tokenId].borrower = msg.sender;
        emit Deposited(tokenId, msg.sender);
    }

    /// @dev The one pass-through check (C4): the recorded borrower, the position still in custody (C2) and no
    ///      auction, where the resolution steps own the position. `strict` adds what vote and extendLock need:
    ///      an Active loan must be on time and safe at a fresh price, so neither runs on a loan that anyone may
    ///      already send to auction. Maturities are a week apart, so timestamp drift does not matter.
    // forge-lint: disable-next-item(block-timestamp)
    function _requirePassThrough(uint256 tokenId, bool strict) private view {
        _requireBorrower(tokenId);
        _requireCustody(tokenId);
        Loan storage loan = _loans[tokenId];
        LoanState state = loan.state;
        if (state == LoanState.Auction) revert LoanInAuction(tokenId);
        if (!strict || state != LoanState.Active) return;
        if (block.timestamp > loan.maturity) revert LoanOverdue(tokenId);
        (,,, uint256 usdValue) = _collateral(tokenId);
        if (Resolution.isUnsafe(uint256(loan.face) - loan.repaid, usdValue, loan.liqLtvBps)) {
            revert LoanUnsafe(tokenId);
        }
    }

    /// @dev The collateral and term checks of the open-loan path (C2, C6, C8, C24), returning the largest
    ///      face allowed at the current price. Maturities are a week apart, so timestamp drift does not matter.
    // forge-lint: disable-next-item(block-timestamp)
    function _maxFace(uint256 tokenId, uint64 maturity) private view returns (uint256) {
        _requireCustody(tokenId);
        _requireAcceptedCollateral(tokenId);
        if (!creditMarkets.isValidMaturity(maturity)) revert InvalidMaturity(maturity);

        (, uint256 lockEnd, bool isPermanent, uint256 usdValue) = _collateral(tokenId);
        if (isPermanent) {
            if (maturity > block.timestamp + creditMarkets.maxTermSeconds()) revert MaturityBeyondMaxTerm(maturity);
        } else if (maturity > lockEnd) {
            revert MaturityAfterLockEnd(maturity, lockEnd);
        }
        return Math.mulDiv(usdValue, maxLtvBps, BPS);
    }

    /// @dev Roll's own preconditions (C4, C24): the borrower, an Active loan, at or before its maturity, and
    ///      a later new maturity. Returns the old loan's maturity and what it still owes.
    // forge-lint: disable-next-item(block-timestamp)
    function _requireRollable(uint256 tokenId, uint64 newMaturity)
        private
        view
        returns (uint64 oldMaturity, uint256 owed)
    {
        _requireBorrower(tokenId);
        Loan storage loan = _loans[tokenId];
        if (loan.state != LoanState.Active) revert LoanNotActive(tokenId);
        oldMaturity = loan.maturity;
        if (block.timestamp > oldMaturity) revert LoanOverdue(tokenId);
        if (newMaturity <= oldMaturity) revert MaturityNotLater(oldMaturity, newMaturity);
        owed = uint256(loan.face) - loan.repaid;
    }

    /// @dev Repays the old market in full (the full-repayment ending of C9) from the new principal held here,
    ///      pulling any shortfall from the borrower only (C17) and returning any excess to them. `received` is
    ///      the measured MUSD the new fill brought in. Rolled is emitted before the MUSD moves.
    function _repayRolled(
        uint256 tokenId,
        uint64 oldMaturity,
        uint64 newMaturity,
        uint256 owed,
        uint256 received,
        uint256 maxTopUp
    ) private {
        uint256 excess = received > owed ? received - owed : 0;
        uint256 topUp = owed > received ? owed - received : 0;
        if (topUp > maxTopUp) revert TopUpTooHigh(topUp, maxTopUp);
        // The fill above is CreditMarkets, fixed at deployment and under its own lock.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Rolled(tokenId, oldMaturity, newMaturity, owed, excess, topUp);

        _pullExact(musd, topUp);
        creditMarkets.credit(oldMaturity, owed, true);
        if (excess != 0) musd.safeTransfer(msg.sender, excess);
    }

    /// @dev The one value function (C6, C7): locked BTC from the chain-specific decoder times the live price.
    function _collateral(uint256 tokenId)
        private
        view
        returns (uint256 btcAmount, uint256 lockEnd, bool isPermanent, uint256 usdValue)
    {
        (btcAmount, lockEnd, isPermanent) = LockReader.read(address(veBTC), tokenId, lockLayoutWords);
        usdValue = Math.mulDiv(btcAmount, _price(), PRICE_SCALE);
    }

    /// @dev The one price function (C7). PriceFeed already returns 18 decimals and reverts when stale.
    function _price() private view returns (uint256 price) {
        try priceFeed.fetchPrice() returns (uint256 fetched) {
            price = fetched;
        } catch {
            revert PriceUnavailable();
        }
        if (price == 0) revert PriceUnavailable();
    }

    /// @dev The one borrower check (C4).
    function _requireBorrower(uint256 tokenId) private view {
        if (_positions[tokenId].borrower != msg.sender) revert NotBorrower(tokenId);
    }

    /// @dev C2: once the position has left this contract, nothing but writeOff runs for its loan.
    function _requireCustody(uint256 tokenId) private view {
        if (veBTC.ownerOf(tokenId) != address(this)) revert NotInCustody(tokenId);
    }

    /// @dev C5: a voter holds a live vote for a position exactly while its usedWeights is above zero; the voter
    ///      marks the position voted on veBTC at the same moment and its reset clears both. A zero voter address
    ///      (no secondary voters on this chain) never holds one.
    function _hasLiveVote(IVeBTCVoter voter, uint256 tokenId) private view returns (bool) {
        return address(voter) != address(0) && voter.usedWeights(tokenId) != 0;
    }

    /// @dev Settle and its preparation run only on an unsold auction past its floor time (C12).
    function _requireFloorTimeReached(uint256 tokenId) private view returns (uint16 penalty) {
        if (_loans[tokenId].state != LoanState.Auction) revert NoAuction(tokenId);
        Auction storage auction = _auctions[tokenId];
        uint256 floorTime = uint256(auction.startTime) + auction.duration;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < floorTime) revert FloorTimeNotReached(tokenId, floorTime);
        penalty = auction.penaltyBps;
    }

    /// @dev C12: the BTC a settle splits is the measured change in this contract's BTC balance around the
    ///      withdraw, never locked().amount, so claimables and stray BTC already here are left out.
    function _withdrawMeasured(uint256 tokenId) private returns (uint256 received) {
        uint256 before = _btcBalance();
        veBTC.withdraw(tokenId);
        received = _btcBalance() - before;
    }

    /// @dev The one BTC reader. On Mezo the ERC-20 view and native BTC are the same coins, so the native
    ///      balance is never added to it.
    function _btcBalance() private view returns (uint256) {
        return btc.balanceOf(address(this));
    }

    /// @dev The price an auction stands at now, from its own snapshot only (C11, C19).
    function _priceOf(Auction memory auction) private view returns (uint256) {
        return Resolution.priceAt(
            auction.startValue, auction.floorPrice, block.timestamp - auction.startTime, auction.duration
        );
    }

    /// @dev The one place a resolution ends a loan (C9): the loan, its auction and the position go together,
    ///      so the market's open-loan count falls once and a returning tokenId starts empty.
    function _close(uint256 tokenId) private returns (address borrower) {
        borrower = _positions[tokenId].borrower;
        delete _loans[tokenId];
        delete _auctions[tokenId];
        delete _positions[tokenId];
    }

    /// @dev Pulls the sale price from the buyer, books the market's share and pays the penalty. The
    ///      borrower's share stays here as the claimable recorded before this runs (C11, C28).
    function _payOutSale(uint64 maturity, uint256 paid, uint256 toMarket, uint256 toTreasury) private {
        _pullExact(musd, paid);
        creditMarkets.credit(maturity, toMarket, true);
        if (toTreasury != 0) musd.safeTransfer(creditMarkets.treasury(), toTreasury);
    }

    /// @dev The one intake for MUSD and BTC (C17): only from the caller, measured, and exact or revert, so
    ///      claimables, market credits and new locks are always backed by tokens that really arrived.
    function _pullExact(IERC20 token, uint256 amount) private {
        if (amount == 0) return;
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert TransferShortfall(amount, received);
    }

    /// @dev One positive test (C2): ordinary escrow and nobody who can revoke it. Any escrow type Mezo adds
    ///      later is refused because it is not NORMAL. It does not cover a new transfer path a veBTC upgrade adds.
    function _requireAcceptedCollateral(uint256 tokenId) private view {
        if (veBTC.escrowType(tokenId) != ESCROW_NORMAL || veBTC.grantManager(tokenId) != address(0)) {
            revert CollateralNotAccepted(tokenId);
        }
    }

    /// @dev The line must stay below the auction floor, so a loan that trips the line still sells above its
    ///      debt at the floor while the price holds.
    function _setRiskParams(uint16 newMaxLtvBps, uint16 newLiqLtvBps) private {
        if (
            newMaxLtvBps < MIN_MAX_LTV_BPS || newMaxLtvBps >= newLiqLtvBps || newLiqLtvBps > MAX_LIQ_LTV_BPS
                || newLiqLtvBps >= auctionFloorBps
        ) {
            revert RiskParamsOutOfBounds(newMaxLtvBps, newLiqLtvBps);
        }
        maxLtvBps = newMaxLtvBps;
        liqLtvBps = newLiqLtvBps;
        emit RiskParamsSet(newMaxLtvBps, newLiqLtvBps);
    }

    function _setAuctionParams(uint16 newPenaltyBps, uint16 newAuctionFloorBps, uint32 newAuctionDuration) private {
        if (
            newPenaltyBps > MAX_PENALTY_BPS || newAuctionFloorBps < MIN_AUCTION_FLOOR_BPS
                || newAuctionFloorBps > MAX_AUCTION_FLOOR_BPS || newAuctionFloorBps <= liqLtvBps
                || newAuctionDuration < MIN_AUCTION_DURATION || newAuctionDuration > MAX_AUCTION_DURATION
        ) {
            revert AuctionParamsOutOfBounds(newPenaltyBps, newAuctionFloorBps, newAuctionDuration);
        }
        penaltyBps = newPenaltyBps;
        auctionFloorBps = newAuctionFloorBps;
        auctionDuration = newAuctionDuration;
        emit AuctionParamsSet(newPenaltyBps, newAuctionFloorBps, newAuctionDuration);
    }

    function _setMinLoan(uint128 newMinLoan) private {
        if (newMinLoan < MIN_LOAN_FLOOR || newMinLoan > MIN_LOAN_CEILING) revert MinLoanOutOfBounds(newMinLoan);
        minLoan = newMinLoan;
        emit MinLoanSet(newMinLoan);
    }

    function _setGuardian(address newGuardian) private {
        if (newGuardian == address(0)) revert ZeroAddress();
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }
}
