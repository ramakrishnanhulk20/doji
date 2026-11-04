// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Audit L-01 (Wave 2). Before the fix, claimRewards reverted LoanInAuction once a loan was in auction, for the
// borrower and for the position's reward operator alike, so pool rewards the position had already earned could no
// longer be claimed or used to repay the loan. They then either passed to the buyer with the NFT (Mezo's reward
// contracts pay the current owner of the tokenId at claim time) or, after a settle burned the NFT, could never be
// claimed by anyone. claimRewards now runs during an auction and every other pass-through still does not (C4).
// Test 1 asserts the borrower can still claim during the auction (failed before the fix). Test 2 has the borrower
// claim, lets the position be sold, and asserts the buyer collects nothing the borrower earned (failed before the
// fix with 500 MUSD). Test 3 is the Wave 2 case that matters most: PayDown, named as operator, harvests during the
// auction with enough MUSD rewards to repay the loan in full, which ends the auction (failed before the fix).
// It does NOT cover: Mezo's real reward contracts (the payee rule is taken from reference/briefs/swap-brief.md
// section 4 and MockReward, not run on a fork), the settle path where the burned NFT strands the rewards, or what
// a claim during an auction should do to the auction itself (a full repayment by PayDown ends it, C9).

import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {PayDown} from "../../src/PayDown.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";
import {MockReward} from "../utils/MockReward.sol";
import {MockRouter} from "../utils/MockRouter.sol";

contract RewardsStrandedInAuctionTest is LoanFixture {
    uint256 internal constant EARNED = 500e18;

    address internal gauge = makeAddr("gauge");
    MockReward internal fees;
    MockReward internal bribes;

    function setUp() public override {
        super.setUp();
        fees = new MockReward(address(voter), ve);
        bribes = new MockReward(address(voter), ve);
        voter.setGauge(gauge, address(fees), address(bribes));
        fees.setReward(address(musd), true);
        bribes.setReward(address(musd), true);
    }

    function _list(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _nest(address[] memory inner) internal pure returns (address[][] memory out) {
        out = new address[][](1);
        out[0] = inner;
    }

    /// @dev Alice's loan goes overdue and the overdue auction starts, with 500 MUSD of pool fees already earned.
    function _overdueAuctionWithEarnedRewards() internal {
        _openLoan();
        musd.mint(address(fees), EARNED);
        fees.setOwed(TOKEN, address(musd), EARNED);
        vm.warp(m1 + 1);
        lm.startAuction(TOKEN);
    }

    function test_L01_BorrowerCanStillClaimEarnedRewardsWhileTheLoanIsInAuction() public {
        _overdueAuctionWithEarnedRewards();
        uint256 before = musd.balanceOf(alice);
        vm.prank(alice);
        lm.claimRewards(TOKEN, _list(gauge), _nest(_list(address(musd))), _nest(new address[](0)));
        assertEq(musd.balanceOf(alice) - before, EARNED, "L-01: earned rewards were out of reach during the auction");
    }

    function test_L01_BuyerDoesNotCollectTheBorrowersEarnedRewards() public {
        _overdueAuctionWithEarnedRewards();
        // The borrower takes what the position earned before it is sold. Before the fix this reverted and was
        // ignored here, so the test measured what was left for the buyer; now it succeeds and nothing is left.
        vm.prank(alice);
        try lm.claimRewards(TOKEN, _list(gauge), _nest(_list(address(musd))), _nest(new address[](0))) {} catch {}
        vm.warp(vm.getBlockTimestamp() + DURATION);
        vm.prank(buyer);
        lm.purchase(TOKEN, type(uint256).max, vm.getBlockTimestamp());
        assertEq(ve.ownerOf(TOKEN), buyer, "the buyer now owns the position");

        uint256 before = musd.balanceOf(buyer);
        vm.prank(buyer);
        voter.claimFees(_list(address(fees)), _nest(_list(address(musd))), TOKEN);
        assertEq(musd.balanceOf(buyer) - before, 0, "L-01: the buyer collected rewards the borrower earned");
    }

    function test_L01_PayDownHarvestCuresTheAuctionWithEarnedRewards() public {
        MockRouter router = new MockRouter(makeAddr("factory"));
        PayDown pd = new PayDown(address(lm), address(router), owner, guardian, 100);
        uint256 face = _openLoan();
        vm.prank(alice);
        lm.setRewardOperator(TOKEN, address(pd));
        uint256 earned = face + 100e18;
        musd.mint(address(fees), earned);
        fees.setOwed(TOKEN, address(musd), earned);
        vm.warp(m1 + 1);
        lm.startAuction(TOKEN);

        uint256 aliceBefore = musd.balanceOf(alice);
        pd.harvest(TOKEN, _list(gauge), _nest(_list(address(musd))), _nest(new address[](0)));

        assertEq(uint8(lm.loanOf(TOKEN).state), uint8(ILoanManager.LoanState.None), "L-01: the loan is repaid");
        assertEq(lm.auctionOf(TOKEN).startTime, 0, "L-01: the auction ended with the repayment");
        assertEq(musd.balanceOf(alice) - aliceBefore, 100e18, "L-01: the surplus reward reaches the borrower");
    }
}
