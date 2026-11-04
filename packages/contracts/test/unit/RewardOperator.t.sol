// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Unit tests for the reward operator (C36, C37) and the reward-token check (F36), on the real CreditMarkets and
// LoanManager with mocks for veBTC, PoolsVoter, the reward contracts and tokens: only the borrower sets or clears
// the operator; the operator is deleted on every path the NFT leaves by, so a returning tokenId has none; it
// passes the borrower check for claimRewards on its own tokenId only and is refused everywhere else; a claim pays
// whoever called it and the borrower's own claim still works; and a token is accepted exactly when the reward
// contract on its side lists it, whether or not PoolsVoter whitelists it.
// It does NOT cover: PayDown, which is not built yet; Mezo's real reward contracts and their isReward lists
// (test/fork/PassThroughFork.t.sol); a reward token whose own code misbehaves (a stated non-goal); or the
// operator inside the randomised invariant run.

import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {IPoolsVoter} from "../../src/interfaces/IPoolsVoter.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";
import {MockReward} from "../utils/MockReward.sol";
import {MockToken} from "../utils/MockToken.sol";

contract RewardOperatorTest is LoanFixture {
    uint256 internal constant TOKEN_B = 8;

    address internal operator = makeAddr("operator");
    address internal gauge = makeAddr("gauge");
    MockToken internal tokenA;
    MockToken internal tokenC;
    MockReward internal fees;
    MockReward internal bribes;

    function setUp() public override {
        super.setUp();
        tokenA = new MockToken("AAA");
        tokenC = new MockToken("CCC");
        fees = new MockReward(address(voter), ve);
        bribes = new MockReward(address(voter), ve);
        voter.setGauge(gauge, address(fees), address(bribes));
        // A MUSD/BTC pool's own tokens on both sides, plus one posted incentive, as Mezo's contracts list them.
        address[3] memory listed = [address(musd), address(btc), address(tokenA)];
        for (uint256 i; i < listed.length; ++i) {
            fees.setReward(listed[i], true);
            bribes.setReward(listed[i], true);
        }
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

    function _name(address who, uint256 tokenId, address op) internal {
        vm.prank(who);
        lm.setRewardOperator(tokenId, op);
    }

    function _claim(address who, uint256 tokenId, address[] memory feeTokens, address[] memory bribeTokens) internal {
        vm.prank(who);
        lm.claimRewards(tokenId, _list(gauge), _nest(feeTokens), _nest(bribeTokens));
    }

    /// @dev MUSD and BTC pool fees and a tokenA incentive owed to `tokenId`.
    function _oweMixed(uint256 tokenId) internal {
        musd.mint(address(fees), 40e18);
        fees.setOwed(tokenId, address(musd), 40e18);
        btc.mint(address(fees), 0.02e18);
        fees.setOwed(tokenId, address(btc), 0.02e18);
        tokenA.mint(address(bribes), 5e18);
        bribes.setOwed(tokenId, address(tokenA), 5e18);
    }

    function _claimMixed(address who, uint256 tokenId) internal {
        _claim(who, tokenId, _list(address(musd), address(btc)), _list(address(tokenA)));
    }

    function _assertNoRecord(uint256 tokenId) internal view {
        ILoanManager.Position memory position = lm.positionOf(tokenId);
        assertEq(position.borrower, address(0), "the record was deleted");
        assertEq(position.rewardOperator, address(0), "C36: the operator left with the record");
    }

    /// @dev The old operator's claim on a tokenId whose record it no longer belongs to stops at the borrower check.
    function _expectOldOperatorRefused(uint256 tokenId) internal {
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotBorrower.selector, tokenId));
        _claim(operator, tokenId, _list(address(musd)), new address[](0));
    }

    function test_C36_BorrowerSetsAndClearsTheOperator() public {
        _openLoan();
        // Never paused: naming or clearing works while new borrows are stopped.
        vm.prank(guardian);
        lm.setBorrowsPaused(true);

        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.RewardOperatorSet(TOKEN, operator);
        _name(alice, TOKEN, operator);
        assertEq(lm.positionOf(TOKEN).rewardOperator, operator);
        assertEq(lm.positionOf(TOKEN).borrower, alice, "naming an operator never changes the borrower");

        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.RewardOperatorSet(TOKEN, address(0));
        _name(alice, TOKEN, address(0));
        assertEq(lm.positionOf(TOKEN).rewardOperator, address(0), "the zero address clears it");
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotBorrower.selector, TOKEN));
        _claim(operator, TOKEN, _list(address(musd)), new address[](0));
    }

    function test_C36_NonBorrowerCannotSetTheOperator() public {
        _deposit(alice, TOKEN);
        address[4] memory others = [bob, owner, guardian, operator];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotBorrower.selector, TOKEN));
            _name(others[i], TOKEN, others[i]);
        }
        assertEq(lm.positionOf(TOKEN).rewardOperator, address(0));

        ve.forceTransfer(address(lm), bob, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotInCustody.selector, TOKEN));
        _name(alice, TOKEN, operator);
    }

    function test_C36_LoanManagerCannotBeTheOperator() public {
        _deposit(alice, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.InvalidOperator.selector, address(lm)));
        _name(alice, TOKEN, address(lm));
    }

    function test_C37_OperatorClaimsAndIsPaid_BorrowerGetsNothingFromThatClaim() public {
        _openLoan();
        _name(alice, TOKEN, operator);
        _oweMixed(TOKEN);
        uint256 aliceMusd = musd.balanceOf(alice);
        uint256 lmMusd = musd.balanceOf(address(lm));

        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.RewardsForwarded(TOKEN, address(musd), 40e18);
        _claimMixed(operator, TOKEN);

        assertEq(musd.balanceOf(operator), 40e18, "C37: the operator's claim pays the operator");
        assertEq(btc.balanceOf(operator), 0.02e18);
        assertEq(tokenA.balanceOf(operator), 5e18);
        assertEq(musd.balanceOf(alice), aliceMusd, "the borrower receives nothing from the operator's claim");
        assertEq(btc.balanceOf(alice), 0);
        assertEq(tokenA.balanceOf(alice), 0);
        assertEq(musd.balanceOf(address(lm)), lmMusd, "LoanManager keeps exactly what it held");
        assertEq(lm.totalClaimableMusd() + lm.totalClaimableBtc(), 0, "C28: no claimable moved");
    }

    function test_C37_BorrowerStillClaimsWhileAnOperatorIsNamed() public {
        _openLoan();
        _name(alice, TOKEN, operator);
        _oweMixed(TOKEN);
        uint256 aliceMusd = musd.balanceOf(alice);

        _claimMixed(alice, TOKEN);

        assertEq(musd.balanceOf(alice) - aliceMusd, 40e18, "C37: the borrower's own claim pays the borrower");
        assertEq(btc.balanceOf(alice), 0.02e18);
        assertEq(tokenA.balanceOf(alice), 5e18);
        assertEq(musd.balanceOf(operator) + btc.balanceOf(operator) + tokenA.balanceOf(operator), 0);
        assertEq(lm.positionOf(TOKEN).rewardOperator, operator, "the operator stays named");
    }

    function test_C36_OperatorIsRefusedEveryOtherBorrowerAction() public {
        _openLoan();
        _name(alice, TOKEN, operator);
        bytes memory refused = abi.encodeWithSelector(ILoanManager.NotBorrower.selector, TOKEN);
        address[] memory pools = _list(makeAddr("pool"));
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        (uint256[] memory ids, uint128[] memory amounts) = _one(offerM2, PRINCIPAL);

        vm.startPrank(operator);
        vm.expectRevert(refused);
        lm.claimRebase(TOKEN);
        vm.expectRevert(refused);
        lm.vote(TOKEN, pools, weights);
        vm.expectRevert(refused);
        lm.resetVotes(TOKEN);
        vm.expectRevert(refused);
        lm.extendLock(TOKEN, 28 days);
        vm.expectRevert(refused);
        lm.borrow(TOKEN, m2, ids, amounts, 5_000);
        vm.expectRevert(refused);
        lm.roll(TOKEN, m2, ids, amounts, 5_000, type(uint256).max);
        vm.expectRevert(refused);
        lm.withdrawCollateral(TOKEN);
        vm.expectRevert(refused);
        lm.setRewardOperator(TOKEN, address(0));
        vm.stopPrank();
        assertEq(lm.positionOf(TOKEN).rewardOperator, operator);
        assertEq(lm.positionOf(TOKEN).borrower, alice);
    }

    function test_C36_OperatorReachesOnlyTheTokenIdThatNamedIt() public {
        ve.mint(alice, TOKEN_B, LOCK_BTC, m3, false);
        _deposit(alice, TOKEN);
        _deposit(alice, TOKEN_B);
        _name(alice, TOKEN, operator);
        _oweMixed(TOKEN_B);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotBorrower.selector, TOKEN_B));
        _claimMixed(operator, TOKEN_B);
    }

    function test_C36_OperatorCannotClaimDuringAnAuction() public {
        _openLoan();
        _name(alice, TOKEN, operator);
        _makeUnsafe(TOKEN);
        lm.startAuction(TOKEN);
        _oweMixed(TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LoanInAuction.selector, TOKEN));
        _claimMixed(operator, TOKEN);
    }

    function test_C36_OperatorGoneAfterWithdrawAndNoneOnRedeposit() public {
        _deposit(alice, TOKEN);
        _name(alice, TOKEN, operator);
        vm.prank(alice);
        lm.withdrawCollateral(TOKEN);
        _assertNoRecord(TOKEN);

        _deposit(alice, TOKEN);
        assertEq(lm.positionOf(TOKEN).borrower, alice);
        assertEq(lm.positionOf(TOKEN).rewardOperator, address(0), "C36: a returning tokenId has no operator");
        _expectOldOperatorRefused(TOKEN);
    }

    function test_C36_OperatorGoneAfterPurchaseAndTheBuyerStartsWithNone() public {
        _openLoan();
        _name(alice, TOKEN, operator);
        _makeUnsafe(TOKEN);
        lm.startAuction(TOKEN);
        vm.warp(vm.getBlockTimestamp() + DURATION / 3);
        vm.prank(buyer);
        lm.purchase(TOKEN, type(uint256).max, vm.getBlockTimestamp());
        _assertNoRecord(TOKEN);

        feed.setPrice(PRICE);
        _deposit(buyer, TOKEN);
        assertEq(lm.positionOf(TOKEN).rewardOperator, address(0), "C36: the buyer's deposit has no operator");
        _expectOldOperatorRefused(TOKEN);
    }

    function test_C36_OperatorGoneAfterSettle() public {
        _openLoan();
        _name(alice, TOKEN, operator);
        vm.warp(m1 + 1);
        lm.startAuction(TOKEN);
        vm.warp(m3 + 1);
        lm.settle(TOKEN);
        _assertNoRecord(TOKEN);
    }

    function test_C36_OperatorGoneAfterWriteOff() public {
        _openLoan();
        _name(alice, TOKEN, operator);
        ve.forceTransfer(address(lm), bob, TOKEN);
        lm.writeOff(TOKEN);
        _assertNoRecord(TOKEN);

        _deposit(bob, TOKEN);
        assertEq(lm.positionOf(TOKEN).rewardOperator, address(0), "C36: a returning tokenId has no operator");
        _expectOldOperatorRefused(TOKEN);
    }

    /// @dev rescuePosition only moves a token with no record, so such a token can never have had an operator.
    function test_C36_StrayTokenNeverGetsAnOperatorAndIsRescuedWithNone() public {
        vm.prank(alice);
        ve.transferFrom(alice, address(lm), TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.NotBorrower.selector, TOKEN));
        _name(alice, TOKEN, operator);

        vm.prank(owner);
        lm.rescuePosition(TOKEN, alice);
        _assertNoRecord(TOKEN);
        _deposit(alice, TOKEN);
        assertEq(lm.positionOf(TOKEN).rewardOperator, address(0));
    }

    /// @dev The live failure on testnet: MUSD is a reward of the MUSD/BTC pool's contracts but PoolsVoter does not
    ///      whitelist it. The mock voter keeps no whitelist at all, so a whitelist read would revert the claim.
    function test_F36_PoolTokenTheVoterDoesNotWhitelistIsClaimed() public {
        _deposit(alice, TOKEN);
        musd.mint(address(bribes), 3e18);
        bribes.setOwed(TOKEN, address(musd), 3e18);
        btc.mint(address(fees), 0.01e18);
        fees.setOwed(TOKEN, address(btc), 0.01e18);
        uint256 aliceMusd = musd.balanceOf(alice);

        vm.expectCall(address(voter), abi.encodeWithSelector(IPoolsVoter.isWhitelistedToken.selector), 0);
        _claim(alice, TOKEN, _list(address(btc)), _list(address(musd)));

        assertEq(musd.balanceOf(alice) - aliceMusd, 3e18, "F36: the MUSD incentive reached the borrower");
        assertEq(btc.balanceOf(alice), 0.01e18, "F36: the BTC pool fee reached the borrower");
    }

    function test_F36_TokenTheRewardContractDoesNotListReverts() public {
        _deposit(alice, TOKEN);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.TokenNotReward.selector, address(fees), address(tokenC)));
        _claim(alice, TOKEN, _list(address(tokenC)), new address[](0));

        // The check is per side: listed by the fee contract only, the token is refused on the incentive side.
        fees.setReward(address(tokenC), true);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.TokenNotReward.selector, address(bribes), address(tokenC)));
        _claim(alice, TOKEN, _list(address(tokenC)), _list(address(tokenC)));

        vm.expectRevert(abi.encodeWithSelector(ILoanManager.TokenNotReward.selector, address(fees), address(ve)));
        _claim(alice, TOKEN, _list(address(ve)), new address[](0));
    }
}
