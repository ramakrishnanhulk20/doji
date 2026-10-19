// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// M2b borrower pass-through against real Mezo state. (A) A real mainnet position's owner deposits it and
// borrows, then through LoanManager votes on a live PoolsVoter gauge, has a stranger poke it and still resets in
// the same epoch, votes again, collects a real incentive through the pool's gauge, extends the lock and claims
// from the real fee distributor. (B) Anyone can claim from the fee distributor, and on an unexpired lock the
// claim goes into the lock. (C) A BoostVoter vote never touches veBTC's voted flag. (D) A permanent position
// voted on both PoolsVoter and ValidatorsVoter defaults unsold, prepareSettle clears both votes and unlocks it,
// settle withdraws the BTC and the lender redeems it. (E) lockAndBorrow mints a real testnet veBTC position
// straight into LoanManager and borrows against it. (F) A position's real unclaimed MUSD and BTC pool fees are
// claimed through its real gauges and reach the borrower.
// It does NOT cover: the live Skip oracle (PriceFeed reads a precompile the local EVM cannot run, so the price is
// read from the node once at the fork block and mocked); Mezo's BTC ERC-20 precompile, which cannot run locally
// either, so wherever BTC moves (the fee distributor, its period update, lock creation on testnet)
// test/utils/MezoBtcStandIn is etched over 0x7b7C...0000 and the distributor's standing veBTC approval is
// recreated on it; real swaps, so pool fees earned are whatever the chain already held; MEZO-paying rewards
// (another precompile); positions owned by contracts; ids beyond the newest few hundred; or anything a Mezo
// upgrade adds later.

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CreditMarkets} from "../../src/CreditMarkets.sol";
import {LoanManager} from "../../src/LoanManager.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {IVeBTC} from "../../src/interfaces/IVeBTC.sol";
import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";
import {IFeeDistributor} from "../../src/interfaces/IFeeDistributor.sol";
import {IPoolsVoter} from "../../src/interfaces/IPoolsVoter.sol";
import {MezoBtcStandIn} from "../utils/MezoBtcStandIn.sol";

interface IVeBTCLive is IVeBTC {
    function tokenId() external view returns (uint256);
    function approve(address spender, uint256 tokenId) external;
    function votedVoters(uint256 tokenId) external view returns (address[] memory);
    function isSecondaryVoter(address voter) external view returns (bool);
    function distributor() external view returns (address);
    function voter() external view returns (address);
}

interface IPoolsVoterLive {
    function gauges(address pool) external view returns (address);
    function poolVote(uint256 tokenId, uint256 index) external view returns (address);
    function usedWeights(uint256 tokenId) external view returns (uint256);
    function isAlive(address gauge) external view returns (bool);
    function gaugeToFees(address gauge) external view returns (address);
    function gaugeToBribe(address gauge) external view returns (address);
    function lastVoted(uint256 tokenId) external view returns (uint256);
    function votes(uint256 tokenId, address pool) external view returns (uint256);
    function poke(uint256 tokenId) external;
    function length() external view returns (uint256);
    function pools(uint256 index) external view returns (address);
}

interface IVeBTCVoterLive {
    function usedWeights(uint256 tokenId) external view returns (uint256);
    function lastVoted(uint256 tokenId) external view returns (uint256);
}

interface IRewardLive {
    function earned(address token, uint256 tokenId) external view returns (uint256);
    function notifyRewardAmount(address token, uint256 amount) external;
}

interface IBoostVoterLive {
    function boostableTokenIdToGauge(uint256 tokenId) external view returns (address);
    function isAlive(address gauge) external view returns (bool);
    function lastVoted(uint256 tokenId) external view returns (uint256);
    function vote(uint256 tokenId, address[] calldata gauges, uint256[] calldata weights) external;
}

interface IVeMezoLive {
    function tokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function voted(uint256 tokenId) external view returns (bool);
    function votingPowerOfNFT(uint256 tokenId) external view returns (uint256);
    function escrowType(uint256 tokenId) external view returns (uint8);
}

interface IFeeDistributorLive is IFeeDistributor {
    function depositor() external view returns (address);
}

interface IPeriodic {
    function activePeriod() external view returns (uint256);
    function updatePeriod() external returns (uint256);
}

