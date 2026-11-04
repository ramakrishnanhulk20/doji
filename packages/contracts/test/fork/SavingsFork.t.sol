// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Parked offers against real Mezo mainnet state: the real sMUSD vault (MUSDSavingsRate behind its proxy), the real
// MUSD token, the real veBTC contract and a real position moved by its real owner. A lender parks two offers in the
// vault, the position's owner borrows from the first and is paid exactly the principal out of the vault, and the
// lender cancels the second and gets exactly its amount back.
// It does NOT cover: the live Skip oracle (PriceFeed reads a precompile the local EVM cannot run, so the price is read
// from the node once at the fork block and mocked); real MUSD acquisition (deal mints the lender's MUSD, as the other
// fork suites do); yield arriving between post and fill, which needs the next order's booking; a vault owner
// changing the strategy or upgrading the proxy; positions owned by contracts, grant or managed positions, or ids
// below the 400 newest; or testnet, which script/savings-slice.sh proves with live transactions.

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreditMarkets} from "../../src/CreditMarkets.sol";
import {LoanManager} from "../../src/LoanManager.sol";
import {ICreditMarkets} from "../../src/interfaces/ICreditMarkets.sol";
import {ILoanManager} from "../../src/interfaces/ILoanManager.sol";
import {IMUSDSavingsRate} from "../../src/interfaces/IMUSDSavingsRate.sol";
import {IVeBTC} from "../../src/interfaces/IVeBTC.sol";
import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";

interface IVeBTCMainnet is IVeBTC {
    function tokenId() external view returns (uint256);
    function approve(address spender, uint256 tokenId) external;
}

