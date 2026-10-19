// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPoolsVoter
/// @notice The slice of Mezo's PoolsVoter (veBTC gauge voting) that Doji calls.
interface IPoolsVoter {
    /// @notice Clears a position's gauge vote so veBTC lets it be withdrawn or unlocked.
    /// @dev Owner or approved address only. The live source reverts AlreadyVotedOrDeposited in the epoch of
    ///      the last vote and DistributeWindow in the first hour of every epoch.
    function reset(uint256 tokenId) external;
}
