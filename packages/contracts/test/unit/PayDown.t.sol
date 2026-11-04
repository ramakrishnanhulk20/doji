// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Unit tests for PayDown (C38 to C42, Ram's F26 ruling, C7) on the real CreditMarkets and LoanManager, with mocks
// for veBTC, PoolsVoter, the reward contracts, the price feed and Mezo's Router: MUSD rewards repay the loan; BTC
// is sold only as far as the debt needs, along the fixed route, never below the oracle floor, with the MUSD that
// arrives measured; no loan means no sale; any other token is sold only by the borrower's own harvestAndSwap, at
// the borrower's minimum, along a route that ends in MUSD; duplicates, strays, re-entry through a route, pause,
// approvals and auctions; and a fuzz run showing every gain is either repaid or reaches the borrower.
// It does NOT cover: Mezo's real Router, pools and BTC (test/fork/PayDownFork.t.sol); price moves inside the
// slippage allowance or the oracle's 60-second window (stated non-goals); a reward token whose own code misbehaves
// during the claim; fee-on-transfer reward tokens; or the keeper that decides what to harvest.

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {IMezoRouter} from "../../src/interfaces/IMezoRouter.sol";
import {IPayDown} from "../../src/interfaces/IPayDown.sol";
import {PayDown} from "../../src/PayDown.sol";
import {LoanFixture} from "../utils/LoanFixture.sol";
import {MockReward} from "../utils/MockReward.sol";
import {MockToken} from "../utils/MockToken.sol";
import {MockRouter, CallbackToken} from "../utils/MockRouter.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

