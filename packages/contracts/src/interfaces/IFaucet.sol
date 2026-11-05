// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IFaucet
/// @notice Gives a brand-new wallet one starter kit of test BTC and test MUSD, once ever. Only Doji's relayer can
///         call claim, so a tester needs no gas to get their first gas. Claims are released evenly through each UTC
///         day and unused ones carry over within that day, so no burst at midnight can take the whole day. Testnet
///         only: everything the faucet holds is funding, owed to nobody.
interface IFaucet {
    /// @notice `to` received one kit: `btc` native BTC and `musd` MUSD, on UTC day `day`.
    event Claimed(address indexed to, uint256 btc, uint256 musd, uint256 indexed day);
    /// @notice Claims from now on pay `btc` native BTC and `musd` MUSD.
    event KitSet(uint128 btc, uint128 musd);
    /// @notice Each UTC day from now on releases this many claims.
    event DailyLimitSet(uint32 dailyLimit);
    /// @notice The one address allowed to call claim changed.
    event RelayerSet(address indexed relayer);
    /// @notice The owner took `btc` native BTC and `musd` MUSD out of the faucet.
    event Withdrawn(address indexed to, uint256 btc, uint256 musd);
    /// @notice The owner took out a stray `token` that is not MUSD.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Only the relayer may call claim.
    error NotRelayer();
    /// @notice An address given to the constructor or setRelayer was zero.
    error ZeroAddress();
    /// @notice A claim's receiver is the zero address or the faucet itself.
    error BadRecipient(address to);
    /// @notice This address already took its one kit.
    error AlreadyClaimed(address to);
    /// @notice No claim can land right now. `nextOpenAt` is when one opens, or 0 when none will open by waiting,
    ///         because the faucet cannot pay a full kit or the daily limit is zero.
    error NoClaimOpen(uint256 nextOpenAt);
    /// @notice The BTC payment to `to` failed: it refused the coins or ran past RECIPIENT_GAS.
    error BtcPaymentFailed(address to);
    /// @notice A kit amount is above MAX_BTC_PER_CLAIM or MAX_MUSD_PER_CLAIM.
    error KitTooLarge();
    /// @notice A kit amount is zero.
    error KitEmpty();
    /// @notice The daily limit is above MAX_DAILY_LIMIT.
    error LimitTooHigh();
    /// @notice MUSD leaves through withdraw, never rescueToken, so every MUSD exit emits Withdrawn.
    error TokenNotRescuable(address token);
    /// @notice Ownership can never be given up, so the funding can always be reached and the relayer replaced.
    error RenounceDisabled();

    /// @notice Relayer only. Pays one whole kit to `to`, once ever for that address.
    /// @dev Not payable, not while paused, under the reentrancy lock. `claimed[to]` and today's count are written
    ///      and Claimed is emitted before any value moves; MUSD is paid first and BTC last, so `to`'s code runs only
    ///      after every other effect. The BTC payment forwards exactly RECIPIENT_GAS and copies no return data.
    ///      Any failure reverts the whole transaction: `claimed[to]` stays false and nothing moves. Contracts are
    ///      welcome: a smart wallet receives a kit like any other address. Reverts NotRelayer, EnforcedPause,
    ///      ReentrancyGuardReentrantCall, BadRecipient for the zero address or the faucet, AlreadyClaimed,
    ///      NoClaimOpen (day's release used up, limit zero, or too little BTC or MUSD for a kit), any MUSD
    ///      transfer revert (MUSD refuses some recipients), or BtcPaymentFailed. Emits Claimed.
    /// @param to Address that receives the kit.
    function claim(address to) external;

    /// @notice How many claims could land right now, counting today's release and what the faucet can pay.
    /// @dev Never reverts: a MUSD balance that cannot be read counts as none held. 0 when paused, when the faucet
    ///      cannot pay one full kit of BTC and MUSD, when the daily limit is zero, or when today's count is at or
    ///      above what has been released so far, which includes the owner lowering the limit below today's count.
    /// @return The claims open now.
    function claimsOpen() external view returns (uint256);

    /// @notice The unix second the next claim opens: now when one is open, for the website's countdown.
    /// @dev Never reverts. 0 when paused, when the faucet cannot pay one full kit, or when the daily limit is zero:
    ///      waiting alone opens nothing then. A day whose limit is used up opens at the next 00:00:00 UTC.
    /// @return The unix second, or 0.
    function nextOpenAt() external view returns (uint256);

