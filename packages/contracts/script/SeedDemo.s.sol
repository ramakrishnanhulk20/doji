// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DeployCore} from "./DeployCore.s.sol";
import {ITigrisRouter} from "./CoreSliceLive.s.sol";
import {CreditMarkets} from "../src/CreditMarkets.sol";
import {LoanManager} from "../src/LoanManager.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {MezoBtcStandIn} from "../test/utils/MezoBtcStandIn.sol";

/// @title SeedDemo
/// @notice Seeds the live Doji deployment on Mezo testnet with the state a judge walks through. The deployer lends:
///         it buys MUSD on Tigris and posts offers on four Thursdays. Two loans fall due on Thursday 2026-10-22 and
///         are left unpaid on purpose: loan A (BORROWER) ends in a Bitcoin settlement, loan B (BORROWER2) is bought
///         at auction by BUYER. Loan C (BORROWER) stays healthy until 2026-10-29. KEEPER gets gas to start the
///         auctions and settle them. Every address, offer id, position id and amount goes to
///         deployments/<chainId>-demo.json.
/// @dev Run once, after DeployCore is broadcast and its record is in deployments/<chainId>.json:
///        forge script script/SeedDemo.s.sol --rpc-url mezo_testnet --broadcast --skip-simulation --slow
///      Running it again posts a second set of offers and loans. Rehearse on an anvil fork first, with the BTC and
///      Skip oracle stand-ins and the same flags. Reads DEPLOYER, BORROWER, BORROWER2, BUYER and KEEPER keys and
///      addresses from .env, and DEPLOYMENTS_DIR if set (the rehearsal only).
///      As in CoreSliceLive, the local pass etches a stand-in over the BTC ERC-20 precompile and mocks PriceFeed
///      with the node's live price; the broadcast transactions run against the real precompiles. Position ids
///      come from veBTC, so the recorded ids are what the local pass saw; a lock minted by someone else between
///      the local pass and the broadcast shifts them, which the read-back after the broadcast catches.
contract SeedDemo is DeployCore {
    using SafeERC20 for IERC20;

    uint256 internal constant OFFER_COUNT = 5;

    struct Wallets {
        uint256 deployerKey;
        address deployer;
        uint256 borrowerKey;
        address borrower;
        uint256 borrower2Key;
        address borrower2;
        uint256 buyerKey;
        address buyer;
        uint256 keeperKey;
        address keeper;
    }

    struct OfferPlan {
        uint64 maturity;
        uint16 aprBps;
        uint128 amount;
    }

    struct DemoLoan {
        string role;
        address borrower;
        uint256 tokenId;
        uint256 offerId;
        uint64 maturity;
        uint256 lockEnd;
        uint256 principal;
        uint256 face;
        uint256 valueAtSeed;
    }

    struct Funding {
        uint256 swapBtc;
        uint256 swapMusd;
        uint256 borrowerTopUp;
        uint256 buyerMusd;
        uint256 btcSpent;
    }

    struct Demo {
        Wallets w;
        CreditMarkets cm;
        LoanManager lm;
        uint256 price;
        uint256 value;
        Funding f;
        OfferPlan[OFFER_COUNT] plans;
        uint256[OFFER_COUNT] offerIds;
        DemoLoan[3] loans;
    }

    address internal constant BTC = 0x7b7C000000000000000000000000000000000000;
    address internal constant ROUTER = 0x9a1ff7FE3a0F69959A3fBa1F1e5ee18e1A9CD7E9;
    string internal constant EXPLORER = "https://explorer.test.mezo.org";

    uint64 internal constant OCT_22 = 1_792_627_200;
    uint64 internal constant OCT_29 = 1_793_232_000;
    uint64 internal constant NOV_05 = 1_793_836_800;
    uint64 internal constant NOV_12 = 1_794_441_600;

    uint256 internal constant SWAP_BTC = 0.004 ether;
    uint256 internal constant EXTRA_SWAP_BTC = 0.002 ether;
    uint256 internal constant SLIPPAGE_BPS = 200;
    uint256 internal constant NEW_WALLET_BTC = 0.002 ether;
    uint256 internal constant LOCK_BTC = 0.001 ether;
    uint256 internal constant BORROWER_GAS_BTC = 0.0002 ether;
    uint256 internal constant DEMO_LTV_BPS = 3_500;
    uint256 internal constant HEALTHY_LTV_BPS = 3_000;
    // The auction starts from the value on 2026-10-22, not today's, so the buyer holds a quarter more in case
    // Bitcoin rises before then.
    uint256 internal constant BUYER_HEADROOM_BPS = 12_500;
    uint256 internal constant BTC_BUDGET = 0.02 ether;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant CENT = 1e16;

    error NoLiveDeployment(string path);
    error DeploymentMismatch(address creditMarkets, address loanManager);
    error MaturityNotOpen(uint64 maturity);
    error DeployerUnderfunded(uint256 balance, uint256 needed);
    error MusdShort(uint256 held, uint256 needed);
    error OverBudget(uint256 spent, uint256 budget);
    error LockEndMismatch(uint256 tokenId, uint256 lockEnd, uint64 expected);
    error NativeTransferFailed(address to);

    /// @notice Seeds the demo offers, loans and wallets, then writes the demo record and prints a summary.
    /// @dev Reverts before anything is broadcast if the deployment record is not a live one, any maturity is no
    ///      longer open, the deployer cannot cover the plan, the MUSD bought falls short even after the extra
    ///      swap, the BTC sent out would reach the 0.02 budget, or a lock would not end on its loan's maturity.
    function run() public override {
        Demo memory d;
        d.w = _wallets();
        ChainConfig memory cfg = _config();
        d.price = _standInForLocalRun(cfg);
        (d.cm, d.lm) = _loadLive(cfg);
        _requireOpenMaturities(d.cm);
        d.value = LOCK_BTC * d.price / 1e18;
        d.plans = _offerPlans();

        // Read through the BTC ERC-20 view: the local pass books swaps and locks there, not in the native balance.
        uint256 startBalance = _btcOf(d.w.deployer);
        _lend(cfg, d);
        _borrowAll(d);
        d.f.btcSpent = startBalance - _btcOf(d.w.deployer);
        if (d.f.btcSpent >= BTC_BUDGET) revert OverBudget(d.f.btcSpent, BTC_BUDGET);

        _writeDemoRecord(d);
        _summary(d);
    }

    function _wallets() internal view returns (Wallets memory w) {
        (w.deployerKey, w.deployer) = _wallet("DEPLOYER_PRIVATE_KEY", "DEPLOYER_ADDRESS");
        (w.borrowerKey, w.borrower) = _wallet("BORROWER_PRIVATE_KEY", "BORROWER_ADDRESS");
        (w.borrower2Key, w.borrower2) = _wallet("BORROWER2_PRIVATE_KEY", "BORROWER2_ADDRESS");
        (w.buyerKey, w.buyer) = _wallet("BUYER_PRIVATE_KEY", "BUYER_ADDRESS");
        (w.keeperKey, w.keeper) = _wallet("KEEPER_PRIVATE_KEY", "KEEPER_ADDRESS");
    }

    function _offerPlans() internal pure returns (OfferPlan[OFFER_COUNT] memory) {
        return [
            OfferPlan({maturity: OCT_22, aprBps: 500, amount: 60e18}),
            OfferPlan({maturity: OCT_29, aprBps: 500, amount: 40e18}),
            OfferPlan({maturity: OCT_29, aprBps: 650, amount: 40e18}),
            OfferPlan({maturity: NOV_05, aprBps: 600, amount: 40e18}),
            OfferPlan({maturity: NOV_12, aprBps: 700, amount: 40e18})
        ];
    }

    function _standInForLocalRun(ChainConfig memory cfg) internal returns (uint256 price) {
        vm.etch(BTC, type(MezoBtcStandIn).runtimeCode);
        price = _priceOnNode(cfg.priceFeed);
        if (price < MIN_BTC_PRICE || price > MAX_BTC_PRICE) revert PriceOutOfRange(price);
        vm.mockCall(cfg.priceFeed, abi.encodeWithSelector(IPriceFeed.fetchPrice.selector), abi.encode(price));
        console.log("live BTC price from the node (18 dp):", price);
    }

    function _loadLive(ChainConfig memory cfg) internal view returns (CreditMarkets cm, LoanManager lm) {
        string memory path = string.concat(_deploymentsDir(), "/", vm.toString(block.chainid), ".json");
        if (!vm.exists(path)) revert NoLiveDeployment(path);
        string memory json = vm.readFile(path);
        if (!vm.parseJsonBool(json, ".broadcast")) revert NoLiveDeployment(path);
        cm = CreditMarkets(vm.parseJsonAddress(json, ".creditMarkets"));
        lm = LoanManager(vm.parseJsonAddress(json, ".loanManager"));
        if (address(cm).code.length == 0 || address(lm).code.length == 0) revert NoLiveDeployment(path);
        if (
            address(lm.creditMarkets()) != address(cm) || cm.loanManager() != address(lm)
                || address(lm.veBTC()) != cfg.veBTC || address(lm.musd()) != cfg.musd
        ) revert DeploymentMismatch(address(cm), address(lm));
        console.log("using live deployment from", path);
    }

    function _requireOpenMaturities(CreditMarkets cm) internal view {
        uint64[4] memory maturities = [OCT_22, OCT_29, NOV_05, NOV_12];
        for (uint256 i; i < maturities.length; ++i) {
            if (!cm.isValidMaturity(maturities[i])) revert MaturityNotOpen(maturities[i]);
        }
    }

    /// @dev Buys the MUSD, posts every offer, then funds the other wallets and hands the buyer its MUSD.
    function _lend(ChainConfig memory cfg, Demo memory d) internal {
        d.f.buyerMusd = _cents(d.value * BUYER_HEADROOM_BPS / BPS);
        d.f.borrowerTopUp = _borrowerTopUp(d.w.borrower);
        _requirePlanFits(_btcOf(d.w.deployer), d.f.borrowerTopUp);
        (d.f.swapBtc, d.f.swapMusd) = _buyMusd(cfg, d.w, _offerTotal(d.plans) + d.f.buyerMusd);
        d.offerIds = _postOffers(cfg, d.w, d.cm, d.plans);
        _fundWallets(cfg, d.w, d.f);
    }

    function _borrowerTopUp(address borrower) internal view returns (uint256) {
        uint256 needed = 2 * LOCK_BTC + BORROWER_GAS_BTC;
        uint256 held = _btcOf(borrower);
        return held >= needed ? 0 : needed - held;
    }

    function _btcOf(address account) internal view returns (uint256) {
        return IERC20(BTC).balanceOf(account);
    }

    /// @dev Checked against the worst case, both swaps, so the run cannot stop halfway for lack of BTC.
    function _requirePlanFits(uint256 balance, uint256 borrowerTopUp) internal pure {
        uint256 needed = SWAP_BTC + EXTRA_SWAP_BTC + 3 * NEW_WALLET_BTC + borrowerTopUp;
        if (needed >= BTC_BUDGET) revert OverBudget(needed, BTC_BUDGET);
        if (balance < needed) revert DeployerUnderfunded(balance, needed);
    }

    function _offerTotal(OfferPlan[OFFER_COUNT] memory plans) internal pure returns (uint256 total) {
        for (uint256 i; i < OFFER_COUNT; ++i) {
            total += plans[i].amount;
        }
    }

    function _buyMusd(ChainConfig memory cfg, Wallets memory w, uint256 needed)
        internal
        returns (uint256 btcIn, uint256 musdOut)
    {
        uint256 held = IERC20(cfg.musd).balanceOf(w.deployer);
        btcIn = SWAP_BTC;
        musdOut = _swap(cfg, w, SWAP_BTC);
        if (held + musdOut < needed) {
            btcIn += EXTRA_SWAP_BTC;
            musdOut += _swap(cfg, w, EXTRA_SWAP_BTC);
        }
        if (held + musdOut < needed) revert MusdShort(held + musdOut, needed);
    }

    function _swap(ChainConfig memory cfg, Wallets memory w, uint256 btcIn) internal returns (uint256 musdOut) {
        ITigrisRouter router = ITigrisRouter(ROUTER);
        ITigrisRouter.Route[] memory routes = new ITigrisRouter.Route[](1);
        routes[0] = ITigrisRouter.Route({from: BTC, to: cfg.musd, stable: false, factory: router.defaultFactory()});
        uint256 minOut = router.getAmountsOut(btcIn, routes)[1] * (BPS - SLIPPAGE_BPS) / BPS;

        vm.startBroadcast(w.deployerKey);
        IERC20(BTC).forceApprove(ROUTER, btcIn);
        musdOut = router.swapExactTokensForTokens(btcIn, minOut, routes, w.deployer, block.timestamp + 15 minutes)[1];
        vm.stopBroadcast();
        console.log("swap: BTC in", btcIn);
        console.log("swap: MUSD out", musdOut);
    }

    function _postOffers(
        ChainConfig memory cfg,
        Wallets memory w,
        CreditMarkets cm,
        OfferPlan[OFFER_COUNT] memory plans
    ) internal returns (uint256[OFFER_COUNT] memory offerIds) {
        vm.startBroadcast(w.deployerKey);
        IERC20(cfg.musd).forceApprove(address(cm), _offerTotal(plans));
        for (uint256 i; i < OFFER_COUNT; ++i) {
            offerIds[i] = cm.postOffer(plans[i].maturity, plans[i].aprBps, plans[i].amount);
        }
        vm.stopBroadcast();
    }

    function _fundWallets(ChainConfig memory cfg, Wallets memory w, Funding memory f) internal {
        vm.startBroadcast(w.deployerKey);
        _send(w.borrower2, NEW_WALLET_BTC);
        _send(w.buyer, NEW_WALLET_BTC);
        _send(w.keeper, NEW_WALLET_BTC);
        if (f.borrowerTopUp > 0) _send(w.borrower, f.borrowerTopUp);
        IERC20(cfg.musd).safeTransfer(w.buyer, f.buyerMusd);
        vm.stopBroadcast();
    }

    function _send(address to, uint256 amount) internal {
        (bool sent,) = to.call{value: amount}("");
        if (!sent) revert NativeTransferFailed(to);
    }

    /// @dev Loans A and B share the Oct 22 offer, so each is capped at half of it in case Bitcoin rose.
    function _borrowAll(Demo memory d) internal {
        uint256 demoPrincipal = _min(_cents(d.value * DEMO_LTV_BPS / BPS), d.plans[0].amount / 2);
        uint256 healthyPrincipal = _min(_cents(d.value * HEALTHY_LTV_BPS / BPS), d.plans[1].amount);
        d.loans[0] = _loanPlan("settle", d.w.borrower, d.offerIds[0], d.plans[0].maturity, demoPrincipal, d.value);
        d.loans[1] = _loanPlan("purchase", d.w.borrower2, d.offerIds[0], d.plans[0].maturity, demoPrincipal, d.value);
        d.loans[2] = _loanPlan("healthy", d.w.borrower, d.offerIds[1], d.plans[1].maturity, healthyPrincipal, d.value);
        _openLoan(d.lm, d.w.borrowerKey, d.loans[0], d.plans[0].aprBps);
        _openLoan(d.lm, d.w.borrower2Key, d.loans[1], d.plans[0].aprBps);
        _openLoan(d.lm, d.w.borrowerKey, d.loans[2], d.plans[1].aprBps);
    }

    function _loanPlan(
        string memory role,
        address borrower,
        uint256 offerId,
        uint64 maturity,
        uint256 principal,
        uint256 value
    ) internal pure returns (DemoLoan memory) {
        return DemoLoan({
            role: role,
            borrower: borrower,
            tokenId: 0,
            offerId: offerId,
            maturity: maturity,
            lockEnd: 0,
            principal: principal,
            face: 0,
            valueAtSeed: value
        });
    }

    /// @dev Fills in the loan's tokenId, lock end, principal received and face.
    function _openLoan(LoanManager lm, uint256 key, DemoLoan memory loan, uint16 aprBps) internal {
        uint256[] memory ids = new uint256[](1);
        uint128[] memory amounts = new uint128[](1);
        (ids[0], amounts[0]) = (loan.offerId, uint128(loan.principal));
        uint256 duration = _lockDurationEndingAt(loan.maturity);

        vm.startBroadcast(key);
        IERC20(BTC).forceApprove(address(lm), LOCK_BTC);
        (loan.tokenId, loan.principal, loan.face) =
            lm.lockAndBorrow(LOCK_BTC, duration, loan.maturity, ids, amounts, aprBps);
        vm.stopBroadcast();

        (, loan.lockEnd,) = lm.lockOf(loan.tokenId);
        if (loan.lockEnd != loan.maturity) revert LockEndMismatch(loan.tokenId, loan.lockEnd, loan.maturity);
    }

    /// @dev veBTC ends a lock at floor((now + duration) / week) * week. Aiming half a week past `end` keeps that
    ///      floor on `end` even when the transaction lands hours after this script read the clock.
    function _lockDurationEndingAt(uint64 end) internal view returns (uint256) {
        if (end <= block.timestamp) revert MaturityNotOpen(end);
        return end + WEEK / 2 - block.timestamp;
    }

    function _cents(uint256 amount) internal pure returns (uint256) {
        return amount / CENT * CENT;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _writeDemoRecord(Demo memory d) internal {
        string memory obj = "demo";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeBool(obj, "broadcast", vm.isContext(VmSafe.ForgeContext.ScriptBroadcast));
        vm.serializeUint(obj, "block", block.number);
        vm.serializeUint(obj, "timestamp", block.timestamp);
        vm.serializeUint(obj, "btcPrice", d.price);
        vm.serializeAddress(obj, "creditMarkets", address(d.cm));
        vm.serializeAddress(obj, "loanManager", address(d.lm));
        vm.serializeString(obj, "wallets", _walletsJson(d.w));
        vm.serializeString(obj, "funding", _fundingJson(d.f));
        vm.serializeString(obj, "offers", _offersJson(d));
        string memory json = vm.serializeString(obj, "loans", _loansJson(d.loans));

        string memory path = string.concat(_deploymentsDir(), "/", vm.toString(block.chainid), "-demo.json");
        vm.writeJson(json, path);
        console.log("wrote", path);
    }

    function _walletsJson(Wallets memory w) internal returns (string memory) {
        string memory obj = "wallets";
        vm.serializeAddress(obj, "deployer", w.deployer);
        vm.serializeAddress(obj, "borrower", w.borrower);
        vm.serializeAddress(obj, "borrower2", w.borrower2);
        vm.serializeAddress(obj, "buyer", w.buyer);
        return vm.serializeAddress(obj, "keeper", w.keeper);
    }

    function _fundingJson(Funding memory f) internal returns (string memory) {
        string memory obj = "funding";
        vm.serializeUint(obj, "swapBtc", f.swapBtc);
        vm.serializeUint(obj, "swapMusd", f.swapMusd);
        vm.serializeUint(obj, "newWalletBtc", NEW_WALLET_BTC);
        vm.serializeUint(obj, "borrowerTopUpBtc", f.borrowerTopUp);
        vm.serializeUint(obj, "buyerMusd", f.buyerMusd);
        return vm.serializeUint(obj, "deployerBtcSent", f.btcSpent);
    }

    function _offersJson(Demo memory d) internal returns (string memory json) {
        string memory obj = "offers";
        for (uint256 i; i < OFFER_COUNT; ++i) {
            string memory one = string.concat("offer", vm.toString(d.offerIds[i]));
            vm.serializeUint(one, "offerId", d.offerIds[i]);
            vm.serializeUint(one, "maturity", d.plans[i].maturity);
            vm.serializeUint(one, "aprBps", d.plans[i].aprBps);
            string memory offerJson = vm.serializeUint(one, "amount", d.plans[i].amount);
            json = vm.serializeString(obj, vm.toString(d.offerIds[i]), offerJson);
        }
    }

    function _loansJson(DemoLoan[3] memory loans) internal returns (string memory json) {
        string[3] memory names = ["A", "B", "C"];
        string memory obj = "loans";
        for (uint256 i; i < loans.length; ++i) {
            string memory one = string.concat("loan", names[i]);
            vm.serializeString(one, "role", loans[i].role);
            vm.serializeAddress(one, "borrower", loans[i].borrower);
            vm.serializeUint(one, "tokenId", loans[i].tokenId);
            vm.serializeUint(one, "offerId", loans[i].offerId);
            vm.serializeUint(one, "maturity", loans[i].maturity);
            vm.serializeUint(one, "lockEnd", loans[i].lockEnd);
            vm.serializeUint(one, "principal", loans[i].principal);
            vm.serializeUint(one, "face", loans[i].face);
            vm.serializeUint(one, "valueAtSeed", loans[i].valueAtSeed);
            string memory loanJson = vm.serializeUint(one, "ltvBps", loans[i].face * BPS / loans[i].valueAtSeed);
            json = vm.serializeString(obj, names[i], loanJson);
        }
    }

    function _summary(Demo memory d) internal pure {
        console.log("== contracts");
        _logLink("CreditMarkets", address(d.cm));
        _logLink("LoanManager  ", address(d.lm));
        console.log("== wallets");
        _logLink("deployer (lender, owner, treasury)", d.w.deployer);
        _logLink("borrower  (loans A and C)", d.w.borrower);
        _logLink("borrower2 (loan B)", d.w.borrower2);
        _logLink("buyer", d.w.buyer);
        _logLink("keeper", d.w.keeper);
        console.log("== offers: id, maturity, apr bps, MUSD wei");
        for (uint256 i; i < OFFER_COUNT; ++i) {
            console.log(d.offerIds[i], d.plans[i].maturity, d.plans[i].aprBps, d.plans[i].amount);
        }
        console.log("== loans: role, tokenId, maturity, face MUSD wei");
        for (uint256 i; i < d.loans.length; ++i) {
            console.log(d.loans[i].role, d.loans[i].tokenId, d.loans[i].maturity, d.loans[i].face);
        }
        console.log("== funding");
        console.log("swap BTC in", d.f.swapBtc);
        console.log("swap MUSD out", d.f.swapMusd);
        console.log("buyer MUSD", d.f.buyerMusd);
        console.log("borrower top-up BTC", d.f.borrowerTopUp);
        console.log("deployer BTC sent out", d.f.btcSpent);
        console.log("transactions: forge prints each hash; open them at", string.concat(EXPLORER, "/tx/<hash>"));
    }

    function _logLink(string memory label, address account) internal pure {
        console.log(label, string.concat(EXPLORER, "/address/", vm.toString(account)));
    }
}
