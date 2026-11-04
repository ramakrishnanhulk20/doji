// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Stands in for Mezo's MUSDSavingsRate as verified on 2026-11-03 (reference/briefs/smusd-brief.md
///         section 4): sMUSD is minted and burned 1:1 with MUSD, yield is a running per-sMUSD index, and withdraw
///         pays the amount plus everything the caller has accrued. Unlike the real vault it holds the MUSD itself
///         instead of passing it to a strategy, and has no PCV or gauge hooks. Switches make it misbehave the way
///         an upgraded vault could: pay short, mint short, refuse deposits, withdrawals, claims or index reads,
///         pay out accrued yield during a deposit, or report a yieldIndex that differs from the index it actually
///         pays from.
contract MockSavingsVault is ERC20 {
    using SafeERC20 for IERC20;

    uint256 internal constant INDEX_SCALE = 1e18;

    error ZeroAmount();
    error InsufficientBalance();
    error AmountTooSmall();
    error NoSupply();
    error DepositRefused();
    error WithdrawRefused();
    error ClaimRefused();
    error IndexRefused();

    address public immutable musdToken;
    /// @dev The index payments really follow. yieldIndex() reports it unless a reported index is set.
    uint256 public accrualIndex;
    mapping(address account => uint256) public supplyYieldIndex;
    mapping(address account => uint256) public claimableYield;

    uint256 public shortPay;
    uint256 public mintShortfall;
    bool public depositsRefused;
    bool public withdrawalsRefused;
    bool public claimsRefused;
    bool public indexRefused;
    bool public indexReported;
    uint256 public reportedIndex;
    bool public paysOnDeposit;

    constructor(address musd_) ERC20("MUSD Savings Rate", "sMUSD") {
        musdToken = musd_;
    }

    function shortPayBy(uint256 amount) external {
        shortPay = amount;
    }

    function mintLessBy(uint256 amount) external {
        mintShortfall = amount;
    }

    function revertOnDeposit(bool refused) external {
        depositsRefused = refused;
    }

    function revertOnWithdraw(bool refused) external {
        withdrawalsRefused = refused;
    }

    function revertOnClaim(bool refused) external {
        claimsRefused = refused;
    }

    function revertOnIndex(bool refused) external {
        indexRefused = refused;
    }

    function payYieldOnDeposit(bool pays) external {
        paysOnDeposit = pays;
    }

    /// @notice From now on yieldIndex() reports `value`, while every payment still follows accrualIndex: a vault
    ///         whose index jumped or fell without the MUSD to match.
    function reportIndex(uint256 value) external {
        indexReported = true;
        reportedIndex = value;
    }

    function stopReportingIndex() external {
        indexReported = false;
    }

    function yieldIndex() external view returns (uint256) {
        if (indexRefused) revert IndexRefused();
        return indexReported ? reportedIndex : accrualIndex;
    }

    function deposit(uint256 amount) external {
        if (depositsRefused) revert DepositRefused();
        if (amount == 0) revert ZeroAmount();
        if (paysOnDeposit) _payYield(msg.sender);
        IERC20(musdToken).safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount - mintShortfall);
    }

    function withdraw(uint256 amount) external {
        if (withdrawalsRefused) revert WithdrawRefused();
        if (amount == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();
        _payYield(msg.sender);
        _burn(msg.sender, amount);
        IERC20(musdToken).safeTransfer(msg.sender, amount - shortPay);
    }

    function claimYield() external returns (uint256) {
        if (claimsRefused) revert ClaimRefused();
        return _payYield(msg.sender);
    }

    /// @notice Spreads `amount` MUSD pulled from the caller over every sMUSD outstanding, as PCV's payments do.
    function receiveProtocolYield(uint256 amount) external {
        uint256 supply = totalSupply();
        if (supply == 0) revert NoSupply();
        uint256 step = amount * INDEX_SCALE / supply;
        if (step == 0) revert AmountTooSmall();
        IERC20(musdToken).safeTransferFrom(msg.sender, address(this), amount);
        accrualIndex += step;
    }

    /// @notice What withdraw or claimYield would pay `account` in yield right now.
    function accruedYield(address account) public view returns (uint256) {
        return claimableYield[account] + balanceOf(account) * (accrualIndex - supplyYieldIndex[account]) / INDEX_SCALE;
    }

    function _payYield(address account) internal returns (uint256 paid) {
        _book(account);
        paid = claimableYield[account];
        if (paid == 0) return 0;
        claimableYield[account] = 0;
        IERC20(musdToken).safeTransfer(account, paid);
    }

    function _book(address account) internal {
        claimableYield[account] = accruedYield(account);
        supplyYieldIndex[account] = accrualIndex;
    }

    /// @dev Books both sides at their old balance before it changes, so yield stays with whoever held the sMUSD.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) _book(from);
        if (to != address(0)) _book(to);
        super._update(from, to, value);
    }
}
