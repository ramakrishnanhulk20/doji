// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IVotingReward
/// @notice The one read Doji makes on a gauge's fee or incentive reward contract, the contracts PoolsVoter
///         returns from gaugeToFees and gaugeToBribe.
/// @dev Both kinds share Mezo's Reward base, which keeps the public isReward mapping. Live reads on 2026-11-04:
///      testnet fee contract 0xbCF0FAF26Dab69050b004eaE5DC817B522d5d813 reports MUSD true and 0x...dEaD false,
///      though the testnet PoolsVoter whitelists neither; mainnet fee contract
///      0x33b8B1162F0b86d68CAd418D96246Ee2c5164a01 reports MUSD true and veBTC false.
interface IVotingReward {
    /// @notice True for a token this reward contract records as one of its rewards, so it may pay it.
    /// @dev A fee contract lists its pool's own tokens. An incentive contract lists them too, and adds another
    ///      token only when an incentive in it is first posted, which BribeVotingReward allows only for a token
    ///      PoolsVoter whitelists.
    /// @param token Token address.
    /// @return listed Whether the token is one of this contract's rewards.
    function isReward(address token) external view returns (bool listed);
}
