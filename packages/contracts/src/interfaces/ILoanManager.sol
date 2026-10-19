// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVeBTC} from "./IVeBTC.sol";
import {IPriceFeed} from "./IPriceFeed.sol";
import {ICreditMarkets} from "./ICreditMarkets.sol";
import {IPoolsVoter} from "./IPoolsVoter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ILoanManager
/// @notice Holds veBTC positions as collateral and opens fixed-term MUSD loans against them from
///         CreditMarkets offers.
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

    /// @dev Starting owner, guardian and owner-settable parameters, passed to the constructor as one argument
    ///      because that many separate constructor arguments overflow the compiler's stack. Later changes go
    ///      through the setters and two-step ownership transfer.
    struct Settings {
        address owner;
        address guardian;
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

    event Deposited(uint256 indexed tokenId, address indexed borrower);
    event Borrowed(
        uint256 indexed tokenId, address indexed borrower, uint64 indexed maturity, uint256 principal, uint256 face
    );
    event Repaid(uint256 indexed tokenId, address indexed payer, uint256 amount, uint256 owedAfter);
    event LoanClosed(uint256 indexed tokenId, uint64 indexed maturity);
    event Withdrawn(uint256 indexed tokenId, address indexed borrower);
    event RiskParamsSet(uint16 maxLtvBps, uint16 liqLtvBps);
    event MinLoanSet(uint128 minLoan);
    event GuardianSet(address guardian);
    event BorrowsPausedSet(bool paused);
    event AuctionParamsSet(uint16 penaltyBps, uint16 auctionFloorBps, uint32 auctionDuration);
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
    event AuctionCancelled(uint256 indexed tokenId, uint256 owed, uint256 usdValue);
    event Purchased(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed borrower,
        uint256 price,
        uint256 toMarket,
        uint256 toTreasury,
        uint256 toBorrower
    );
    event SettlePrepared(uint256 indexed tokenId, bool voteReset, bool permanentUnlocked);
    event Settled(
        uint256 indexed tokenId,
        address indexed borrower,
        uint256 btcReceived,
        uint256 btcPrice,
        uint256 toMarket,
        uint256 toTreasury,
        uint256 toBorrower
    );
    event WrittenOff(uint256 indexed tokenId, uint64 indexed maturity, uint256 owed);
    event Rolled(
        uint256 indexed tokenId,
        uint64 indexed oldMaturity,
        uint64 indexed newMaturity,
        uint256 oldOwed,
        uint256 excessPaid,
        uint256 topUp
    );
    event Claimed(address indexed account, uint256 musdAmount, uint256 btcAmount);

    error ZeroAddress();
    error ZeroAmount();
    error BadLockLayout(uint256 layoutWords);
    error CreditMarketsMismatch();
    error MusdMismatch();
    error NotTokenOwner(uint256 tokenId);
    error CollateralNotAccepted(uint256 tokenId);
    error PositionExists(uint256 tokenId);
    error CustodyCheckFailed(uint256 tokenId);
    error NotBorrower(uint256 tokenId);
    error LoanOpen(uint256 tokenId);
    error NoActiveLoan(uint256 tokenId);
    error NotInCustody(uint256 tokenId);
    error BorrowsPaused();
    error InvalidMaturity(uint64 maturity);
    error MaturityAfterLockEnd(uint64 maturity, uint256 lockEnd);
    error MaturityBeyondMaxTerm(uint64 maturity);
    error BelowMinLoan(uint256 principal, uint256 minLoan);
    error LtvTooHigh(uint256 face, uint256 maxFace);
    error PriceUnavailable();
    error TransferShortfall(uint256 expected, uint256 received);
    error NotGuardianOrOwner();
    error RiskParamsOutOfBounds(uint16 maxLtvBps, uint16 liqLtvBps);
    error MinLoanOutOfBounds(uint128 minLoan);
    error BtcMismatch();
    error AuctionParamsOutOfBounds(uint16 penaltyBps, uint16 auctionFloorBps, uint32 auctionDuration);
    error LoanNotActive(uint256 tokenId);
    error NoAuction(uint256 tokenId);
    error NotLiquidatable(uint256 tokenId);
    error LoanOverdue(uint256 tokenId);
    error StillUnsafe(uint256 tokenId);
    error StillSafe(uint256 tokenId);
    error DeadlinePassed(uint256 deadline);
    error PriceAboveMax(uint256 price, uint256 maxPay);
    error FloorTimeNotReached(uint256 tokenId, uint256 floorTime);
    error NothingToPrepare(uint256 tokenId);
    error LockIsPermanent(uint256 tokenId);
    error LockNotEnded(uint256 tokenId, uint256 lockEnd);
    error StillVoted(uint256 tokenId);
    error StillInCustody(uint256 tokenId);
    error MaturityNotLater(uint64 oldMaturity, uint64 newMaturity);
    error TopUpTooHigh(uint256 topUp, uint256 maxTopUp);
    error NothingToClaim(address account);

    /// @notice Hands a veBTC position to LoanManager and records the caller as its borrower.
    /// @dev The caller must own the position and approve this contract for that single token first.
    ///      Only NORMAL escrow positions with no grant manager are accepted. LoanManager pulls the token with
    ///      transferFrom and confirms it now owns it. Reverts NotTokenOwner (also for a missing token),
    ///      CollateralNotAccepted, PositionExists or CustodyCheckFailed. Emits Deposited.
    /// @param tokenId veBTC position id.
    function deposit(uint256 tokenId) external;

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
    function auctionPrice(uint256 tokenId) external view returns (uint256);

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

    /// @notice Readies an unsold auctioned position for settle: clears a standing gauge vote and turns a
    ///         permanent lock into a normal one. Anyone may call.
    /// @dev Needs the loan in Auction, the floor time reached and the position in custody. Calls
    ///      PoolsVoter.reset when the position is voted, whose own revert (same epoch as the last vote, or
    ///      the first hour of an epoch) surfaces unchanged, then veBTC.unlockPermanent when the lock is
    ///      permanent. Never paused. Reverts NoAuction, FloorTimeNotReached, NotInCustody or
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

    /// @notice The one collateral value used for borrowing and shown to users: locked BTC times the
    ///         live BTC price. Voting power is never used.
    /// @dev Reverts LockReadFailed or BadLockAmount from LockReader, or PriceUnavailable.
    /// @return btcAmount Locked BTC in wei.
    /// @return usdValue Value in MUSD wei at the current price.
    function collateralValue(uint256 tokenId) external view returns (uint256 btcAmount, uint256 usdValue);

    /// @notice MUSD still owed on a position's loan, zero when there is no loan.
    function owedOf(uint256 tokenId) external view returns (uint256);

    /// @notice A position's recorded borrower. A zero borrower means LoanManager holds no position for it.
    function positionOf(uint256 tokenId) external view returns (Position memory);

    /// @notice A position's loan record. State None means no open loan.
    function loanOf(uint256 tokenId) external view returns (Loan memory);

    /// @notice A loan's running auction. A zero startTime means no auction.
    function auctionOf(uint256 tokenId) external view returns (Auction memory);

    /// @notice True when the position has an open loan whose maturity has passed.
    function isOverdue(uint256 tokenId) external view returns (bool);

    /// @notice True when the position has an open loan with owed > value * the loan's liqLtvBps / 10,000.
    /// @dev Reverts PriceUnavailable or a LockReader error, like borrow, when the loan is open.
    function isUnsafe(uint256 tokenId) external view returns (bool);

    /// @notice MUSD from auction surpluses waiting for `account` to claim.
    function claimableMusd(address account) external view returns (uint256);

    /// @notice BTC from settle leftovers waiting for `account` to claim.
    function claimableBtc(address account) external view returns (uint256);

    /// @notice Sum of every account's claimableMusd.
    function totalClaimableMusd() external view returns (uint256);

    /// @notice Sum of every account's claimableBtc.
    function totalClaimableBtc() external view returns (uint256);

    /// @notice The lock behind a position, decoded for this chain's veBTC layout.
    /// @dev Reverts LockReadFailed or BadLockAmount.
    function lockOf(uint256 tokenId) external view returns (uint256 amount, uint256 end, bool isPermanent);

    /// @notice The veBTC contract, fixed at deployment.
    function veBTC() external view returns (IVeBTC);

    /// @notice The BTC price feed, fixed at deployment.
    function priceFeed() external view returns (IPriceFeed);

    /// @notice The MUSD token, fixed at deployment.
    function musd() external view returns (IERC20);

    /// @notice The BTC ERC-20 view that veBTC.withdraw pays in, fixed at deployment.
    function btc() external view returns (IERC20);

    /// @notice Mezo's PoolsVoter, the only voter prepareSettle resets, fixed at deployment.
    function poolsVoter() external view returns (IPoolsVoter);

    /// @notice The CreditMarkets contract, fixed at deployment.
    function creditMarkets() external view returns (ICreditMarkets);

    /// @notice Number of 32-byte words veBTC's locked() returns on this chain: 3 on testnet, 4 on mainnet.
    function lockLayoutWords() external view returns (uint256);

    /// @notice Highest face-to-value ratio a new loan may open at, in basis points.
    function maxLtvBps() external view returns (uint16);

    /// @notice Ratio at which a loan becomes unsafe, in basis points. Snapshotted per loan.
    function liqLtvBps() external view returns (uint16);

    /// @notice Smallest principal a loan may have, in MUSD wei.
    function minLoan() external view returns (uint128);

    /// @notice Penalty on the debt paid to the treasury from an auction or settle, in basis points.
    ///         Snapshotted per auction.
    function penaltyBps() external view returns (uint16);

    /// @notice Lowest the auction price falls to, as a share of the start value, in basis points. The
    ///         floor is never below min(owed, start value). Snapshotted per auction.
    function auctionFloorBps() external view returns (uint16);

    /// @notice Seconds the auction price takes to fall to its floor. Snapshotted per auction.
    function auctionDuration() external view returns (uint32);

    /// @notice Address that may pause new borrows alongside the owner.
    function guardian() external view returns (address);

    /// @notice True while new borrows are paused.
    function borrowsPaused() external view returns (bool);

    /// @notice Owner only. Sets the LTV limits for future loans; existing loans keep theirs.
    /// @dev Reverts RiskParamsOutOfBounds unless 1000 <= maxLtvBps < liqLtvBps <= 9000 and liqLtvBps is below
    ///      auctionFloorBps. Emits RiskParamsSet.
    function setRiskParams(uint16 newMaxLtvBps, uint16 newLiqLtvBps) external;

    /// @notice Owner only. Sets the penalty, floor and duration for future auctions; running auctions keep
    ///         theirs.
    /// @dev Reverts AuctionParamsOutOfBounds unless penaltyBps <= 1000, 5000 <= auctionFloorBps <= 9500 with
    ///      auctionFloorBps above liqLtvBps, and 1 hour <= auctionDuration <= 7 days. Emits AuctionParamsSet.
    function setAuctionParams(uint16 newPenaltyBps, uint16 newAuctionFloorBps, uint32 newAuctionDuration) external;

    /// @notice Owner only. Sets the minimum loan. Reverts MinLoanOutOfBounds outside 1 to 100,000 MUSD.
    /// Emits MinLoanSet.
    function setMinLoan(uint128 newMinLoan) external;

    /// @notice Owner only. Sets the guardian. Reverts ZeroAddress. Emits GuardianSet.
    function setGuardian(address newGuardian) external;

    /// @notice Guardian or owner. Pauses or resumes borrow only; roll, repay, withdrawCollateral, every
    /// auction and settle step, writeOff and claim are never paused. Reverts NotGuardianOrOwner. Emits
    /// BorrowsPausedSet.
    function setBorrowsPaused(bool paused) external;
}
