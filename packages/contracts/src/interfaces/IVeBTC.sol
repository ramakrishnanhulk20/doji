// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IVeBTC
/// @notice The slice of Mezo's veBTC (vote-escrow BTC, an ERC-721) that Doji calls.
/// @dev `locked()` is deliberately absent: its return shape differs between testnet (3 words)
///      and mainnet (4 words), so it is only ever read through LockReader.
interface IVeBTC {
    /// @notice Current owner of a position. Mezo mainnet returns the zero address for a missing or burned id.
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @notice Moves a position without calling any receiver hook.
    function transferFrom(address from, address to, uint256 tokenId) external;

    /// @notice 0 = NORMAL, 1 = LOCKED, 2 = MANAGED.
    function escrowType(uint256 tokenId) external view returns (uint8);

    /// @notice Address that can revoke a grant-backed position, or zero for an ordinary position.
    function grantManager(uint256 tokenId) external view returns (address);

    /// @notice True while the position has a standing gauge vote.
    function voted(uint256 tokenId) external view returns (bool);

    /// @notice Burns an expired, non-permanent, unvoted position and pays its locked BTC to the caller.
    /// @dev Live source pays through the BTC ERC-20 view (`IERC20(token).safeTransfer`), not a native call.
    function withdraw(uint256 tokenId) external;

    /// @notice Turns a permanent lock into a normal one that ends at the next week boundary after the
    ///         maximum lock time. Reverts while the position is voted.
    function unlockPermanent(uint256 tokenId) external;

    /// @notice Locks `value` BTC, pulled from the caller with transferFrom, and mints the new position to `to`.
    /// @dev The unlock time is floor((now + lockDuration) / 1 week) * 1 week. Reverts ZeroAmount,
    ///      LockDurationNotInFuture or LockDurationTooLong.
    /// @param value BTC to lock, 18 decimals.
    /// @param lockDuration Seconds from now, rounded down to a week boundary.
    /// @param to Receiver of the new position.
    /// @return tokenId The new position's id.
    function createLockFor(uint256 value, uint256 lockDuration, address to) external returns (uint256 tokenId);

    /// @notice Pushes a normal, unexpired lock's end out to floor((now + lockDuration) / 1 week) * 1 week.
    /// @dev Owner or approved address only. Reverts unless the new end is later than the current one and
    ///      within the maximum lock time.
    /// @param tokenId Position id.
    /// @param lockDuration Seconds from now, rounded down to a week boundary.
    function increaseUnlockTime(uint256 tokenId, uint256 lockDuration) external;
}
