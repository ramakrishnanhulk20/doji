// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// M2a resolution against real Mezo mainnet state: real veBTC positions moved by their real owners, the real
// veBTC contract, MUSD token and PoolsVoter. (a) An unsafe loan is auctioned and bought half way down its
// curve. (b) An unpaid loan's auction goes unsold, settle withdraws the real lock, and that date's lenders
// redeem Bitcoin. (c) A real voted position has its vote cleared by prepareSettle through the real PoolsVoter
// once the epoch turns, then settles. (d) A loan rolls to a later date.
// It does NOT cover: the live Skip oracle (PriceFeed reads a precompile the local EVM cannot run, so the price
// is read from the node once at the fork block, mocked, and then moved by hand); Mezo's BTC ERC-20 precompile,
// which cannot run locally either, so wherever BTC moves (settle, redeem, claim) test/utils/MezoBtcStandIn is
// etched over it after the real call is shown to fail; real buyers, keepers or MUSD acquisition (deal mints
// it); positions owned by contracts; grant or managed positions; ids below the 400 newest; or testnet.

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CreditMarkets} from "../../src/CreditMarkets.sol";
import {LoanManager} from "../../src/LoanManager.sol";
import {ICreditMarkets} from "../../src/interfaces/ICreditMarkets.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {IVeBTC} from "../../src/interfaces/IVeBTC.sol";
import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";
import {IPoolsVoter} from "../../src/interfaces/IPoolsVoter.sol";
import {MezoBtcStandIn} from "../utils/MezoBtcStandIn.sol";

interface IVeBTCMainnet is IVeBTC {
    function tokenId() external view returns (uint256);
    function approve(address spender, uint256 tokenId) external;
    function voter() external view returns (address);
}

interface IPoolsVoterMainnet {
    error AlreadyVotedOrDeposited();
    error DistributeWindow();

    function lastVoted(uint256 tokenId) external view returns (uint256);
}

