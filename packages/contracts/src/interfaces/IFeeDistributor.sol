// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IFeeDistributor
/// @notice The slice of Mezo's veBTC fee distributor (a RewardsDistributor paying BTC) that Doji calls.
interface IFeeDistributor {
    /// @notice Claims a position's share of distributed fees. Anyone may call.
    /// @dev Live source: on an unexpired or permanent lock the amount is added to the lock with
    ///      veBTC.depositFor; on an expired normal lock it is paid in BTC to the position's owner. Reverts
    ///      UpdatePeriod until the epoch's emissions period is updated.
    /// @param tokenId veBTC position id.
    /// @return amount BTC claimed, 18 decimals.
    function claim(uint256 tokenId) external returns (uint256 amount);

    /// @notice A position's fees waiting to be claimed.
    /// @param tokenId veBTC position id.
    /// @return amount BTC claimable, 18 decimals.
    function claimable(uint256 tokenId) external view returns (uint256 amount);
}