contract SavingsForkTest is Test {
    address internal constant VEBTC = 0x3D4b1b884A7a1E59fE8589a3296EC8f8cBB6f279;
    address internal constant MUSD = 0xdD468A1DDc392dcdbEf6db6e34E89AA338F9F186;
    address internal constant PRICE_FEED = 0xc5aC5A8892230E0A3e1c473881A2de7353fFcA88;
    address internal constant BTC = 0x7b7C000000000000000000000000000000000000;
    address internal constant POOLS_VOTER = 0x48233cCC97B87Ba93bCA212cbEe48e3210211f03;
    address internal constant FEE_DISTRIBUTOR = 0xb58477e074265BdC7F7ca6100eD0f7De264F74A2;
    address internal constant VALIDATORS_VOTER = 0xe99a9ad5Ed26BD30e4DB25397f378817e9b9515a;
    address internal constant SMUSD = 0xb4D498029af77680cD1eF828b967f010d06C51CC;
    uint256 internal constant MAINNET_LAYOUT_WORDS = 4;

    uint256 internal constant WEEK = 604_800;
    uint256 internal constant MAX_ID_TRIES = 400;
    uint256 internal constant MIN_LOCK_BTC = 0.001 ether;
    uint256 internal constant MIN_BTC_PRICE = 10_000e18;
    uint256 internal constant MAX_BTC_PRICE = 1_000_000e18;
    uint256 internal constant MAX_PRINCIPAL = 50_000e18;
    uint128 internal constant SECOND_OFFER = 1_234e18;
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
    IMUSDSavingsRate internal vault = IMUSDSavingsRate(SMUSD);
    CreditMarkets internal cm;
    LoanManager internal lm;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal lender = makeAddr("lender");

    function test_ParkedOffersOnTheRealSavingsVault() public {
        vm.createSelectFork("mezo_mainnet");
        uint256 price = _fetchPriceOnNode(PRICE_FEED);
        assertGe(price, MIN_BTC_PRICE, "price below sanity floor");
        assertLe(price, MAX_BTC_PRICE, "price above sanity ceiling");
        vm.mockCall(PRICE_FEED, abi.encodeWithSelector(IPriceFeed.fetchPrice.selector), abi.encode(price));
        assertEq(vault.musdToken(), MUSD, "the vault takes mainnet MUSD");

        uint64 maturity = uint64((block.timestamp / WEEK + 1) * WEEK);
        Candidate memory pos = _findPosition(maturity);
        console.log("fork block", block.number);
        console.log("btc price (18 dp)", price);
        console.log("tokenId / holder", pos.tokenId, pos.holder);
        _deploy();

        (, uint256 usdValue) = lm.collateralValue(pos.tokenId);
        uint128 principal = uint128(usdValue / 4 / 1e18 * 1e18);
        if (principal > MAX_PRINCIPAL) principal = uint128(MAX_PRINCIPAL);
        assertGe(principal, lm.minLoan(), "position too small for the minimum loan");

        uint256 first = _parkAndCheck(maturity, principal);
        uint256 second = _parkAndCheck(maturity, SECOND_OFFER);
        assertTrue(cm.offerOf(first).parked && cm.offerOf(second).parked);
        assertEq(cm.parkedPrincipal(), uint256(principal) + SECOND_OFFER);

        _borrowFromParked(pos, maturity, first, principal);
        _cancelParked(second);

        assertEq(cm.parkedPrincipal(), 0, "every parked offer is out of the vault");
        assertEq(vault.balanceOf(address(cm)), 0);
        assertEq(musd.allowance(address(cm), SMUSD), 0, "no allowance left behind");
    }

    /// @dev C30 and C34 on the real vault: the sMUSD minted is exactly the amount and no approval outlives the call.
    function _parkAndCheck(uint64 maturity, uint128 amount) internal returns (uint256 offerId) {
        deal(MUSD, lender, musd.balanceOf(lender) + amount);
        uint256 sharesBefore = vault.balanceOf(address(cm));
        uint256 cmMusdBefore = musd.balanceOf(address(cm));
        vm.startPrank(lender);
        musd.approve(address(cm), amount);
        offerId = cm.postParkedOffer(maturity, APR_BPS, amount);
        vm.stopPrank();
        console.log("gas postParkedOffer (real vault deposit)", vm.lastFrameGas().gasTotalUsed);

        assertEq(vault.balanceOf(address(cm)) - sharesBefore, amount, "real sMUSD rose by exactly the amount");
        assertGe(musd.balanceOf(address(cm)), cmMusdBefore, "the MUSD went on to the vault");
        assertEq(musd.allowance(address(cm), SMUSD), 0, "approval cleared in the same call");
    }

    /// @dev C30 on the real vault: the borrower gets exactly the principal, all of it out of the vault.
    function _borrowFromParked(Candidate memory pos, uint64 maturity, uint256 offerId, uint128 principal) internal {
        uint256[] memory ids = new uint256[](1);
        uint128[] memory amounts = new uint128[](1);
        (ids[0], amounts[0]) = (offerId, principal);
        uint256 sharesBefore = vault.balanceOf(address(cm));
        uint256 cmMusdBefore = musd.balanceOf(address(cm));

        vm.startPrank(pos.holder);
        ve.approve(address(lm), pos.tokenId);
        lm.deposit(pos.tokenId);
        uint256 holderBefore = musd.balanceOf(pos.holder);
        (uint256 borrowed, uint256 face) = lm.borrow(pos.tokenId, maturity, ids, amounts, APR_BPS);
        console.log("gas borrow from a parked offer (real vault withdraw)", vm.lastFrameGas().gasTotalUsed);
        vm.stopPrank();

        assertEq(borrowed, principal);
        assertEq(musd.balanceOf(pos.holder) - holderBefore, principal, "borrower got exactly the principal");
        assertEq(sharesBefore - vault.balanceOf(address(cm)), principal, "real sMUSD fell by exactly the principal");
        assertGe(musd.balanceOf(address(cm)), cmMusdBefore, "nothing paid from MUSD held in CreditMarkets");
        assertEq(lm.loanOf(pos.tokenId).face, face);
        assertEq(cm.offerOf(offerId).remaining, 0);
        console.log("borrowed / face (musd wei)", borrowed, face);
        console.log("vault yield kept by CreditMarkets (musd wei)", musd.balanceOf(address(cm)) - cmMusdBefore);
    }

    function _cancelParked(uint256 offerId) internal {
        uint128 refund = cm.offerOf(offerId).remaining;
        uint256 sharesBefore = vault.balanceOf(address(cm));
        uint256 lenderBefore = musd.balanceOf(lender);
        vm.prank(lender);
        cm.cancelOffer(offerId);
        console.log("gas cancel of a parked offer (real vault withdraw)", vm.lastFrameGas().gasTotalUsed);

        assertEq(musd.balanceOf(lender) - lenderBefore, refund, "lender got exactly the remaining back");
        assertEq(sharesBefore - vault.balanceOf(address(cm)), refund, "real sMUSD fell by exactly the refund");
    }

    function _deploy() internal {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        cm = new CreditMarkets(MUSD, BTC, predicted, owner, owner, treasury, 1_000, 10e18, uint32(4 * WEEK), "", SMUSD);
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
        assertEq(cm.savingsVault(), SMUSD);
    }

    /// @dev As CoreSliceFork: walks down from the newest id, EOA owner, NORMAL escrow, no grant manager, at least
    ///      0.001 BTC, preferring a normal lock that outlives the maturity, else a permanent one.
    function _findPosition(uint64 maturity) internal view returns (Candidate memory) {
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
