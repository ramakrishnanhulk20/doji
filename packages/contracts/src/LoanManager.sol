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
import {LockReader} from "./libraries/LockReader.sol";

/// @title LoanManager
/// @notice Takes custody of veBTC positions and opens one fixed-term MUSD loan per position from
///         CreditMarkets offers. The borrower repays the fixed face by the maturity and takes the position back.
/// @dev Deliberately has no receive(), no onERC721Received, no payable function, no generic call and no
///      approval on veBTC. A position can only become collateral through deposit(), which pulls it from the
///      caller, so a token pushed in any other way never gets a borrower.
contract LoanManager is ILoanManager, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint16 public constant MIN_MAX_LTV_BPS = 1_000;
    uint16 public constant MAX_LIQ_LTV_BPS = 9_000;
    uint128 public constant MIN_LOAN_FLOOR = 1e18;
    uint128 public constant MIN_LOAN_CEILING = 100_000e18;
    uint8 public constant ESCROW_NORMAL = 0;
    uint256 private constant BPS = 10_000;
    uint256 private constant PRICE_SCALE = 1e18;

    IVeBTC public immutable veBTC;
    IPriceFeed public immutable priceFeed;
    IERC20 public immutable musd;
    ICreditMarkets public immutable creditMarkets;
    uint256 public immutable lockLayoutWords;

    address public guardian;
    uint16 public maxLtvBps;
    uint16 public liqLtvBps;
    uint128 public minLoan;
    bool public borrowsPaused;

    mapping(uint256 tokenId => Position) private _positions;
    mapping(uint256 tokenId => Loan) private _loans;

    /// @notice Wires LoanManager to fixed Mezo contracts and to the CreditMarkets deployed for it.
    /// @dev Reverts ZeroAddress, BadLockLayout (not 3 or 4), CreditMarketsMismatch unless CreditMarkets already
    ///      names this contract as its LoanManager, MusdMismatch, OwnableInvalidOwner, or a bound error.
    ///      Gives CreditMarkets an unlimited MUSD allowance, the only approval this contract ever grants.
    constructor(
        address veBTC_,
        address priceFeed_,
        address musd_,
        address creditMarkets_,
        uint256 lockLayoutWords_,
        address owner_,
        address guardian_,
        uint16 maxLtvBps_,
        uint16 liqLtvBps_,
        uint128 minLoan_
    ) Ownable(owner_) {
        if (veBTC_ == address(0) || priceFeed_ == address(0) || musd_ == address(0) || creditMarkets_ == address(0)) {
            revert ZeroAddress();
        }
        if (lockLayoutWords_ != 3 && lockLayoutWords_ != 4) revert BadLockLayout(lockLayoutWords_);
        if (ICreditMarkets(creditMarkets_).loanManager() != address(this)) revert CreditMarketsMismatch();
        if (ICreditMarkets(creditMarkets_).musd() != musd_) revert MusdMismatch();

        veBTC = IVeBTC(veBTC_);
        priceFeed = IPriceFeed(priceFeed_);
        musd = IERC20(musd_);
        creditMarkets = ICreditMarkets(creditMarkets_);
        lockLayoutWords = lockLayoutWords_;

        _setGuardian(guardian_);
        _setRiskParams(maxLtvBps_, liqLtvBps_);
        _setMinLoan(minLoan_);

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
    function borrow(
        uint256 tokenId,
        uint64 maturity,
        uint256[] calldata offerIds,
        uint128[] calldata amounts,
        uint16 maxAprBps
    ) external nonReentrant returns (uint256 principal, uint256 face) {
        return _borrow(tokenId, maturity, offerIds, amounts, maxAprBps);
    }

    /// @inheritdoc ILoanManager
    function repay(uint256 tokenId, uint256 amount) external nonReentrant returns (uint256 paid) {
        Loan storage loan = _loans[tokenId];
        if (loan.state != LoanState.Active) revert NoActiveLoan(tokenId);
        if (amount == 0) revert ZeroAmount();

        uint64 maturity = loan.maturity;
        uint256 face = loan.face;
        uint256 owed = face - loan.repaid;
        paid = amount < owed ? amount : owed;
        uint256 owedAfter = owed - paid;
        bool closes = owedAfter == 0;

        if (closes) delete _loans[tokenId];
        else loan.repaid = (face - owedAfter).toUint128();
        emit Repaid(tokenId, msg.sender, paid, owedAfter);
        if (closes) emit LoanClosed(tokenId, maturity);

        uint256 before = musd.balanceOf(address(this));
        musd.safeTransferFrom(msg.sender, address(this), paid);
        uint256 received = musd.balanceOf(address(this)) - before;
        if (received != paid) revert TransferShortfall(paid, received);
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
    function lockOf(uint256 tokenId) external view returns (uint256 amount, uint256 end, bool isPermanent) {
        return LockReader.read(address(veBTC), tokenId, lockLayoutWords);
    }

    /// @inheritdoc ILoanManager
    function setRiskParams(uint16 newMaxLtvBps, uint16 newLiqLtvBps) external onlyOwner {
        _setRiskParams(newMaxLtvBps, newLiqLtvBps);
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

    /// @dev The one borrow path (C8). Roll in milestone 2 must come through here too. The face is only known
    ///      once CreditMarkets prices the fill, so the loan is written after that call. CreditMarkets is fixed
    ///      at deployment, its only outside call is the MUSD transfer to the borrower, and both contracts hold
    ///      their reentrancy locks throughout. Borrowed records the loan write. Maturities are a week apart, so
    ///      timestamp drift does not matter.
    // forge-lint: disable-next-item(reentrancy-no-eth,reentrancy-events,missing-events-access-control,block-timestamp)
    function _borrow(
        uint256 tokenId,
        uint64 maturity,
        uint256[] calldata offerIds,
        uint128[] calldata amounts,
        uint16 maxAprBps
    ) private returns (uint256 principal, uint256 face) {
        if (borrowsPaused) revert BorrowsPaused();
        _requireBorrower(tokenId);
        if (_loans[tokenId].state != LoanState.None) revert LoanOpen(tokenId);
        if (veBTC.ownerOf(tokenId) != address(this)) revert NotInCustody(tokenId);
        _requireAcceptedCollateral(tokenId);
        if (!creditMarkets.isValidMaturity(maturity)) revert InvalidMaturity(maturity);

        (, uint256 lockEnd, bool isPermanent, uint256 usdValue) = _collateral(tokenId);
        if (isPermanent) {
            if (maturity > block.timestamp + creditMarkets.maxTermSeconds()) revert MaturityBeyondMaxTerm(maturity);
        } else if (maturity > lockEnd) {
            revert MaturityAfterLockEnd(maturity, lockEnd);
        }

        (principal, face) = creditMarkets.fill(maturity, offerIds, amounts, maxAprBps, msg.sender);
        if (principal < minLoan) revert BelowMinLoan(principal, minLoan);
        uint256 maxFace = Math.mulDiv(usdValue, maxLtvBps, BPS);
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

    /// @dev One positive test (C2): ordinary escrow and nobody who can revoke it. Any escrow type Mezo adds
    ///      later is refused because it is not NORMAL. It does not cover a new transfer path a veBTC upgrade adds.
    function _requireAcceptedCollateral(uint256 tokenId) private view {
        if (veBTC.escrowType(tokenId) != ESCROW_NORMAL || veBTC.grantManager(tokenId) != address(0)) {
            revert CollateralNotAccepted(tokenId);
        }
    }

    function _setRiskParams(uint16 newMaxLtvBps, uint16 newLiqLtvBps) private {
        if (newMaxLtvBps < MIN_MAX_LTV_BPS || newMaxLtvBps >= newLiqLtvBps || newLiqLtvBps > MAX_LIQ_LTV_BPS) {
            revert RiskParamsOutOfBounds(newMaxLtvBps, newLiqLtvBps);
        }
        maxLtvBps = newMaxLtvBps;
        liqLtvBps = newLiqLtvBps;
        emit RiskParamsSet(newMaxLtvBps, newLiqLtvBps);
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
