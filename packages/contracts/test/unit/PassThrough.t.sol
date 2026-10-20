// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Unit tests for the borrower pass-throughs (vote, resetVotes, claimRewards, claimRebase, extendLock) and the
// vote clearing settle relies on: the one borrower check (C4), the vote cut-off before a lock ends and
// prepareSettle resetting every voter with a live vote (C5, C26), reward forwarding through registered gauges
// and whitelisted tokens only, with MUSD and BTC forwarded and claimables untouched (C10, C28), fee-distributor
// claims credited to the right claimable (C28), and the pause leaving every pass-through and roll open (C19), on
// the real CreditMarkets and LoanManager with mocks for veBTC, PoolsVoter, ValidatorsVoter, the fee
// distributor, reward contracts and tokens.
// It does NOT cover: Mezo's real voters, reward contracts, fee distributor or veBTC
// (test/fork/PassThroughFork.t.sol), tokens whose balanceOf lies, fee-on-transfer reward tokens, a secondary
// voter Mezo adds after deployment (a stated non-goal), or pass-throughs inside the randomised invariant run.

import {Vm} from "forge-std/Vm.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";
import {MockPoolsVoter} from "../utils/MockPoolsVoter.sol";
import {MockReward} from "../utils/MockReward.sol";
import {MockToken} from "../utils/MockToken.sol";
import {MockVeBTC} from "../utils/MockVeBTC.sol";