contract PassThroughForkTest is Test {
    address internal constant VEBTC = 0x3D4b1b884A7a1E59fE8589a3296EC8f8cBB6f279;
    address internal constant MUSD = 0xdD468A1DDc392dcdbEf6db6e34E89AA338F9F186;
    address internal constant PRICE_FEED = 0xc5aC5A8892230E0A3e1c473881A2de7353fFcA88;
    address internal constant BTC = 0x7b7C000000000000000000000000000000000000;
    address internal constant POOLS_VOTER = 0x48233cCC97B87Ba93bCA212cbEe48e3210211f03;
    address internal constant FEE_DISTRIBUTOR = 0xb58477e074265BdC7F7ca6100eD0f7De264F74A2;
    address internal constant BOOST_VOTER = 0x2Ba614a598Cffa5a19d683cDCA97bac3a49313d1;
    address internal constant VALIDATORS_VOTER = 0xe99a9ad5Ed26BD30e4DB25397f378817e9b9515a;
    address internal constant VEMEZO = 0xb90fdAd3DFD180458D62Cc6acedc983D78E20122;
    // The mUSDC/mUSDT pool: a live gauge whose fee and incentive tokens are ordinary ERC-20s, not MUSD or BTC.
    address internal constant POOL = 0x2a1ab0224a7a608d3A992Cb15594a2934F74f4C0;
    address internal constant MUSDC = 0x04671C72Aab5AC02A03c1098314b1BB6B560c197;
    address internal constant MUSDT = 0xeB5a5d39dE4Ea42C2Aa6A57EcA2894376683bB8E;
    uint256 internal constant MAINNET_LAYOUT_WORDS = 4;

    address internal constant T_VEBTC = 0xB63fcCd03521Cf21907627bd7fA465C129479231;
    address internal constant T_MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    address internal constant T_PRICE_FEED = 0x86bCF0841622a5dAC14A313a15f96A95421b9366;
    address internal constant T_POOLS_VOTER = 0x72F8dd7F44fFa19E45955aa20A5486E8EB255738;
    uint256 internal constant TESTNET_LAYOUT_WORDS = 3;

    uint256 internal constant WEEK = 604_800;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_ID_TRIES = 150;
    uint256 internal constant MIN_LOCK_BTC = 0.001 ether;
    uint256 internal constant MIN_BTC_PRICE = 10_000e18;
    uint256 internal constant MAX_BTC_PRICE = 1_000_000e18;
    uint16 internal constant APR_BPS = 800;

    struct Candidate {
        uint256 tokenId;
        address holder;
        uint256 amount;
        uint256 end;
        bool isPermanent;
    }

    error NoUsablePosition(string kind, uint256 newestId, uint256 tries);
    error NoPositionWithFees(uint256 tokenId);
    error UnexpectedPriceLength(uint256 length);

    IVeBTCLive internal ve = IVeBTCLive(VEBTC);
    IPoolsVoterLive internal voter = IPoolsVoterLive(POOLS_VOTER);
    CreditMarkets internal cm;
    LoanManager internal lm;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal lender = makeAddr("lender");
    address internal stranger = makeAddr("stranger");
    address internal briber = makeAddr("briber");
    address internal keeper = makeAddr("keeper");

    Candidate internal pos;
    uint256 internal epoch0;
    address internal poolGauge;
    address internal fees;
    address internal bribe;

    function test_A_BorrowerVotesClaimsAndExtendsThroughLoanManager() public {
        _forkMainnet();
        epoch0 = _enterVoteWindow();
        uint64 maturity = uint64(epoch0 + 3 * WEEK);
        pos = _findUnvoted(maturity);
        _logPosition("(A) position", pos);
        _deploy(VEBTC, PRICE_FEED, MUSD, POOLS_VOTER, VALIDATORS_VOTER, FEE_DISTRIBUTOR, MAINNET_LAYOUT_WORDS);
        _borrow(pos, maturity, 3_000);
        // veBTC reports no voting power in the block a position changes owner, so the vote comes a block later,
        // as it always would on chain.
        _warp(vm.getBlockTimestamp() + 12);

        poolGauge = voter.gauges(POOL);
        assertTrue(voter.isAlive(poolGauge), "the chosen gauge is live");
        fees = voter.gaugeToFees(poolGauge);
        bribe = voter.gaugeToBribe(poolGauge);

        _voteThroughLoanManager("(A) vote in the first epoch");
        _strangerPokesThenBorrowerResets();
        _voteThroughLoanManager("(A) vote again after the reset");
        _postIncentive();

        _warp(epoch0 + 2 * WEEK + 1 hours + 1);
        _claimRealRewards();
        _claimSixteenListedTokens();
        _extendLock();
        _claimRebaseIntoTheLock();
        assertEq(uint8(lm.loanOf(pos.tokenId).state), uint8(ILoanManager.LoanState.Active), "the loan never moved");
    }

    function test_B_FeeDistributorClaimIsOpenToAnyoneAndFeedsAnUnexpiredLock() public {
        _forkMainnet();
        uint256 start = vm.getBlockTimestamp() - vm.getBlockTimestamp() % WEEK;
        _standInBtc();
        _updateFeePeriod();
        IFeeDistributor distributor = IFeeDistributor(FEE_DISTRIBUTOR);
        Candidate memory target = _findWithFees(start + WEEK);
        _logPosition("(B) position", target);
        uint256 claimable = distributor.claimable(target.tokenId);
        uint256 ownerBtc = IERC20(BTC).balanceOf(target.holder);

        vm.prank(stranger);
        uint256 claimed = distributor.claim(target.tokenId);
        (int128 amountAfter,,,) = _locked(target.tokenId);

        assertEq(claimed, claimable);
        assertGt(claimed, 0);
        assertEq(uint256(int256(amountAfter)), target.amount + claimed, "(b) unexpired lock: the claim went into it");
        assertEq(IERC20(BTC).balanceOf(target.holder), ownerBtc, "(b) and nothing was paid to the owner");
        assertEq(ve.ownerOf(target.tokenId), target.holder);
        console.log("(b) a stranger claimed (BTC wei) for someone else's unexpired lock:", claimed);
    }

    function test_C_BoostVoterVoteLeavesTheVeBTCVotedFlagAlone() public {
        _forkMainnet();
        uint256 start = _enterVoteWindow();
        assertFalse(ve.isSecondaryVoter(BOOST_VOTER), "(c) BoostVoter is not registered as a voter on veBTC");
        IBoostVoterLive booster = IBoostVoterLive(BOOST_VOTER);

        (uint256 boosted, address gauge) = _findBoostedUnvoted(booster);
        (uint256 veMezoId, address veMezoOwner) = _findVeMezoVoter(booster, start);
        if (boosted == 0 || veMezoId == 0) {
            console.log("(c) no unvoted boosted veBTC and fresh veMEZO voter pair found; structural answer only");
            return;
        }
        console.log("(c) boosted veBTC", boosted, "gauge", gauge);
        console.log("(c) veMEZO voter", veMezoId, veMezoOwner);

        bool before = ve.voted(boosted);
        address[] memory gauges = new address[](1);
        uint256[] memory weights = new uint256[](1);
        (gauges[0], weights[0]) = (gauge, 1);
        vm.prank(veMezoOwner);
        booster.vote(veMezoId, gauges, weights);

        assertFalse(before, "the boosted veBTC started unvoted");
        assertEq(ve.voted(boosted), before, "(c) the boost vote did not set veBTC.voted");
        assertTrue(IVeMezoLive(VEMEZO).voted(veMezoId), "the boost vote is recorded on the veMEZO position");
        console.log("(c) veBTC.voted before / after the boost vote:", before, ve.voted(boosted));
    }

    /// @dev The FIX 1 proof on position 6087, which holds live votes on both PoolsVoter and ValidatorsVoter. If its
    ///      state has moved on since 2026-10-19, the newest position with a ValidatorsVoter vote stands in.
    function test_D_PrepareSettleClearsBothVotersAndTheLenderRedeemsBtc() public {
        _forkMainnet();
        uint256 start = vm.getBlockTimestamp() - vm.getBlockTimestamp() % WEEK;
        uint64 maturity = uint64(start + WEEK);
        pos = _validatorVotedOr6087(maturity);
        _logPosition("(D) position", pos);
        IVeBTCLive veLive = ve;
        IVeBTCVoterLive validators = IVeBTCVoterLive(VALIDATORS_VOTER);
        assertTrue(veLive.isSecondaryVoter(VALIDATORS_VOTER), "ValidatorsVoter is a secondary voter on veBTC");
        console.log("(D) live vote weight on PoolsVoter / ValidatorsVoter",
            voter.usedWeights(pos.tokenId), validators.usedWeights(pos.tokenId));
        assertGt(validators.usedWeights(pos.tokenId), 0, "the position holds a live ValidatorsVoter vote");
        _deploy(VEBTC, PRICE_FEED, MUSD, POOLS_VOTER, VALIDATORS_VOTER, FEE_DISTRIBUTOR, MAINNET_LAYOUT_WORDS);
        _borrow(pos, maturity, 3_000);

        _warp(uint256(maturity) + 1);
        vm.prank(keeper);
        lm.startAuction(pos.tokenId);
        _warp(_resetReady(pos.tokenId, validators));

        vm.prank(keeper);
        lm.prepareSettle(pos.tokenId);
        console.log("gas prepareSettle (two resets and an unlock)", vm.lastFrameGas().gasTotalUsed);
        assertEq(voter.usedWeights(pos.tokenId), 0, "PoolsVoter vote cleared");
        assertEq(validators.usedWeights(pos.tokenId), 0, "ValidatorsVoter vote cleared");
        assertFalse(veLive.voted(pos.tokenId), "veBTC counts no vote any more");
        (, uint256 end, bool isPermanent) = lm.lockOf(pos.tokenId);
        assertFalse(isPermanent, "the permanent lock was unlocked");
        console.log("(D) lock end after prepareSettle", end);

        _warp(Math.max(end, vm.getBlockTimestamp()));
        _settleWithRealCall(pos.tokenId);
        uint256 marketBtc = cm.marketOf(maturity).collectedBtc;
        assertGt(marketBtc, 0, "settle paid the market in BTC");
        cm.finalize(maturity);
        vm.startPrank(lender);
        uint256 units = cm.claimUnits(maturity);
        (uint256 musdOut, uint256 btcOut) = cm.redeem(maturity, units);
        vm.stopPrank();
        assertEq(musdOut, 0);
        assertGt(btcOut, 0, "C26: the lender redeemed BTC with no buyer");
        assertEq(IERC20(BTC).balanceOf(lender), btcOut);
        console.log("(D) market collected BTC / lender redeemed BTC (wei)", marketBtc, btcOut);
    }

    /// @dev The FIX 2 proof: a position with real unclaimed MUSD and BTC fees on gauges it voted for (6033 on
    ///      2026-10-19, else found again) claims them through LoanManager by naming only its gauges.
    function test_F_RealMusdAndBtcPoolFeesReachTheBorrowerThroughGauges() public {
        _forkMainnet();
        uint256 start = vm.getBlockTimestamp() - vm.getBlockTimestamp() % WEEK;
        uint64 maturity = uint64(start + WEEK);
        (Candidate memory c, address[] memory gauges) = _withMusdOrBtcFees(maturity);
        pos = c;
        _logPosition("(F) position", pos);
        _deploy(VEBTC, PRICE_FEED, MUSD, POOLS_VOTER, VALIDATORS_VOTER, FEE_DISTRIBUTOR, MAINNET_LAYOUT_WORDS);
        _borrow(pos, maturity, 3_000);
        // The fee contracts pay BTC through the precompile, which a local EVM cannot run.
        _standInBtc();

        (uint256 dueMusd, uint256 dueBtc) = _feesDue(gauges, pos.tokenId);
        assertGt(dueMusd + dueBtc, 0);
        uint256 holderMusd = IERC20(MUSD).balanceOf(pos.holder);
        uint256 holderBtc = IERC20(BTC).balanceOf(pos.holder);
        uint256 lmMusd = IERC20(MUSD).balanceOf(address(lm));
        uint256 lmBtc = IERC20(BTC).balanceOf(address(lm));
        address[][] memory feeTokens = new address[][](gauges.length);
        address[][] memory bribeTokens = new address[][](gauges.length);
        for (uint256 i; i < gauges.length; ++i) {
            feeTokens[i] = _pair(MUSD, BTC);
            bribeTokens[i] = new address[](0);
        }

        vm.prank(pos.holder);
        lm.claimRewards(pos.tokenId, gauges, feeTokens, bribeTokens);
        console.log("gas claimRewards (real MUSD and BTC fees)", vm.lastFrameGas().gasTotalUsed);

        assertEq(IERC20(MUSD).balanceOf(pos.holder) - holderMusd, dueMusd, "C10: the real MUSD fees reached the borrower");
        assertEq(IERC20(BTC).balanceOf(pos.holder) - holderBtc, dueBtc, "C10: the real BTC fees reached the borrower");
        assertEq(IERC20(MUSD).balanceOf(address(lm)), lmMusd, "LoanManager keeps exactly what it held");
        assertEq(IERC20(BTC).balanceOf(address(lm)), lmBtc);
        assertEq(lm.totalClaimableMusd() + lm.totalClaimableBtc(), 0, "C28: no claimable moved");
        console.log("(F) fees forwarded: MUSD wei / BTC wei", dueMusd, dueBtc);
        for (uint256 i; i < gauges.length; ++i) {
            assertEq(IRewardLive(voter.gaugeToFees(gauges[i])).earned(MUSD, pos.tokenId), 0, "nothing left unclaimed");
        }
    }

    function test_E_LockAndBorrowMintsARealTestnetLockIntoLoanManager() public {
        vm.createSelectFork("mezo_testnet");
        uint256 price = _fetchPriceOnNode(T_PRICE_FEED);
        _mockPrice(T_PRICE_FEED, price);
        // The BTC ERC-20 precompile cannot run in a local EVM; the stand-in reads native balances instead.
        vm.etch(BTC, type(MezoBtcStandIn).runtimeCode);
        address distributor = IVeBTCLive(T_VEBTC).distributor();
        assertGt(distributor.code.length, 0, "testnet veBTC names a deployed fee distributor");
        assertEq(IVeBTCLive(T_VEBTC).voter(), T_POOLS_VOTER);
        console.log("testnet block", vm.getBlockNumber());
        console.log("testnet fee distributor", distributor);
        _deploy(T_VEBTC, T_PRICE_FEED, T_MUSD, T_POOLS_VOTER, address(0), distributor, TESTNET_LAYOUT_WORDS);

        uint64 maturity = uint64((vm.getBlockTimestamp() / WEEK + 1) * WEEK);
        uint128 principal = 20e18;
        deal(T_MUSD, lender, principal);
        vm.startPrank(lender);
        IERC20(T_MUSD).approve(address(cm), principal);
        uint256 offerId = cm.postOffer(maturity, 500, principal);
        vm.stopPrank();

        address borrower = makeAddr("testnetBorrower");
        uint256 lockAmount = 0.001 ether;
        vm.deal(borrower, 0.01 ether);
        vm.prank(borrower);
        IERC20(BTC).approve(address(lm), lockAmount);
        (uint256[] memory ids, uint128[] memory amounts) = _one(offerId, principal);
        uint256 btcBefore = IERC20(BTC).balanceOf(borrower);

        vm.prank(borrower);
        (uint256 tokenId, uint256 borrowed, uint256 face) =
            lm.lockAndBorrow(lockAmount, 2 weeks, maturity, ids, amounts, 500);
        console.log("gas lockAndBorrow (testnet veBTC, BTC through the stand-in)", vm.lastFrameGas().gasTotalUsed);

        (uint256 locked, uint256 end, bool isPermanent) = lm.lockOf(tokenId);
        assertEq(IVeBTC(T_VEBTC).ownerOf(tokenId), address(lm), "the real testnet veBTC minted into LoanManager");
        assertEq(lm.positionOf(tokenId).borrower, borrower, "C1: the caller is the borrower");
        assertEq(IERC20(BTC).allowance(address(lm), T_VEBTC), 0, "C17: no BTC allowance left");
        assertEq(locked, lockAmount);
        assertFalse(isPermanent);
        assertEq(end, (vm.getBlockTimestamp() + 2 weeks) / WEEK * WEEK);
        assertGe(end, maturity);
        assertEq(btcBefore - IERC20(BTC).balanceOf(borrower), lockAmount, "exactly the lock amount left the borrower");
        assertEq(IERC20(T_MUSD).balanceOf(borrower), borrowed);
        assertEq(borrowed, principal);
        assertEq(uint8(lm.loanOf(tokenId).state), uint8(ILoanManager.LoanState.Active));
        console.log("testnet veBTC tokenId", tokenId);
        console.log("lock end", end);
        console.log("borrowed / face (musd wei)", borrowed, face);

        deal(T_MUSD, borrower, face);
        vm.startPrank(borrower);
        IERC20(T_MUSD).approve(address(lm), face);
        lm.repay(tokenId, face);
        lm.withdrawCollateral(tokenId);
        vm.stopPrank();
        assertEq(IVeBTC(T_VEBTC).ownerOf(tokenId), borrower, "repaid and the new lock went to the borrower");
    }

    function _voteThroughLoanManager(string memory label) internal {
        address[] memory pools = new address[](1);
        uint256[] memory weights = new uint256[](1);
        (pools[0], weights[0]) = (POOL, 1);
        vm.prank(pos.holder);
        lm.vote(pos.tokenId, pools, weights);
        console.log(label, "gas vote", vm.lastFrameGas().gasTotalUsed);
        assertTrue(ve.voted(pos.tokenId), "the real PoolsVoter marked the position voted");
        assertEq(voter.lastVoted(pos.tokenId), vm.getBlockTimestamp());
        assertGt(voter.votes(pos.tokenId, POOL), 0, "votes landed on the pool");
    }

    function _strangerPokesThenBorrowerResets() internal {
        _warp(epoch0 + WEEK + 1 hours + 1);
        uint256 votedAt = voter.lastVoted(pos.tokenId);
        vm.prank(stranger);
        voter.poke(pos.tokenId);
        assertEq(voter.lastVoted(pos.tokenId), votedAt, "(a) poke records no new vote time");
        assertTrue(ve.voted(pos.tokenId), "(a) poke re-casts the standing vote");

        vm.prank(pos.holder);
        lm.resetVotes(pos.tokenId);
        assertFalse(ve.voted(pos.tokenId), "(a) the reset after a stranger's poke went through");
        console.log("(a) a stranger's poke did not block resetVotes in the same epoch");
    }

    function _postIncentive() internal {
        uint256 amount = 1_000 * 10 ** IERC20Metadata(MUSDC).decimals();
        deal(MUSDC, briber, amount);
        vm.startPrank(briber);
        IERC20(MUSDC).approve(bribe, amount);
        IRewardLive(bribe).notifyRewardAmount(MUSDC, amount);
        vm.stopPrank();
        console.log("incentive posted on the pool (mUSDC wei)", amount);
    }

    function _claimRealRewards() internal {
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (MUSDC, MUSDT);
        uint256 dueC = IRewardLive(fees).earned(MUSDC, pos.tokenId) + IRewardLive(bribe).earned(MUSDC, pos.tokenId);
        uint256 dueT = IRewardLive(fees).earned(MUSDT, pos.tokenId) + IRewardLive(bribe).earned(MUSDT, pos.tokenId);
        assertGt(IRewardLive(bribe).earned(MUSDC, pos.tokenId), 0, "the vote earned a share of the incentive");
        uint256 lmC = IERC20(MUSDC).balanceOf(address(lm));
        uint256 lmT = IERC20(MUSDT).balanceOf(address(lm));
        uint256 holderC = IERC20(MUSDC).balanceOf(pos.holder);
        uint256 holderT = IERC20(MUSDT).balanceOf(pos.holder);

        vm.prank(pos.holder);
        lm.claimRewards(pos.tokenId, _list(poolGauge), _nest(tokens), _nest(tokens));
        console.log("gas claimRewards (one gauge, fee and incentive sides, two tokens)", vm.lastFrameGas().gasTotalUsed);

        assertEq(IERC20(MUSDC).balanceOf(pos.holder) - holderC, dueC, "C10: paid exactly what arrived");
        assertEq(IERC20(MUSDT).balanceOf(pos.holder) - holderT, dueT);
        assertEq(IERC20(MUSDC).balanceOf(address(lm)), lmC, "nothing left behind");
        assertEq(IERC20(MUSDT).balanceOf(address(lm)), lmT);
        console.log("rewards forwarded (mUSDC wei, mUSDT wei)", dueC, dueT);

        assertFalse(IPoolsVoter(POOLS_VOTER).isWhitelistedToken(VEBTC), "veBTC is not a whitelisted token");
        vm.startPrank(pos.holder);
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.TokenNotWhitelisted.selector, VEBTC));
        lm.claimRewards(pos.tokenId, _list(poolGauge), _nest(_list(VEBTC)), _nest(new address[](0)));
        vm.expectRevert(abi.encodeWithSelector(ILoanManager.UnknownGauge.selector, fees));
        lm.claimRewards(pos.tokenId, _list(fees), _nest(tokens), _nest(new address[](0)));
        vm.stopPrank();
    }

    /// @dev The worst case the cap allows: 8 live gauges, one token on each side, so 16 reward contract calls over
    ///      8 distinct ordinary tokens.
    function _claimSixteenListedTokens() internal {
        address[8] memory pick = [
            MUSDC,
            MUSDT,
            0x68bBA5ecC126DedFa52C0399671E3A7a514D311C,
            0x6a7CD8E1384d49f502b4A4CE9aC9eb320835c5d7,
            0x9d36F8f62347538440a212e9162f534f797542df,
            0xa10aD2570ea7b93d19fDae6Bd7189fF4929Bc747,
            0xaaC423eDC4E3ee9ef81517e8093d52737165b71F,
            0xdF708431162Ba247dDaE362D2c919e0fbAfcf9DE
        ];
        address[] memory gaugeList = new address[](8);
        address[][] memory feeTokens = new address[][](8);
        address[][] memory bribeTokens = new address[][](8);
        uint256 found;
        for (uint256 i; i < voter.length() && found < 8; ++i) {
            address gauge = voter.gauges(voter.pools(i));
            if (!voter.isAlive(gauge)) continue;
            gaugeList[found] = gauge;
            feeTokens[found] = _list(pick[found]);
            bribeTokens[found] = _list(pick[(found + 4) % 8]);
            ++found;
        }
        assertEq(found, 8, "eight live gauges");
        vm.prank(pos.holder);
        lm.claimRewards(pos.tokenId, gaugeList, feeTokens, bribeTokens);
        uint256 gasUsed = vm.lastFrameGas().gasTotalUsed;
        console.log("gas claimRewards at the 16-token cap", gasUsed);
        assertLt(gasUsed, 5_000_000, "a full claim stays far below Mezo's 10M block gas limit");
    }

    function _extendLock() internal {
        (, uint256 endBefore,) = lm.lockOf(pos.tokenId);
        vm.prank(pos.holder);
        lm.extendLock(pos.tokenId, 28 days);
        console.log("gas extendLock", vm.lastFrameGas().gasTotalUsed);
        (, uint256 endAfter,) = lm.lockOf(pos.tokenId);
        assertEq(endAfter, (vm.getBlockTimestamp() + 28 days) / WEEK * WEEK);
        assertGt(endAfter, endBefore, "the real veBTC pushed the lock end out");
        console.log("lock end before / after", endBefore, endAfter);
    }

    function _claimRebaseIntoTheLock() internal {
        _standInBtc();
        _updateFeePeriod();
        uint256 claimable = IFeeDistributor(FEE_DISTRIBUTOR).claimable(pos.tokenId);
        (uint256 amountBefore,,) = lm.lockOf(pos.tokenId);
        uint256 lmBtc = IERC20(BTC).balanceOf(address(lm));

        vm.prank(pos.holder);
        lm.claimRebase(pos.tokenId);
        console.log("gas claimRebase", vm.lastFrameGas().gasTotalUsed);

        (uint256 amountAfter,,) = lm.lockOf(pos.tokenId);
        assertEq(amountAfter - amountBefore, claimable, "(b) unexpired lock: the claim went into the collateral");
        assertEq(IERC20(BTC).balanceOf(address(lm)), lmBtc, "(b) no BTC was paid to LoanManager");
        assertEq(lm.claimableBtc(pos.holder), 0);
        console.log("fee distributor claim added to the lock (BTC wei)", claimable);
    }

    function _forkMainnet() internal {
        vm.createSelectFork("mezo_mainnet");
        uint256 price = _fetchPriceOnNode(PRICE_FEED);
        _mockPrice(PRICE_FEED, price);
        assertEq(ve.voter(), POOLS_VOTER, "veBTC's primary voter is the PoolsVoter LoanManager calls");
        assertEq(ve.distributor(), FEE_DISTRIBUTOR, "veBTC's fee distributor is the one LoanManager calls");
        console.log("fork block", vm.getBlockNumber());
        console.log("btc price (18 dp)", price);
    }

    function _deploy(
        address veBTC_,
        address feed,
        address musd_,
        address poolsVoter_,
        address validatorsVoter_,
        address distributor,
        uint256 words
    ) internal {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        cm = new CreditMarkets(musd_, BTC, predicted, owner, owner, treasury, 1_000, 10e18, uint32(4 * WEEK), "");
        ILoanManager.Settings memory settings = ILoanManager.Settings({
            owner: owner,
            guardian: owner,
            feeDistributor: distributor,
            validatorsVoter: validatorsVoter_,
            maxVotes: 30,
            maxLtvBps: 4_000,
            liqLtvBps: 6_500,
            minLoan: 10e18,
            penaltyBps: 500,
            auctionFloorBps: 7_000,
            auctionDuration: 72 hours
        });
        lm = new LoanManager(veBTC_, feed, musd_, BTC, poolsVoter_, address(cm), words, settings);
        assertEq(address(lm), predicted);
    }

    /// @dev The position's real owner deposits it and borrows `ltvBps` of its value from a fresh offer.
    function _borrow(Candidate memory c, uint64 date, uint256 ltvBps) internal {
        (, uint256 value) = lm.collateralValue(c.tokenId);
        uint128 principal = uint128(value * ltvBps / BPS);
        assertGe(principal, lm.minLoan(), "position too small for the minimum loan");
        deal(MUSD, lender, principal);
        vm.startPrank(lender);
        IERC20(MUSD).approve(address(cm), principal);
        uint256 offerId = cm.postOffer(date, APR_BPS, principal);
        vm.stopPrank();
        (uint256[] memory ids, uint128[] memory amounts) = _one(offerId, principal);

        vm.startPrank(c.holder);
        ve.approve(address(lm), c.tokenId);
        lm.deposit(c.tokenId);
        lm.borrow(c.tokenId, date, ids, amounts, APR_BPS);
        vm.stopPrank();
        assertEq(ve.ownerOf(c.tokenId), address(lm));
        console.log("borrowed (musd wei)", principal);
    }

    /// @dev Moves into the current epoch's voting window if the fork landed in its first or last hour, and
    ///      returns that epoch's start.
    function _enterVoteWindow() internal returns (uint256 start) {
        uint256 now_ = vm.getBlockTimestamp();
        start = now_ - now_ % WEEK;
        if (now_ <= start + 1 hours || now_ > start + WEEK - 1 hours) {
            start += WEEK;
            _warp(start + 2 hours);
        }
    }

    /// @dev Recreates on the stand-in the distributor's standing approval of veBTC, which on Mezo lives in the
    ///      precompile's own state, so depositFor can pull BTC from it.
    function _standInBtc() internal {
        vm.etch(BTC, type(MezoBtcStandIn).runtimeCode);
        vm.prank(FEE_DISTRIBUTOR);
        IERC20(BTC).approve(VEBTC, type(uint256).max);
    }

    /// @dev The distributor refuses claims until its splitter has rolled into the current epoch; anyone may roll it.
    function _updateFeePeriod() internal {
        IPeriodic splitter = IPeriodic(IFeeDistributorLive(FEE_DISTRIBUTOR).depositor());
        uint256 start = vm.getBlockTimestamp() - vm.getBlockTimestamp() % WEEK;
        if (splitter.activePeriod() < start) splitter.updatePeriod();
        assertEq(splitter.activePeriod(), start);
    }

    function _locked(uint256 id) internal view returns (int128 amount, uint256 end, bool isPermanent, uint256 boost) {
        (bool ok, bytes memory raw) = VEBTC.staticcall(abi.encodeWithSignature("locked(uint256)", id));
        if (!ok || raw.length != MAINNET_LAYOUT_WORDS * 32) return (0, 0, false, 0);
        return abi.decode(raw, (int128, uint256, bool, uint256));
    }

    /// @dev The usual filters (live, EOA owner, NORMAL escrow, no grant manager, at least 0.001 BTC), cheapest
    ///      reads first, because every read on a fork is a round trip to the node.
    function _usable(uint256 id) internal view returns (bool ok, Candidate memory c) {
        return _usableHeldBy(id, false);
    }

    /// @dev As _usable, optionally accepting a contract owner such as a smart-contract wallet; a prank speaks for
    ///      it just as well, and it only ever receives plain ERC-20 transfers here.
    function _usableHeldBy(uint256 id, bool contractOwnerOk) internal view returns (bool ok, Candidate memory c) {
        address holder = ve.ownerOf(id);
        if (holder == address(0) || (!contractOwnerOk && holder.code.length != 0)) return (false, c);
        (int128 amount, uint256 end, bool isPermanent,) = _locked(id);
        if (amount < int128(int256(MIN_LOCK_BTC))) return (false, c);
        if (ve.escrowType(id) != 0 || ve.grantManager(id) != address(0)) return (false, c);
        return (true, Candidate(id, holder, uint256(int256(amount)), end, isPermanent));
    }

    /// @dev A normal lock ending at or after `minEnd`, with no standing vote and no vote this epoch.
    function _findUnvoted(uint256 minEnd) internal view returns (Candidate memory) {
        uint256 newest = ve.tokenId();
        uint256 start = vm.getBlockTimestamp() - vm.getBlockTimestamp() % WEEK;
        for (uint256 i; i < MAX_ID_TRIES && i < newest; ++i) {
            (bool ok, Candidate memory c) = _usable(newest - i);
            if (!ok || c.isPermanent || c.end < minEnd) continue;
            if (ve.voted(c.tokenId) || voter.lastVoted(c.tokenId) >= start) continue;
            return c;
        }
        revert NoUsablePosition("unvoted", newest, MAX_ID_TRIES);
    }

    /// @dev An unexpired normal lock with fees waiting at the distributor.
    function _findWithFees(uint256 minEnd) internal view returns (Candidate memory) {
        uint256 newest = ve.tokenId();
        for (uint256 i; i < MAX_ID_TRIES && i < newest; ++i) {
            (bool ok, Candidate memory c) = _usable(newest - i);
            if (!ok || c.isPermanent || c.end < minEnd) continue;
            if (IFeeDistributor(FEE_DISTRIBUTOR).claimable(c.tokenId) == 0) continue;
            return c;
        }
        revert NoUsablePosition("with fees", newest, MAX_ID_TRIES);
    }

    /// @dev A position whose standing vote includes ValidatorsVoter, the secondary voter LoanManager never resets.
    function _findValidatorVoted(uint64 maturity) internal view returns (Candidate memory) {
        uint256 newest = ve.tokenId();
        for (uint256 i; i < MAX_ID_TRIES && i < newest; ++i) {
            (bool ok, Candidate memory c) = _usable(newest - i);
            if (!ok || (!c.isPermanent && c.end < maturity)) continue;
            address[] memory voters = ve.votedVoters(c.tokenId);
            for (uint256 k; k < voters.length; ++k) {
                if (voters[k] == VALIDATORS_VOTER) return c;
            }
        }
        revert NoUsablePosition("validator voted", newest, MAX_ID_TRIES);
    }

    /// @dev Position 6087 when it still qualifies (EOA owner, NORMAL, no grant, a live ValidatorsVoter vote, a lock
    ///      that reaches `maturity`), else the newest position that does.
    function _validatorVotedOr6087(uint64 maturity) internal view returns (Candidate memory) {
        (bool ok, Candidate memory c) = _usable(6087);
        if (ok && (c.isPermanent || c.end >= maturity) && IVeBTCVoterLive(VALIDATORS_VOTER).usedWeights(6087) != 0) {
            return c;
        }
        console.log("(D) 6087 no longer qualifies; searching");
        return _findValidatorVoted(maturity);
    }

    /// @dev The first time both voters allow a reset after the auction's floor time: past the floor time, past the
    ///      first hour of its epoch, and in an epoch later than either voter's last vote.
    function _resetReady(uint256 tokenId, IVeBTCVoterLive validators) internal view returns (uint256 ready) {
        ILoanManager.Auction memory auction = lm.auctionOf(tokenId);
        ready = uint256(auction.startTime) + auction.duration;
        uint256 lastVote = Math.max(voter.lastVoted(tokenId), validators.lastVoted(tokenId));
        uint256 epoch = ready - ready % WEEK;
        if (ready <= epoch + 1 hours || epoch <= lastVote) {
            uint256 next = Math.max(epoch, lastVote - lastVote % WEEK) + WEEK;
            ready = next + 1 hours + 1;
        }
    }

    /// @dev Calls settle as-is first; Mezo's BTC ERC-20 precompile cannot run locally, so only when that fails is
    ///      the stand-in etched and settle run again, with the real veBTC.withdraw underneath.
    function _settleWithRealCall(uint256 tokenId) internal {
        vm.prank(keeper);
        (bool ok,) = address(lm).call(abi.encodeCall(ILoanManager.settle, (tokenId)));
        if (ok) return;
        console.log("settle against the real BTC precompile reverted locally; etching the stand-in");
        vm.etch(BTC, type(MezoBtcStandIn).runtimeCode);
        vm.prank(keeper);
        lm.settle(tokenId);
    }

    /// @dev Position 6033 (held by a smart-contract wallet, with both MUSD and BTC fees on 2026-10-19) when it still
    ///      has MUSD or BTC fees waiting on gauges it voted for, else the newest usable position that has. Returns
    ///      the gauges with fees waiting.
    function _withMusdOrBtcFees(uint64 maturity) internal view returns (Candidate memory c, address[] memory gauges) {
        bool ok;
        (ok, c) = _usableHeldBy(6033, true);
        if (ok && (c.isPermanent || c.end >= maturity)) {
            gauges = _gaugesWithFees(6033);
            if (gauges.length != 0) return (c, gauges);
        }
        uint256 newest = ve.tokenId();
        for (uint256 i; i < MAX_ID_TRIES && i < newest; ++i) {
            (ok, c) = _usable(newest - i);
            if (!ok || (!c.isPermanent && c.end < maturity) || voter.usedWeights(c.tokenId) == 0) continue;
            gauges = _gaugesWithFees(c.tokenId);
            if (gauges.length != 0) return (c, gauges);
        }
        revert NoPositionWithFees(0);
    }

    /// @dev The gauges among the position's current pool votes whose fee contract owes it MUSD or BTC.
    function _gaugesWithFees(uint256 tokenId) internal view returns (address[] memory gauges) {
        address[] memory found = new address[](8);
        uint256 count;
        for (uint256 i; i < 8; ++i) {
            address pool;
            try voter.poolVote(tokenId, i) returns (address p) {
                pool = p;
            } catch {
                break;
            }
            address gauge = voter.gauges(pool);
            IRewardLive feeReward = IRewardLive(voter.gaugeToFees(gauge));
            if (feeReward.earned(MUSD, tokenId) + feeReward.earned(BTC, tokenId) != 0) found[count++] = gauge;
        }
        gauges = new address[](count);
        for (uint256 i; i < count; ++i) {
            gauges[i] = found[i];
        }
    }

    function _feesDue(address[] memory gauges, uint256 tokenId) internal view returns (uint256 dueMusd, uint256 dueBtc) {
        for (uint256 i; i < gauges.length; ++i) {
            IRewardLive feeReward = IRewardLive(voter.gaugeToFees(gauges[i]));
            dueMusd += feeReward.earned(MUSD, tokenId);
            dueBtc += feeReward.earned(BTC, tokenId);
        }
    }

    function _pair(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        (out[0], out[1]) = (a, b);
    }

    function _findBoostedUnvoted(IBoostVoterLive booster) internal view returns (uint256 id, address gauge) {
        uint256 newest = ve.tokenId();
        for (uint256 i; i < MAX_ID_TRIES && i < newest; ++i) {
            uint256 candidate = newest - i;
            address g = booster.boostableTokenIdToGauge(candidate);
            if (g == address(0) || !booster.isAlive(g)) continue;
            if (ve.ownerOf(candidate) == address(0) || ve.voted(candidate)) continue;
            return (candidate, g);
        }
    }

    function _findVeMezoVoter(IBoostVoterLive booster, uint256 start) internal view returns (uint256 id, address holder) {
        IVeMezoLive veMezo = IVeMezoLive(VEMEZO);
        uint256 newest = veMezo.tokenId();
        for (uint256 i; i < MAX_ID_TRIES && i < newest; ++i) {
            uint256 candidate = newest - i;
            address o = veMezo.ownerOf(candidate);
            if (o == address(0) || o.code.length != 0 || veMezo.escrowType(candidate) != 0) continue;
            if (veMezo.votingPowerOfNFT(candidate) == 0 || veMezo.voted(candidate)) continue;
            if (booster.lastVoted(candidate) >= start) continue;
            return (candidate, o);
        }
    }

    function _logPosition(string memory label, Candidate memory c) internal pure {
        console.log(label, c.tokenId);
        console.log("  holder", c.holder);
        console.log("  locked btc (wei)", c.amount);
        console.log("  lock end / permanent", c.end, c.isPermanent);
    }

    function _list(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _nest(address[] memory inner) internal pure returns (address[][] memory out) {
        out = new address[][](1);
        out[0] = inner;
    }

    function _one(uint256 offerId, uint128 amount) internal pure returns (uint256[] memory ids, uint128[] memory amounts) {
        ids = new uint256[](1);
        amounts = new uint128[](1);
        ids[0] = offerId;
        amounts[0] = amount;
    }

    /// @dev Moves the clock and the block number together, about 3 seconds per block, as ResolutionFork does.
    function _warp(uint256 timestamp) internal {
        uint256 now_ = vm.getBlockTimestamp();
        if (timestamp > now_) vm.roll(vm.getBlockNumber() + (timestamp - now_) / 3 + 1);
        vm.warp(timestamp);
    }

    function _mockPrice(address feed, uint256 price) internal {
        vm.mockCall(feed, abi.encodeWithSelector(IPriceFeed.fetchPrice.selector), abi.encode(price));
    }

    /// @dev Pinned to the fork block so the price and the veBTC reads come from the same state.
    function _fetchPriceOnNode(address feed) internal returns (uint256 price) {
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
        price = abi.decode(raw, (uint256));
        assertGe(price, MIN_BTC_PRICE, "price below sanity floor");
        assertLe(price, MAX_BTC_PRICE, "price above sanity ceiling");
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