contract ResolutionForkTest is Test {
    address internal constant VEBTC = 0x3D4b1b884A7a1E59fE8589a3296EC8f8cBB6f279;
    address internal constant MUSD = 0xdD468A1DDc392dcdbEf6db6e34E89AA338F9F186;
    address internal constant PRICE_FEED = 0xc5aC5A8892230E0A3e1c473881A2de7353fFcA88;
    address internal constant BTC = 0x7b7C000000000000000000000000000000000000;
    address internal constant POOLS_VOTER = 0x48233cCC97B87Ba93bCA212cbEe48e3210211f03;
    address internal constant FEE_DISTRIBUTOR = 0xb58477e074265BdC7F7ca6100eD0f7De264F74A2;
    address internal constant VALIDATORS_VOTER = 0xe99a9ad5Ed26BD30e4DB25397f378817e9b9515a;
    uint256 internal constant MAINNET_LAYOUT_WORDS = 4;

    uint256 internal constant WEEK = 604_800;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_ID_TRIES = 400;
    uint256 internal constant MIN_LOCK_BTC = 0.001 ether;
    uint256 internal constant MIN_BTC_PRICE = 10_000e18;
    uint256 internal constant MAX_BTC_PRICE = 1_000_000e18;
    uint16 internal constant MAX_LTV = 4_000;
    uint16 internal constant LIQ_LTV = 6_500;
    uint16 internal constant FLOOR = 7_000;
    uint16 internal constant PENALTY = 500;
    uint32 internal constant DURATION = 72 hours;
    uint16 internal constant APR_BPS = 800;
    // Just under the 40% limit, leaving room for a week of interest at 8%.
    uint256 internal constant BORROW_LTV_BPS = 3_990;

    enum VoteFilter {
        Any,
        Unvoted,
        Voted
    }

    struct Candidate {
        uint256 tokenId;
        address holder;
        uint256 amount;
        uint256 end;
        bool isPermanent;
        bool voted;
    }

    error NoUsablePosition(uint256 newestId, uint256 tries);
    error UnexpectedPriceLength(uint256 length);

    IVeBTCMainnet internal ve = IVeBTCMainnet(VEBTC);
    IERC20 internal musd = IERC20(MUSD);
    IERC20 internal btc = IERC20(BTC);
    CreditMarkets internal cm;
    LoanManager internal lm;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal lender = makeAddr("lender");
    address internal buyer = makeAddr("buyer");
    address internal keeper = makeAddr("keeper");

    uint256 internal forkPrice;
    uint64 internal maturity;

    function test_A_UnsafeLoanSellsHalfWayDownTheCurve() public {
        _fork(DURATION);
        Candidate memory pos = _find(maturity, false, VoteFilter.Any);
        _logPosition("(a) position", pos);
        uint256 face = _borrowAt(pos, maturity, BORROW_LTV_BPS);
        (, uint256 value) = lm.collateralValue(pos.tokenId);
        assertLe(face * BPS, value * MAX_LTV, "borrowed inside 40% LTV");

        _mockPrice(face * BPS * 1e18 / (6_600 * pos.amount));
        assertTrue(lm.isUnsafe(pos.tokenId), "price drop makes the loan unsafe");
        vm.prank(keeper);
        lm.startAuction(pos.tokenId);
        console.log("gas startAuction", vm.lastCallGas().gasTotalUsed);
        ILoanManager.Auction memory a = lm.auctionOf(pos.tokenId);

        _warp(vm.getBlockTimestamp() + DURATION / 2);
        uint256 price = lm.auctionPrice(pos.tokenId);
        assertEq(price, a.startValue - (uint256(a.startValue) - a.floorPrice) / 2, "half way down the curve");
        deal(MUSD, buyer, price);
        uint256 treasuryBefore = lm.claimableMusd(treasury);
        vm.startPrank(buyer);
        musd.approve(address(lm), price);
        uint256 paid = lm.purchase(pos.tokenId, price, block.timestamp);
        console.log("gas purchase", vm.lastCallGas().gasTotalUsed);
        vm.stopPrank();

        uint256 toMarket = cm.marketOf(maturity).collectedMusd;
        uint256 toTreasury = lm.claimableMusd(treasury) - treasuryBefore;
        uint256 toBorrower = lm.claimableMusd(pos.holder);
        assertEq(paid, price);
        assertEq(toMarket + toTreasury + toBorrower, paid, "split sums to the price");
        assertEq(toMarket, face, "market gets the debt");
        assertEq(toTreasury, face * PENALTY / BPS, "treasury gets the 5% penalty");
        assertEq(ve.ownerOf(pos.tokenId), buyer, "buyer owns the real NFT");
        assertEq(cm.marketOf(maturity).openLoans, 0);
        console.log("auction start value (musd wei)", a.startValue);
        console.log("price paid (musd wei)", paid);
        console.log("to market / treasury / borrower", toMarket, toTreasury, toBorrower);
    }

    function test_B_UnsoldAuctionSettlesTheRealLock() public {
        _fork(DURATION);
        Candidate memory pos = _find(maturity, false, VoteFilter.Unvoted);
        _logPosition("(b) position", pos);
        uint256 face = _borrowAt(pos, maturity, BORROW_LTV_BPS);

        _warp(uint256(maturity) + 1);
        vm.prank(keeper);
        lm.startAuction(pos.tokenId);
        assertTrue(lm.isOverdue(pos.tokenId));
        _warp(Math.max(uint256(maturity) + 1 + DURATION, pos.end));

        _settleWithRealCall(pos.tokenId);
        console.log("gas settle (BTC moves through the stand-in)", vm.lastCallGas().gasTotalUsed);

        ICreditMarkets.Market memory market = cm.marketOf(maturity);
        uint256 toTreasury = lm.claimableBtc(treasury);
        uint256 toBorrower = lm.claimableBtc(pos.holder);
        assertEq(market.collectedBtc + toTreasury + toBorrower, pos.amount, "split sums to the BTC the lock held");
        assertEq(market.collectedBtc, Math.mulDiv(face, 1e18, forkPrice, Math.Rounding.Ceil), "market: debt in BTC");
        assertEq(toTreasury, (face * PENALTY / BPS) * 1e18 / forkPrice, "treasury: penalty in BTC");
        assertEq(ve.ownerOf(pos.tokenId), address(0), "withdraw burned the real NFT");
        assertEq(address(lm).balance, 0, "no native BTC arrived: withdraw pays through the ERC-20 view");
        assertEq(btc.balanceOf(address(lm)), lm.totalClaimableBtc(), "LoanManager holds exactly the claimables");

        cm.finalize(maturity);
        vm.startPrank(lender);
        uint256 units = cm.claimUnits(maturity);
        (uint256 musdOut, uint256 btcOut) = cm.redeem(maturity, units);
        vm.stopPrank();
        assertEq(musdOut, 0);
        assertGt(btcOut, 0, "lender redeems Bitcoin");
        assertEq(btc.balanceOf(lender), btcOut);

        vm.prank(pos.holder);
        (, uint256 claimed) = lm.claim();
        assertEq(claimed, toBorrower, "borrower claims the rest of the Bitcoin");
        console.log("btc received from withdraw (wei)", pos.amount);
        console.log("to market / treasury / borrower", market.collectedBtc, toTreasury, toBorrower);
        console.log("lender redeemed units / btc", units, btcOut);
    }

    function test_C_PrepareSettleResetsARealVote() public {
        // A one-hour curve lets the floor time fall inside the vote's own epoch, so the voter's rule shows.
        _fork(1 hours);
        Candidate memory pos = _find(maturity, true, VoteFilter.Voted);
        _logPosition("(c) position", pos);
        uint256 lastVoted = IPoolsVoterMainnet(POOLS_VOTER).lastVoted(pos.tokenId);
        console.log("last voted", lastVoted);
        uint256 face = _borrowAt(pos, maturity, BORROW_LTV_BPS);
        _mockPrice(face * BPS * 1e18 / (6_600 * pos.amount));
        lm.startAuction(pos.tokenId);
        _warp(vm.getBlockTimestamp() + 1 hours);

        uint256 now_ = vm.getBlockTimestamp();
        uint256 epochStart = now_ - (now_ % WEEK);
        if (epochStart <= lastVoted) {
            vm.expectRevert(IPoolsVoterMainnet.AlreadyVotedOrDeposited.selector);
            lm.prepareSettle(pos.tokenId);
            console.log("same epoch as the vote: the real reset reverted AlreadyVotedOrDeposited");
        } else {
            console.log("vote is from an earlier epoch; the same-epoch revert is not reachable on this fork");
        }
        uint256 nextEpoch = epochStart + WEEK;
        _warp(nextEpoch + 30 minutes);
        vm.expectRevert(IPoolsVoterMainnet.DistributeWindow.selector);
        lm.prepareSettle(pos.tokenId);

        _warp(nextEpoch + 1 hours + 1);
        vm.expectCall(POOLS_VOTER, abi.encodeCall(IPoolsVoter.reset, (pos.tokenId)));
        if (pos.isPermanent) vm.expectCall(VEBTC, abi.encodeCall(IVeBTC.unlockPermanent, (pos.tokenId)));
        vm.prank(keeper);
        lm.prepareSettle(pos.tokenId);
        console.log("gas prepareSettle", vm.lastCallGas().gasTotalUsed);
        assertFalse(ve.voted(pos.tokenId), "the real PoolsVoter cleared the vote");

        (, uint256 end, bool isPermanent) = lm.lockOf(pos.tokenId);
        assertFalse(isPermanent);
        assertEq(end % WEEK, 0);
        console.log("lock end after prepare", end);
        _warp(Math.max(end, block.timestamp));
        _settleWithRealCall(pos.tokenId);
        assertGt(cm.marketOf(maturity).collectedBtc, 0, "the voted position settled");
        assertEq(cm.marketOf(maturity).openLoans, 0);
    }

    function test_D_RollsARealLoanToALaterDate() public {
        _fork(DURATION);
        uint64 later = maturity + uint64(WEEK);
        Candidate memory pos = _find(later, true, VoteFilter.Any);
        _logPosition("(d) position", pos);
        uint256 face = _borrowAt(pos, maturity, 3_000);

        (, uint256 value) = lm.collateralValue(pos.tokenId);
        uint128 principal = uint128(value * BORROW_LTV_BPS / BPS);
        uint256 offerId = _post(later, principal);
        uint256 before = musd.balanceOf(pos.holder);
        (uint256[] memory ids, uint128[] memory amounts) = _one(offerId, principal);
        vm.prank(pos.holder);
        (, uint256 newFace) = lm.roll(pos.tokenId, later, ids, amounts, APR_BPS, 0);
        console.log("gas roll", vm.lastCallGas().gasTotalUsed);

        assertEq(musd.balanceOf(pos.holder) - before, principal - face, "excess paid to the borrower");
        assertEq(cm.marketOf(maturity).collectedMusd, face, "old market repaid in full");
        assertEq(cm.marketOf(maturity).openLoans, 0);
        assertEq(lm.loanOf(pos.tokenId).maturity, later);
        assertEq(lm.loanOf(pos.tokenId).face, newFace);
        assertEq(ve.ownerOf(pos.tokenId), address(lm), "the real NFT never left custody");
    }

    function _fork(uint32 auctionDuration) internal {
        vm.createSelectFork("mezo_mainnet");
        forkPrice = _fetchPriceOnNode(PRICE_FEED);
        assertGe(forkPrice, MIN_BTC_PRICE, "price below sanity floor");
        assertLe(forkPrice, MAX_BTC_PRICE, "price above sanity ceiling");
        _mockPrice(forkPrice);
        assertEq(ve.voter(), POOLS_VOTER, "veBTC's voter is the PoolsVoter we reset with");
        // The maturity is fixed before any warp on purpose: settle, finalize and redeem run after that date.
        // forge-lint: disable-next-line(environment-read-across-mutation)
        maturity = uint64((block.timestamp / WEEK + 1) * WEEK);
        console.log("fork block", vm.getBlockNumber());
        console.log("btc price (18 dp)", forkPrice);
        console.log("maturity", maturity);

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        cm = new CreditMarkets(MUSD, BTC, predicted, owner, owner, treasury, 1_000, 10e18, uint32(4 * WEEK), "");
        ILoanManager.Settings memory settings = ILoanManager.Settings({
            owner: owner,
            guardian: owner,
            feeDistributor: FEE_DISTRIBUTOR,
            validatorsVoter: VALIDATORS_VOTER,
            maxVotes: 30,
            maxLtvBps: MAX_LTV,
            liqLtvBps: LIQ_LTV,
            minLoan: 10e18,
            penaltyBps: PENALTY,
            auctionFloorBps: FLOOR,
            auctionDuration: auctionDuration
        });
        lm = new LoanManager(VEBTC, PRICE_FEED, MUSD, BTC, POOLS_VOTER, address(cm), MAINNET_LAYOUT_WORDS, settings);
        assertEq(address(lm), predicted);
    }

    /// @dev Moves the clock and the block number together. veBTC refuses some calls on a position in the
    ///      block it changed owner (unlockPermanent's delegation reset reverts OwnershipChange), and on chain a
    ///      deposit and the resolution after it are always blocks apart. Assumes about 3 seconds per block.
    function _warp(uint256 timestamp) internal {
        uint256 now_ = vm.getBlockTimestamp();
        if (timestamp > now_) vm.roll(vm.getBlockNumber() + (timestamp - now_) / 3 + 1);
        vm.warp(timestamp);
    }

    function _mockPrice(uint256 price) internal {
        vm.mockCall(PRICE_FEED, abi.encodeWithSelector(IPriceFeed.fetchPrice.selector), abi.encode(price));
    }

    function _post(uint64 date, uint128 amount) internal returns (uint256 offerId) {
        deal(MUSD, lender, musd.balanceOf(lender) + amount);
        vm.startPrank(lender);
        musd.approve(address(cm), amount);
        offerId = cm.postOffer(date, APR_BPS, amount);
        vm.stopPrank();
    }

    function _one(uint256 offerId, uint128 amount) internal pure returns (uint256[] memory ids, uint128[] memory amounts) {
        ids = new uint256[](1);
        amounts = new uint128[](1);
        ids[0] = offerId;
        amounts[0] = amount;
    }

    /// @dev The position's real owner deposits it and borrows `ltvBps` of its value from a fresh offer.
    function _borrowAt(Candidate memory pos, uint64 date, uint256 ltvBps) internal returns (uint256 face) {
        (, uint256 value) = lm.collateralValue(pos.tokenId);
        uint128 principal = uint128(value * ltvBps / BPS);
        assertGe(principal, lm.minLoan(), "position too small for the minimum loan");
        uint256 offerId = _post(date, principal);
        (uint256[] memory ids, uint128[] memory amounts) = _one(offerId, principal);

        vm.startPrank(pos.holder);
        ve.approve(address(lm), pos.tokenId);
        lm.deposit(pos.tokenId);
        (, face) = lm.borrow(pos.tokenId, date, ids, amounts, APR_BPS);
        vm.stopPrank();
        assertEq(ve.ownerOf(pos.tokenId), address(lm));
        console.log("borrowed (musd wei)", principal);
        console.log("face (musd wei)", face);
    }

    /// @dev Calls settle as-is first. Mezo's BTC ERC-20 view is a precompile whose stored bytecode only calls
    ///      itself, so on a local fork that call is expected to fail; only then is the stand-in etched and
    ///      settle run again, with the real veBTC.withdraw underneath.
    function _settleWithRealCall(uint256 tokenId) internal {
        vm.prank(keeper);
        (bool ok, bytes memory reason) = address(lm).call(abi.encodeCall(ILoanManager.settle, (tokenId)));
        if (ok) {
            console.log("settle ran against the real BTC precompile");
            return;
        }
        console.log("settle against the real BTC precompile reverted locally, reason bytes:", reason.length);
        console.log("etching MezoBtcStandIn over 0x7b7C...0000 and settling again");
        vm.etch(BTC, type(MezoBtcStandIn).runtimeCode);
        vm.prank(keeper);
        lm.settle(tokenId);
    }

    /// @dev Walks down from the newest id, as CoreSliceFork does: EOA owner, NORMAL escrow, no grant manager,
    ///      at least 0.001 BTC, the vote state asked for, and a normal lock ending at or after `minEnd` (or a
    ///      permanent one when allowed).
    function _find(uint256 minEnd, bool allowPermanent, VoteFilter filter) internal view returns (Candidate memory) {
        uint256 newest = ve.tokenId();
        for (uint256 i; i < MAX_ID_TRIES && i < newest; ++i) {
            uint256 id = newest - i;
            address holder = ve.ownerOf(id);
            if (holder == address(0) || holder.code.length != 0) continue;
            if (ve.escrowType(id) != 0 || ve.grantManager(id) != address(0)) continue;
            bool voted = ve.voted(id);
            if ((filter == VoteFilter.Unvoted && voted) || (filter == VoteFilter.Voted && !voted)) continue;

            (bool ok, bytes memory raw) = VEBTC.staticcall(abi.encodeWithSignature("locked(uint256)", id));
            if (!ok || raw.length != MAINNET_LAYOUT_WORDS * 32) continue;
            (int128 amount, uint256 end, bool isPermanent,) = abi.decode(raw, (int128, uint256, bool, uint256));
            if (amount < int128(int256(MIN_LOCK_BTC))) continue;
            if (isPermanent ? !allowPermanent : end < minEnd) continue;
            return Candidate(id, holder, uint256(int256(amount)), end, isPermanent, voted);
        }
        revert NoUsablePosition(newest, MAX_ID_TRIES);
    }

    function _logPosition(string memory label, Candidate memory pos) internal pure {
        console.log(label, pos.tokenId);
        console.log("  holder", pos.holder);
        console.log("  locked btc (wei)", pos.amount);
        console.log("  lock end", pos.end);
        console.log("  permanent / voted", pos.isPermanent, pos.voted);
    }

    /// @dev Pinned to the fork block so the price and the veBTC reads come from the same state.
    function _fetchPriceOnNode(address feed) internal returns (uint256) {
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
        return abi.decode(raw, (uint256));
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
