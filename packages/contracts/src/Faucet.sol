// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IFaucet} from "./interfaces/IFaucet.sol";

/// @title Faucet
/// @notice Pays one starter kit of test BTC and test MUSD to a new wallet, once ever, when Doji's relayer asks.
///         Claims are released evenly through each UTC day, so a sweep at midnight gets one kit, not the day.
/// @dev Native BTC is Mezo's gas token and the BTC ERC-20 is a view of the same coins, so this contract reads BTC one
///      way, address(this).balance, and never holds the ERC-20's address (C58). The faucet owes nobody: BTC or MUSD
///      sent in is funding, and no balance is tracked per person. Nothing else in Doji reads this contract.
contract Faucet is IFaucet, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Ten times the planned 0.001 BTC kit, which is gas plus a small lock. The cap stops a slipped digit in
    ///      setKit from handing one tester the whole balance.
    uint128 public constant MAX_BTC_PER_CLAIM = 0.01e18;
    /// @dev Four times the planned 25 MUSD kit and ten times Doji's 10 MUSD smallest offer and loan, for the same
    ///      slipped-digit reason.
    uint128 public constant MAX_MUSD_PER_CLAIM = 100e18;
    /// @dev One claim every 173 seconds. With the two caps above, a stolen relayer key reaches at most 5 BTC and
    ///      50,000 MUSD a day until the owner replaces it (C65), far beyond what a test faucet ever holds.
    uint32 public constant MAX_DAILY_LIMIT = 500;
    /// @dev A Safe-style proxy wallet's receive needs 4,004 gas on top of the EVM's 2,300 stipend (measured cold in
    ///      test/unit/Faucet.t.sol), so 50,000 leaves room for a much heavier wallet. It stays this small because it
    ///      is the most a hostile recipient can cost the relayer (C55).
    uint256 public constant RECIPIENT_GAS = 50_000;

    IERC20 public immutable musd;

    address public relayer;
    uint32 public dailyLimit;
    uint128 public btcPerClaim;
    uint128 public musdPerClaim;
    mapping(address account => bool) public claimed;
    mapping(uint256 day => uint256) public claimsOnDay;

    modifier onlyRelayer() {
        _checkRelayer();
        _;
    }

    /// @notice Fixes MUSD for the life of the contract and sets the first owner, relayer, kit and daily limit.
    /// @dev Reverts ZeroAddress for a zero MUSD, owner or relayer, KitEmpty, KitTooLarge or LimitTooHigh. Emits
    ///      RelayerSet, KitSet and DailyLimitSet.
    /// @param musd_ The MUSD token.
    /// @param owner_ Starting owner.
    /// @param relayer_ Starting relayer.
    /// @param btcPerClaim_ Native BTC per claim.
    /// @param musdPerClaim_ MUSD per claim.
    /// @param dailyLimit_ Claims each UTC day releases.
    constructor(
        address musd_,
        address owner_,
        address relayer_,
        uint128 btcPerClaim_,
        uint128 musdPerClaim_,
        uint32 dailyLimit_
    ) Ownable(_nonZero(owner_)) {
        musd = IERC20(_nonZero(musd_));
        _setRelayer(relayer_);
        _setKit(btcPerClaim_, musdPerClaim_);
        _setDailyLimit(dailyLimit_);
    }

    /// @notice Accepts native BTC as funding, credited to nobody.
    receive() external payable {}

    /// @inheritdoc IFaucet
    function claim(address to) external nonReentrant onlyRelayer whenNotPaused {
        if (to == address(0) || to == address(this)) revert BadRecipient(to);
        if (claimed[to]) revert AlreadyClaimed(to);
        if (claimsOpen() == 0) revert NoClaimOpen(nextOpenAt());

        (uint256 day,,) = _release(block.timestamp, dailyLimit);
        uint256 btc = btcPerClaim;
        uint256 musdAmount = musdPerClaim;
        claimed[to] = true;
        claimsOnDay[day] += 1;
        // The only call so far is the read-only MUSD balance, a staticcall that can change nothing.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Claimed(to, btc, musdAmount, day);

        musd.safeTransfer(to, musdAmount);
        _payBtc(to, btc);
    }

    /// @inheritdoc IFaucet
    function setKit(uint128 btc, uint128 musdAmount) external onlyOwner {
        _setKit(btc, musdAmount);
    }

    /// @inheritdoc IFaucet
    function setDailyLimit(uint32 newDailyLimit) external onlyOwner {
        _setDailyLimit(newDailyLimit);
    }

    /// @inheritdoc IFaucet
    function setRelayer(address newRelayer) external onlyOwner {
        _setRelayer(newRelayer);
    }

    /// @inheritdoc IFaucet
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc IFaucet
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @inheritdoc IFaucet
    function withdraw(uint256 btc, uint256 musdAmount) external nonReentrant onlyOwner {
        address to = owner();
        emit Withdrawn(to, btc, musdAmount);
        if (musdAmount != 0) musd.safeTransfer(to, musdAmount);
        if (btc != 0) Address.sendValue(payable(to), btc);
    }

    /// @inheritdoc IFaucet
    function rescueToken(address token, uint256 amount) external nonReentrant onlyOwner {
        if (token == address(musd)) revert TokenNotRescuable(token);
        address to = owner();
        emit Rescued(token, to, amount);
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Always reverts: ownership can never be given up, so the funding can always be reached and a stolen
    ///         relayer key replaced. Ownership still moves by the two-step transfer.
    /// @dev Reverts RenounceDisabled for every caller.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @inheritdoc IFaucet
    function claimsToday() external view returns (uint256) {
        (uint256 day,,) = _release(block.timestamp, dailyLimit);
        return claimsOnDay[day];
    }

    /// @inheritdoc IFaucet
    function claimsOpen() public view returns (uint256) {
        if (paused()) return 0;
        (uint256 day,, uint256 released) = _release(block.timestamp, dailyLimit);
        uint256 count = claimsOnDay[day];
        if (count >= released) return 0;
        return Math.min(released - count, _kitsHeld());
    }

    /// @inheritdoc IFaucet
    function nextOpenAt() public view returns (uint256) {
        uint256 limit = dailyLimit;
        if (paused() || limit == 0 || _kitsHeld() == 0) return 0;
        (uint256 day, uint256 elapsed, uint256 released) = _release(block.timestamp, limit);
        uint256 count = claimsOnDay[day];
        if (count < released) return block.timestamp;
        uint256 dayStart = block.timestamp - elapsed;
        if (count >= limit) return dayStart + 1 days;
        // The first second at which limit * elapsed / 1 days reaches count, the inverse of _release.
        return dayStart + Math.ceilDiv(count * 1 days, limit);
    }

    /// @inheritdoc IFaucet
    function paused() public view override(IFaucet, Pausable) returns (bool) {
        return super.paused();
    }

    /// @dev C56 and C57: the one place block time becomes a day and a release count, used by claim and every view,
    ///      so the two can never disagree about a day's edge. Plus one so a claim is open at 00:00:00, and the
    ///      rounded-down share reaches limit - 1 in the day's last second, which makes the whole limit by then.
    function _release(uint256 time, uint256 limit)
        private
        pure
        returns (uint256 day, uint256 elapsed, uint256 released)
    {
        day = time / 1 days;
        elapsed = time % 1 days;
        released = limit == 0 ? 0 : Math.min(limit, limit * elapsed / 1 days + 1);
    }

    /// @dev Whole kits the faucet can pay. The kit amounts are never zero: _setKit refuses it, also in the constructor.
    function _kitsHeld() private view returns (uint256) {
        return Math.min(address(this).balance / btcPerClaim, _musdHeld() / musdPerClaim);
    }

    /// @dev C56: a plain balanceOf call would revert the views if MUSD ever answered badly, so a failed or malformed
    ///      answer counts as nothing held, and claim then refuses with NoClaimOpen.
    function _musdHeld() private view returns (uint256) {
        (bool ok, bytes memory raw) = address(musd).staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        return ok && raw.length == 32 ? abi.decode(raw, (uint256)) : 0;
    }

    /// @dev C55: Solidity's call would copy whatever the recipient returns into this frame at the caller's cost, so
    ///      this is assembly with no output area. There is no is-it-a-contract check: it would block smart wallets
    ///      and miss contracts not deployed yet. The gas allowance is the safeguard. The EVM adds its 2,300 gas
    ///      stipend to any call that carries value. A relayer that sends too little gas forwards less than the
    ///      allowance, and a recipient that then runs short reverts the whole claim, so short gas never spends a kit.
    function _payBtc(address to, uint256 amount) private {
        bool ok;
        assembly ("memory-safe") {
            ok := call(RECIPIENT_GAS, to, amount, 0, 0, 0, 0)
        }
        if (!ok) revert BtcPaymentFailed(to);
    }

    function _setKit(uint128 btc, uint128 musdAmount) private {
        if (btc == 0 || musdAmount == 0) revert KitEmpty();
        if (btc > MAX_BTC_PER_CLAIM || musdAmount > MAX_MUSD_PER_CLAIM) revert KitTooLarge();
        btcPerClaim = btc;
        musdPerClaim = musdAmount;
        emit KitSet(btc, musdAmount);
    }

    function _setDailyLimit(uint32 newDailyLimit) private {
        if (newDailyLimit > MAX_DAILY_LIMIT) revert LimitTooHigh();
        dailyLimit = newDailyLimit;
        emit DailyLimitSet(newDailyLimit);
    }

    function _setRelayer(address newRelayer) private {
        relayer = _nonZero(newRelayer);
        emit RelayerSet(newRelayer);
    }

    function _checkRelayer() private view {
        if (msg.sender != relayer) revert NotRelayer();
    }

    function _nonZero(address account) private pure returns (address) {
        if (account == address(0)) revert ZeroAddress();
        return account;
    }
}
