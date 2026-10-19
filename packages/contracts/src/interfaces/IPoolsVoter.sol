// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVeBTCVoter} from "./IVeBTCVoter.sol";

/// @title IPoolsVoter
/// @notice The slice of Mezo's PoolsVoter (veBTC gauge voting) that Doji calls.
/// @dev Signatures copied from the verified PoolsVoter implementation (reference/briefs/mezo-docs-brief.md 3.C).
interface IPoolsVoter is IVeBTCVoter {
    /// @notice Casts a position's gauge vote, splitting its voting power across pools by weight.
    /// @dev Owner or approved address only, once per epoch, never in the first hour of an epoch and, for a
    ///      position Mezo has not whitelisted, never in the last hour. Reverts TooManyPools above maxVotingNum.
    /// @param tokenId veBTC position id.
    /// @param poolVote Pools to vote for; each must have a live gauge.
    /// @param weights Relative weight per pool, same length as `poolVote`.
    function vote(uint256 tokenId, address[] calldata poolVote, uint256[] calldata weights) external;

    /// @notice Re-casts a position's standing vote at its current voting power. Anyone may call.
    /// @dev The live source reverts DistributeWindow in the first hour of an epoch and does not record a new
    ///      vote time, so it does not block a reset.
    /// @param tokenId veBTC position id.
    function poke(uint256 tokenId) external;

    /// @inheritdoc IVeBTCVoter
    function reset(uint256 tokenId) external override;

    /// @notice Claims a position's incentives from each listed bribe reward contract.
    /// @dev Owner or approved address only. Each reward contract pays the position's current owner.
    /// @param bribes Bribe reward contracts.
    /// @param tokens Tokens to claim from each, one list per contract.
    /// @param tokenId veBTC position id.
    function claimBribes(address[] calldata bribes, address[][] calldata tokens, uint256 tokenId) external;

    /// @notice Claims a position's share of pool fees from each listed fee reward contract.
    /// @dev Owner or approved address only. Each reward contract pays the position's current owner.
    /// @param fees Fee reward contracts.
    /// @param tokens Tokens to claim from each, one list per contract.
    /// @param tokenId veBTC position id.
    function claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId) external;

    /// @notice The fee reward contract PoolsVoter created for a gauge; zero for an address it never registered.
    /// @param gauge Gauge address.
    /// @return fees The gauge's fee reward contract.
    function gaugeToFees(address gauge) external view returns (address fees);

    /// @notice The incentive (bribe) reward contract PoolsVoter created for a gauge; zero for an address it never
    ///         registered.
    /// @param gauge Gauge address.
    /// @return bribe The gauge's incentive reward contract.
    function gaugeToBribe(address gauge) external view returns (address bribe);

    /// @notice True for a token Mezo governance has put on PoolsVoter's whitelist.
    /// @param token Token address.
    /// @return whitelisted Whether the token is whitelisted.
    function isWhitelistedToken(address token) external view returns (bool whitelisted);
}
