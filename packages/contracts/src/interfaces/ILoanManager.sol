// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVeBTC} from "./IVeBTC.sol";
import {IPriceFeed} from "./IPriceFeed.sol";
import {ICreditMarkets} from "./ICreditMarkets.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ILoanManager
/// @notice Holds veBTC positions as collateral and opens fixed-term MUSD loans against them from
///         CreditMarkets offers.
interface ILoanManager {
    /// @dev Auction is reached from milestone 2 on. A closed loan is deleted, so it reads back as None.
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
    /// @dev Pulls min(amount, owed) from the caller and credits the loan's market. The payment that clears
    ///      the debt closes and deletes the loan in the same call. Paying early still costs the full face.
    ///      Reverts NoActiveLoan, ZeroAmount or TransferShortfall. Emits Repaid, and LoanClosed on the last
    ///      payment.
    /// @param tokenId Position whose loan to pay.
    /// @param amount Most MUSD to pay.
    /// @return paid MUSD actually paid.
    function repay(uint256 tokenId, uint256 amount) external returns (uint256 paid);

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

    /// @notice The lock behind a position, decoded for this chain's veBTC layout.
    /// @dev Reverts LockReadFailed or BadLockAmount.
    function lockOf(uint256 tokenId) external view returns (uint256 amount, uint256 end, bool isPermanent);

    /// @notice The veBTC contract, fixed at deployment.
    function veBTC() external view returns (IVeBTC);

    /// @notice The BTC price feed, fixed at deployment.
    function priceFeed() external view returns (IPriceFeed);

    /// @notice The MUSD token, fixed at deployment.
    function musd() external view returns (IERC20);

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

    /// @notice Address that may pause new borrows alongside the owner.
    function guardian() external view returns (address);

    /// @notice True while new borrows are paused.
    function borrowsPaused() external view returns (bool);

    /// @notice Owner only. Sets the LTV limits for future loans; existing loans keep theirs.
    /// @dev Reverts RiskParamsOutOfBounds unless 1000 <= maxLtvBps < liqLtvBps <= 9000. Emits RiskParamsSet.
    function setRiskParams(uint16 newMaxLtvBps, uint16 newLiqLtvBps) external;

    /// @notice Owner only. Sets the minimum loan. Reverts MinLoanOutOfBounds outside 1 to 100,000 MUSD.
    /// Emits MinLoanSet.
    function setMinLoan(uint128 newMinLoan) external;

    /// @notice Owner only. Sets the guardian. Reverts ZeroAddress. Emits GuardianSet.
    function setGuardian(address newGuardian) external;

    /// @notice Guardian or owner. Pauses or resumes borrow only; repay and withdrawCollateral are never
    /// paused. Reverts NotGuardianOrOwner. Emits BorrowsPausedSet.
    function setBorrowsPaused(bool paused) external;
}
