// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// PayDown's swap path against Mezo testnet's real pool Router (0x9a1ff7FE..., the documented one) and real pools,
// on a local fork. The real CreditMarkets, LoanManager and PayDown are deployed there over the real testnet MUSD,
// sMUSD vault and Router, with mocks for veBTC, PoolsVoter and the reward contract so a week of rewards can be
// owed at once. (A) A keeper's harvest sells a BTC reward through PayDown's fixed route into the real BTC/MUSD
// pool and receives at least the oracle floor; after a large prior swap pushes that pool 5% under the oracle,
// the same harvest reverts. (B) The borrower's harvestAndSwap sells an mT reward through the real mT/MUSD pool
// at the borrower's minimum; after a large prior swap pushes that pool 5%, it reverts.
// It does NOT cover: the live Skip oracle (PriceFeed reads a precompile the local EVM cannot run, so the price is
// read from the node once at the fork block and mocked); Mezo's BTC ERC-20 precompile, which cannot run locally
// either, so for (A) test/utils/MezoBtcStandIn is etched over 0x7b7C...0000 after a probe shows the real one
// failing, and BTC's own transfer code is left to the live testnet run; Mezo's real veBTC, PoolsVoter and reward
// contracts (test/fork/PassThroughFork.t.sol); mainnet's thin BTC pool; or ordering by a block producer.

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreditMarkets} from "../../src/CreditMarkets.sol";
import {LoanManager} from "../../src/LoanManager.sol";
import {PayDown} from "../../src/PayDown.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {IMezoRouter} from "../../src/interfaces/IMezoRouter.sol";
import {IPayDown} from "../../src/interfaces/IPayDown.sol";
import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";
import {MezoBtcStandIn} from "../utils/MezoBtcStandIn.sol";
import {MockBTC} from "../utils/MockBTC.sol";
import {MockPoolsVoter} from "../utils/MockPoolsVoter.sol";
import {MockReward} from "../utils/MockReward.sol";
import {MockVeBTC} from "../utils/MockVeBTC.sol";
import {ForkNode} from "../utils/ForkNode.sol";

interface IRouterLive {
    function poolFor(address tokenA, address tokenB, bool stable, address factory) external view returns (address);
}

interface IPoolFactoryLive {
    function getFee(address pool, bool stable) external view returns (uint256);
}

interface IPoolLive {
    function token0() external view returns (address);
    function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);
}

