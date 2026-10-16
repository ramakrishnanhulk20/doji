// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IVeBTC
/// @notice The slice of Mezo's veBTC (vote-escrow BTC, an ERC-721) that Dojima calls.
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
}