contract PassThroughTest is LoanFixture {
    uint256 internal constant TOKEN_B = 8;
    uint256 internal constant TOKEN_C = 9;
    uint256 internal constant TOKEN_D = 10;

    MockToken internal tokenA;
    MockToken internal tokenB;
    MockToken internal tokenC;
    MockReward internal fees;
    MockReward internal bribes;
    address internal gauge = makeAddr("gauge");
    address[] internal pools;
    uint256[] internal weights;
    uint256 internal treasuryMusdOwed;

    function setUp() public override {
        super.setUp();
        tokenA = new MockToken("AAA");
        tokenB = new MockToken("BBB");
        tokenC = new MockToken("CCC");
        fees = new MockReward(address(voter), ve);
        bribes = new MockReward(address(voter), ve);
        voter.setGauge(gauge, address(fees), address(bribes));
        address[4] memory whitelisted = [address(tokenA), address(tokenB), address(musd), address(btc)];
        for (uint256 i; i < whitelisted.length; ++i) {
            voter.setWhitelisted(whitelisted[i], true);
        }
        pools.push(makeAddr("poolX"));
        pools.push(makeAddr("poolY"));
        weights.push(70);
        weights.push(30);
    }

    function _list(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _list(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        (out[0], out[1]) = (a, b);
    }

    function _nest(address[] memory inner) internal pure returns (address[][] memory out) {
        out = new address[][](1);
        out[0] = inner;
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _noLists() internal pure returns (address[][] memory) {
        return new address[][](0);
    }

    function _owe(MockReward reward, uint256 tokenId, MockToken token, uint256 amount) internal {
        token.mint(address(reward), amount);
        reward.setOwed(tokenId, address(token), amount);
    }

    function _claim(address who, uint256 tokenId, address[] memory feeTokens, address[] memory bribeTokens) internal {
        vm.prank(who);
        lm.claimRewards(tokenId, _list(gauge), _nest(feeTokens), _nest(bribeTokens));
    }

    /// @dev A fresh gauge registered on PoolsVoter with the given reward contracts.
    function _gauge(string memory name, MockReward feeReward, MockReward bribeReward) internal returns (address g) {
        g = makeAddr(name);
        voter.setGauge(g, address(feeReward), address(bribeReward));
    }

    function _vote(address who, uint256 tokenId) internal {
        vm.prank(who);
        lm.vote(tokenId, pools, weights);
    }

    /// @dev Claims token A from the gauge's fee contract and token B from its bribe contract.
    function _claimAB(address who, uint256 tokenId) internal {
        _claim(who, tokenId, _list(address(tokenA)), _list(address(tokenB)));
    }

    /// @dev A time inside the voting window of the epoch after the current one.
    function _nextEpochWindow() internal view returns (uint256) {
        return (vm.getBlockTimestamp() / WEEK + 1) * WEEK + 2 hours;
    }

    /// @dev Every pass-through, called by `who` on `tokenId`, must revert with `reason`.
    function _expectAllRevert(address who, uint256 tokenId, bytes memory reason) internal {
        vm.startPrank(who);
        vm.expectRevert(reason);
        lm.vote(tokenId, pools, weights);
        vm.expectRevert(reason);
        lm.resetVotes(tokenId);
        vm.expectRevert(reason);
        lm.claimRewards(tokenId, _list(gauge), _nest(_list(address(tokenA))), _nest(_none()));
        vm.expectRevert(reason);
        lm.claimRebase(tokenId);
        vm.expectRevert(reason);
        lm.extendLock(tokenId, 28 days);
        vm.stopPrank();
    }

    /// @dev Alice's TOKEN goes to auction and is bought, leaving her and the treasury MUSD claimables; bob's
    ///      TOKEN_C, on a lock that has ended, collects an expired-lock fee claim, leaving him a BTC claimable.
    function _makeClaimables() internal returns (uint256 musdOwed, uint256 btcOwed) {
        _openLoan();
        _makeUnsafe(TOKEN);
        lm.startAuction(TOKEN);
        vm.warp(vm.getBlockTimestamp() + DURATION / 3);
        vm.prank(buyer);
        lm.purchase(TOKEN, type(uint256).max, vm.getBlockTimestamp());
        feed.setPrice(PRICE);

        ve.mint(bob, TOKEN_C, LOCK_BTC, m1, false);
        _deposit(bob, TOKEN_C);
        vm.warp(m1 + 1);
        dist.setClaimable(TOKEN_C, 0.05e18);
        vm.prank(bob);
        lm.claimRebase(TOKEN_C);

        musdOwed = lm.claimableMusd(alice);
        btcOwed = lm.claimableBtc(bob);
        treasuryMusdOwed = lm.claimableMusd(treasury);
        assertGt(musdOwed, 0);
        assertGt(treasuryMusdOwed, 0);
        assertEq(btcOwed, 0.05e18);
    }

    function _assertClaimablesUntouched(uint256 musdOwed, uint256 btcOwed) internal view {
        assertEq(lm.claimableMusd(alice), musdOwed, "C28: MUSD claimable moved");
        assertEq(lm.claimableMusd(treasury), treasuryMusdOwed, "C28: treasury claimable moved");
        assertEq(lm.claimableBtc(bob), btcOwed, "C28: BTC claimable moved");
        assertEq(lm.totalClaimableMusd(), musdOwed + treasuryMusdOwed);
        assertEq(lm.totalClaimableBtc(), btcOwed);
        assertGe(musd.balanceOf(address(lm)), musdOwed + treasuryMusdOwed, "C28: MUSD claimables unbacked");
        assertGe(btc.balanceOf(address(lm)), btcOwed, "C28: BTC claimables unbacked");
    }

    function test_Constructor_WiresPassThroughs() public view {
        assertEq(address(lm.feeDistributor()), address(dist));
        assertEq(address(lm.validatorsVoter()), address(validators));
        assertEq(lm.maxVotes(), 30);
        assertEq(lm.MAX_REWARD_TOKENS(), 16);
    }

    function test_RevertWhen_ConstructorVoteCapOutOfBounds() public {
        uint16[2] memory bad = [uint16(0), 31];
        for (uint256 i; i < bad.length; ++i) {
            ILoanManager.Settings memory settings = _settings();
            settings.maxVotes = bad[i];
            vm.expectRevert(abi.encodeWithSelector(ILoanManager.MaxVotesOutOfBounds.selector, bad[i]));
            this.deployManager(address(btc), address(voter), address(cm), settings);
        }
        ILoanManager.Settings memory noDistributor = _settings();
        noDistributor.feeDistributor = address(0);
        vm.expectRevert(ILoanManager.ZeroAddress.selector);
        this.deployManager(address(btc), address(voter), address(cm), noDistributor);

        ILoanManager.Settings memory sameVoter = _settings();
        sameVoter.validatorsVoter = address(voter);
        vm.expectRevert(ILoanManager.DuplicateVoter.selector);
        this.deployManager(address(btc), address(voter), address(cm), sameVoter);
    }

    function test_Vote_CastsThroughPoolsVoter() public {
        _deposit(alice, TOKEN);
        _vote(alice, TOKEN);
        assertEq(voter.poolsOf(TOKEN), pools);
        assertEq(voter.weightsOf(TOKEN), weights);
        assertTrue(ve.voted(TOKEN));
        assertEq(voter.lastVoted(TOKEN), block.timestamp);
    }

    function test_C4_NonBorrowerCannotUseAnyPassThrough() public {
        _deposit(alice, TOKEN);
        address[3] memory others = [bob, owner, guardian];
        for (uint256 i; i < others.length; ++i) {
            _expectAllRevert(others[i], TOKEN, abi.encodeWithSelector(ILoanManager.NotBorrower.selector, TOKEN));
        }
    }

    function test_C4_PlainTransferredTokenHasNoPassThrough() public {
        vm.prank(alice);
        ve.transferFrom(alice, address(lm), TOKEN);
        _expectAllRevert(alice, TOKEN, abi.encodeWithSelector(ILoanManager.NotBorrower.selector, TOKEN));
        _expectAllRevert(bob, TOKEN, abi.encodeWithSelector(ILoanManager.NotBorrower.selector, TOKEN));
    }

    function test_C4_PassThroughsWorkWithNoLoan() public {
        _deposit(alice, TOKEN);
        _vote(alice, TOKEN);
        vm.warp(_nextEpochWindow());
        vm.prank(alice);
        lm.resetVotes(TOKEN);
        assertFalse(ve.voted(TOKEN));

        _owe(fees, TOKEN, tokenA, 5e18);
        _owe(bribes, TOKEN, tokenB, 3e18);
        _claimAB(alice, TOKEN);
        assertEq(tokenA.balanceOf(alice), 5e18);
        assertEq(tokenB.balanceOf(alice), 3e18);

        dist.setClaimable(TOKEN, 0.1e18);
        vm.prank(alice);
        lm.claimRebase(TOKEN);
        (uint256 amount,,) = lm.lockOf(TOKEN);
        assertEq(amount, 1.1e18, "fees added to the lock");

        vm.prank(alice);
        lm.extendLock(TOKEN, 28 days);
        (, uint256 end,) = lm.lockOf(TOKEN);
        assertEq(end, (block.timestamp + 28 days) / WEEK * WEEK);
        assertGt(end, m3);
    }

    function test_C4_VoteAndExtendLockRevertWhenOverdue() public {
        _openLoan();
        _vote(alice, TOKEN);
        vm.warp(m1 + 2 hours);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LoanOverdue.selector, TOKEN));
        lm.vote(TOKEN, pools, weights);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LoanOverdue.selector, TOKEN));
        lm.extendLock(TOKEN, 28 days);

        lm.resetVotes(TOKEN);
        lm.claimRebase(TOKEN);
        vm.stopPrank();
        _owe(fees, TOKEN, tokenA, 1e18);
        _owe(bribes, TOKEN, tokenB, 1e18);
        _claimAB(alice, TOKEN);
        assertFalse(ve.voted(TOKEN), "an overdue borrower may still clear the vote");
        assertEq(tokenA.balanceOf(alice), 1e18, "and still collect rewards");
    }

    function test_C4_VoteAndExtendLockRevertWhenUnsafe() public {
        _openLoan();
        _makeUnsafe(TOKEN);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LoanUnsafe.selector, TOKEN));
        lm.vote(TOKEN, pools, weights);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LoanUnsafe.selector, TOKEN));
        lm.extendLock(TOKEN, 28 days);
        lm.claimRebase(TOKEN);
        vm.stopPrank();
        _owe(fees, TOKEN, tokenA, 1e18);
        _owe(bribes, TOKEN, tokenB, 1e18);
        _claimAB(alice, TOKEN);
        assertEq(tokenA.balanceOf(alice), 1e18, "rewards are not collateral, so health does not gate them");
    }

    function test_C4_PassThroughsRevertInAuction() public {
        _openLoan();
        _vote(alice, TOKEN);
        _makeUnsafe(TOKEN);
        lm.startAuction(TOKEN);
        _expectAllRevert(alice, TOKEN, abi.encodeWithSelector(ILoanManager.LoanInAuction.selector, TOKEN));

        vm.warp(m1 + 1);
        _expectAllRevert(alice, TOKEN, abi.encodeWithSelector(ILoanManager.LoanInAuction.selector, TOKEN));
    }

    function test_C2_PassThroughsRevertWhenCustodyLost() public {
        _deposit(alice, TOKEN);
        ve.forceTransfer(address(lm), bob, TOKEN);
        _expectAllRevert(alice, TOKEN, abi.encodeWithSelector(ILoanManager.NotInCustody.selector, TOKEN));
    }

    function test_C7_VoteNeedsAFreshPriceOnlyWithALoan() public {
        _deposit(alice, TOKEN);
        feed.setStale(true);
        _vote(alice, TOKEN);

        vm.warp(_nextEpochWindow());
        feed.setStale(false);
        (uint256[] memory ids, uint128[] memory amounts) = _one(offerM2, PRINCIPAL);
        vm.prank(alice);
        lm.borrow(TOKEN, m2, ids, amounts, 5_000);
        feed.setStale(true);
        vm.expectRevert(ILoanManager.PriceUnavailable.selector);
        _vote(alice, TOKEN);
        vm.prank(alice);
        lm.resetVotes(TOKEN);
        assertFalse(ve.voted(TOKEN), "a reset needs no price");
    }

    function test_C5_VoteRefusedAtAndAfterLockEndMinusOneWeek() public {
        _deposit(alice, TOKEN);
        uint256 cutoff = uint256(m3) - WEEK;
        vm.warp(cutoff - 2 hours);
        _vote(alice, TOKEN);

        vm.warp(cutoff);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.VoteTooLate.selector, TOKEN, uint256(m3)));
        _vote(alice, TOKEN);
        vm.warp(cutoff + 3 days);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.VoteTooLate.selector, TOKEN, uint256(m3)));
        _vote(alice, TOKEN);

        // The point of the cut-off: the last allowed vote still leaves a whole epoch to reset before the lock ends.
        vm.warp(cutoff + 1 hours + 1);
        vm.prank(alice);
        lm.resetVotes(TOKEN);
        assertFalse(ve.voted(TOKEN));
        assertLt(block.timestamp, m3);
    }

    function test_C5_PermanentLockMayVoteInAnyEpoch() public {
        ve.setLock(TOKEN, LOCK_BTC, 0, true);
        _deposit(alice, TOKEN);
        _vote(alice, TOKEN);
        vm.warp(uint256(m3) + 5 * WEEK + 2 hours);
        _vote(alice, TOKEN);
        assertEq(voter.lastVoted(TOKEN), block.timestamp);
    }

    function test_C5_ExpiredLockCannotVote() public {
        ve.setLock(TOKEN, LOCK_BTC, m1, false);
        _deposit(alice, TOKEN);
        vm.warp(m1 + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.VoteTooLate.selector, TOKEN, uint256(m1)));
        _vote(alice, TOKEN);
    }

    function test_RevertWhen_VoteListsAreBad() public {
        _deposit(alice, TOKEN);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.BadVoteCount.selector, 0));
        lm.vote(TOKEN, new address[](0), new uint256[](0));
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.BadVoteCount.selector, 31));
        lm.vote(TOKEN, new address[](31), new uint256[](31));
        vm.expectRevert(ILoanManager.LengthMismatch.selector);
        lm.vote(TOKEN, pools, new uint256[](1));
        vm.stopPrank();
    }

    function test_Vote_SurfacesTheVoterEpochRule() public {
        _deposit(alice, TOKEN);
        _vote(alice, TOKEN);
        vm.expectRevert(MockPoolsVoter.AlreadyVotedOrDeposited.selector);
        _vote(alice, TOKEN);
    }

    function test_ResetVotes_SurfacesTheVoterRules() public {
        _deposit(alice, TOKEN);
        _vote(alice, TOKEN);
        vm.startPrank(alice);
        vm.expectRevert(MockPoolsVoter.AlreadyVotedOrDeposited.selector);
        lm.resetVotes(TOKEN);
        vm.warp((vm.getBlockTimestamp() / WEEK + 1) * WEEK + 30 minutes);
        vm.expectRevert(MockPoolsVoter.DistributeWindow.selector);
        lm.resetVotes(TOKEN);
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        lm.resetVotes(TOKEN);
        vm.stopPrank();
        assertFalse(ve.voted(TOKEN));
    }

    function test_ExtendLock_KeepsTheLoanInsideItsLock() public {
        _openLoan();
        vm.prank(alice);
        lm.extendLock(TOKEN, 28 days);
        (, uint256 end,) = lm.lockOf(TOKEN);
        assertGt(end, m3);
        assertGe(end, lm.loanOf(TOKEN).maturity);
        vm.expectRevert(MockVeBTC.LockDurationNotInFuture.selector);
        vm.prank(alice);
        lm.extendLock(TOKEN, 1 days);
    }

    function test_C10_MusdAndBtcRewardsAreForwardedAndClaimablesUntouched() public {
        (uint256 musdOwed, uint256 btcOwed) = _makeClaimables();
        ve.mint(bob, TOKEN_B, LOCK_BTC, m3 + uint64(WEEK), false);
        _deposit(bob, TOKEN_B);
        musd.mint(address(fees), 40e18);
        fees.setOwed(TOKEN_B, address(musd), 40e18);
        btc.mint(address(fees), 0.02e18);
        fees.setOwed(TOKEN_B, address(btc), 0.02e18);
        btc.mint(address(bribes), 0.01e18);
        bribes.setOwed(TOKEN_B, address(btc), 0.01e18);
        uint256 lmMusd = musd.balanceOf(address(lm));
        uint256 lmBtc = btc.balanceOf(address(lm));
        uint256 bobMusd = musd.balanceOf(bob);

        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.RewardsForwarded(TOKEN_B, address(musd), 40e18);
        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.RewardsForwarded(TOKEN_B, address(btc), 0.03e18);
        _claim(bob, TOKEN_B, _list(address(musd), address(btc)), _list(address(btc)));

        assertEq(musd.balanceOf(bob) - bobMusd, 40e18, "MUSD fees reach the borrower");
        assertEq(btc.balanceOf(bob), 0.03e18, "BTC fees and incentives reach the borrower, measured once");
        assertEq(musd.balanceOf(address(lm)), lmMusd, "LoanManager keeps exactly what it held");
        assertEq(btc.balanceOf(address(lm)), lmBtc);
        _assertClaimablesUntouched(musdOwed, btcOwed);
    }

    function test_C10_UnregisteredGaugeReverts() public {
        _deposit(alice, TOKEN);
        address stranger = makeAddr("notAGauge");
        address[][] memory oneA = _nest(_list(address(tokenA)));
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.UnknownGauge.selector, stranger));
        lm.claimRewards(TOKEN, _list(stranger), oneA, _nest(_none()));

        address halfGauge = makeAddr("halfGauge");
        voter.setGauge(halfGauge, address(fees), address(0));
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.UnknownGauge.selector, halfGauge));
        lm.claimRewards(TOKEN, _list(halfGauge), oneA, _nest(_none()));
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.UnknownGauge.selector, address(fees)));
        lm.claimRewards(TOKEN, _list(address(fees)), oneA, _nest(_none()));
        vm.stopPrank();
    }

    function test_C10_NonWhitelistedTokenReverts() public {
        _deposit(alice, TOKEN);
        address[3] memory refused = [address(tokenC), address(ve), address(cm)];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ILoanManager.TokenNotWhitelisted.selector, refused[i]));
            _claim(alice, TOKEN, _list(address(tokenA)), _list(refused[i]));
        }
    }

    function test_C10_PaysExactlyTheMeasuredIncrease() public {
        (uint256 musdOwed, uint256 btcOwed) = _makeClaimables();
        ve.mint(bob, TOKEN_B, LOCK_BTC, m3 + uint64(WEEK), false);
        _deposit(bob, TOKEN_B);
        tokenA.mint(address(lm), 7e18);
        _owe(fees, TOKEN_B, tokenA, 5e18);
        _owe(bribes, TOKEN_B, tokenB, 3e18);

        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.RewardsForwarded(TOKEN_B, address(tokenA), 5e18);
        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.RewardsForwarded(TOKEN_B, address(tokenB), 3e18);
        _claimAB(bob, TOKEN_B);

        assertEq(tokenA.balanceOf(bob), 5e18);
        assertEq(tokenB.balanceOf(bob), 3e18);
        assertEq(tokenA.balanceOf(address(lm)), 7e18, "stray tokens already here are not paid out");
        assertEq(tokenB.balanceOf(address(lm)), 0);
        _assertClaimablesUntouched(musdOwed, btcOwed);
    }

    /// @dev Defence in depth: even if a registered reward contract pushed extra tokens in during the claim, the
    ///      payout is exactly what arrived, stray tokens stay, and claimables are untouched.
    function test_C10_DonatingRewardContractCannotMakeLoanManagerPayMoreThanArrived() public {
        (uint256 musdOwed, uint256 btcOwed) = _makeClaimables();
        ve.mint(bob, TOKEN_B, LOCK_BTC, m3 + uint64(WEEK), false);
        _deposit(bob, TOKEN_B);
        tokenA.mint(address(lm), 7e18);
        uint256 lmMusdBefore = musd.balanceOf(address(lm));

        _owe(fees, TOKEN_B, tokenA, 5e18);
        bribes.setMode(MockReward.Mode.Donate);
        bribes.setDonation(address(tokenA), 4e18);
        tokenA.mint(address(bribes), 4e18);
        MockReward donorC = new MockReward(address(voter), ve);
        donorC.setMode(MockReward.Mode.Donate);
        donorC.setDonation(address(tokenC), 2e18);
        tokenC.mint(address(donorC), 2e18);
        MockReward donorMusd = new MockReward(address(voter), ve);
        donorMusd.setMode(MockReward.Mode.Donate);
        donorMusd.setDonation(address(musd), 1e18);
        musd.mint(address(donorMusd), 1e18);
        address second = _gauge("secondGauge", donorC, donorMusd);

        address[] memory gauges = _list(gauge, second);
        address[][] memory feeTokens = new address[][](2);
        address[][] memory bribeTokens = new address[][](2);
        (feeTokens[0], feeTokens[1]) = (_list(address(tokenA)), _list(address(tokenB)));
        (bribeTokens[0], bribeTokens[1]) = (_list(address(tokenB)), _list(address(tokenB)));
        vm.prank(bob);
        lm.claimRewards(TOKEN_B, gauges, feeTokens, bribeTokens);

        assertEq(tokenA.balanceOf(bob), 9e18, "paid exactly the 9 A that arrived during the claim");
        assertEq(tokenA.balanceOf(address(lm)), 7e18, "the 7 A that were here before stay");
        assertEq(tokenC.balanceOf(bob), 0, "an unlisted token is never paid");
        assertEq(tokenC.balanceOf(address(lm)), 2e18);
        assertEq(musd.balanceOf(address(lm)), lmMusdBefore + 1e18, "unlisted MUSD pushed in becomes nobody's");
        _assertClaimablesUntouched(musdOwed, btcOwed);
    }

    function test_C10_RevertingRewardOnlyFailsItsOwnClaim() public {
        (uint256 musdOwed, uint256 btcOwed) = _makeClaimables();
        ve.mint(bob, TOKEN_B, LOCK_BTC, m3 + uint64(WEEK), false);
        _deposit(bob, TOKEN_B);
        _owe(fees, TOKEN_B, tokenA, 5e18);
        _owe(bribes, TOKEN_B, tokenB, 3e18);
        bribes.setMode(MockReward.Mode.Revert);

        vm.expectRevert(MockReward.Hostile.selector);
        _claimAB(bob, TOKEN_B);
        assertEq(tokenA.balanceOf(bob), 0);
        assertEq(fees.owed(TOKEN_B, address(tokenA)), 5e18, "nothing was taken by the failed call");

        _claim(bob, TOKEN_B, _list(address(tokenA)), _none());
        assertEq(tokenA.balanceOf(bob), 5e18, "the fee side alone still pays: the bribe side is not called");

        ve.mint(alice, TOKEN_D, LOCK_BTC, m3 + uint64(WEEK), false);
        _deposit(alice, TOKEN_D);
        _owe(fees, TOKEN_D, tokenA, 2e18);
        _claim(alice, TOKEN_D, _list(address(tokenA)), _none());
        assertEq(tokenA.balanceOf(alice), 2e18, "another borrower is untouched");
        _assertClaimablesUntouched(musdOwed, btcOwed);
    }

    function test_C10_ReentryDuringAClaimIsRefused() public {
        _deposit(alice, TOKEN);
        _owe(fees, TOKEN, tokenA, 5e18);
        fees.setMode(MockReward.Mode.Reenter);
        fees.setReentry(
            address(lm),
            abi.encodeCall(ILoanManager.claimRewards, (TOKEN, _list(gauge), _nest(_list(address(tokenA))), _nest(_none())))
        );
        _claim(alice, TOKEN, _list(address(tokenA)), _none());
        assertTrue(fees.reentryRefused(), "the reentrancy lock refused the nested claim");
        assertEq(tokenA.balanceOf(alice), 5e18, "and the outer claim paid exactly once");
        assertEq(fees.calls(), 1);
    }

    function test_C10_TokenListedTwiceIsMeasuredAndPaidOnce() public {
        _deposit(alice, TOKEN);
        _owe(fees, TOKEN, tokenA, 5e18);
        _owe(bribes, TOKEN, tokenA, 2e18);
        vm.recordLogs();
        _claim(alice, TOKEN, _list(address(tokenA), address(tokenA)), _list(address(tokenA)));
        assertEq(tokenA.balanceOf(alice), 7e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 forwarded;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ILoanManager.RewardsForwarded.selector) ++forwarded;
        }
        assertEq(forwarded, 1, "one payout for the one token");
    }

    function test_C10_ClaimWithOneSideSkipsTheOther() public {
        _deposit(alice, TOKEN);
        _owe(fees, TOKEN, tokenA, 5e18);
        vm.expectCall(address(voter), abi.encodeWithSelector(MockPoolsVoter.claimBribes.selector), 0);
        _claim(alice, TOKEN, _list(address(tokenA)), _none());
        assertEq(tokenA.balanceOf(alice), 5e18);
    }

    function test_RevertWhen_RewardListsAreBad() public {
        _deposit(alice, TOKEN);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.BadRewardTokenCount.selector, 0));
        lm.claimRewards(TOKEN, _none(), _noLists(), _noLists());
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.BadRewardTokenCount.selector, 0));
        lm.claimRewards(TOKEN, _list(gauge), _nest(_none()), _nest(_none()));

        address[] memory seventeen = new address[](17);
        for (uint256 i; i < 17; ++i) {
            seventeen[i] = address(tokenA);
        }
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.BadRewardTokenCount.selector, 17));
        lm.claimRewards(TOKEN, _list(gauge), _nest(seventeen), _nest(_none()));

        vm.expectRevert(ILoanManager.LengthMismatch.selector);
        lm.claimRewards(TOKEN, _list(gauge), _noLists(), _nest(_none()));
        vm.expectRevert(ILoanManager.LengthMismatch.selector);
        lm.claimRewards(TOKEN, _list(gauge), _nest(_none()), new address[][](2));
        vm.stopPrank();
    }

    /// @dev A loan at m1 on TOKEN, overdue and auctioned at m1 + 1 and past its 72-hour floor time, three days into
    ///      the epoch after the one the fixture starts in.
    function _unsoldAndPastFloor() internal {
        _openLoan();
        vm.warp(m1 + 1);
        lm.startAuction(TOKEN);
        vm.warp(m1 + 1 + DURATION);
    }

    function test_C5_PrepareSettleResetsEveryVoterWithALiveVote() public {
        voter.vote(TOKEN);
        validators.vote(TOKEN);
        assertEq(ve.voterCount(TOKEN), 2, "voted on both voters before deposit");
        _unsoldAndPastFloor();

        vm.expectEmit(true, false, false, true, address(lm));
        emit ILoanManager.SettlePrepared(TOKEN, true, true, false);
        vm.expectCall(address(voter), abi.encodeWithSelector(MockPoolsVoter.reset.selector, TOKEN), 1);
        vm.expectCall(address(validators), abi.encodeWithSelector(MockPoolsVoter.reset.selector, TOKEN), 1);
        vm.prank(bob);
        lm.prepareSettle(TOKEN);
        assertEq(voter.usedWeights(TOKEN), 0);
        assertEq(validators.usedWeights(TOKEN), 0);
        assertFalse(ve.voted(TOKEN), "no voter holds a vote any more");

        vm.warp(m3 + 1);
        lm.settle(TOKEN);
        cm.finalize(m1);
        vm.startPrank(lender);
        (, uint256 btcOut) = cm.redeem(m1, cm.claimUnits(m1));
        vm.stopPrank();
        assertGt(btcOut, 0, "C26: settle was reachable and the lender redeemed BTC");
    }

    function test_C5_PrepareSettleNeverResetsAVoterWithoutAVote() public {
        validators.vote(TOKEN);
        _unsoldAndPastFloor();
        vm.expectEmit(true, false, false, true, address(lm));
        emit ILoanManager.SettlePrepared(TOKEN, false, true, false);
        vm.expectCall(address(voter), abi.encodeWithSelector(MockPoolsVoter.reset.selector, TOKEN), 0);
        lm.prepareSettle(TOKEN);
        assertEq(voter.resetCount(), 0, "PoolsVoter was never reset blind");
        assertEq(validators.resetCount(), 1);
        assertFalse(ve.voted(TOKEN));
    }

    function test_C26_PrepareSettleWaitsOneEpochForAVoteCastThatEpoch() public {
        ve.setLock(TOKEN, LOCK_BTC, 0, true);
        // Before the loan opens: the loan snapshots its auction terms, so a later change would not reach it.
        vm.prank(owner);
        lm.setAuctionParams(PENALTY, FLOOR, 1 hours);
        _openLoan();
        _makeUnsafe(TOKEN);
        lm.startAuction(TOKEN);
        // A ValidatorsVoter vote in the epoch the floor time falls in, standing in for one cast before deposit.
        validators.vote(TOKEN);
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        vm.expectRevert(MockPoolsVoter.AlreadyVotedOrDeposited.selector);
        lm.prepareSettle(TOKEN);
        vm.warp((vm.getBlockTimestamp() / WEEK + 1) * WEEK + 1 hours + 1);
        lm.prepareSettle(TOKEN);
        (, uint256 end, bool isPermanent) = lm.lockOf(TOKEN);
        assertFalse(isPermanent, "unlocked once the vote was cleared");
        vm.warp(end);
        lm.settle(TOKEN);
        assertEq(cm.marketOf(m1).openLoans, 0);
    }

    function test_ClaimRebase_UnexpiredLockGrowsTheLock() public {
        _openLoan();
        dist.setClaimable(TOKEN, 0.1e18);
        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.RebaseClaimed(TOKEN, alice, 0);
        vm.prank(alice);
        lm.claimRebase(TOKEN);
        (uint256 amount,,) = lm.lockOf(TOKEN);
        assertEq(amount, 1.1e18, "the claim went into the collateral");
        assertEq(lm.claimableBtc(alice), 0);
        assertEq(btc.balanceOf(address(lm)), 0);
    }

    function test_C28_ClaimRebaseCreditsTheMeasuredBtcOfAnExpiredLock() public {
        ve.setLock(TOKEN, LOCK_BTC, m1, false);
        _deposit(alice, TOKEN);
        vm.warp(m1 + 1);
        btc.mint(address(lm), 1e18);
        dist.setClaimable(TOKEN, 0.05e18);

        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.RebaseClaimed(TOKEN, alice, 0.05e18);
        vm.prank(alice);
        lm.claimRebase(TOKEN);
        assertEq(lm.claimableBtc(alice), 0.05e18, "exactly what arrived, not the stray BTC");
        assertEq(lm.totalClaimableBtc(), 0.05e18);
        assertEq(btc.balanceOf(address(lm)), 1.05e18);

        vm.prank(alice);
        (, uint256 btcOut) = lm.claim();
        assertEq(btcOut, 0.05e18);
        assertEq(btc.balanceOf(address(lm)), 1e18, "the stray BTC is still nobody's");
        assertEq(lm.totalClaimableBtc(), 0);
    }

    function test_ClaimRebase_NothingToClaimChangesNothing() public {
        _deposit(alice, TOKEN);
        vm.prank(alice);
        lm.claimRebase(TOKEN);
        assertEq(lm.claimableBtc(alice), 0);
        (uint256 amount,,) = lm.lockOf(TOKEN);
        assertEq(amount, uint256(int256(LOCK_BTC)));
    }

    function test_C19_PassThroughsAndRollRunWhileBorrowsArePaused() public {
        uint256 face = _openLoan();
        vm.startPrank(guardian);
        lm.setBorrowsPaused(true);
        cm.setOffersPaused(true);
        vm.stopPrank();

        _vote(alice, TOKEN);
        _owe(fees, TOKEN, tokenA, 1e18);
        _owe(bribes, TOKEN, tokenB, 1e18);
        _claimAB(alice, TOKEN);
        dist.setClaimable(TOKEN, 0.01e18);
        // An exact refinance: a roll that pays out new MUSD is new borrowing and is paused.
        (uint256[] memory ids, uint128[] memory amounts) = _one(offerM2, uint128(face));
        vm.startPrank(alice);
        lm.claimRebase(TOKEN);
        lm.extendLock(TOKEN, 28 days);
        lm.roll(TOKEN, m2, ids, amounts, 5_000, 0);
        vm.stopPrank();

        vm.warp(_nextEpochWindow());
        vm.prank(alice);
        lm.resetVotes(TOKEN);

        assertFalse(ve.voted(TOKEN));
        assertEq(tokenA.balanceOf(alice), 1e18);
        assertEq(lm.loanOf(TOKEN).maturity, m2, "rolled while paused");
    }
}

/// @notice prepareSettle on a chain whose veBTC has no secondary voters: LoanManager is deployed with no
/// ValidatorsVoter and skips it, and a PoolsVoter vote alone is cleared.
contract PrepareSettleWithoutValidatorsTest is LoanFixture {
    function _settings() internal view override returns (ILoanManager.Settings memory settings) {
        settings = super._settings();
        settings.validatorsVoter = address(0);
    }

    function test_C5_PrepareSettleSkipsAnUnsetValidatorsVoter() public {
        assertEq(address(lm.validatorsVoter()), address(0));
        voter.vote(TOKEN);
        _openLoan();
        vm.warp(m1 + 1);
        lm.startAuction(TOKEN);
        vm.warp(m1 + 1 + DURATION);

        vm.expectEmit(true, false, false, true, address(lm));
        emit ILoanManager.SettlePrepared(TOKEN, true, false, false);
        lm.prepareSettle(TOKEN);
        assertFalse(ve.voted(TOKEN));
        vm.warp(m3 + 1);
        lm.settle(TOKEN);
        assertEq(cm.marketOf(m1).openLoans, 0);
    }
}
