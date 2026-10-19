// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVeBTC} from "./IVeBTC.sol";
import {IPriceFeed} from "./IPriceFeed.sol";
import {ICreditMarkets} from "./ICreditMarkets.sol";
import {IPoolsVoter} from "./IPoolsVoter.sol";
import {IVeBTCVoter} from "./IVeBTCVoter.sol";
import {IFeeDistributor} from "./IFeeDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ILoanManager
/// @notice Holds veBTC positions as collateral and opens fixed-term MUSD loans against them from
///         CreditMarkets offers. While a position is held, its borrower keeps voting, claiming and extending
///         the lock through LoanManager.
interface ILoanManager {
    /// @dev A closed loan is deleted, so it reads back as None and Closed is never stored.
    enum LoanState {
        None,
        Active,
        Auction,
        Closed
    }

    struct Position {
        address borrower;
    }

    struct Loan {
        uint64 maturity;
        uint128 face;
        uint128 repaid;
        uint16 maxLtvBps;
        uint16 liqLtvBps;
        LoanState state;
    }

    /// @dev Starting owner and guardian, the fixed veBTC fee distributor, ValidatorsVoter (zero on a chain whose
    ///      veBTC has no secondary voters) and per-vote pool cap, and the owner-settable parameters, passed to the
    ///      constructor as one argument because that many separate constructor arguments overflow the compiler's
    ///      stack. Later parameter changes go through the setters and two-step ownership transfer; the fee
    ///      distributor, ValidatorsVoter and the vote cap never change.
    struct Settings {
        address owner;
        address guardian;
        address feeDistributor;
        address validatorsVoter;
        uint16 maxVotes;
        uint16 maxLtvBps;
        uint16 liqLtvBps;
        uint128 minLoan;
        uint16 penaltyBps;
        uint16 auctionFloorBps;
        uint32 auctionDuration;
    }

    /// @dev Snapshotted when the auction starts (C19): later setter calls never reach a running auction.
    struct Auction {
        uint64 startTime;
        uint32 duration;
        uint16 penaltyBps;
        uint128 startValue;
        uint128 floorPrice;
    }

    /// @notice A position entered custody and `borrower` became its borrower.
    event Deposited(uint256 indexed tokenId, address indexed borrower);
    /// @notice A loan opened: `principal` MUSD lent, `face` MUSD owed at `maturity`.
    event Borrowed(
        uint256 indexed tokenId, address indexed borrower, uint64 indexed maturity, uint256 principal, uint256 face
    );
    /// @notice `payer` paid `amount` MUSD towards a loan, leaving `owedAfter`.
    event Repaid(uint256 indexed tokenId, address indexed payer, uint256 amount, uint256 owedAfter);
    /// @notice A loan ended by any of the endings in C9.
    event LoanClosed(uint256 indexed tokenId, uint64 indexed maturity);
    /// @notice A position with no loan went back to its borrower.
    event Withdrawn(uint256 indexed tokenId, address indexed borrower);
    /// @notice New loans will use these LTV limits.
    event RiskParamsSet(uint16 maxLtvBps, uint16 liqLtvBps);
    /// @notice New loans need at least this principal.
    event MinLoanSet(uint128 minLoan);
    /// @notice The address that may pause new borrows changed.
    event GuardianSet(address indexed guardian);
    /// @notice New borrows and lock creation were paused or resumed.
    event BorrowsPausedSet(bool paused);
    /// @notice New auctions will use these settings.
    event AuctionParamsSet(uint16 penaltyBps, uint16 auctionFloorBps, uint32 auctionDuration);
    /// @notice A loan went to auction, with the curve snapshotted for its whole life.
    event AuctionStarted(
        uint256 indexed tokenId,
        uint64 indexed maturity,
        bool overdue,
        uint256 owed,
        uint256 startValue,
        uint256 floorPrice,
        uint32 duration,
        uint16 penaltyBps
    );
    /// @notice A recovered loan left auction and is Active again.
    event AuctionCancelled(uint256 indexed tokenId, uint256 owed, uint256 usdValue);
    /// @notice `buyer` bought an auctioned position; the price split between market, treasury and borrower.
    event Purchased(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed borrower,
        uint256 price,
        uint256 toMarket,
        uint256 toTreasury,
        uint256 toBorrower
    );
    /// @notice An unsold position's live votes were reset on each voter that held one and, if permanent, its
    ///         lock unlocked, ready for settle.
    event SettlePrepared(
        uint256 indexed tokenId, bool poolsVoteReset, bool validatorsVoteReset, bool permanentUnlocked
    );
    /// @notice An unsold position's BTC was withdrawn and split between market, treasury and borrower.
    event Settled(
        uint256 indexed tokenId,
        address indexed borrower,
        uint256 btcReceived,
        uint256 btcPrice,
        uint256 toMarket,
        uint256 toTreasury,
        uint256 toBorrower
    );
    /// @notice A loan whose position left custody closed with zero recovery.
    event WrittenOff(uint256 indexed tokenId, uint64 indexed maturity, uint256 owed);
    /// @notice A loan rolled from `oldMaturity` to `newMaturity`, repaying the old market in full.
    event Rolled(
        uint256 indexed tokenId,
        uint64 indexed oldMaturity,
        uint64 indexed newMaturity,
        uint256 oldOwed,
        uint256 excessPaid,
        uint256 topUp
    );
    /// @notice `account` collected its MUSD and BTC claimables.
    event Claimed(address indexed account, uint256 musdAmount, uint256 btcAmount);
    /// @notice A position's reward claim raised LoanManager's `token` balance by `amount`, all of it paid to
    ///         the borrower.
    event RewardsForwarded(uint256 indexed tokenId, address indexed token, uint256 amount);
    /// @notice A position's fee-distributor claim ran. `btcCredited` is the BTC that arrived and was added to
    ///         the borrower's BTC claimable; zero when the claim went into the lock instead.
    event RebaseClaimed(uint256 indexed tokenId, address indexed borrower, uint256 btcCredited);
    /// @notice The owner moved stray `token` that belongs to no record.
    event Rescued(address indexed token, address indexed to, uint256 amount);
    /// @notice The owner moved a veBTC position that arrived without becoming a position.
    event PositionRescued(uint256 indexed tokenId, address indexed to);

