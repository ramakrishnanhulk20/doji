// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockVeBTC} from "./MockVeBTC.sol";

/// @notice Stand-in for Mezo's PoolsVoter with the live reset rules: owner or approved only, no reset in the
/// epoch of the last vote, and none in the first hour of an epoch. vote() is a test hook with no checks.
contract MockPoolsVoter {
    uint256 internal constant WEEK = 604_800;

    MockVeBTC public immutable ve;
    mapping(uint256 tokenId => uint256) public lastVoted;

    error AlreadyVotedOrDeposited();
    error DistributeWindow();
    error NotApprovedOrOwner();

    constructor(MockVeBTC ve_) {
        ve = ve_;
    }

    function vote(uint256 tokenId) external {
        lastVoted[tokenId] = block.timestamp;
        ve.setVoted(tokenId, true);
    }

    function reset(uint256 tokenId) external {
        uint256 epochStart = block.timestamp - (block.timestamp % WEEK);
        if (epochStart <= lastVoted[tokenId]) revert AlreadyVotedOrDeposited();
        if (block.timestamp <= epochStart + 1 hours) revert DistributeWindow();
        if (!ve.isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();
        ve.setVoted(tokenId, false);
    }
}
