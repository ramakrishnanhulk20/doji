// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IVeBTCVoter
/// @notice The calls Doji makes on any voter registered with veBTC: PoolsVoter (the primary voter) and
///         ValidatorsVoter (a secondary voter) both have them, from their verified sources.
interface IVeBTCVoter {
    /// @notice Voting power a position has cast and not withdrawn on this voter; zero means it holds no live vote.
    /// @dev Set only when a vote with weight lands, which is also when the voter marks the position voted on
    ///      veBTC, and zeroed by reset.
    /// @param tokenId veBTC position id.
    /// @return weight The live vote weight.
    function usedWeights(uint256 tokenId) external view returns (uint256 weight);

    /// @notice Clears a position's vote on this voter so veBTC lets it be withdrawn or unlocked.
    /// @dev Owner or approved address only. The live sources revert AlreadyVotedOrDeposited in the epoch of the
    ///      last vote and DistributeWindow in the first hour of every epoch.
    /// @param tokenId veBTC position id.
    function reset(uint256 tokenId) external;
}