contract PayDownTest is LoanFixture {
    uint256 internal constant TOKEN_B = 8;
    uint16 internal constant SLIPPAGE = 100;

    address internal gauge = makeAddr("gauge");
    address internal keeper = makeAddr("keeper");
    address internal factory = makeAddr("factory");
    MockToken internal tokenA;
    MockToken internal tokenC;
    MockReward internal fees;
    MockReward internal bribes;
    MockRouter internal router;
    PayDown internal pd;
    uint256 internal face;

    function setUp() public override {
        super.setUp();
        tokenA = new MockToken("AAA");
        tokenC = new MockToken("CCC");
        fees = new MockReward(address(voter), ve);
        bribes = new MockReward(address(voter), ve);
        voter.setGauge(gauge, address(fees), address(bribes));
        address[4] memory listed = [address(musd), address(btc), address(tokenA), address(tokenC)];
        for (uint256 i; i < listed.length; ++i) {
            fees.setReward(listed[i], true);
            bribes.setReward(listed[i], true);
        }

        router = new MockRouter(factory);
        router.setRate(address(btc), address(musd), PRICE);
        musd.mint(address(router), 100_000_000e18);
        pd = new PayDown(address(lm), address(router), owner, guardian, SLIPPAGE);

        face = _openLoan();
        vm.prank(alice);
        lm.setRewardOperator(TOKEN, address(pd));
    }

    function _list(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _list(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        (out[0], out[1]) = (a, b);
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _nest(address[] memory inner) internal pure returns (address[][] memory out) {
        out = new address[][](1);
        out[0] = inner;
    }

    function _hop(address from, address to) internal view returns (IMezoRouter.Route memory) {
        return IMezoRouter.Route({from: from, to: to, stable: false, factory: factory});
    }

    function _route(address from, address to) internal view returns (IMezoRouter.Route[] memory routes) {
        routes = new IMezoRouter.Route[](1);
        routes[0] = _hop(from, to);
    }

    function _route(address from, address via, address to) internal view returns (IMezoRouter.Route[] memory routes) {
        routes = new IMezoRouter.Route[](2);
        (routes[0], routes[1]) = (_hop(from, via), _hop(via, to));
    }

    function _oneSwap(address token, uint256 minOut, IMezoRouter.Route[] memory routes)
        internal
        pure
        returns (IPayDown.Swap[] memory swaps)
    {
        swaps = new IPayDown.Swap[](1);
        swaps[0] = IPayDown.Swap({token: token, amountOutMin: minOut, routes: routes});
    }

    /// @dev Mints `amount` of `token` into a reward contract and owes it to `tokenId`.
    function _owe(MockReward reward, uint256 tokenId, address token, uint256 amount) internal {
        IMintable(token).mint(address(reward), amount);
        reward.setOwed(tokenId, token, amount);
    }

    function _harvest(address caller, uint256 tokenId, address[] memory feeList, address[] memory bribeList)
        internal
        returns (uint256)
    {
        vm.prank(caller);
        return pd.harvest(tokenId, _list(gauge), _nest(feeList), _nest(bribeList));
    }

    function _harvestAndSwap(
        address caller,
        uint256 tokenId,
        address[] memory feeList,
        address[] memory bribeList,
        IPayDown.Swap[] memory swaps
    ) internal returns (uint256) {
        vm.prank(caller);
        return pd.harvestAndSwap(tokenId, _list(gauge), _nest(feeList), _nest(bribeList), swaps);
    }

    /// @dev The oracle floor written out the plain way, independent of PayDown's own code.
    function _floor(uint256 btcAmount, uint256 price) internal pure returns (uint256) {
        return btcAmount * price / 1e18 * (10_000 - SLIPPAGE) / 10_000;
    }

    /// @dev C40 as a property: the BTC sold covers `need` at its floor, and one wei less would not have.
    function _assertCovers(uint256 sold, uint256 need, uint256 price) internal pure {
        assertGe(_floor(sold, price), need, "C40: the BTC sold covers the debt at its floor");
        assertLt(_floor(sold - 1, price), need, "C40: one wei less would not cover it, so no more was sold");
    }

    function _assertNoAllowances() internal view {
        address[3] memory tokens = [address(musd), address(btc), address(tokenA)];
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(IERC20(tokens[i]).allowance(address(pd), address(router)), 0, "C40: no allowance to the Router");
            assertEq(IERC20(tokens[i]).allowance(address(pd), address(lm)), 0, "C40: no allowance to LoanManager");
        }
    }

    function test_C40_MusdRewardsRepayTheLoan() public {
        _owe(fees, TOKEN, address(musd), 1_000e18);
        uint256 aliceMusd = musd.balanceOf(alice);

        vm.expectEmit(true, true, false, true, address(pd));
        emit IPayDown.Harvested(TOKEN, keeper, 1_000e18, 0, 0);
        uint256 repaid = _harvest(keeper, TOKEN, _list(address(musd)), _none());

        assertEq(repaid, 1_000e18, "anyone's harvest sends the MUSD reward to the loan");
        assertEq(lm.owedOf(TOKEN), face - 1_000e18);
        assertEq(musd.balanceOf(alice), aliceMusd, "nothing was left over for the borrower");
        assertEq(musd.balanceOf(address(pd)), 0, "PayDown keeps nothing");
        assertEq(router.swaps(), 0, "MUSD is never sold");
        _assertNoAllowances();
    }

    function test_C40_BtcSoldOnlyAsMuchAsTheDebtNeeds_RestGoesToTheBorrower() public {
        _owe(fees, TOKEN, address(musd), 10_000e18);
        _owe(fees, TOKEN, address(btc), 1e18);
        uint256 aliceMusd = musd.balanceOf(alice);

        uint256 repaid = _harvest(keeper, TOKEN, _list(address(musd), address(btc)), _none());

        uint256 sold = router.lastAmountIn();
        _assertCovers(sold, face - 10_000e18, PRICE);
        assertEq(router.lastAmountOutMin(), _floor(sold, PRICE), "C39: the oracle floor is the Router's minimum");
        (address from, address to, bool stable, address hopFactory) = router.lastFirstHop();
        assertEq(from, address(btc), "C39: the fixed route starts at BTC");
        assertEq(to, address(musd), "C39: and ends at MUSD");
        assertFalse(stable, "C39: through the volatile pool");
        assertEq(hopFactory, factory, "C39: of the Router's default factory");
        assertEq(router.lastHops(), 1);
        assertEq(btc.balanceOf(alice), 1e18 - sold, "C40: the BTC the debt did not need went to the borrower");
        assertEq(repaid, face, "the loan was repaid in full");
        assertEq(uint8(lm.loanOf(TOKEN).state), uint8(ILoanManager.LoanState.None));
        assertEq(musd.balanceOf(alice) - aliceMusd, 10_000e18 + sold * PRICE / 1e18 - face, "MUSD over the debt");
        assertEq(musd.balanceOf(address(pd)) + btc.balanceOf(address(pd)), 0, "PayDown keeps nothing");
        _assertNoAllowances();
    }

    function test_C39_BtcSaleRevertsBelowFloorWhenPaid5PercentUnder_PassesAtHalfPercent() public {
        _owe(fees, TOKEN, address(btc), 0.1e18);
        address[] memory btcOnly = _list(address(btc));
        uint256 value = 8_000e18;
        uint256 floor = _floor(0.1e18, PRICE);

        // A sandwich seen from PayDown: the Router's own quote clears the floor, but 5% less MUSD arrives.
        router.setShortBps(500);
        vm.expectRevert(abi.encodeWithSelector(IPayDown.BelowFloor.selector, value * 95 / 100, floor));
        _harvest(keeper, TOKEN, btcOnly, _none());

        // The pool itself 5% under the oracle: the floor PayDown hands the Router stops the sale there.
        router.setShortBps(0);
        router.setRate(address(btc), address(musd), PRICE * 95 / 100);
        vm.expectRevert(MockRouter.InsufficientOutputAmount.selector);
        _harvest(keeper, TOKEN, btcOnly, _none());

        // Half a percent short is inside the 1% allowance.
        router.setRate(address(btc), address(musd), PRICE);
        router.setShortBps(50);
        uint256 repaid = _harvest(keeper, TOKEN, btcOnly, _none());
        assertEq(repaid, value * 9_950 / 10_000, "the MUSD that actually arrived was repaid");
        assertEq(btc.balanceOf(address(pd)), 0);
        _assertNoAllowances();
    }

    function test_C7_StaleOrZeroPriceRevertsTheHarvest() public {
        _owe(fees, TOKEN, address(musd), 100e18);
        address[] memory musdOnly = _list(address(musd));

        feed.setStale(true);
        vm.expectRevert(IPayDown.PriceUnavailable.selector);
        _harvest(keeper, TOKEN, musdOnly, _none());

        feed.setStale(false);
        feed.setPrice(0);
        vm.expectRevert(IPayDown.PriceUnavailable.selector);
        _harvest(keeper, TOKEN, musdOnly, _none());

        feed.setPrice(PRICE);
        assertEq(_harvest(keeper, TOKEN, musdOnly, _none()), 100e18, "a fresh price lets it run");
    }

    function test_C40_NoOpenLoan_NothingSold_EveryGainToTheBorrower() public {
        ve.mint(bob, TOKEN_B, LOCK_BTC, m3, false);
        _deposit(bob, TOKEN_B);
        vm.prank(bob);
        lm.setRewardOperator(TOKEN_B, address(pd));
        router.setRate(address(tokenA), address(musd), 2e18);
        _owe(fees, TOKEN_B, address(musd), 500e18);
        _owe(fees, TOKEN_B, address(btc), 0.5e18);
        _owe(bribes, TOKEN_B, address(tokenA), 5e18);
        uint256 bobMusd = musd.balanceOf(bob);

        vm.expectEmit(true, true, false, true, address(pd));
        emit IPayDown.Harvested(TOKEN_B, keeper, 0, 0, 0);
        uint256 repaid = _harvest(keeper, TOKEN_B, _list(address(musd), address(btc)), _list(address(tokenA)));

        assertEq(repaid, 0);
        assertEq(router.swaps(), 0, "C40: no loan, no sale");
        assertEq(musd.balanceOf(bob) - bobMusd, 500e18);
        assertEq(btc.balanceOf(bob), 0.5e18);
        assertEq(tokenA.balanceOf(bob), 5e18);

        // The borrower's own harvestAndSwap sells nothing either while there is no loan to repay.
        _owe(bribes, TOKEN_B, address(tokenA), 5e18);
        _harvestAndSwap(
            bob, TOKEN_B, _none(), _list(address(tokenA)), _oneSwap(address(tokenA), 1, _route(address(tokenA), address(musd)))
        );
        assertEq(router.swaps(), 0, "C40: no loan, no sale, even when the borrower asks");
        assertEq(tokenA.balanceOf(bob), 10e18);
        assertEq(musd.balanceOf(address(pd)) + btc.balanceOf(address(pd)) + tokenA.balanceOf(address(pd)), 0);
    }

    function test_C40_MusdOverTheDebtGoesToTheBorrowerAndTheLoanCloses() public {
        _owe(fees, TOKEN, address(musd), face + 500e18);
        _owe(fees, TOKEN, address(btc), 0.3e18);
        uint256 aliceMusd = musd.balanceOf(alice);

        vm.expectEmit(true, true, false, true, address(lm));
        emit ILoanManager.LoanClosed(TOKEN, m1);
        uint256 repaid = _harvest(keeper, TOKEN, _list(address(musd), address(btc)), _none());

        assertEq(repaid, face, "C40: repays no more than is owed");
        assertEq(uint8(lm.loanOf(TOKEN).state), uint8(ILoanManager.LoanState.None), "the loan closed");
        assertEq(musd.balanceOf(alice) - aliceMusd, 500e18, "MUSD over the debt went to the borrower");
        assertEq(btc.balanceOf(alice), 0.3e18, "C40: the MUSD covered the debt, so no BTC was sold");
        assertEq(router.swaps(), 0);
        assertEq(lm.positionOf(TOKEN).borrower, alice, "the position stays the borrower's");
    }

    function test_F26_AnotherTokenInHarvestGoesToTheBorrowerUnsold() public {
        router.setRate(address(tokenA), address(musd), 2e18);
        _owe(fees, TOKEN, address(musd), 100e18);
        _owe(bribes, TOKEN, address(tokenA), 5e18);

        uint256 repaid = _harvest(keeper, TOKEN, _list(address(musd)), _list(address(tokenA)));

        assertEq(repaid, 100e18);
        assertEq(tokenA.balanceOf(alice), 5e18, "F26: a token with no reference price reached the borrower unsold");
        assertEq(router.swaps(), 0, "F26: a keeper's harvest never sells it");
        assertEq(tokenA.balanceOf(address(pd)), 0);
    }

    function test_F26_HarvestAndSwapSellsAtTheBorrowersMinimumAndRepays() public {
        router.setRate(address(tokenA), address(musd), 2e18);
        router.setRate(address(tokenC), address(btc), 0.0001e18);
        _owe(bribes, TOKEN, address(tokenA), 100e18);
        _owe(bribes, TOKEN, address(tokenC), 50e18);
        _owe(fees, TOKEN, address(btc), 1e18);
        address[] memory feeList = _list(address(btc));
        address[] memory bribeList = _list(address(tokenA), address(tokenC));
        IMezoRouter.Route[] memory routeA = _route(address(tokenA), address(musd));

        // The minimum is checked against the MUSD that arrives: 1% short of the Router's own figure misses it.
        router.setShortBps(100);
        vm.expectRevert(abi.encodeWithSelector(IPayDown.BelowFloor.selector, 198e18, 199e18));
        _harvestAndSwap(alice, TOKEN, feeList, bribeList, _oneSwap(address(tokenA), 199e18, routeA));
        router.setShortBps(0);

        IPayDown.Swap[] memory swaps = new IPayDown.Swap[](2);
        swaps[0] = IPayDown.Swap({token: address(tokenA), amountOutMin: 190e18, routes: routeA});
        swaps[1] = IPayDown.Swap({
            token: address(tokenC),
            amountOutMin: 399e18,
            routes: _route(address(tokenC), address(btc), address(musd))
        });
        vm.expectCall(
            address(router),
            abi.encodeCall(
                MockRouter.swapExactTokensForTokens, (100e18, 190e18, routeA, address(pd), vm.getBlockTimestamp())
            )
        );
        vm.expectEmit(true, true, false, true, address(pd));
        emit IPayDown.RewardSwapped(TOKEN, address(tokenA), 100e18, 200e18);
        vm.expectEmit(true, true, false, true, address(pd));
        emit IPayDown.RewardSwapped(TOKEN, address(tokenC), 50e18, 400e18);
        uint256 repaid = _harvestAndSwap(alice, TOKEN, feeList, bribeList, swaps);

        // The swaps ran first, so the BTC sold covers only the debt their 600 MUSD left.
        uint256 sold = router.lastAmountIn();
        _assertCovers(sold, face - 600e18, PRICE);
        assertEq(repaid, face, "the swapped MUSD and the BTC sale repaid the loan");
        assertEq(tokenA.balanceOf(alice) + tokenC.balanceOf(alice), 0, "the named tokens were sold whole");
        assertEq(btc.balanceOf(alice), 1e18 - sold, "the BTC the debt did not need went to the borrower");
        assertEq(router.swaps(), 3);
        _assertNoAllowances();
    }

    function test_F26_HarvestAndSwapByAnyoneButTheBorrowerReverts() public {
        _owe(bribes, TOKEN, address(tokenA), 5e18);
        IPayDown.Swap[] memory swaps = _oneSwap(address(tokenA), 1e18, _route(address(tokenA), address(musd)));
        address[5] memory others = [keeper, bob, owner, guardian, address(pd)];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IPayDown.NotBorrower.selector, TOKEN));
            _harvestAndSwap(others[i], TOKEN, _none(), _list(address(tokenA)), swaps);
        }
        assertEq(bribes.owed(TOKEN, address(tokenA)), 5e18, "the reward stayed with Mezo");
    }

    function test_C39_RouteNotEndingInMusdOrWithABrokenHopReverts() public {
        _owe(bribes, TOKEN, address(tokenA), 5e18);
        address a = address(tokenA);
        IMezoRouter.Route[][] memory bad = new IMezoRouter.Route[][](5);
        bad[0] = _route(a, address(btc));
        bad[1] = new IMezoRouter.Route[](2);
        (bad[1][0], bad[1][1]) = (_hop(a, address(tokenC)), _hop(address(btc), address(musd)));
        bad[2] = _route(address(tokenC), address(musd));
        bad[3] = new IMezoRouter.Route[](0);
        bad[4] = new IMezoRouter.Route[](4);
        (bad[4][0], bad[4][1]) = (_hop(a, address(tokenC)), _hop(address(tokenC), a));
        (bad[4][2], bad[4][3]) = (_hop(a, address(btc)), _hop(address(btc), address(musd)));
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IPayDown.BadRoute.selector, a));
            _harvestAndSwap(alice, TOKEN, _none(), _list(a), _oneSwap(a, 1e18, bad[i]));
        }
        assertEq(bribes.owed(TOKEN, a), 5e18, "a bad route is refused before the claim");
    }

    function test_C39_SwapListRules() public {
        _owe(fees, TOKEN, address(musd), 10e18);
        _owe(bribes, TOKEN, address(tokenA), 5e18);
        address[] memory feeList = _list(address(musd), address(btc));
        address[] memory bribeList = _list(address(tokenA), address(tokenC));
        address stranger = address(new MockToken("ZZZ"));

        // MUSD and BTC are handled by the contract's own rules, never by a borrower's route.
        address[3] memory refused = [address(musd), address(btc), stranger];
        for (uint256 i; i < refused.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IPayDown.BadSwapToken.selector, refused[i]));
            _harvestAndSwap(
                alice, TOKEN, feeList, bribeList, _oneSwap(refused[i], 1e18, _route(refused[i], address(musd)))
            );
        }
        // Listed but owed nothing this week: there is nothing of it to sell.
        vm.expectRevert(abi.encodeWithSelector(IPayDown.BadSwapToken.selector, address(tokenC)));
        _harvestAndSwap(
            alice, TOKEN, feeList, bribeList, _oneSwap(address(tokenC), 1e18, _route(address(tokenC), address(musd)))
        );
        // A minimum of zero never reaches the Router (C39).
        vm.expectRevert(abi.encodeWithSelector(IPayDown.ZeroMinimum.selector, address(tokenA)));
        _harvestAndSwap(
            alice, TOKEN, feeList, bribeList, _oneSwap(address(tokenA), 0, _route(address(tokenA), address(musd)))
        );
        vm.expectRevert(abi.encodeWithSelector(IPayDown.TooManySwaps.selector, 9));
        _harvestAndSwap(alice, TOKEN, feeList, bribeList, new IPayDown.Swap[](9));
    }

    function test_C38_TokenOnBothSidesIsClaimedAndMeasuredOnce() public {
        _owe(fees, TOKEN, address(musd), 10e18);
        _owe(bribes, TOKEN, address(musd), 5e18);
        uint256 owedBefore = lm.owedOf(TOKEN);

        _harvest(keeper, TOKEN, _list(address(musd)), _list(address(musd)));
        assertEq(owedBefore - lm.owedOf(TOKEN), 15e18, "both sides' MUSD repaid, counted once");
        assertEq(musd.balanceOf(address(pd)), 0, "nothing left behind");
    }

    function test_C38_DuplicateSwapTokenReverts() public {
        _owe(fees, TOKEN, address(musd), 10e18);
        _owe(bribes, TOKEN, address(tokenA), 5e18);

        IPayDown.Swap[] memory swaps = new IPayDown.Swap[](2);
        IMezoRouter.Route[] memory routeA = _route(address(tokenA), address(musd));
        swaps[0] = IPayDown.Swap({token: address(tokenA), amountOutMin: 1, routes: routeA});
        swaps[1] = swaps[0];
        vm.expectRevert(abi.encodeWithSelector(IPayDown.DuplicateToken.selector, address(tokenA)));
        _harvestAndSwap(alice, TOKEN, _none(), _list(address(tokenA)), swaps);

        // Lists out of shape, or past the cap, are refused before anything is read.
        vm.expectRevert(IPayDown.LengthMismatch.selector);
        vm.prank(keeper);
        pd.harvest(TOKEN, _list(gauge), new address[][](2), _nest(_none()));
        address[] memory many = new address[](17);
        for (uint256 i; i < many.length; ++i) {
            many[i] = address(uint160(0x1000 + i));
        }
        vm.expectRevert(abi.encodeWithSelector(IPayDown.TooManyTokens.selector, 17));
        _harvest(keeper, TOKEN, many, _none());

        assertEq(fees.owed(TOKEN, address(musd)), 10e18, "nothing was claimed");
    }

    function test_C38_MusdAndBtcDonatedBeforeAHarvestAreUntouched() public {
        musd.mint(address(pd), 777e18);
        btc.mint(address(pd), 0.05e18);
        _owe(fees, TOKEN, address(musd), 100e18);
        _owe(fees, TOKEN, address(btc), 0.01e18);
        uint256 aliceMusd = musd.balanceOf(alice);

        uint256 repaid = _harvest(keeper, TOKEN, _list(address(musd), address(btc)), _none());

        assertEq(router.lastAmountIn(), 0.01e18, "only the BTC this harvest brought was sold");
        assertEq(repaid, 900e18, "only this harvest's MUSD was repaid");
        assertEq(musd.balanceOf(address(pd)), 777e18, "C38: the stray MUSD stayed put");
        assertEq(btc.balanceOf(address(pd)), 0.05e18, "C38: the stray BTC stayed put");
        assertEq(musd.balanceOf(alice), aliceMusd, "the stray was not paid to the borrower either");

        // A stray belongs to nobody; the owner can move it, outside any harvest.
        address rescued = makeAddr("rescued");
        vm.expectEmit(true, true, false, true, address(pd));
        emit IPayDown.Rescued(address(musd), rescued, 777e18);
        vm.prank(owner);
        pd.rescueToken(address(musd), rescued, 777e18);
        assertEq(musd.balanceOf(rescued), 777e18);
    }

    function test_C38_HostileTokenOnABorrowerRouteCannotCallHarvestAgain() public {
        // The attacker's own opted-in position, which the hostile token tries to harvest in the middle of a swap.
        ve.mint(bob, TOKEN_B, LOCK_BTC, m3, false);
        _deposit(bob, TOKEN_B);
        vm.prank(bob);
        lm.setRewardOperator(TOKEN_B, address(pd));
        _owe(fees, TOKEN_B, address(musd), 50e18);

        CallbackToken hostile = new CallbackToken();
        router.setRate(address(tokenA), address(hostile), 1e18);
        router.setRate(address(hostile), address(musd), 2e18);
        hostile.arm(
            address(router),
            address(pd),
            abi.encodeCall(IPayDown.harvest, (TOKEN_B, _list(gauge), _nest(_list(address(musd))), _nest(_none())))
        );
        _owe(bribes, TOKEN, address(tokenA), 5e18);
        IMezoRouter.Route[] memory routes = _route(address(tokenA), address(hostile), address(musd));

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        _harvestAndSwap(alice, TOKEN, _none(), _list(address(tokenA)), _oneSwap(address(tokenA), 1e18, routes));

        assertEq(fees.owed(TOKEN_B, address(musd)), 50e18, "C38: the attacker's position was not harvested");
        assertEq(bribes.owed(TOKEN, address(tokenA)), 5e18, "C41: the whole harvest reverted");
    }

    function test_C42_PausedHarvestReverts_BorrowersOwnClaimClearAndRepayStillWork() public {
        _owe(fees, TOKEN, address(musd), 50e18);
        vm.expectEmit(false, false, false, true, address(pd));
        emit IPayDown.PausedSet(true);
        vm.prank(guardian);
        pd.setPaused(true);

        vm.expectRevert(IPayDown.HarvestsPaused.selector);
        _harvest(keeper, TOKEN, _list(address(musd)), _none());
        vm.expectRevert(IPayDown.HarvestsPaused.selector);
        _harvestAndSwap(alice, TOKEN, _list(address(musd)), _none(), new IPayDown.Swap[](0));

        uint256 aliceMusd = musd.balanceOf(alice);
        vm.startPrank(alice);
        lm.claimRewards(TOKEN, _list(gauge), _nest(_list(address(musd))), _nest(_none()));
        assertEq(musd.balanceOf(alice) - aliceMusd, 50e18, "C42: the borrower's own claim still pays the borrower");
        lm.repay(TOKEN, 10e18);
        lm.setRewardOperator(TOKEN, address(0));
        vm.stopPrank();
        assertEq(lm.owedOf(TOKEN), face - 10e18, "C42: repay still works");
        assertEq(lm.positionOf(TOKEN).rewardOperator, address(0), "C42: the borrower can still clear PayDown");

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        pd.setPaused(false);
        vm.prank(keeper);
        vm.expectRevert(IPayDown.NotGuardianOrOwner.selector);
        pd.setPaused(true);
        vm.prank(owner);
        pd.setPaused(false);
        assertFalse(pd.paused(), "only the owner resumes");
    }

    function test_C40_ApprovalsToTheRouterAndLoanManagerAreZeroAfterEveryHarvest() public {
        router.setRate(address(tokenA), address(musd), 2e18);
        _owe(fees, TOKEN, address(musd), 100e18);
        _owe(fees, TOKEN, address(btc), 0.01e18);
        _owe(bribes, TOKEN, address(tokenA), 10e18);
        _harvestAndSwap(
            alice,
            TOKEN,
            _list(address(musd), address(btc)),
            _list(address(tokenA)),
            _oneSwap(address(tokenA), 1, _route(address(tokenA), address(musd)))
        );
        assertEq(router.swaps(), 2, "a swap, a BTC sale and a repay all ran");
        assertEq(lm.owedOf(TOKEN), face - 100e18 - 20e18 - 800e18);
        _assertNoAllowances();

        _owe(fees, TOKEN, address(btc), 0.01e18);
        _harvest(keeper, TOKEN, _list(address(btc)), _none());
        _assertNoAllowances();

        _owe(fees, TOKEN, address(musd), face);
        _harvest(keeper, TOKEN, _list(address(musd)), _none());
        assertEq(uint8(lm.loanOf(TOKEN).state), uint8(ILoanManager.LoanState.None));
        _assertNoAllowances();
    }

    function test_C41_HarvestDuringAnAuctionReverts() public {
        _makeUnsafe(TOKEN);
        lm.startAuction(TOKEN);
        _owe(fees, TOKEN, address(musd), 100e18);
        _owe(fees, TOKEN, address(btc), 0.01e18);

        vm.expectRevert(abi.encodeWithSelector(ILoanManager.LoanInAuction.selector, TOKEN));
        _harvest(keeper, TOKEN, _list(address(musd), address(btc)), _none());

        assertEq(fees.owed(TOKEN, address(musd)), 100e18, "C41: the rewards stay in Mezo's reward contract");
        assertEq(lm.owedOf(TOKEN), face, "C41: the loan is untouched");
        assertEq(router.swaps(), 0);
    }

    function test_C42_ConstructorFixesItsAddressesFromLoanManagerAndTheRouter() public {
        assertEq(address(pd.loanManager()), address(lm));
        assertEq(address(pd.router()), address(router));
        assertEq(pd.factory(), factory);
        assertEq(address(pd.musd()), address(lm.musd()));
        assertEq(address(pd.btc()), address(lm.btc()));
        assertEq(address(pd.priceFeed()), address(lm.priceFeed()));
        assertEq(pd.slippageBps(), SLIPPAGE);
        assertEq(pd.guardian(), guardian);
        assertEq(pd.owner(), owner);

        address r = address(router);
        vm.expectRevert(IPayDown.ZeroAddress.selector);
        new PayDown(address(0), r, owner, guardian, SLIPPAGE);
        vm.expectRevert(IPayDown.ZeroAddress.selector);
        new PayDown(address(lm), address(0), owner, guardian, SLIPPAGE);
        vm.expectRevert(IPayDown.ZeroAddress.selector);
        new PayDown(address(lm), r, address(0), guardian, SLIPPAGE);
        vm.expectRevert(IPayDown.ZeroAddress.selector);
        new PayDown(address(lm), r, owner, address(0), SLIPPAGE);
        address noFactory = address(new MockRouter(address(0)));
        vm.expectRevert(IPayDown.ZeroAddress.selector);
        new PayDown(address(lm), noFactory, owner, guardian, SLIPPAGE);
        vm.expectRevert(abi.encodeWithSelector(IPayDown.SlippageTooHigh.selector, 301));
        new PayDown(address(lm), r, owner, guardian, 301);
    }

    function test_C42_OwnerSetsOnlyTheCappedAllowance_GuardianOnlyPauses() public {
        vm.expectEmit(false, false, false, true, address(pd));
        emit IPayDown.SlippageSet(300);
        vm.prank(owner);
        pd.setSlippageBps(300);
        assertEq(pd.slippageBps(), 300);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IPayDown.SlippageTooHigh.selector, 301));
        pd.setSlippageBps(301);

        bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian);
        vm.startPrank(guardian);
        vm.expectRevert(notOwner);
        pd.setSlippageBps(50);
        vm.expectRevert(notOwner);
        pd.setGuardian(guardian);
        vm.expectRevert(notOwner);
        pd.rescueToken(address(musd), guardian, 1);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert(IPayDown.ZeroAddress.selector);
        pd.setGuardian(address(0));
        vm.expectEmit(true, false, false, true, address(pd));
        emit IPayDown.GuardianSet(bob);
        pd.setGuardian(bob);
        vm.expectRevert(IPayDown.RenounceDisabled.selector);
        pd.renounceOwnership();
        vm.expectRevert(IPayDown.ZeroAddress.selector);
        pd.rescueToken(address(musd), address(0), 1);
        vm.expectRevert(IPayDown.ZeroAmount.selector);
        pd.rescueToken(address(musd), owner, 0);
        vm.stopPrank();
        assertEq(pd.guardian(), bob);
        assertEq(pd.owner(), owner);
    }

    /// @dev One fuzz case's inputs and the balances read just before its harvest.
    struct FuzzCase {
        uint256 musdReward;
        uint256 btcReward;
        uint256 price;
        uint256 strayMusd;
        uint256 strayBtc;
        uint256 owedBefore;
        uint256 aliceMusd;
        uint256 aliceBtc;
        uint256 routerMusd;
        uint256 routerBtc;
    }

    function testFuzz_C38_C40_EveryGainIsRepaidOrReachesTheBorrower(
        uint256 musdReward,
        uint256 btcReward,
        uint256 prepaid,
        uint256 price,
        uint256 discountBps,
        uint256 strayMusd,
        uint256 strayBtc
    ) public {
        FuzzCase memory c;
        c.musdReward = bound(musdReward, 0, 60_000e18);
        c.btcReward = bound(btcReward, 0, 3e18);
        c.price = bound(price, 20_000e18, 200_000e18);
        c.strayMusd = bound(strayMusd, 0, 1_000_000e18);
        c.strayBtc = bound(strayBtc, 0, 10e18);
        prepaid = bound(prepaid, 0, face - 1);
        discountBps = bound(discountBps, 0, SLIPPAGE - 1);

        if (prepaid != 0) {
            vm.prank(alice);
            lm.repay(TOKEN, prepaid);
        }
        feed.setPrice(c.price);
        router.setRate(address(btc), address(musd), c.price * (10_000 - discountBps) / 10_000);
        musd.mint(address(pd), c.strayMusd);
        btc.mint(address(pd), c.strayBtc);
        if (c.musdReward != 0) _owe(fees, TOKEN, address(musd), c.musdReward);
        if (c.btcReward != 0) _owe(fees, TOKEN, address(btc), c.btcReward);

        c.owedBefore = lm.owedOf(TOKEN);
        c.aliceMusd = musd.balanceOf(alice);
        c.aliceBtc = btc.balanceOf(alice);
        c.routerMusd = musd.balanceOf(address(router));
        c.routerBtc = btc.balanceOf(address(router));

        uint256 repaid = _harvest(keeper, TOKEN, _list(address(musd), address(btc)), _none());
        _checkFuzzCase(c, repaid);
    }

    function _checkFuzzCase(FuzzCase memory c, uint256 repaid) internal view {
        uint256 btcSold = btc.balanceOf(address(router)) - c.routerBtc;
        uint256 fromBtc = c.routerMusd - musd.balanceOf(address(router));
        assertLe(repaid, c.owedBefore, "repaid never exceeds what was owed");
        assertEq(repaid, Math.min(c.musdReward + fromBtc, c.owedBefore), "C40: the smaller of MUSD brought and owed");
        assertEq(lm.owedOf(TOKEN), c.owedBefore - repaid);
        assertLe(btcSold, c.btcReward, "BTC sold never exceeds BTC gained");
        assertEq(musd.balanceOf(alice) - c.aliceMusd, c.musdReward + fromBtc - repaid, "C38: unrepaid MUSD to the borrower");
        assertEq(btc.balanceOf(alice) - c.aliceBtc, c.btcReward - btcSold, "C38: unsold BTC to the borrower");
        assertEq(musd.balanceOf(address(pd)), c.strayMusd, "C38: the stray MUSD is untouched");
        assertEq(btc.balanceOf(address(pd)), c.strayBtc, "C38: the stray BTC is untouched");
        if (c.owedBefore <= c.musdReward) {
            assertEq(btcSold, 0, "C40: the MUSD covered the debt, so no BTC was sold");
        } else if (btcSold != 0) {
            uint256 need = c.owedBefore - c.musdReward;
            assertLt(_floor(btcSold - 1, c.price), need, "C40: no more BTC sold than the debt needed");
            if (btcSold < c.btcReward) assertGe(_floor(btcSold, c.price), need, "C40: a partial sale covers the debt");
            assertGe(fromBtc, _floor(btcSold, c.price), "C39: never below the oracle floor");
        }
        _assertNoAllowances();
    }
}