    /// @notice An address argument or setting was the zero address.
    error ZeroAddress();
    /// @notice An amount was zero where it must be positive.
    error ZeroAmount();
    /// @notice The lock layout is not 3 (testnet) or 4 (mainnet) words.
    error BadLockLayout(uint256 layoutWords);
    /// @notice CreditMarkets does not name this contract as its LoanManager.
    error CreditMarketsMismatch();
    /// @notice CreditMarkets uses a different MUSD.
    error MusdMismatch();
    /// @notice The caller does not own the position, or it does not exist.
    error NotTokenOwner(uint256 tokenId);
    /// @notice The position is not NORMAL escrow with no grant manager (C2).
    error CollateralNotAccepted(uint256 tokenId);
    /// @notice A position record already exists for this token.
    error PositionExists(uint256 tokenId);
    /// @notice The token did not arrive in LoanManager's custody.
    error CustodyCheckFailed(uint256 tokenId);
    /// @notice The caller is not the position's recorded borrower.
    error NotBorrower(uint256 tokenId);
    /// @notice The position has an open loan.
    error LoanOpen(uint256 tokenId);
    /// @notice The position has no open loan.
    error NoActiveLoan(uint256 tokenId);
    /// @notice LoanManager no longer owns the position.
    error NotInCustody(uint256 tokenId);
    /// @notice New borrows and lock creation are paused.
    error BorrowsPaused();
    /// @notice The maturity is not a valid, open Thursday within the maximum term.
    error InvalidMaturity(uint64 maturity);
    /// @notice A normal lock would end before the loan's maturity.
    error MaturityAfterLockEnd(uint64 maturity, uint256 lockEnd);
    /// @notice A permanent lock's loan would run past the maximum term.
    error MaturityBeyondMaxTerm(uint64 maturity);
    /// @notice The principal is below the minimum loan.
    error BelowMinLoan(uint256 principal, uint256 minLoan);
    /// @notice The face is above the borrow limit at the current price.
    error LtvTooHigh(uint256 face, uint256 maxFace);
    /// @notice The price feed reverted or returned zero.
    error PriceUnavailable();
    /// @notice Fewer tokens arrived than were pulled.
    error TransferShortfall(uint256 expected, uint256 received);
    /// @notice Only the guardian or the owner may pause.
    error NotGuardianOrOwner();
    /// @notice The LTV limits are outside their hard-coded bounds.
    error RiskParamsOutOfBounds(uint16 maxLtvBps, uint16 liqLtvBps);
    /// @notice The minimum loan is outside 1 to 100,000 MUSD.
    error MinLoanOutOfBounds(uint128 minLoan);
    /// @notice CreditMarkets uses a different BTC.
    error BtcMismatch();
    /// @notice The auction settings are outside their hard-coded bounds.
    error AuctionParamsOutOfBounds(uint16 penaltyBps, uint16 auctionFloorBps, uint32 auctionDuration);
    /// @notice The loan is not Active.
    error LoanNotActive(uint256 tokenId);
    /// @notice The loan is not in auction.
    error NoAuction(uint256 tokenId);
    /// @notice The loan is neither overdue nor unsafe.
    error NotLiquidatable(uint256 tokenId);
    /// @notice The loan's maturity has passed.
    error LoanOverdue(uint256 tokenId);
    /// @notice The loan is still above its liquidation line.
    error StillUnsafe(uint256 tokenId);
    /// @notice The loan is back under its liquidation line.
    error StillSafe(uint256 tokenId);
    /// @notice The purchase deadline has passed.
    error DeadlinePassed(uint256 deadline);
    /// @notice The auction price is above what the buyer agreed to pay.
    error PriceAboveMax(uint256 price, uint256 maxPay);
    /// @notice The auction has not reached its floor time.
    error FloorTimeNotReached(uint256 tokenId, uint256 floorTime);
    /// @notice The position has no vote to reset and no permanent lock to unlock.
    error NothingToPrepare(uint256 tokenId);
    /// @notice The lock is still permanent.
    error LockIsPermanent(uint256 tokenId);
    /// @notice The lock has not ended.
    error LockNotEnded(uint256 tokenId, uint256 lockEnd);
    /// @notice The position still has a standing vote.
    error StillVoted(uint256 tokenId);
    /// @notice LoanManager still owns the position, so it cannot be written off.
    error StillInCustody(uint256 tokenId);
    /// @notice A roll must move to a later maturity.
    error MaturityNotLater(uint64 oldMaturity, uint64 newMaturity);
    /// @notice The roll needs more top-up than the caller allowed.
    error TopUpTooHigh(uint256 topUp, uint256 maxTopUp);
    /// @notice The account has nothing to claim.
    error NothingToClaim(address account);
    /// @notice The vote cap is outside 1 to 30, PoolsVoter's own per-vote pool limit.
    error MaxVotesOutOfBounds(uint16 maxVotes);
    /// @notice The loan is in auction, so the borrower's pass-throughs are closed (C4).
    error LoanInAuction(uint256 tokenId);
    /// @notice The loan is above its liquidation line at a fresh price (C4).
    error LoanUnsafe(uint256 tokenId);
    /// @notice A vote must list 1 to maxVotes pools.
    error BadVoteCount(uint256 count);
    /// @notice Two arrays that pair up have different lengths.
    error LengthMismatch();
    /// @notice A normal lock may not vote at or after lockEnd - 1 week (C5).
    error VoteTooLate(uint256 tokenId, uint256 lockEnd);
    /// @notice A reward claim must list 1 to MAX_REWARD_TOKENS tokens, at least one per gauge.
    error BadRewardTokenCount(uint256 count);
    /// @notice PoolsVoter has no fee and incentive reward contracts for this address, so it is not a gauge (C10).
    error UnknownGauge(address gauge);
    /// @notice The token is not on PoolsVoter's whitelist, so no Mezo reward contract pays it (C10).
    error TokenNotWhitelisted(address token);
    /// @notice ValidatorsVoter and PoolsVoter must be different contracts.
    error DuplicateVoter();
    /// @notice The rescue would dip into what is owed to claimable holders (C28).
    error RescueExceedsSurplus(address token, uint256 amount, uint256 surplus);
    /// @notice veBTC is never moved by rescueToken; stray positions go through rescuePosition.
    error TokenNotRescuable(address token);

