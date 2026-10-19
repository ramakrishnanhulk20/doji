// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILoanManager} from "../interfaces/ILoanManager.sol";
import {IPoolsVoter} from "../interfaces/IPoolsVoter.sol";
import {IVeBTCVoter} from "../interfaces/IVeBTCVoter.sol";
import {IVeBTC} from "../interfaces/IVeBTC.sol";
import {LockReader} from "./LockReader.sol";

/// @title PassThrough
/// @notice LoanManager's calls into Mezo's veBTC voters: the borrower's vote and reward claim, and the vote
///         clearing settle needs. Run by LoanManager with delegatecall so they act as LoanManager, the position's
///         owner on Mezo.
/// @dev An external library only so LoanManager fits under the contract size limit. Its code is fixed and
///      linked when LoanManager is deployed, it keeps no state, and LoanManager runs the C4 check and holds its
///      reentrancy lock around every call (and, for clearForSettle, its floor-time, resolution and custody
///      checks). Errors and events are LoanManager's own, so the UI decodes them
///      from ILoanManager and the logs carry LoanManager's address.
library PassThrough {
    using SafeERC20 for IERC20;

    /// @dev Each listed token costs two balance reads and at most one transfer, and each reward contract one
    ///      getReward call inside PoolsVoter. A full claim of 16 reward contracts measured about 1.0M gas on the
    ///      mainnet fork (test/fork/PassThroughFork.t.sol), a tenth of Mezo's 10M block gas limit.
    uint256 internal constant MAX_REWARD_TOKENS = 16;
    uint256 private constant WEEK = 604_800;

    /// @notice Clears every live vote veBTC counts for a position and turns a permanent lock into a normal one,
    ///         so settle can withdraw it (C5, C26).
    /// @dev Runs inside prepareSettle. Resets each voter only when it reports a live vote (usedWeights above
    ///      zero), never blind; a zero voter address (no secondary voters on this chain) is skipped. A reset not yet
    ///      allowed this epoch reverts unchanged and the next epoch allows it. Then veBTC.unlockPermanent when the
    ///      lock is permanent. Reverts NothingToPrepare when there is no vote and no permanent lock. Emits
    ///      SettlePrepared before any call.
    /// @param poolsVoter Mezo's PoolsVoter.
    /// @param validatorsVoter Mezo's ValidatorsVoter, or zero.
    /// @param veBTC Mezo's veBTC.
    /// @param tokenId Position being prepared.
    /// @param isPermanent Whether its lock is permanent, as LoanManager's lock reader decoded it.
    function clearForSettle(
        IVeBTCVoter poolsVoter,
        IVeBTCVoter validatorsVoter,
        address veBTC,
        uint256 tokenId,
        bool isPermanent
    ) external {
        bool poolsVote = _hasLiveVote(poolsVoter, tokenId);
        bool validatorsVote = _hasLiveVote(validatorsVoter, tokenId);
        if (!poolsVote && !validatorsVote && !isPermanent) revert ILoanManager.NothingToPrepare(tokenId);
        // The only calls above are usedWeights reads on voters fixed at deployment; every reset and the unlock
        // come after this event.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ILoanManager.SettlePrepared(tokenId, poolsVote, validatorsVote, isPermanent);

        if (poolsVote) poolsVoter.reset(tokenId);
        if (validatorsVote) validatorsVoter.reset(tokenId);
        if (isPermanent) IVeBTC(veBTC).unlockPermanent(tokenId);
    }

    /// @dev C5: a voter holds a live vote for a position exactly while its usedWeights is above zero; the voter
    ///      marks the position voted on veBTC at the same moment and its reset clears both.
    function _hasLiveVote(IVeBTCVoter voter, uint256 tokenId) private view returns (bool) {
        return address(voter) != address(0) && voter.usedWeights(tokenId) != 0;
    }

    /// @notice Casts a position's gauge vote through PoolsVoter, refusing a vote a normal lock could not reset
    ///         before it ends (C5).
    /// @dev `args` is vote's own calldata after the selector, decoded here with the standard ABI rules; its
    ///      first word is ignored in favour of `tokenId`, the id LoanManager has already checked. A vote must
    ///      list 1 to `maxVotes` pools with one weight each. PoolsVoter refuses a reset only in the epoch of the
    ///      last vote, so a normal lock may not vote at or after lockEnd - WEEK, which always leaves a whole
    ///      epoch for the reset settle needs; a permanent lock never ends and may vote in any epoch. Reverts
    ///      BadVoteCount, LengthMismatch, VoteTooLate, a LockReader error, or any PoolsVoter.vote revert.
    /// @param voter Mezo's PoolsVoter.
    /// @param veBTC Mezo's veBTC.
    /// @param layoutWords Words veBTC's locked() returns on this chain.
    /// @param maxVotes Most pools one vote may list.
    /// @param tokenId Position to vote with, already checked by LoanManager.
    /// @param args ABI encoding of (tokenId, pools, weights).
    // forge-lint: disable-next-item(block-timestamp)
    function castVote(
        IPoolsVoter voter,
        address veBTC,
        uint256 layoutWords,
        uint256 maxVotes,
        uint256 tokenId,
        bytes calldata args
    ) external {
        (, address[] memory pools, uint256[] memory weights) = abi.decode(args, (uint256, address[], uint256[]));
        uint256 count = pools.length;
        if (count == 0 || count > maxVotes) revert ILoanManager.BadVoteCount(count);
        if (weights.length != count) revert ILoanManager.LengthMismatch();
        (, uint256 lockEnd, bool isPermanent) = LockReader.read(veBTC, tokenId, layoutWords);
        if (!isPermanent && block.timestamp + WEEK >= lockEnd) revert ILoanManager.VoteTooLate(tokenId, lockEnd);

        voter.vote(tokenId, pools, weights);
    }

    /// @notice Claims a position's pool fees and incentives from the listed gauges through PoolsVoter and pays the
    ///         caller exactly the measured increase in LoanManager's balance of each distinct listed token (C10).
    /// @dev `args` is claimRewards' own calldata after the selector, decoded here with the standard ABI rules;
    ///      its first word is ignored in favour of `tokenId`, the id LoanManager has already checked. Each gauge's
    ///      fee and incentive contracts come from PoolsVoter and both must exist, and every distinct token must be
    ///      on PoolsVoter's whitelist, so the only code that runs is Mezo's own reward contracts paying this
    ///      tokenId; MUSD and BTC are forwarded like any other whitelisted token. Every gauge must list at least
    ///      one token and at most MAX_REWARD_TOKENS are listed in total. Balances are read before the claims and
    ///      all read again before anything is paid, so no payout runs code inside the measured window. Reverts
    ///      LengthMismatch, BadRewardTokenCount, UnknownGauge, TokenNotWhitelisted, or any PoolsVoter, reward or
    ///      token revert. Emits RewardsForwarded per token whose balance rose.
    /// @param voter Mezo's PoolsVoter.
    /// @param tokenId Position the borrower is claiming for, already checked by LoanManager.
    /// @param args ABI encoding of (tokenId, gauges, feeTokens, bribeTokens).
    function forwardRewards(IPoolsVoter voter, uint256 tokenId, bytes calldata args) external {
        (, address[] memory gauges, address[][] memory feeTokens, address[][] memory bribeTokens) =
            abi.decode(args, (uint256, address[], address[][], address[][]));
        if (feeTokens.length != gauges.length || bribeTokens.length != gauges.length) {
            revert ILoanManager.LengthMismatch();
        }
        address[] memory tokens = _distinctTokens(voter, feeTokens, bribeTokens);
        (address[] memory feeRewards, address[] memory bribeRewards) = _rewardContracts(voter, gauges);
        uint256[] memory before = _balancesOf(tokens);

        _claimSide(voter, feeRewards, feeTokens, tokenId, true);
        _claimSide(voter, bribeRewards, bribeTokens, tokenId, false);

        _payGains(tokenId, tokens, before);
    }

    /// @dev Each gauge's fee and incentive reward contracts as PoolsVoter registered them. An address PoolsVoter
    ///      never registered has neither, so only gauges PoolsVoter created, live or killed, pass.
    // forge-lint: disable-next-item(calls-loop,require-revert-in-loop)
    function _rewardContracts(IPoolsVoter voter, address[] memory gauges)
        private
        view
        returns (address[] memory feeRewards, address[] memory bribeRewards)
    {
        uint256 count = gauges.length;
        feeRewards = new address[](count);
        bribeRewards = new address[](count);
        for (uint256 i; i < count; ++i) {
            feeRewards[i] = voter.gaugeToFees(gauges[i]);
            bribeRewards[i] = voter.gaugeToBribe(gauges[i]);
            if (feeRewards[i] == address(0) || bribeRewards[i] == address(0)) {
                revert ILoanManager.UnknownGauge(gauges[i]);
            }
        }
    }

    /// @dev One side's claim through PoolsVoter, leaving out gauges that list no token on this side and skipped
    ///      entirely when none do.
    function _claimSide(
        IPoolsVoter voter,
        address[] memory rewards,
        address[][] memory lists,
        uint256 tokenId,
        bool fees
    ) private {
        uint256 count = rewards.length;
        uint256 used = 0;
        for (uint256 i; i < count; ++i) {
            if (lists[i].length != 0) ++used;
        }
        if (used == 0) return;
        address[] memory calledRewards = new address[](used);
        address[][] memory calledLists = new address[][](used);
        uint256 j = 0;
        for (uint256 i; i < count; ++i) {
            if (lists[i].length == 0) continue;
            calledRewards[j] = rewards[i];
            calledLists[j] = lists[i];
            ++j;
        }
        if (fees) voter.claimFees(calledRewards, calledLists, tokenId);
        else voter.claimBribes(calledRewards, calledLists, tokenId);
    }

    /// @dev The distinct tokens across every gauge and both sides; a token listed twice is kept once, so its
    ///      increase is measured and paid once. The running total is checked before each gauge's lists are walked,
    ///      so every loop here stops within MAX_REWARD_TOKENS steps whatever the caller sends.
    // forge-lint: disable-next-item(require-revert-in-loop)
    function _distinctTokens(IPoolsVoter voter, address[][] memory feeTokens, address[][] memory bribeTokens)
        private
        view
        returns (address[] memory tokens)
    {
        address[] memory found = new address[](MAX_REWARD_TOKENS);
        uint256 listed = 0;
        uint256 count = 0;
        uint256 gaugeCount = feeTokens.length;
        for (uint256 i; i < gaugeCount; ++i) {
            uint256 n = feeTokens[i].length + bribeTokens[i].length;
            listed += n;
            if (n == 0 || listed > MAX_REWARD_TOKENS) revert ILoanManager.BadRewardTokenCount(listed);
            count = _addTokens(voter, feeTokens[i], found, count);
            count = _addTokens(voter, bribeTokens[i], found, count);
        }
        if (listed == 0) revert ILoanManager.BadRewardTokenCount(0);
        tokens = new address[](count);
        for (uint256 i; i < count; ++i) {
            tokens[i] = found[i];
        }
    }

    /// @dev Appends a list's new tokens to `found`, each checked once against PoolsVoter's whitelist: one
    ///      predicate Mezo governance maintains, which covers every token a Mezo reward contract can pay and
    ///      refuses anything else (veBTC, CreditMarkets units, an attacker's token). Returns the new count.
    // forge-lint: disable-next-item(calls-loop,require-revert-in-loop)
    function _addTokens(IPoolsVoter voter, address[] memory list, address[] memory found, uint256 count)
        private
        view
        returns (uint256)
    {
        uint256 n = list.length;
        for (uint256 j; j < n; ++j) {
            address token = list[j];
            uint256 k = 0;
            while (k < count && found[k] != token) ++k;
            if (k < count) continue;
            if (!voter.isWhitelistedToken(token)) revert ILoanManager.TokenNotWhitelisted(token);
            found[count++] = token;
        }
        return count;
    }

    /// @dev This contract's balance of each token. One read per distinct token is the measurement itself, and
    ///      the list is capped at MAX_REWARD_TOKENS.
    // forge-lint: disable-next-item(calls-loop)
    function _balancesOf(address[] memory tokens) private view returns (uint256[] memory balances) {
        uint256 count = tokens.length;
        balances = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            balances[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
    }

    /// @dev Pays the caller each token's increase since `before`. A balance that fell reverts the claim. The
    ///      events follow the claim calls on purpose: the amounts are only known once they return.
    // forge-lint: disable-next-item(reentrancy-events)
    function _payGains(uint256 tokenId, address[] memory tokens, uint256[] memory before) private {
        uint256[] memory gained = _balancesOf(tokens);
        uint256 count = tokens.length;
        for (uint256 i; i < count; ++i) {
            gained[i] -= before[i];
        }
        for (uint256 i; i < count; ++i) {
            if (gained[i] == 0) continue;
            emit ILoanManager.RewardsForwarded(tokenId, tokens[i], gained[i]);
            IERC20(tokens[i]).safeTransfer(msg.sender, gained[i]);
        }
    }
}
