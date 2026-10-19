// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// The M1 core slice against real Mezo mainnet state: a real veBTC position, the real veBTC contract and
// the real MUSD token. A lender posts an offer, the position's real owner deposits, borrows, repays and
// withdraws, borrows and repays again, and after the maturity the lender redeems for the full face.
// It does NOT cover: the live Skip oracle (PriceFeed reads a Mezo precompile the local EVM cannot run, so
// the price is read from the node once at the fork block and mocked), price moves during the loan, real
// MUSD acquisition (the lender and the borrower's interest are minted with deal), positions owned by
// contracts, grant or managed positions, ids below the 400 newest, or anything on testnet.

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreditMarkets} from "../../src/CreditMarkets.sol";
import {LoanManager} from "../../src/LoanManager.sol";
import {ICreditMarkets} from "../../src/interfaces/ICreditMarkets.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {IVeBTC} from "../../src/interfaces/IVeBTC.sol";
import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";

interface IVeBTCMainnet is IVeBTC {
    function tokenId() external view returns (uint256);
    function approve(address spender, uint256 tokenId) external;
}

contract CoreSliceForkTest is Test {
    address internal constant VEBTC = 0x3D4b1b884A7a1E59fE8589a3296EC8f8cBB6f279;
    address internal constant MUSD = 0xdD468A1DDc392dcdbEf6db6e34E89AA338F9F186;
    address internal constant PRICE_FEED = 0xc5aC5A8892230E0A3e1c473881A2de7353fFcA88;
    address internal constant BTC = 0x7b7C000000000000000000000000000000000000;
    address internal constant POOLS_VOTER = 0x48233cCC97B87Ba93bCA212cbEe48e3210211f03;
    address internal constant FEE_DISTRIBUTOR = 0xb58477e074265BdC7F7ca6100eD0f7De264F74A2;
    address internal constant VALIDATORS_VOTER = 0xe99a9ad5Ed26BD30e4DB25397f378817e9b9515a;
    uint256 internal constant MAINNET_LAYOUT_WORDS = 4;

    uint256 internal constant WEEK = 604_800;
    uint256 internal constant MAX_ID_TRIES = 400;
    uint256 internal constant MIN_LOCK_BTC = 0.001 ether;
    uint256 internal constant MIN_BTC_PRICE = 10_000e18;
    uint256 internal constant MAX_BTC_PRICE = 1_000_000e18;
    uint256 internal constant MAX_PRINCIPAL = 50_000e18;
    uint16 internal constant APR_BPS = 800;

    error NoUsablePosition(uint256 newestId, uint256 tries);
    error UnexpectedPriceLength(uint256 length);

    struct Candidate {
        uint256 tokenId;
        address holder;
        uint256 amount;
        uint256 end;
        bool isPermanent;
    }

    IVeBTCMainnet internal ve = IVeBTCMainnet(VEBTC);
    IERC20 internal musd = IERC20(MUSD);
    CreditMarkets internal cm;
    LoanManager internal lm;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal lender = makeAddr("lender");

    function test_CoreSliceOnMainnetFork() public {
        vm.createSelectFork("mezo_mainnet");

        uint256 price = _fetchPriceOnNode(PRICE_FEED);
        assertGe(price, MIN_BTC_PRICE, "price below sanity floor");
        assertLe(price, MAX_BTC_PRICE, "price above sanity ceiling");
        vm.mockCall(PRICE_FEED, abi.encodeWithSelector(IPriceFeed.fetchPrice.selector), abi.encode(price));

        // The maturity is fixed before the warp on purpose: finalize and redeem must run after that same date.
        // forge-lint: disable-next-line(environment-read-across-mutation)
        uint64 maturity = uint64((block.timestamp / WEEK + 1) * WEEK);
        Candidate memory pos = _findPosition(maturity);
        console.log("fork block", block.number);
        console.log("btc price (18 dp)", price);
        console.log("maturity", maturity);
        console.log("tokenId", pos.tokenId);
        console.log("holder", pos.holder);
        console.log("locked btc (wei)", pos.amount);
        console.log("lock end", pos.end);
        console.log("permanent", pos.isPermanent);

        _deploy();

        (uint256 btcAmount, uint256 usdValue) = lm.collateralValue(pos.tokenId);
        assertEq(btcAmount, pos.amount, "lock reader disagrees with the raw read");
        uint128 principal = uint128(usdValue / 4 / 1e18 * 1e18);
        if (principal > MAX_PRINCIPAL) principal = uint128(MAX_PRINCIPAL);
        assertGe(principal, lm.minLoan(), "position too small for the minimum loan");

        deal(MUSD, lender, uint256(principal) * 2);
        vm.startPrank(lender);
        musd.approve(address(cm), type(uint256).max);
        uint256 offerId = cm.postOffer(maturity, APR_BPS, principal * 2);
        vm.stopPrank();

        uint256 face1 = _depositBorrowRepayWithdraw(pos, maturity, offerId, principal, usdValue);
        uint256 face2 = _depositBorrowRepayWithdraw(pos, maturity, offerId, principal, usdValue);
        assertEq(cm.offerOf(offerId).remaining, 0);

        vm.warp(maturity + 1);
        cm.finalize(maturity);
        ICreditMarkets.Market memory market = cm.marketOf(maturity);
        assertTrue(market.isFinal);
        assertEq(market.unitsAtFinal, face1 + face2);
        assertEq(market.musdAtFinal, face1 + face2);

        uint256 lenderBefore = musd.balanceOf(lender);
        vm.startPrank(lender);
        uint256 lenderUnits = cm.claimUnits(maturity);
        (uint256 lenderOut,) = cm.redeem(maturity, lenderUnits);
        vm.stopPrank();
        vm.startPrank(treasury);
        uint256 treasuryUnits = cm.claimUnits(maturity);
        (uint256 treasuryOut,) = cm.redeem(maturity, treasuryUnits);
        vm.stopPrank();

        assertEq(lenderOut, lenderUnits, "lender paid one MUSD per unit");
        assertEq(musd.balanceOf(lender) - lenderBefore, lenderOut);
        assertEq(lenderOut + treasuryOut, face1 + face2, "units redeem for the full face");
        assertEq(musd.balanceOf(address(cm)), 0, "nothing stuck in CreditMarkets");
        assertEq(ve.ownerOf(pos.tokenId), pos.holder, "position back with its owner");

        console.log("lender units", lenderUnits);
        console.log("lender redeemed (musd wei)", lenderOut);
        console.log("treasury redeemed (musd wei)", treasuryOut);
        console.log("lender profit (musd wei)", lenderOut - uint256(principal) * 2);
    }

    function _deploy() internal {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        cm = new CreditMarkets(MUSD, BTC, predicted, owner, owner, treasury, 1_000, 10e18, uint32(4 * WEEK), "");
        ILoanManager.Settings memory settings = ILoanManager.Settings({
            owner: owner,
            guardian: owner,
            feeDistributor: FEE_DISTRIBUTOR,
            validatorsVoter: VALIDATORS_VOTER,
            maxVotes: 30,
            maxLtvBps: 5_000,
            liqLtvBps: 6_500,
            minLoan: 10e18,
            penaltyBps: 500,
            auctionFloorBps: 7_000,
            auctionDuration: 72 hours
        });
        lm = new LoanManager(VEBTC, PRICE_FEED, MUSD, BTC, POOLS_VOTER, address(cm), MAINNET_LAYOUT_WORDS, settings);
        assertEq(address(lm), predicted);
        assertEq(cm.loanManager(), address(lm));
    }

    function _depositBorrowRepayWithdraw(
        Candidate memory pos,
        uint64 maturity,
        uint256 offerId,
        uint128 principal,
        uint256 usdValue
    ) internal returns (uint256 face) {
        uint64 openBefore = cm.marketOf(maturity).openLoans;
        face = _depositAndBorrow(pos, maturity, offerId, principal, usdValue);
        assertEq(cm.marketOf(maturity).openLoans, openBefore + 1);
        _repayAndWithdraw(pos, face - principal, face);
        assertEq(cm.marketOf(maturity).openLoans, openBefore, "open loans fall back exactly once");
    }

    function _depositAndBorrow(
        Candidate memory pos,
        uint64 maturity,
        uint256 offerId,
        uint128 principal,
        uint256 usdValue
    ) internal returns (uint256 face) {
        uint256[] memory ids = new uint256[](1);
        uint128[] memory amounts = new uint128[](1);
        (ids[0], amounts[0]) = (offerId, principal);

        vm.startPrank(pos.holder);
        ve.approve(address(lm), pos.tokenId);
        lm.deposit(pos.tokenId);
        assertEq(ve.ownerOf(pos.tokenId), address(lm), "LoanManager holds the position");
        assertEq(lm.positionOf(pos.tokenId).borrower, pos.holder);

        uint256 musdBefore = musd.balanceOf(pos.holder);
        uint256 borrowed;
        (borrowed, face) = lm.borrow(pos.tokenId, maturity, ids, amounts, APR_BPS);
        assertEq(borrowed, principal);
        assertEq(musd.balanceOf(pos.holder) - musdBefore, principal, "MUSD arrived");
        assertEq(lm.loanOf(pos.tokenId).face, face);
        assertLe(face, usdValue / 2, "inside max LTV");
        vm.stopPrank();
        console.log("borrowed (musd wei)", borrowed);
        console.log("face (musd wei)", face);
    }

    function _repayAndWithdraw(Candidate memory pos, uint256 interest, uint256 face) internal {
        deal(MUSD, pos.holder, musd.balanceOf(pos.holder) + interest);

        vm.startPrank(pos.holder);
        musd.approve(address(lm), face);
        assertEq(lm.repay(pos.tokenId, face), face);
        assertEq(uint8(lm.loanOf(pos.tokenId).state), uint8(ILoanManager.LoanState.None), "closed in the same call");
        lm.withdrawCollateral(pos.tokenId);
        vm.stopPrank();

        assertEq(ve.ownerOf(pos.tokenId), pos.holder, "position returned");
        assertEq(lm.positionOf(pos.tokenId).borrower, address(0));
    }

    /// @dev Walks down from the newest id because recent locks are the ones still running; old ids are mostly
    /// expired or burned. Prefers a normal lock that outlives the maturity, else falls back to a permanent one.
    function _findPosition(uint64 maturity) internal view returns (Candidate memory best) {
        uint256 newest = ve.tokenId();
        Candidate memory fallbackPick;
        for (uint256 i; i < MAX_ID_TRIES && i < newest; ++i) {
            uint256 id = newest - i;
            address holder = ve.ownerOf(id);
            if (holder == address(0) || holder.code.length != 0) continue;
            if (ve.escrowType(id) != 0 || ve.grantManager(id) != address(0)) continue;

            (bool ok, bytes memory raw) = VEBTC.staticcall(abi.encodeWithSignature("locked(uint256)", id));
            if (!ok || raw.length != MAINNET_LAYOUT_WORDS * 32) continue;
            (int128 amount, uint256 end, bool isPermanent,) = abi.decode(raw, (int128, uint256, bool, uint256));
            if (amount < int128(int256(MIN_LOCK_BTC))) continue;

            Candidate memory found = Candidate(id, holder, uint256(int256(amount)), end, isPermanent);
            if (!isPermanent && end > maturity) return found;
            if (isPermanent && fallbackPick.holder == address(0)) fallbackPick = found;
        }
        if (fallbackPick.holder == address(0)) revert NoUsablePosition(newest, MAX_ID_TRIES);
        return fallbackPick;
    }

    /// @dev Pinned to the fork block so the price and the veBTC reads come from the same state.
    function _fetchPriceOnNode(address feed) internal returns (uint256) {
        string memory params = string.concat(
            '[{"to":"',
            vm.toString(feed),
            '","data":"',
            vm.toString(abi.encodeWithSelector(IPriceFeed.fetchPrice.selector)),
            '"},"',
            _hexQuantity(block.number),
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
