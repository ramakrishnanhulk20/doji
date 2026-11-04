// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ILoanManager} from "./interfaces/ILoanManager.sol";
import {IMezoRouter} from "./interfaces/IMezoRouter.sol";
import {IPayDown} from "./interfaces/IPayDown.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

/// @title PayDown
/// @notice Pays Doji loans down with the positions' own pool rewards. A borrower names PayDown as a position's
///         reward operator once; after that anyone can harvest it. MUSD rewards repay the loan, BTC rewards are
///         sold on Mezo's BTC/MUSD pool for only what the debt still needs and never below the MUSD oracle price
///         minus a capped allowance, and the rest goes straight back to the borrower. Reward tokens with no
///         on-chain price are sold only when the borrower runs harvestAndSwap with their own minimums (F26).
/// @dev Every address it calls is fixed at deployment (C42): LoanManager, Mezo's Router and its default factory,
///      and the MUSD, BTC and PriceFeed LoanManager uses. It keeps no balance between calls: each harvest
///      measures what arrived and sends everything it did not repay to the borrower in the same call, so any
///      token it holds at rest is a stray credited to nobody (C38). The only outside code a harvest runs is
///      LoanManager's claim (Mezo's reward contracts and the reward tokens), the Router with the pools and
///      tokens on the route, and LoanManager's repay, all under this contract's reentrancy lock. LoanManager
///      relies on nothing PayDown says (C37).
contract PayDown is IPayDown, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_SLIPPAGE_BPS = 300;
    /// @dev Each hop is one pool swap. One real Router hop measured 276k to 321k gas cold and about 175k warm on
    ///      the testnet fork (test/fork/PayDownFork.t.sol). Eight swaps of three hops is at most 24 hops, under
    ///      7.8M gas even if every one cost as much as the coldest, plus a full 16-token claim at about 1.0M
    ///      (test/fork/PassThroughFork.t.sol): just inside Mezo's 10M block gas limit. Only the borrower can send
    ///      swaps, so a call over budget fails that borrower's own transaction and nobody else's.
    uint256 public constant MAX_SWAPS = 8;
    uint256 public constant MAX_ROUTE_HOPS = 3;
    /// @dev LoanManager refuses a claim that lists more than its own MAX_REWARD_TOKENS (16), and each gauge must
    ///      list a token, so the same cap bounds every loop here before LoanManager is called.
    uint256 public constant MAX_REWARD_TOKENS = 16;
    uint256 private constant BPS = 10_000;
    uint256 private constant PRICE_SCALE = 1e18;
    uint256 private constant NONE = type(uint256).max;

    ILoanManager public immutable loanManager;
    IMezoRouter public immutable router;
    address public immutable factory;
    IERC20 public immutable musd;
    IERC20 public immutable btc;
    IPriceFeed public immutable priceFeed;

    address public guardian;
    uint16 public slippageBps;
    bool public paused;

    /// @dev One harvest's working state, in memory because the calldata lists leave no stack room. tokens[0] is
    ///      always MUSD, which every sale pays in; base is each token's balance before the claim and gained the
    ///      claim's measured increase. The price and the allowance are read once so the BTC sizing and the BTC
    ///      floor come from the same two numbers.
    struct Run {
        uint256 tokenId;
        address borrower;
        uint256 price;
        uint256 slippage;
        bool open;
        uint256 btcIndex;
        address[] tokens;
        uint256[] base;
        uint256[] gained;
        uint256 btcSold;
        uint256 musdFromBtc;
        uint256 repaid;
    }

    /// @notice Fixes LoanManager and Mezo's Router, and reads MUSD, BTC and the PriceFeed from LoanManager and
    ///         the default factory from the Router, so PayDown can only ever price, sell and repay in what
    ///         LoanManager itself uses.
    /// @dev Reverts ZeroAddress for any zero argument or any zero address read back, or SlippageTooHigh above
    ///      MAX_SLIPPAGE_BPS. Emits GuardianSet and SlippageSet.
    /// @param loanManager_ The LoanManager whose positions PayDown harvests.
    /// @param router_ Mezo's documented pool Router on this chain.
    /// @param owner_ Starting owner.
    /// @param guardian_ Address that may pause harvests alongside the owner.
    /// @param slippageBps_ Starting discount to the oracle price a BTC sale may accept.
    constructor(address loanManager_, address router_, address owner_, address guardian_, uint16 slippageBps_)
        Ownable(_nonZero(owner_))
    {
        ILoanManager manager = ILoanManager(_nonZero(loanManager_));
        IMezoRouter mezoRouter = IMezoRouter(_nonZero(router_));
        loanManager = manager;
        router = mezoRouter;
        musd = IERC20(_nonZero(address(manager.musd())));
        btc = IERC20(_nonZero(address(manager.btc())));
        priceFeed = IPriceFeed(_nonZero(address(manager.priceFeed())));
        factory = _nonZero(mezoRouter.defaultFactory());
        _setGuardian(guardian_);
        _setSlippageBps(slippageBps_);
    }

    /// @inheritdoc IPayDown
    function harvest(
        uint256 tokenId,
        address[] calldata gauges,
        address[][] calldata feeTokens,
        address[][] calldata bribeTokens
    ) external nonReentrant returns (uint256 repaid) {
        Run memory run = _start(tokenId);
        _record(run, feeTokens, bribeTokens, gauges.length);
        _claim(run, gauges, feeTokens, bribeTokens);
        return _finish(run);
    }

    /// @inheritdoc IPayDown
    function harvestAndSwap(
        uint256 tokenId,
        address[] calldata gauges,
        address[][] calldata feeTokens,
        address[][] calldata bribeTokens,
        Swap[] calldata swaps
    ) external nonReentrant returns (uint256 repaid) {
        Run memory run = _start(tokenId);
        if (msg.sender != run.borrower) revert NotBorrower(tokenId);
        _record(run, feeTokens, bribeTokens, gauges.length);
        _checkSwaps(run, swaps);
        _claim(run, gauges, feeTokens, bribeTokens);
        if (run.open) {
            uint256 count = swaps.length;
            for (uint256 i; i < count; ++i) {
                _sellReward(run, swaps[i]);
            }
        }
        return _finish(run);
    }

    /// @inheritdoc IPayDown
    function setSlippageBps(uint16 newSlippageBps) external onlyOwner {
        _setSlippageBps(newSlippageBps);
    }

    /// @inheritdoc IPayDown
    function setGuardian(address newGuardian) external onlyOwner {
        _setGuardian(newGuardian);
    }

    /// @inheritdoc IPayDown
    function setPaused(bool newPaused) external {
        if (newPaused) {
            if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner();
        } else {
            _checkOwner();
        }
        paused = newPaused;
        emit PausedSet(newPaused);
    }

    /// @inheritdoc IPayDown
    function rescueToken(address token, address to, uint256 amount) external nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        emit Rescued(token, to, amount);
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Always reverts: ownership can never be given up, so strays can always be rescued and the
    ///         allowance always has an owner. Ownership still moves by the two-step transfer.
    /// @dev Reverts RenounceDisabled for every caller.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @dev C38: the borrower every leftover goes to is fixed here, before any code but LoanManager's and the
    ///      price feed's views has run. C39 and C7: the price is read once, up front, and a stale or zero price
    ///      stops the harvest whatever it would have sold.
    function _start(uint256 tokenId) private view returns (Run memory run) {
        if (paused) revert HarvestsPaused();
        run.tokenId = tokenId;
        run.borrower = loanManager.positionOf(tokenId).borrower;
        run.price = _price();
        run.slippage = slippageBps;
        run.btcIndex = NONE;
    }

    /// @dev C38: each token may be listed once across both sides of every gauge, so each balance is measured
    ///      once and no gain can be counted twice. Balances are read before LoanManager is called.
    function _record(
        Run memory run,
        address[][] calldata feeTokens,
        address[][] calldata bribeTokens,
        uint256 gaugeCount
    ) private view {
        if (feeTokens.length != gaugeCount || bribeTokens.length != gaugeCount) revert LengthMismatch();
        if (gaugeCount > MAX_REWARD_TOKENS) revert TooManyTokens(gaugeCount);
        address[] memory listed = new address[](MAX_REWARD_TOKENS);
        uint256 count = 0;
        for (uint256 i; i < gaugeCount; ++i) {
            count = _append(listed, count, feeTokens[i]);
            count = _append(listed, count, bribeTokens[i]);
        }

        address musdToken = address(musd);
        address btcToken = address(btc);
        bool musdListed = _indexOf(listed, count, musdToken) != NONE;
        address[] memory tokens = new address[](musdListed ? count : count + 1);
        tokens[0] = musdToken;
        uint256 next = 1;
        for (uint256 k; k < count; ++k) {
            address token = listed[k];
            if (token == musdToken) continue;
            if (token == btcToken) run.btcIndex = next;
            tokens[next++] = token;
        }
        run.tokens = tokens;
        run.base = _balancesOf(tokens);
    }

    /// @dev Appends one gauge side's tokens, reverting on a token already listed or past the cap. The cap is
    ///      checked before each write, so this stops within MAX_REWARD_TOKENS steps whatever the caller sends.
    // forge-lint: disable-next-item(require-revert-in-loop)
    function _append(address[] memory listed, uint256 count, address[] calldata list)
        private
        pure
        returns (uint256)
    {
        uint256 n = list.length;
        for (uint256 j; j < n; ++j) {
            address token = list[j];
            // A pool's fee and incentive contracts both pay MUSD and BTC, so a full claim lists them on both sides;
            // each distinct token is measured once, as LoanManager's own claim does (C38).
            if (_indexOf(listed, count, token) != NONE) continue;
            if (count == MAX_REWARD_TOKENS) revert TooManyTokens(count + 1);
            listed[count++] = token;
        }
        return count;
    }

    /// @dev C10 and C37: LoanManager pays the operator exactly what each listed token raised its own balance by.
    ///      PayDown measures its own increase again, so only what arrived in this call is used (C38). A balance
    ///      that fell reverts. C40: whether a loan is open is read after the claim, the last moment before any
    ///      sale, and with no open loan nothing is sold.
    // forge-lint: disable-next-item(calls-loop)
    function _claim(
        Run memory run,
        address[] calldata gauges,
        address[][] calldata feeTokens,
        address[][] calldata bribeTokens
    ) private {
        loanManager.claimRewards(run.tokenId, gauges, feeTokens, bribeTokens);
        uint256[] memory gained = _balancesOf(run.tokens);
        uint256 count = gained.length;
        for (uint256 i; i < count; ++i) {
            gained[i] -= run.base[i];
        }
        run.gained = gained;
        run.open = loanManager.loanOf(run.tokenId).state != ILoanManager.LoanState.None;
    }

    /// @dev C39: a token with no reference price is sold only on the borrower's own word, so its route must start
    ///      at it and end at MUSD, its minimum must be above zero, and MUSD and BTC, whose handling the contract
    ///      decides, can never be named. Checked before LoanManager is called, so bad input costs nothing. At most
    ///      MAX_SWAPS swaps of MAX_ROUTE_HOPS hops.
    // forge-lint: disable-next-item(require-revert-in-loop)
    function _checkSwaps(Run memory run, Swap[] calldata swaps) private view {
        uint256 count = swaps.length;
        if (count > MAX_SWAPS) revert TooManySwaps(count);
        address musdToken = address(musd);
        for (uint256 i; i < count; ++i) {
            Swap calldata swap = swaps[i];
            address token = swap.token;
            if (token == musdToken || token == address(btc) || _indexOf(run.tokens, run.tokens.length, token) == NONE)
            {
                revert BadSwapToken(token);
            }
            for (uint256 k; k < i; ++k) {
                if (swaps[k].token == token) revert DuplicateToken(token);
            }
            if (swap.amountOutMin == 0) revert ZeroMinimum(token);
            IMezoRouter.Route[] calldata routes = swap.routes;
            uint256 hops = routes.length;
            if (hops == 0 || hops > MAX_ROUTE_HOPS || routes[0].from != token || routes[hops - 1].to != musdToken) {
                revert BadRoute(token);
            }
            for (uint256 j = 1; j < hops; ++j) {
                if (routes[j].from != routes[j - 1].to) revert BadRoute(token);
            }
        }
    }

    /// @dev Sells a borrower-named token's whole gain at the borrower's minimum. A listed token that brought
    ///      nothing this harvest cannot be named. Runs once per swap, at most MAX_SWAPS times.
    // forge-lint: disable-next-item(calls-loop,require-revert-in-loop)
    function _sellReward(Run memory run, Swap calldata swap) private {
        address token = swap.token;
        uint256 amountIn = run.gained[_indexOf(run.tokens, run.tokens.length, token)];
        if (amountIn == 0) revert BadSwapToken(token);
        uint256 musdOut = _swap(IERC20(token), amountIn, swap.amountOutMin, swap.routes);
        // The Router and the route's tokens ran inside _swap under this contract's lock.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RewardSwapped(run.tokenId, token, amountIn, musdOut);
    }

    /// @dev With an open loan: the BTC sale, then the repay. Then every leftover to the borrower.
    function _finish(Run memory run) private returns (uint256) {
        if (run.open) {
            _sellBtc(run);
            _repay(run);
        }
        _payOut(run);
        // Every outside call is done by now and ran under this contract's lock; the amounts are only known here.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Harvested(run.tokenId, msg.sender, run.repaid, run.btcSold, run.musdFromBtc);
        return run.repaid;
    }

    /// @dev C40: sells only the BTC whose oracle floor covers what is still owed after the MUSD already here, and
    ///      nothing when that MUSD covers it. C39: the route is fixed (BTC to MUSD, volatile, this contract's
    ///      factory), so no caller ever chooses a pool, and the floor is computed here from the oracle and handed
    ///      to the Router as its minimum; a caller has no input that could lower it.
    function _sellBtc(Run memory run) private {
        if (run.btcIndex == NONE) return;
        uint256 gained = run.gained[run.btcIndex];
        if (gained == 0) return;
        uint256 owed = loanManager.owedOf(run.tokenId);
        uint256 musdIn = _musdIn(run);
        if (owed <= musdIn) return;

        uint256 sold = Math.min(gained, _btcCovering(owed - musdIn, run.price, run.slippage));
        uint256 floor = _floorOf(sold, run.price, run.slippage);
        IMezoRouter.Route[] memory routes = new IMezoRouter.Route[](1);
        routes[0] = IMezoRouter.Route({from: address(btc), to: address(musd), stable: false, factory: factory});
        run.musdFromBtc = _swap(btc, sold, floor == 0 ? 1 : floor, routes);
        run.btcSold = sold;
    }

    /// @dev C40: repays the smaller of the MUSD this harvest brought and owedOf read right here, after every
    ///      swap, with an exact approval set back to zero. What was repaid is measured, not taken from
    ///      LoanManager's return value.
    function _repay(Run memory run) private {
        uint256 amount = Math.min(_musdIn(run), loanManager.owedOf(run.tokenId));
        if (amount == 0) return;
        IERC20 musdToken = musd;
        uint256 before = musdToken.balanceOf(address(this));
        musdToken.forceApprove(address(loanManager), amount);
        // slither-disable-next-line unused-return
        // forge-lint: disable-next-line(unused-return)
        loanManager.repay(run.tokenId, amount);
        musdToken.forceApprove(address(loanManager), 0);
        run.repaid = before - musdToken.balanceOf(address(this));
    }

    /// @dev C38: each token's balance above where it stood before the claim is this harvest's own and goes to the
    ///      borrower read at the start; whatever PayDown held before stays put. At most MAX_REWARD_TOKENS + 1
    ///      tokens.
    // forge-lint: disable-next-item(calls-loop)
    function _payOut(Run memory run) private {
        uint256 count = run.tokens.length;
        for (uint256 i; i < count; ++i) {
            IERC20 token = IERC20(run.tokens[i]);
            uint256 left = token.balanceOf(address(this)) - run.base[i];
            if (left != 0) token.safeTransfer(run.borrower, left);
        }
    }

    /// @dev C39: the MUSD a sale brought is PayDown's measured balance increase and must reach `minOut`; the
    ///      Router's return value is never read. The approval covers exactly `amountIn` and is set back to zero,
    ///      so the Router can never reach a stray. The deadline is this block, as the floor already bounds the
    ///      price.
    // forge-lint: disable-next-item(block-timestamp,calls-loop,require-revert-in-loop)
    function _swap(IERC20 token, uint256 amountIn, uint256 minOut, IMezoRouter.Route[] memory routes)
        private
        returns (uint256 musdOut)
    {
        IERC20 musdToken = musd;
        uint256 before = musdToken.balanceOf(address(this));
        token.forceApprove(address(router), amountIn);
        // slither-disable-next-line unused-return
        // forge-lint: disable-next-line(unused-return)
        router.swapExactTokensForTokens(amountIn, minOut, routes, address(this), block.timestamp);
        token.forceApprove(address(router), 0);
        musdOut = musdToken.balanceOf(address(this)) - before;
        if (musdOut < minOut) revert BelowFloor(musdOut, minOut);
    }

    /// @dev MUSD this harvest has brought so far: the claim and every sale, less nothing yet repaid.
    function _musdIn(Run memory run) private view returns (uint256) {
        return musd.balanceOf(address(this)) - run.base[0];
    }

    /// @dev C39: the least MUSD a sale of `btcAmount` must bring, the oracle value less the allowance.
    function _floorOf(uint256 btcAmount, uint256 price, uint256 slippage) private pure returns (uint256) {
        return Math.mulDiv(btcAmount, price, PRICE_SCALE) * (BPS - slippage) / BPS;
    }

    /// @dev C40: the least BTC whose _floorOf covers `need`, rounding up at both steps; one wei less would not
    ///      cover it.
    function _btcCovering(uint256 need, uint256 price, uint256 slippage) private pure returns (uint256) {
        uint256 atPrice = Math.mulDiv(need, BPS, BPS - slippage, Math.Rounding.Ceil);
        return Math.mulDiv(atPrice, PRICE_SCALE, price, Math.Rounding.Ceil);
    }

    /// @dev The one price rule, copied from LoanManager (C7): PriceFeed already returns 18 decimals and reverts
    ///      when stale; a revert or a zero is PriceUnavailable.
    function _price() private view returns (uint256 price) {
        try priceFeed.fetchPrice() returns (uint256 fetched) {
            price = fetched;
        } catch {
            revert PriceUnavailable();
        }
        if (price == 0) revert PriceUnavailable();
    }

    /// @dev One read per token is the measurement itself; the list is at most MAX_REWARD_TOKENS + 1 long.
    // forge-lint: disable-next-item(calls-loop)
    function _balancesOf(address[] memory tokens) private view returns (uint256[] memory balances) {
        uint256 count = tokens.length;
        balances = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            balances[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
    }

    function _indexOf(address[] memory list, uint256 count, address token) private pure returns (uint256) {
        for (uint256 i; i < count; ++i) {
            if (list[i] == token) return i;
        }
        return NONE;
    }

    function _setSlippageBps(uint16 newSlippageBps) private {
        if (newSlippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh(newSlippageBps);
        slippageBps = newSlippageBps;
        emit SlippageSet(newSlippageBps);
    }

    function _setGuardian(address newGuardian) private {
        guardian = _nonZero(newGuardian);
        emit GuardianSet(newGuardian);
    }

    function _nonZero(address account) private pure returns (address) {
        if (account == address(0)) revert ZeroAddress();
        return account;
    }
}
