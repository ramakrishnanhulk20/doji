// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DeployCore} from "./DeployCore.s.sol";
import {CreditMarkets} from "../src/CreditMarkets.sol";
import {LoanManager} from "../src/LoanManager.sol";
import {ICreditMarkets} from "../src/interfaces/ICreditMarkets.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {MezoBtcStandIn} from "../test/utils/MezoBtcStandIn.sol";

interface ITigrisRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function defaultFactory() external view returns (address);
    function getAmountsOut(uint256 amountIn, Route[] calldata routes) external view returns (uint256[] memory);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory);
}

interface IVeBTCLocks {
    function createLock(uint256 value, uint256 lockDuration) external returns (uint256);
    function approve(address spender, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title CoreSliceLive
/// @notice The M1 core slice on Mezo testnet with two wallets. The deployer lends: it swaps a little BTC for
///         MUSD on Tigris and posts an offer for the next Thursday. The borrower locks a little BTC as veBTC,
///         deposits it, borrows from that offer, repays the full face and takes the position back.
/// @dev Dry run (no BTC needed): forge script script/CoreSliceLive.s.sol --rpc-url mezo_testnet --skip-simulation
///      Live run, after DeployCore is broadcast and the deployer holds at least 0.003 testnet BTC:
///        forge script script/CoreSliceLive.s.sol --rpc-url mezo_testnet --broadcast --skip-simulation --slow
///      Rehearse both scripts first on an anvil fork with script/rehearse-live.sh, which uses the same flags.
///      Forge prints every transaction hash and saves them in broadcast/CoreSliceLive.s.sol/31611/run-latest.json.
///      The local run cannot execute Mezo's precompiles, so before anything runs it etches a stand-in over the
///      BTC ERC-20 precompile and mocks PriceFeed with the node's live price. Those changes stay local: the
///      broadcast transactions run against the real precompiles. --skip-simulation stops forge from replaying
///      them in a second local EVM that has neither stand-in, and makes it estimate each transaction's gas on
///      the node just before sending it. Reads BORROWER_PRIVATE_KEY and BORROWER_ADDRESS from .env too.
contract CoreSliceLive is DeployCore {
    using SafeERC20 for IERC20;

    struct Wallets {
        uint256 lenderKey;
        address lender;
        uint256 borrowerKey;
        address borrower;
    }

    address internal constant BTC = 0x7b7C000000000000000000000000000000000000;
    address internal constant ROUTER = 0x9a1ff7FE3a0F69959A3fBa1F1e5ee18e1A9CD7E9;

    uint256 internal constant MIN_LENDER_BTC = 0.003 ether;
    uint256 internal constant SWAP_BTC = 0.0003 ether;
    uint256 internal constant LOCK_BTC = 0.001 ether;
    uint256 internal constant BORROWER_GAS_BTC = 0.0002 ether;
    uint128 internal constant OFFER_MUSD = 20e18;
    uint128 internal constant BORROW_MUSD = 15e18;
    uint256 internal constant INTEREST_GIFT_MUSD = 1e18;
    uint16 internal constant APR_BPS = 500;
    uint256 internal constant LOCK_DURATION = 2 weeks;
    uint256 internal constant SLIPPAGE_BPS = 200;

    error DeployerUnderfunded(uint256 balance, uint256 needed);
    error NoLiveDeployment(string path);
    error DeploymentMismatch(address creditMarkets, address loanManager);
    error NativeTransferFailed();

    function run() public override {
        Wallets memory w;
        (w.lenderKey, w.lender) = _wallet("DEPLOYER_PRIVATE_KEY", "DEPLOYER_ADDRESS");
        (w.borrowerKey, w.borrower) = _wallet("BORROWER_PRIVATE_KEY", "BORROWER_ADDRESS");
        ChainConfig memory cfg = _config();
        bool live = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);

        _fundIfDryRun(w.lender, live);
        _standInForLocalRun(cfg);
        (CreditMarkets cm, LoanManager lm) = _loadOrDeploy(cfg, w, live);

        uint64 maturity = uint64((block.timestamp / WEEK + 1) * WEEK);
        uint256 offerId = _lend(cfg, w, cm, maturity);
        uint256 tokenId = _borrowRepayWithdraw(cfg, w, lm, maturity, offerId);
        _report(cfg, w, cm, maturity, offerId, tokenId);
    }

    function _fundIfDryRun(address lender, bool live) internal {
        console.log("deployer BTC on testnet:", lender.balance);
        if (lender.balance >= MIN_LENDER_BTC) return;
        if (live) revert DeployerUnderfunded(lender.balance, MIN_LENDER_BTC);
        vm.deal(lender, MIN_LENDER_BTC);
        console.log("SIMULATION ONLY: deployer topped up with vm.deal. Live run waiting on faucet BTC.");
    }

    function _standInForLocalRun(ChainConfig memory cfg) internal {
        vm.etch(BTC, type(MezoBtcStandIn).runtimeCode);
        uint256 price = _priceOnNode(cfg.priceFeed);
        if (price < MIN_BTC_PRICE || price > MAX_BTC_PRICE) revert PriceOutOfRange(price);
        vm.mockCall(cfg.priceFeed, abi.encodeWithSelector(IPriceFeed.fetchPrice.selector), abi.encode(price));
        console.log("live BTC price from the node (18 dp):", price);
    }

    function _loadOrDeploy(ChainConfig memory cfg, Wallets memory w, bool live)
        internal
        returns (CreditMarkets cm, LoanManager lm)
    {
        string memory path = string.concat(_deploymentsDir(), "/", vm.toString(block.chainid), ".json");
        if (vm.exists(path)) {
            string memory json = vm.readFile(path);
            if (vm.parseJsonBool(json, ".broadcast")) {
                cm = CreditMarkets(vm.parseJsonAddress(json, ".creditMarkets"));
                lm = LoanManager(vm.parseJsonAddress(json, ".loanManager"));
                if (address(cm).code.length == 0 || address(lm).code.length == 0) revert NoLiveDeployment(path);
                if (address(lm.creditMarkets()) != address(cm) || address(lm.veBTC()) != cfg.veBTC) {
                    revert DeploymentMismatch(address(cm), address(lm));
                }
                console.log("using live deployment from", path);
                return (cm, lm);
            }
        }
        if (live) revert NoLiveDeployment(path);
        console.log("SIMULATION ONLY: no broadcast deployment recorded, deploying locally");
        return _deployCore(cfg, w.lenderKey, w.lender);
    }

    function _lend(ChainConfig memory cfg, Wallets memory w, CreditMarkets cm, uint64 maturity)
        internal
        returns (uint256 offerId)
    {
        ITigrisRouter router = ITigrisRouter(ROUTER);
        ITigrisRouter.Route[] memory routes = new ITigrisRouter.Route[](1);
        routes[0] = ITigrisRouter.Route({from: BTC, to: cfg.musd, stable: false, factory: router.defaultFactory()});
        uint256 quoted = router.getAmountsOut(SWAP_BTC, routes)[1];
        uint256 minOut = quoted * (10_000 - SLIPPAGE_BPS) / 10_000;

        vm.startBroadcast(w.lenderKey);
        IERC20(BTC).forceApprove(ROUTER, SWAP_BTC);
        uint256 musdOut = router.swapExactTokensForTokens(SWAP_BTC, minOut, routes, w.lender, block.timestamp + 15 minutes)[1];
        IERC20(cfg.musd).forceApprove(address(cm), OFFER_MUSD);
        offerId = cm.postOffer(maturity, APR_BPS, OFFER_MUSD);
        (bool sent,) = w.borrower.call{value: LOCK_BTC + BORROWER_GAS_BTC}("");
        if (!sent) revert NativeTransferFailed();
        IERC20(cfg.musd).safeTransfer(w.borrower, INTEREST_GIFT_MUSD);
        vm.stopBroadcast();

        console.log("swap: BTC in", SWAP_BTC);
        console.log("swap: MUSD out", musdOut);
        console.log("offer id", offerId);
        console.log("offer maturity", maturity);
    }

    function _borrowRepayWithdraw(
        ChainConfig memory cfg,
        Wallets memory w,
        LoanManager lm,
        uint64 maturity,
        uint256 offerId
    ) internal returns (uint256 tokenId) {
        IVeBTCLocks ve = IVeBTCLocks(cfg.veBTC);
        uint256[] memory ids = new uint256[](1);
        uint128[] memory amounts = new uint128[](1);
        (ids[0], amounts[0]) = (offerId, BORROW_MUSD);

        vm.startBroadcast(w.borrowerKey);
        IERC20(BTC).forceApprove(cfg.veBTC, LOCK_BTC);
        tokenId = ve.createLock(LOCK_BTC, LOCK_DURATION);
        ve.approve(address(lm), tokenId);
        lm.deposit(tokenId);
        (uint256 principal, uint256 face) = lm.borrow(tokenId, maturity, ids, amounts, APR_BPS);
        IERC20(cfg.musd).forceApprove(address(lm), face);
        uint256 paid = lm.repay(tokenId, face);
        lm.withdrawCollateral(tokenId);
        vm.stopBroadcast();

        (, uint256 lockEnd,) = lm.lockOf(tokenId);
        console.log("veBTC tokenId", tokenId);
        console.log("lock end", lockEnd);
        console.log("borrowed MUSD", principal);
        console.log("face MUSD", face);
        console.log("repaid MUSD", paid);
    }

    function _report(
        ChainConfig memory cfg,
        Wallets memory w,
        CreditMarkets cm,
        uint64 maturity,
        uint256 offerId,
        uint256 tokenId
    ) internal view {
        ICreditMarkets.Market memory market = cm.marketOf(maturity);
        console.log("position owner after withdraw", IVeBTCLocks(cfg.veBTC).ownerOf(tokenId));
        console.log("market open loans", market.openLoans);
        console.log("market collected MUSD", market.collectedMusd);
        console.log("offer remaining MUSD", cm.offerOf(offerId).remaining);
        console.log("lender pending units", cm.pendingUnits(w.lender, maturity));
        console.log("lender BTC", IERC20(BTC).balanceOf(w.lender));
        console.log("lender MUSD", IERC20(cfg.musd).balanceOf(w.lender));
        console.log("borrower BTC", IERC20(BTC).balanceOf(w.borrower));
        console.log("borrower MUSD", IERC20(cfg.musd).balanceOf(w.borrower));
        console.log("explorer: https://explorer.test.mezo.org/tx/<hash> for each hash forge prints on --broadcast");
    }
}