    /// @notice Hands a veBTC position to LoanManager and records the caller as its borrower.
    /// @dev The caller must own the position and approve this contract for that single token first.
    ///      Only NORMAL escrow positions with no grant manager are accepted. LoanManager pulls the token with
    ///      transferFrom and confirms it now owns it. Reverts NotTokenOwner (also for a missing token),
    ///      CollateralNotAccepted, PositionExists or CustodyCheckFailed. Emits Deposited.
    /// @param tokenId veBTC position id.
    function deposit(uint256 tokenId) external;

    /// @notice Locks the caller's BTC as a new veBTC position held by LoanManager, with the caller as its
    ///         borrower.
    /// @dev Pausable like borrow (C19). Pulls exactly `amount` of the BTC ERC-20 from the caller, measured,
    ///      so the caller approves this contract first. Approves veBTC for exactly `amount`, calls
    ///      createLockFor(amount, lockDuration, LoanManager), then sets the BTC allowance back to zero (C17).
    ///      The new id is recorded only after veBTC.ownerOf confirms LoanManager holds it and it passes the
    ///      C2 test. Reverts BorrowsPaused, ZeroAmount, TransferShortfall, CustodyCheckFailed,
    ///      CollateralNotAccepted, PositionExists, or any createLockFor revert. Emits Deposited.
    /// @param amount BTC to lock, 18 decimals.
    /// @param lockDuration Seconds from now; veBTC rounds the end down to a Thursday 00:00 UTC.
    /// @return tokenId The new position's id.
    function lockAndDeposit(uint256 amount, uint256 lockDuration) external returns (uint256 tokenId);

