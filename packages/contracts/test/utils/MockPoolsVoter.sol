// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockVeBTC} from "./MockVeBTC.sol";

interface IRewardContract {
    function getReward(uint256 tokenId, address[] calldata tokens) external;
}

/// @notice Stand-in for Mezo's PoolsVoter, and for ValidatorsVoter, with the live rules from the verified sources:
/// vote and reset are owner or approved only, once per epoch and never in an epoch's first hour; vote is also
/// refused in the last hour; a vote records its weight in usedWeights and marks the position voted on veBTC, and
/// reset zeroes both; poke is open to anyone, re-casts the standing vote and never records a vote time;
/// claimFees and claimBribes are owner or approved only and call getReward on each listed reward contract, which
/// pays the position's owner. Tests register gauges (gaugeToFees, gaugeToBribe) and whitelist tokens as Mezo
/// governance would. vote(tokenId) is a test hook that casts a vote with no checks.
contract MockPoolsVoter {
    uint256 internal constant WEEK = 604_800;
    uint256 internal constant MAX_VOTING_NUM = 30;

    MockVeBTC public immutable ve;
    mapping(uint256 tokenId => uint256) public lastVoted;
    mapping(uint256 tokenId => uint256) public usedWeights;
    mapping(uint256 tokenId => address[]) internal _pools;
    mapping(uint256 tokenId => uint256[]) internal _weights;
    mapping(address gauge => address) public gaugeToFees;
    mapping(address gauge => address) public gaugeToBribe;
    mapping(address token => bool) public isWhitelistedToken;
    uint256 public pokeCount;
    uint256 public resetCount;

    error AlreadyVotedOrDeposited();
    error DistributeWindow();
    error NotApprovedOrOwner();
    error UnequalLengths();
    error TooManyPools();
    error NotWhitelistedNFT();

    constructor(MockVeBTC ve_) {
        ve = ve_;
    }

    function setGauge(address gauge, address fees, address bribe) external {
        gaugeToFees[gauge] = fees;
        gaugeToBribe[gauge] = bribe;
    }

    function setWhitelisted(address token, bool whitelisted) external {
        isWhitelistedToken[token] = whitelisted;
    }

    function vote(uint256 tokenId) external {
        lastVoted[tokenId] = block.timestamp;
        usedWeights[tokenId] = 1;
        ve.voting(tokenId, true);
    }

    function vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights) external {
        _onlyNewEpoch(tokenId);
        if (!ve.isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();
        if (pools.length != weights.length) revert UnequalLengths();
        if (pools.length > MAX_VOTING_NUM) revert TooManyPools();
        if (block.timestamp > _epochStart() + WEEK - 1 hours) revert NotWhitelistedNFT();
        lastVoted[tokenId] = block.timestamp;
        _pools[tokenId] = pools;
        _weights[tokenId] = weights;
        usedWeights[tokenId] = pools.length;
        ve.voting(tokenId, pools.length != 0);
    }

    function poke(uint256 tokenId) external {
        if (block.timestamp <= _epochStart() + 1 hours) revert DistributeWindow();
        ++pokeCount;
        ve.voting(tokenId, usedWeights[tokenId] != 0);
    }

    function reset(uint256 tokenId) external {
        _onlyNewEpoch(tokenId);
        if (!ve.isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();
        ++resetCount;
        delete _pools[tokenId];
        delete _weights[tokenId];
        usedWeights[tokenId] = 0;
        ve.voting(tokenId, false);
    }

    function claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId) external {
        _claim(fees, tokens, tokenId);
    }

    function claimBribes(address[] calldata bribes, address[][] calldata tokens, uint256 tokenId) external {
        _claim(bribes, tokens, tokenId);
    }

    function poolsOf(uint256 tokenId) external view returns (address[] memory) {
        return _pools[tokenId];
    }

    function weightsOf(uint256 tokenId) external view returns (uint256[] memory) {
        return _weights[tokenId];
    }

    function _claim(address[] calldata rewards, address[][] calldata tokens, uint256 tokenId) internal {
        if (!ve.isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();
        for (uint256 i; i < rewards.length; ++i) {
            IRewardContract(rewards[i]).getReward(tokenId, tokens[i]);
        }
    }

    function _onlyNewEpoch(uint256 tokenId) internal view {
        uint256 epochStart = _epochStart();
        if (epochStart <= lastVoted[tokenId]) revert AlreadyVotedOrDeposited();
        if (block.timestamp <= epochStart + 1 hours) revert DistributeWindow();
    }

    function _epochStart() internal view returns (uint256) {
        return block.timestamp - (block.timestamp % WEEK);
    }
}