contract PayDownForkTest is Test {
    address internal constant ROUTER = 0x9a1ff7FE3a0F69959A3fBa1F1e5ee18e1A9CD7E9;
    address internal constant BTC_MUSD_POOL = 0xd16A5Df82120ED8D626a1a15232bFcE2366d6AA9;
    address internal constant MT_MUSD_POOL = 0x0E6BD7E52e4491320012f8C9E6161cD915BB0D19;
    address internal constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    address internal constant MT = 0xdd8Bf5ACa0579bEE7e6cd20AC7683E279a5f7d48;
    address internal constant BTC = 0x7b7C000000000000000000000000000000000000;
    address internal constant PRICE_FEED = 0x86bCF0841622a5dAC14A313a15f96A95421b9366;
    address internal constant SMUSD = 0x6f461c68B2c5492C0F5CCEc5a264d692aA7A8e16;

    uint256 internal constant WEEK = 604_800;
    uint256 internal constant TOKEN = 7;
    uint16 internal constant SLIPPAGE = 100;
    uint128 internal constant PRINCIPAL = 3_000e18;
    uint256 internal constant BTC_REWARD = 0.01e18;
    uint256 internal constant MT_REWARD = 10e18;
    uint256 internal constant MIN_BTC_PRICE = 10_000e18;
    uint256 internal constant MAX_BTC_PRICE = 1_000_000e18;
    uint256 internal constant MAX_PUSHES = 30;

    bytes4 internal constant INSUFFICIENT_OUTPUT = bytes4(keccak256("InsufficientOutputAmount()"));

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal lender = makeAddr("lender");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");
    address internal gauge = makeAddr("gauge");

    MockVeBTC internal ve;
    MockPoolsVoter internal voter;
    MockReward internal fees;
    MockReward internal bribes;
    CreditMarkets internal cm;
    LoanManager internal lm;
    PayDown internal pd;
    address internal factory;
    uint256 internal price;

    error UnexpectedPriceLength(uint256 length);

    function test_A_BtcRewardSellsThroughTheRealPoolAtOrAboveTheOracleFloor() public {
        _setUpFork(true);
        _oweBtc();
        uint256 floor = _floor(BTC_REWARD);
        uint256 quoted = _quote(BTC, BTC_REWARD);
        console.log("oracle price (musd wei per btc)", price);
        console.log("0.01 BTC: router quote / oracle floor (musd wei)", quoted, floor);
        assertGe(quoted, floor, "testnet's BTC/MUSD pool sits at or above the oracle floor at this block");
        uint256 poolMusd = IERC20(MUSD).balanceOf(BTC_MUSD_POOL);
        uint256 poolBtc = IERC20(BTC).balanceOf(BTC_MUSD_POOL);

        vm.prank(keeper);
        uint256 repaid = pd.harvest(TOKEN, _list(gauge), _nest(_list(BTC)), _nest(new address[](0)));
        console.log("gas harvest (claim, 1-hop BTC sale on the real pool, repay)", vm.lastFrameGas().gasTotalUsed);

        assertGe(repaid, floor, "C39: the MUSD from the real pool met the oracle floor");
        assertEq(repaid, quoted, "the MUSD measured arriving is the Router's own quote, all of it repaid");
        assertEq(poolMusd - IERC20(MUSD).balanceOf(BTC_MUSD_POOL), repaid, "the MUSD came out of the real pool");
        // The pool sends its swap fee on the input to a separate PoolFees contract, so it keeps the rest.
        uint256 swapFee = BTC_REWARD * IPoolFactoryLive(factory).getFee(BTC_MUSD_POOL, false) / 10_000;
        assertEq(IERC20(BTC).balanceOf(BTC_MUSD_POOL) - poolBtc, BTC_REWARD - swapFee, "the whole reward was sold");
        assertEq(lm.owedOf(TOKEN), lm.loanOf(TOKEN).face - repaid);
        assertEq(IERC20(BTC).balanceOf(alice), 0, "C40: the debt needed every bit of the BTC");
        assertEq(IERC20(BTC).allowance(address(pd), ROUTER), 0, "C40: no allowance left to the Router");
        assertEq(IERC20(MUSD).allowance(address(pd), address(lm)), 0, "C40: no allowance left to LoanManager");
        assertEq(IERC20(MUSD).balanceOf(address(pd)) + IERC20(BTC).balanceOf(address(pd)), 0, "PayDown keeps nothing");
        console.log("repaid from 0.01 BTC (musd wei)", repaid);
    }

    function test_A_BtcPoolPushed5PercentUnderTheOracleMakesTheHarvestRevert() public {
        _setUpFork(true);
        _oweBtc();
        uint256 value = BTC_REWARD * price / 1e18;
        vm.deal(attacker, 1_000 ether);
        uint256 pushed = _pushUntil(BTC, 10 ether, BTC_REWARD, value * 95 / 100);
        console.log("BTC sold into the pool first (wei)", pushed);
        console.log("0.01 BTC: quote after the push / oracle floor", _quote(BTC, BTC_REWARD), _floor(BTC_REWARD));

        // The floor PayDown computes from the oracle is the Router's minimum, so the Router itself refuses.
        vm.expectRevert(INSUFFICIENT_OUTPUT);
        vm.prank(keeper);
        pd.harvest(TOKEN, _list(gauge), _nest(_list(BTC)), _nest(new address[](0)));

        assertEq(fees.owed(TOKEN, BTC), BTC_REWARD, "C41: the reward stays owed for a later harvest");
        assertEq(lm.owedOf(TOKEN), lm.loanOf(TOKEN).face, "C41: the loan is untouched");
    }

    function test_B_MtRewardSellsThroughTheRealPoolAtTheBorrowersMinimum() public {
        _setUpFork(false);
        _oweMt();
        uint256 quoted = _quote(MT, MT_REWARD);
        uint256 minOut = quoted * 99 / 100;
        console.log("10 mT: router quote / borrower's minimum (musd wei)", quoted, minOut);
        uint256 poolMusd = IERC20(MUSD).balanceOf(MT_MUSD_POOL);

        vm.prank(alice);
        uint256 repaid = pd.harvestAndSwap(TOKEN, _list(gauge), _nest(new address[](0)), _nest(_list(MT)), _mtSwap(minOut));
        console.log("gas harvestAndSwap (claim, 1-hop mT sale on the real pool, repay)", vm.lastFrameGas().gasTotalUsed);

        assertGe(repaid, minOut, "C39: the MUSD from the real pool met the borrower's minimum");
        assertEq(repaid, quoted, "the MUSD measured arriving is the Router's own quote, all of it repaid");
        assertEq(poolMusd - IERC20(MUSD).balanceOf(MT_MUSD_POOL), repaid, "the MUSD came out of the real pool");
        assertEq(IERC20(MT).balanceOf(alice), 0, "the mT reward was sold whole");
        assertEq(IERC20(MT).allowance(address(pd), ROUTER), 0, "C40: no allowance left to the Router");
        assertEq(IERC20(MUSD).allowance(address(pd), address(lm)), 0, "C40: no allowance left to LoanManager");
        assertEq(IERC20(MT).balanceOf(address(pd)) + IERC20(MUSD).balanceOf(address(pd)), 0, "PayDown keeps nothing");
    }

    function test_B_MtPoolPushed5PercentMakesTheBorrowersHarvestRevert() public {
        _setUpFork(false);
        _oweMt();
        uint256 quoted = _quote(MT, MT_REWARD);
        uint256 minOut = quoted * 99 / 100;
        deal(MT, attacker, 1_000e18);
        uint256 pushed = _pushUntil(MT, 5e18, MT_REWARD, quoted * 95 / 100);
        console.log("mT sold into the pool first (wei)", pushed);
        console.log("10 mT: quote after the push / borrower's minimum", _quote(MT, MT_REWARD), minOut);

        vm.expectRevert(INSUFFICIENT_OUTPUT);
        vm.prank(alice);
        pd.harvestAndSwap(TOKEN, _list(gauge), _nest(new address[](0)), _nest(_list(MT)), _mtSwap(minOut));

        assertEq(bribes.owed(TOKEN, MT), MT_REWARD, "C41: the reward stays owed");
    }

    /// @dev Forks testnet, mocks the oracle at the node's price for this block, fixes BTC for a local EVM when
    ///      `withBtc`, deploys the pair and PayDown on the real Router, and opens alice's loan with PayDown named.
    function _setUpFork(bool withBtc) internal {
        ForkNode.selectTestnet();
        console.log("testnet block", vm.getBlockNumber());
        price = _fetchPriceOnNode(PRICE_FEED);
        vm.mockCall(PRICE_FEED, abi.encodeWithSelector(IPriceFeed.fetchPrice.selector), abi.encode(price));
        if (withBtc) _btcOnFork();

        factory = IMezoRouter(ROUTER).defaultFactory();
        assertEq(IRouterLive(ROUTER).poolFor(BTC, MUSD, false, factory), BTC_MUSD_POOL, "the documented BTC/MUSD pool");
        assertEq(IRouterLive(ROUTER).poolFor(MT, MUSD, false, factory), MT_MUSD_POOL, "the documented mT/MUSD pool");

        ve = new MockVeBTC(4, MockBTC(BTC));
        voter = new MockPoolsVoter(ve);
        fees = new MockReward(address(voter), ve);
        bribes = new MockReward(address(voter), ve);
        voter.setGauge(gauge, address(fees), address(bribes));
        _deployPair();
        pd = new PayDown(address(lm), ROUTER, owner, owner, SLIPPAGE);
        assertEq(pd.factory(), factory);

        uint64 maturity = uint64((vm.getBlockTimestamp() / WEEK + 1) * WEEK);
        deal(MUSD, lender, PRINCIPAL);
        vm.startPrank(lender);
        IERC20(MUSD).approve(address(cm), PRINCIPAL);
        uint256 offerId = cm.postOffer(maturity, 800, PRINCIPAL);
        vm.stopPrank();
        uint256[] memory ids = new uint256[](1);
        uint128[] memory amounts = new uint128[](1);
        (ids[0], amounts[0]) = (offerId, PRINCIPAL);

        ve.mint(alice, TOKEN, 1e18, maturity + 2 * WEEK, false);
        vm.startPrank(alice);
        ve.approve(address(lm), TOKEN);
        lm.deposit(TOKEN);
        lm.borrow(TOKEN, maturity, ids, amounts, 5_000);
        lm.setRewardOperator(TOKEN, address(pd));
        vm.stopPrank();
    }

    function _deployPair() internal {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        cm = new CreditMarkets(MUSD, BTC, predicted, owner, owner, treasury, 1_000, 10e18, uint32(4 * WEEK), "", SMUSD);
        ILoanManager.Settings memory settings = ILoanManager.Settings({
            owner: owner,
            guardian: owner,
            feeDistributor: makeAddr("feeDistributor"),
            validatorsVoter: address(0),
            maxVotes: 30,
            maxLtvBps: 4_000,
            liqLtvBps: 6_500,
            minLoan: 10e18,
            penaltyBps: 500,
            auctionFloorBps: 7_000,
            auctionDuration: 72 hours
        });
        lm = new LoanManager(address(ve), PRICE_FEED, MUSD, BTC, address(voter), address(cm), 4, settings);
        assertEq(address(lm), predicted);
    }

    /// @dev Mezo's BTC ERC-20 view is a precompile whose stored bytecode only calls itself, so a local EVM cannot
    ///      run it. It is probed once, with a gas cap, and the stand-in is etched only when the probe fails. The
    ///      stand-in reads native balances, which on Mezo are the same coins, so it must show the pool's own
    ///      recorded BTC reserve.
    function _btcOnFork() internal {
        (bool ok, bytes memory raw) =
            BTC.staticcall{gas: 2_000_000}(abi.encodeCall(IERC20.balanceOf, (BTC_MUSD_POOL)));
        if (ok && raw.length == 32) {
            console.log("the real BTC precompile answered on the local fork");
            return;
        }
        console.log("BTC precompile balanceOf on the local fork: success / return bytes", ok, raw.length);
        console.logBytes(raw);
        vm.etch(BTC, type(MezoBtcStandIn).runtimeCode);
        (uint256 reserve0, uint256 reserve1,) = IPoolLive(BTC_MUSD_POOL).getReserves();
        uint256 btcReserve = IPoolLive(BTC_MUSD_POOL).token0() == BTC ? reserve0 : reserve1;
        assertEq(IERC20(BTC).balanceOf(BTC_MUSD_POOL), btcReserve, "the stand-in shows the pool's BTC reserve");
    }

    function _oweBtc() internal {
        fees.setReward(BTC, true);
        vm.deal(address(fees), BTC_REWARD);
        fees.setOwed(TOKEN, BTC, BTC_REWARD);
    }

    function _oweMt() internal {
        bribes.setReward(MT, true);
        deal(MT, address(bribes), MT_REWARD);
        bribes.setOwed(TOKEN, MT, MT_REWARD);
    }

    function _mtSwap(uint256 minOut) internal view returns (IPayDown.Swap[] memory swaps) {
        swaps = new IPayDown.Swap[](1);
        swaps[0] = IPayDown.Swap({token: MT, amountOutMin: minOut, routes: _route(MT)});
    }

    function _route(address from) internal view returns (IMezoRouter.Route[] memory routes) {
        routes = new IMezoRouter.Route[](1);
        routes[0] = IMezoRouter.Route({from: from, to: MUSD, stable: false, factory: factory});
    }

    function _quote(address from, uint256 amountIn) internal view returns (uint256) {
        uint256[] memory amounts = IMezoRouter(ROUTER).getAmountsOut(amountIn, _route(from));
        return amounts[amounts.length - 1];
    }

    /// @dev The attacker sells `chunk` of `token` into its MUSD pool through the real Router until a sale of
    ///      `probe` quotes at most `target` MUSD. Returns how much it sold.
    function _pushUntil(address token, uint256 chunk, uint256 probe, uint256 target) internal returns (uint256 sold) {
        vm.startPrank(attacker);
        IERC20(token).approve(ROUTER, type(uint256).max);
        for (uint256 i; i < MAX_PUSHES && _quote(token, probe) > target; ++i) {
            IMezoRouter(ROUTER).swapExactTokensForTokens(chunk, 0, _route(token), attacker, vm.getBlockTimestamp());
            if (i < 2) console.log("gas one real Router hop, cold then warm", vm.lastFrameGas().gasTotalUsed);
            sold += chunk;
        }
        vm.stopPrank();
        assertLe(_quote(token, probe), target, "the pool was pushed far enough");
    }

    function _floor(uint256 btcAmount) internal view returns (uint256) {
        return btcAmount * price / 1e18 * (10_000 - SLIPPAGE) / 10_000;
    }

    function _list(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _nest(address[] memory inner) internal pure returns (address[][] memory out) {
        out = new address[][](1);
        out[0] = inner;
    }

    /// @dev Pinned to the fork block so the price and the pool reads come from the same state.
    function _fetchPriceOnNode(address feed) internal returns (uint256 fetched) {
        string memory params = string.concat(
            '[{"to":"',
            vm.toString(feed),
            '","data":"',
            vm.toString(abi.encodeWithSelector(IPriceFeed.fetchPrice.selector)),
            '"},"',
            _hexQuantity(vm.getBlockNumber()),
            '"]'
        );
        bytes memory raw = vm.rpc("eth_call", params);
        if (raw.length != 32) revert UnexpectedPriceLength(raw.length);
        fetched = abi.decode(raw, (uint256));
        assertGe(fetched, MIN_BTC_PRICE, "price below sanity floor");
        assertLe(fetched, MAX_BTC_PRICE, "price above sanity ceiling");
    }

    /// @dev JSON-RPC block numbers must be hex with no leading zeros, which vm.toString does not produce.
    function _hexQuantity(uint256 value) internal pure returns (string memory) {
        bytes memory padded = bytes(vm.toString(bytes32(value)));
        uint256 start = 2;
        while (start < padded.length - 1 && padded[start] == "0") ++start;
        bytes memory out = new bytes(padded.length - start + 2);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = start; i < padded.length; ++i) {
            out[i - start + 2] = padded[i];
        }
        return string(out);
    }
}