    /// @notice Claims paid so far in the current UTC day.
    /// @return Today's count.
    function claimsToday() external view returns (uint256);

    /// @notice Owner only. Sets the kit every later claim pays. Works while paused.
    /// @dev Reverts OwnableUnauthorizedAccount, KitEmpty if either amount is zero, or KitTooLarge if either is above
    ///      its cap. Emits KitSet.
    /// @param btc Native BTC per claim.
    /// @param musdAmount MUSD per claim.
    function setKit(uint128 btc, uint128 musdAmount) external;

    /// @notice Owner only. Sets how many claims each UTC day releases. Takes effect at once, today included, and
    ///         zero closes the faucet. Works while paused.
    /// @dev Reverts OwnableUnauthorizedAccount or LimitTooHigh. Emits DailyLimitSet.
    /// @param newDailyLimit New limit, at most MAX_DAILY_LIMIT.
    function setDailyLimit(uint32 newDailyLimit) external;

    /// @notice Owner only. Replaces the relayer, which is how a stolen relayer key is cut off.
    /// @dev Reverts OwnableUnauthorizedAccount or ZeroAddress. Emits RelayerSet.
    /// @param newRelayer New relayer.
    function setRelayer(address newRelayer) external;

    /// @notice Owner only. Stops claim and nothing else.
    /// @dev Reverts OwnableUnauthorizedAccount or EnforcedPause if already paused. Emits Paused.
    function pause() external;

    /// @notice Owner only. Lets claim run again.
    /// @dev Reverts OwnableUnauthorizedAccount or ExpectedPause if not paused. Emits Unpaused.
    function unpause() external;

    /// @notice Owner only. Pays BTC and MUSD to the owner and no one else. Works while paused.
    /// @dev Under the reentrancy lock. An amount of zero skips that coin. Reverts OwnableUnauthorizedAccount, a MUSD
    ///      transfer revert, InsufficientBalance or FailedCall on the BTC payment. Emits Withdrawn.
    /// @param btc Native BTC to take.
    /// @param musdAmount MUSD to take.
    function withdraw(uint256 btc, uint256 musdAmount) external;

    /// @notice Owner only. Sends a stray ERC-20 other than MUSD to the owner. Works while paused.
    /// @dev Under the reentrancy lock. Reverts OwnableUnauthorizedAccount, TokenNotRescuable for MUSD, or a token
    ///      transfer revert. Emits Rescued.
    /// @param token ERC-20 to send.
    /// @param amount Amount to send.
    function rescueToken(address token, uint256 amount) external;

    /// @notice Largest BTC kit the owner can set.
    /// @return The cap, in wei.
    function MAX_BTC_PER_CLAIM() external view returns (uint128);

    /// @notice Largest MUSD kit the owner can set.
    /// @return The cap, in wei.
    function MAX_MUSD_PER_CLAIM() external view returns (uint128);

    /// @notice Highest daily limit the owner can set.
    /// @return The cap.
    function MAX_DAILY_LIMIT() external view returns (uint32);

    /// @notice Gas forwarded with a claim's BTC payment.
    /// @return The gas allowance.
    function RECIPIENT_GAS() external view returns (uint256);

    /// @notice The MUSD token, fixed at deployment.
    /// @return The MUSD token.
    function musd() external view returns (IERC20);

    /// @notice The one address allowed to call claim.
    /// @return The relayer.
    function relayer() external view returns (address);

    /// @notice Native BTC each claim pays.
    /// @return The amount, in wei.
    function btcPerClaim() external view returns (uint128);

    /// @notice MUSD each claim pays.
    /// @return The amount, in wei.
    function musdPerClaim() external view returns (uint128);

    /// @notice Claims each UTC day releases.
    /// @return The limit.
    function dailyLimit() external view returns (uint32);

    /// @notice True while claims are stopped.
    /// @return Whether the faucet is paused.
    function paused() external view returns (bool);

    /// @notice True once an address took its kit.
    /// @param account Address to look up.
    /// @return Whether it has claimed.
    function claimed(address account) external view returns (bool);

    /// @notice Claims paid on a UTC day, numbered as unix time divided by one day.
    /// @param day Day number.
    /// @return That day's count.
    function claimsOnDay(uint256 day) external view returns (uint256);
}