    /// @notice Locks the caller's BTC as a new position and borrows against it in the same transaction.
    /// @dev lockAndDeposit, then the same open-loan path as borrow, with every borrow check. Reverts with any
    ///      lockAndDeposit or borrow revert. Emits Deposited, then Borrowed.
    /// @param amount BTC to lock, 18 decimals.
    /// @param lockDuration Seconds from now; the lock must end at or after `maturity`.
    /// @param maturity Thursday 00:00 UTC repayment date.
    /// @param offerIds Offers to take, all for `maturity`.
    /// @param amounts MUSD to take from each offer.
    /// @param maxAprBps Highest rate accepted on any listed offer.
    /// @return tokenId The new position's id.
    /// @return principal MUSD received.
    /// @return face MUSD owed at maturity.
    function lockAndBorrow(
        uint256 amount,
        uint256 lockDuration,
        uint64 maturity,
        uint256[] calldata offerIds,
        uint128[] calldata amounts,
        uint16 maxAprBps
    ) external returns (uint256 tokenId, uint256 principal, uint256 face);

    /// @notice Borrows MUSD against a deposited position from the listed offers, to be repaid at `maturity`.
    /// @dev Caller must be the position's borrower with no open loan. Reverts BorrowsPaused, NotBorrower,
    ///      LoanOpen, NotInCustody, CollateralNotAccepted, InvalidMaturity, MaturityAfterLockEnd (normal lock),
    ///      MaturityBeyondMaxTerm (permanent lock), PriceUnavailable, BelowMinLoan, LtvTooHigh, and any fill
    ///      revert from CreditMarkets. The principal goes to the caller. Emits Borrowed.
    /// @param tokenId Deposited position.
    /// @param maturity Thursday 00:00 UTC repayment date.
    /// @param offerIds Offers to take, all for `maturity`.
    /// @param amounts MUSD to take from each offer.
    /// @param maxAprBps Highest rate accepted on any listed offer.
    /// @return principal MUSD received.
    /// @return face MUSD owed at maturity.
    function borrow(
        uint256 tokenId,
        uint64 maturity,
        uint256[] calldata offerIds,
        uint128[] calldata amounts,
        uint16 maxAprBps
    ) external returns (uint256 principal, uint256 face);

    /// @notice Pays down a loan. Anyone may pay; the MUSD comes from the caller.
    /// @dev Works while the loan is Active, also after its maturity, and while it is in Auction. Pulls
    ///      min(amount, owed) from the caller and credits the loan's market. The payment that clears the
    ///      debt closes and deletes the loan, and any auction, in the same call; the position stays with
    ///      its borrower. Paying early still costs the full face. Never paused. Reverts NoActiveLoan,
    ///      ZeroAmount or TransferShortfall. Emits Repaid, and LoanClosed on the last payment.
    /// @param tokenId Position whose loan to pay.
    /// @param amount Most MUSD to pay.
    /// @return paid MUSD actually paid.
    function repay(uint256 tokenId, uint256 amount) external returns (uint256 paid);

    /// @notice Rolls an Active loan into a new one at a later maturity, repaying the old market in full.
    /// @dev Borrower only, at or before the old maturity, and never paused (C19). The new loan goes through
    ///      the same open-loan path as borrow (offer, maturity, lock-end, LTV, minimum-loan and collateral
    ///      checks, fresh LTV snapshots); its principal comes to LoanManager. If the principal covers what
    ///      is owed, the excess goes to the caller; otherwise the shortfall is pulled from the caller.
    ///      Reverts NotBorrower, LoanNotActive, LoanOverdue, MaturityNotLater, TopUpTooHigh,
    ///      TransferShortfall, any borrow revert except BorrowsPaused, and any fill revert. Emits LoanClosed for
    ///      the old loan, Borrowed for the new one (principal and face), then Rolled.
    /// @param tokenId Position whose loan to roll.
    /// @param newMaturity Thursday 00:00 UTC date of the new loan, later than the old one.
    /// @param offerIds Offers to take, all for `newMaturity`.
    /// @param amounts MUSD to take from each offer.
    /// @param maxAprBps Highest rate accepted on any listed offer.
    /// @param maxTopUp Most MUSD the caller agrees to add when the new principal is below what is owed.
    /// @return principal MUSD lent on the new loan.
    /// @return face MUSD owed on the new loan at `newMaturity`.
    function roll(
        uint256 tokenId,
        uint64 newMaturity,
        uint256[] calldata offerIds,
        uint128[] calldata amounts,
        uint16 maxAprBps,
        uint256 maxTopUp
    ) external returns (uint256 principal, uint256 face);

    /// @notice Casts the position's gauge vote on Mezo's PoolsVoter for its borrower.
    /// @dev Borrower only, position in custody, no auction, and an Active loan must be on time and safe at a
    ///      fresh price (C4). A normal lock may not vote at or after lockEnd - 1 week, so a reset is always
    ///      possible before the lock ends (C5); a permanent lock may vote in any epoch. Never paused. Reverts
    ///      NotBorrower, NotInCustody, LoanInAuction, LoanOverdue, LoanUnsafe, PriceUnavailable, BadVoteCount,
    ///      LengthMismatch, VoteTooLate, a LockReader error, or any PoolsVoter.vote revert unchanged.
    /// @param tokenId Position to vote with.
    /// @param pools Pools to vote for, 1 to maxVotes entries.
    /// @param weights Relative weight per pool, same length as `pools`.
    function vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights) external;

    /// @notice Clears the position's gauge vote on Mezo's PoolsVoter.
    /// @dev Borrower only, position in custody, loan None or Active at any health, never in auction, where
    ///      prepareSettle owns the reset. Never paused. Reverts NotBorrower, NotInCustody, LoanInAuction, or
    ///      any PoolsVoter.reset revert unchanged (same epoch as the last vote, or an epoch's first hour).
    /// @param tokenId Position whose vote to clear.
    function resetVotes(uint256 tokenId) external;

    /// @notice Claims the position's pool fees and incentives from the listed gauges through PoolsVoter and pays
    ///         them to its borrower.
    /// @dev Borrower only, position in custody, loan None or Active at any health, never in auction (C4). The
    ///      borrower names gauges, never reward contracts: each gauge's fee and incentive contracts are looked up
    ///      from PoolsVoter and both must exist (a registered gauge, live or killed), and every listed token must
    ///      be on PoolsVoter's whitelist, so only Mezo's own reward contracts run and they pay this tokenId only.
    ///      MUSD and BTC are allowed. 1 to MAX_REWARD_TOKENS tokens in total and at least one per gauge; a side
    ///      with no tokens is not called. Under the reentrancy lock, measures each distinct listed token's
    ///      balance, claims, measures again, and pays the borrower exactly each increase; a token listed twice is
    ///      measured and paid once. Claimables never change during the call (C10, C28). Never paused. Reverts
    ///      NotBorrower, NotInCustody, LoanInAuction, LengthMismatch, BadRewardTokenCount, UnknownGauge,
    ///      TokenNotWhitelisted, or any PoolsVoter or reward revert. Emits RewardsForwarded for each token whose
    ///      balance rose.
    /// @param tokenId Position whose rewards to claim.
    /// @param gauges Gauges to claim from, as registered on PoolsVoter.
    /// @param feeTokens Tokens to claim from each gauge's fee reward contract, one list per gauge.
    /// @param bribeTokens Tokens to claim from each gauge's incentive reward contract, one list per gauge.
    function claimRewards(
        uint256 tokenId,
        address[] calldata gauges,
        address[][] calldata feeTokens,
        address[][] calldata bribeTokens
    ) external;

    /// @notice Claims the position's share of veBTC fees from Mezo's fee distributor.
    /// @dev Borrower only, position in custody, loan None or Active at any health, never in auction. The
    ///      distributor adds the claim to an unexpired or permanent lock, which only raises the collateral;
    ///      for an expired normal lock it pays BTC to LoanManager, and exactly the measured BTC increase is
    ///      credited to the borrower's BTC claimable (C10, C28). Never paused. Reverts NotBorrower,
    ///      NotInCustody, LoanInAuction, or any distributor revert. Emits RebaseClaimed.
    /// @param tokenId Position whose fees to claim.
    function claimRebase(uint256 tokenId) external;

    /// @notice Pushes the position's lock end out through veBTC.increaseUnlockTime.
    /// @dev Same check as vote (C4): borrower only, in custody, no auction, and an Active loan on time and
    ///      safe at a fresh price. A later end never breaks a loan's maturity-before-lock-end rule. Never
    ///      paused. Reverts NotBorrower, NotInCustody, LoanInAuction, LoanOverdue, LoanUnsafe,
    ///      PriceUnavailable, a LockReader error, or any increaseUnlockTime revert unchanged.
    /// @param tokenId Position whose lock to extend.
    /// @param lockDuration Seconds from now; veBTC rounds the new end down to a Thursday 00:00 UTC.
    function extendLock(uint256 tokenId, uint256 lockDuration) external;

    /// @notice Puts an overdue or unsafe loan up for sale in a falling-price auction. Anyone may call.
    /// @dev Needs the loan Active, the position in custody and a fresh price, and either now > maturity or
    ///      owed > value * the loan's liqLtvBps / 10,000. Snapshots the start value (the collateralValue
    ///      figure), the floor max(value * auctionFloorBps / 10,000, min(owed, value)), the duration and the
    ///      penalty. Never paused. Reverts LoanNotActive, NotInCustody, PriceUnavailable, a LockReader error,
    ///      or NotLiquidatable. Emits AuctionStarted.
    /// @param tokenId Position whose loan to auction.
    function startAuction(uint256 tokenId) external;

    /// @notice Returns a recovered loan from Auction to Active. Anyone may call.
    /// @dev Needs the loan in Auction, not overdue, in custody, and a fresh price showing
    ///      owed <= value * liqLtvBps / 10,000. Deletes the auction; the next trigger starts a new one from a
    ///      fresh value. Reverts NoAuction, LoanOverdue, NotInCustody, PriceUnavailable or StillUnsafe.
    ///      Emits AuctionCancelled.
    /// @param tokenId Position whose auction to cancel.
    function cancelAuction(uint256 tokenId) external;

    /// @notice The current auction price in MUSD: the start value falling linearly to the floor over the
    ///         duration, then flat at the floor.
    /// @dev Reverts NoAuction when the loan is not in Auction.
    /// @param tokenId Position in auction.
    /// @return price MUSD a purchase would pay now.
    function auctionPrice(uint256 tokenId) external view returns (uint256 price);

    /// @notice Buys an auctioned position at the current auction price. Anyone may buy, the borrower too.
    /// @dev Needs the loan in Auction, the position in custody and now <= deadline. Unless the loan is
    ///      overdue, a fresh price must still show it unsafe. Pulls exactly the price P from the caller. With
    ///      D the debt still owed, the market gets min(P, D), the treasury min(penalty x D, P - min(P, D)) and
    ///      the borrower the rest as a MUSD claimable; the three sum to P. Deletes the loan, auction and
    ///      position, then sends the NFT with transferFrom, so a buyer contract that rejects ERC-721 hooks
    ///      still receives it. Never paused. Reverts DeadlinePassed, NoAuction, NotInCustody, StillSafe,
    ///      PriceUnavailable, PriceAboveMax or TransferShortfall. Emits Purchased and LoanClosed.
    /// @param tokenId Position to buy.
    /// @param maxPay Most MUSD the caller agrees to pay.
    /// @param deadline Last timestamp at which the purchase may run.
    /// @return paid MUSD paid.
    function purchase(uint256 tokenId, uint256 maxPay, uint256 deadline) external returns (uint256 paid);

    /// @notice Readies an unsold auctioned position for settle: clears every live vote veBTC counts and turns a
    ///         permanent lock into a normal one. Anyone may call.
    /// @dev Needs the loan in Auction, the floor time reached and the position in custody. Resets PoolsVoter and
    ///      ValidatorsVoter each only when that voter reports a live vote for the position (usedWeights above
    ///      zero), never blind; a reset not yet allowed this epoch (the epoch of that vote, or an epoch's first
    ///      hour) reverts unchanged, and the next epoch allows it (C5, C26). Then veBTC.unlockPermanent when the
    ///      lock is permanent. Never paused. Reverts NoAuction, FloorTimeNotReached, NotInCustody or
    ///      NothingToPrepare. Emits SettlePrepared.
    /// @param tokenId Position to prepare.
    function prepareSettle(uint256 tokenId) external;

    /// @notice Ends an unsold auction by withdrawing the Bitcoin and paying the market in BTC. Anyone may
    ///         call. No DEX sale happens.
    /// @dev Needs the loan in Auction, the floor time reached, the position in custody, a normal lock whose
    ///      end has passed, no standing vote and a fresh price. The BTC received is the measured change in
    ///      LoanManager's BTC balance around veBTC.withdraw. The market gets min(received, owed / price
    ///      rounded up), the treasury min(the rest, penalty x owed / price rounded down) and the borrower the
    ///      rest as a BTC claimable; the three sum to the BTC received. Deletes the loan, auction and
    ///      position. Never paused. Reverts NoAuction, FloorTimeNotReached, NotInCustody, LockIsPermanent,
    ///      LockNotEnded, StillVoted or PriceUnavailable. Emits Settled and LoanClosed.
    /// @param tokenId Position to settle.
    function settle(uint256 tokenId) external;

    /// @notice Closes a loan whose position has left LoanManager's custody, with zero recovery, so its
    ///         market can still become final (C2). Anyone may call.
    /// @dev Needs the loan Active or in Auction and veBTC.ownerOf(tokenId) not this contract. Deletes the
    ///      loan, auction and position. Never paused. Reverts NoActiveLoan or StillInCustody. Emits
    ///      WrittenOff and LoanClosed.
    /// @param tokenId Position whose loan to write off.
    function writeOff(uint256 tokenId) external;

    /// @notice Pays the caller every MUSD and BTC claimable recorded for them, once.
    /// @dev Zeroes both claimables before paying. Never paused. Reverts NothingToClaim. Emits Claimed.
    /// @return musdOut MUSD paid.
    /// @return btcOut BTC paid.
    function claim() external returns (uint256 musdOut, uint256 btcOut);

    /// @notice Returns a position with no open loan to its borrower.
    /// @dev Reverts NotBorrower or LoanOpen. Deletes the position before sending the token with
    ///      transferFrom. Emits Withdrawn.
    /// @param tokenId Position to withdraw.
    function withdrawCollateral(uint256 tokenId) external;

    /// @notice Owner only. Sends stray ERC-20 tokens that belong to no record.
    /// @dev For MUSD and BTC only the balance above totalClaimableMusd or totalClaimableBtc can leave, so
    ///      no claimable is ever touched (C28); any other ERC-20 leaves freely, because LoanManager keeps
    ///      no record in it. veBTC is refused: stray positions go through rescuePosition. Reverts
    ///      OwnableUnauthorizedAccount, ZeroAddress, ZeroAmount, TokenNotRescuable or RescueExceedsSurplus.
    ///      Emits Rescued.
    /// @param token ERC-20 to send.
    /// @param to Receiver.
    /// @param amount Amount to send.
    function rescueToken(address token, address to, uint256 amount) external;

    /// @notice Owner only. Sends a veBTC position that LoanManager holds but that never became a position
    ///         (it arrived by a plain transfer, C1).
    /// @dev Refuses any token with a position record, so no borrower's collateral can leave this way. Sends
    ///      with transferFrom. Reverts OwnableUnauthorizedAccount, ZeroAddress, PositionExists or
    ///      NotInCustody. Emits PositionRescued.
    /// @param tokenId Stray position id.
    /// @param to Receiver.
    function rescuePosition(uint256 tokenId, address to) external;

    /// @notice The one collateral value used for borrowing and shown to users: locked BTC times the
    ///         live BTC price. Voting power is never used.
    /// @dev Reverts LockReadFailed or BadLockAmount from LockReader, or PriceUnavailable.
    /// @param tokenId Position id.
    /// @return btcAmount Locked BTC in wei.
    /// @return usdValue Value in MUSD wei at the current price.
    function collateralValue(uint256 tokenId) external view returns (uint256 btcAmount, uint256 usdValue);

    /// @notice MUSD still owed on a position's loan, zero when there is no loan.
    /// @param tokenId Position id.
    /// @return owed MUSD still owed.
    function owedOf(uint256 tokenId) external view returns (uint256 owed);

    /// @notice A position's recorded borrower. A zero borrower means LoanManager holds no position for it.
    /// @param tokenId Position id.
    /// @return position The position record.
    function positionOf(uint256 tokenId) external view returns (Position memory position);

    /// @notice A position's loan record. State None means no open loan.
    /// @param tokenId Position id.
    /// @return loan The loan record.
    function loanOf(uint256 tokenId) external view returns (Loan memory loan);

    /// @notice A loan's running auction. A zero startTime means no auction.
    /// @param tokenId Position id.
    /// @return auction The auction snapshot.
    function auctionOf(uint256 tokenId) external view returns (Auction memory auction);

    /// @notice True when the position has an open loan whose maturity has passed.
    /// @param tokenId Position id.
    /// @return overdue Whether the loan is overdue.
    function isOverdue(uint256 tokenId) external view returns (bool overdue);

    /// @notice True when the position has an open loan with owed > value * the loan's liqLtvBps / 10,000.
    /// @dev Reverts PriceUnavailable or a LockReader error, like borrow, when the loan is open.
    /// @param tokenId Position id.
    /// @return unsafe Whether the loan is above its liquidation line.
    function isUnsafe(uint256 tokenId) external view returns (bool unsafe);

    /// @notice MUSD from auction surpluses waiting for `account` to claim.
    /// @param account Claimable holder.
    /// @return amount MUSD waiting.
    function claimableMusd(address account) external view returns (uint256 amount);

    /// @notice BTC from settle leftovers and expired-lock fee claims waiting for `account` to claim.
    /// @param account Claimable holder.
    /// @return amount BTC waiting.
    function claimableBtc(address account) external view returns (uint256 amount);

    /// @notice Sum of every account's claimableMusd.
    /// @return total MUSD owed to claimable holders.
    function totalClaimableMusd() external view returns (uint256 total);

    /// @notice Sum of every account's claimableBtc.
    /// @return total BTC owed to claimable holders.
    function totalClaimableBtc() external view returns (uint256 total);

    /// @notice The lock behind a position, decoded for this chain's veBTC layout.
    /// @dev Reverts LockReadFailed or BadLockAmount.
    /// @param tokenId Position id.
    /// @return amount Locked BTC in wei.
    /// @return end Unlock time, or 0 for a permanent lock.
    /// @return isPermanent True for a permanent lock.
    function lockOf(uint256 tokenId) external view returns (uint256 amount, uint256 end, bool isPermanent);

    /// @notice The veBTC contract, fixed at deployment.
    /// @return The veBTC contract.
    function veBTC() external view returns (IVeBTC);

    /// @notice The BTC price feed, fixed at deployment.
    /// @return The price feed.
    function priceFeed() external view returns (IPriceFeed);

    /// @notice The MUSD token, fixed at deployment.
    /// @return The MUSD token.
    function musd() external view returns (IERC20);

    /// @notice The BTC ERC-20 view that veBTC.withdraw pays in, fixed at deployment.
    /// @return The BTC token.
    function btc() external view returns (IERC20);

    /// @notice Mezo's PoolsVoter, the only voter LoanManager votes and claims through, fixed at deployment.
    /// @return The PoolsVoter.
    function poolsVoter() external view returns (IPoolsVoter);

    /// @notice Mezo's ValidatorsVoter, the secondary veBTC voter prepareSettle also resets, fixed at deployment.
    ///         Zero on a chain whose veBTC has no secondary voters.
    /// @return The ValidatorsVoter, or zero.
    function validatorsVoter() external view returns (IVeBTCVoter);

    /// @notice Mezo's veBTC fee distributor, fixed at deployment.
    /// @return The fee distributor.
    function feeDistributor() external view returns (IFeeDistributor);

    /// @notice Most pools one vote may list, fixed at deployment.
    /// @return The cap.
    function maxVotes() external view returns (uint16);

    /// @notice The CreditMarkets contract, fixed at deployment.
    /// @return The CreditMarkets contract.
    function creditMarkets() external view returns (ICreditMarkets);

    /// @notice Number of 32-byte words veBTC's locked() returns on this chain: 3 on testnet, 4 on mainnet.
    /// @return The layout size in words.
    function lockLayoutWords() external view returns (uint256);

    /// @notice Highest face-to-value ratio a new loan may open at, in basis points.
    /// @return The borrow limit.
    function maxLtvBps() external view returns (uint16);

    /// @notice Ratio at which a loan becomes unsafe, in basis points. Snapshotted per loan.
    /// @return The liquidation line.
    function liqLtvBps() external view returns (uint16);

    /// @notice Smallest principal a loan may have, in MUSD wei.
    /// @return The minimum loan.
    function minLoan() external view returns (uint128);

    /// @notice Penalty on the debt paid to the treasury from an auction or settle, in basis points.
    ///         Snapshotted per auction.
    /// @return The penalty.
    function penaltyBps() external view returns (uint16);

    /// @notice Lowest the auction price falls to, as a share of the start value, in basis points. The
    ///         floor is never below min(owed, start value). Snapshotted per auction.
    /// @return The floor share.
    function auctionFloorBps() external view returns (uint16);

    /// @notice Seconds the auction price takes to fall to its floor. Snapshotted per auction.
    /// @return The duration.
    function auctionDuration() external view returns (uint32);

    /// @notice Address that may pause new borrows alongside the owner.
    /// @return The guardian.
    function guardian() external view returns (address);

    /// @notice True while new borrows and lock creation are paused.
    /// @return Whether borrows are paused.
    function borrowsPaused() external view returns (bool);

    /// @notice Owner only. Sets the LTV limits for future loans; existing loans keep theirs.
    /// @dev Reverts RiskParamsOutOfBounds unless 1000 <= maxLtvBps < liqLtvBps <= 9000 and liqLtvBps is below
    ///      auctionFloorBps. Emits RiskParamsSet.
    /// @param newMaxLtvBps Borrow limit for new loans.
    /// @param newLiqLtvBps Liquidation line for new loans.
    function setRiskParams(uint16 newMaxLtvBps, uint16 newLiqLtvBps) external;

    /// @notice Owner only. Sets the penalty, floor and duration for future auctions; running auctions keep
    ///         theirs.
    /// @dev Reverts AuctionParamsOutOfBounds unless penaltyBps <= 1000, 5000 <= auctionFloorBps <= 9500 with
    ///      auctionFloorBps above liqLtvBps, and 1 hour <= auctionDuration <= 7 days. Emits AuctionParamsSet.
    /// @param newPenaltyBps Penalty for new auctions.
    /// @param newAuctionFloorBps Floor share for new auctions.
    /// @param newAuctionDuration Duration for new auctions.
    function setAuctionParams(uint16 newPenaltyBps, uint16 newAuctionFloorBps, uint32 newAuctionDuration) external;

    /// @notice Owner only. Sets the minimum loan. Reverts MinLoanOutOfBounds outside 1 to 100,000 MUSD.
    ///         Emits MinLoanSet.
    /// @param newMinLoan Minimum principal in MUSD wei.
    function setMinLoan(uint128 newMinLoan) external;

    /// @notice Owner only. Sets the guardian. Reverts ZeroAddress. Emits GuardianSet.
    /// @param newGuardian New guardian.
    function setGuardian(address newGuardian) external;

    /// @notice Guardian or owner. Pauses or resumes new borrows and lock creation (borrow, lockAndDeposit,
    ///         lockAndBorrow) only; roll, repay, withdrawCollateral, every auction and settle step, writeOff,
    ///         claim and every pass-through are never paused. Reverts NotGuardianOrOwner. Emits
    ///         BorrowsPausedSet.
    /// @param paused True to pause.
    function setBorrowsPaused(bool paused) external;
}
