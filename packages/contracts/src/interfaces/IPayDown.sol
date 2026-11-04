// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILoanManager} from "./ILoanManager.sol";
import {IMezoRouter} from "./IMezoRouter.sol";
import {IPriceFeed} from "./IPriceFeed.sol";

/// @title IPayDown
/// @notice Turns a Doji position's pool rewards into repayment of its loan. A borrower opts in once by naming
///         PayDown as the position's reward operator in LoanManager. From then on anyone, the keeper weekly, can
///         harvest: MUSD rewards repay the loan, BTC rewards are sold on Mezo's own BTC/MUSD pool for only what
///         the debt still needs and never below the oracle price minus a small capped allowance, and everything
///         else goes to the borrower in the same call. Other reward tokens are sold only when the borrower runs
///         harvestAndSwap with their own minimums (F26).
interface IPayDown {
    /// @notice One reward token the borrower asks harvestAndSwap to sell for MUSD.
    /// @dev `routes` must start at `token`, end at MUSD and chain hop to hop; `amountOutMin` must be above zero
    ///      and is checked against the MUSD PayDown measures arriving.
    struct Swap {
        address token;
        uint256 amountOutMin;
        IMezoRouter.Route[] routes;
    }

    /// @notice A harvest for `tokenId` ran: `musdRepaid` MUSD went to the loan, and `btcSold` BTC was sold for
    ///         `musdFromBtc` MUSD. Every other part of the rewards went to the position's borrower.
    event Harvested(
        uint256 indexed tokenId, address indexed caller, uint256 musdRepaid, uint256 btcSold, uint256 musdFromBtc
    );
    /// @notice In a borrower's harvestAndSwap, `amountIn` of `token` was sold for `musdOut` MUSD.
    event RewardSwapped(uint256 indexed tokenId, address indexed token, uint256 amountIn, uint256 musdOut);
    /// @notice BTC sales from now on accept at most this discount to the oracle price.
    event SlippageSet(uint16 slippageBps);
    /// @notice The address that may pause harvests alongside the owner changed.
    event GuardianSet(address indexed guardian);
    /// @notice Harvests were paused or resumed.
    event PausedSet(bool paused);
    /// @notice The owner moved stray `token` that PayDown held outside any harvest.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @notice An address argument, or an address read from LoanManager or the Router, was zero.
    error ZeroAddress();
    /// @notice An amount was zero where it must be positive.
    error ZeroAmount();
    /// @notice The slippage allowance is above MAX_SLIPPAGE_BPS.
    error SlippageTooHigh(uint16 slippageBps);
    /// @notice Only the guardian or the owner may pause.
    error NotGuardianOrOwner();
    /// @notice Harvests are paused.
    error HarvestsPaused();
    /// @notice Only the position's recorded borrower may run harvestAndSwap.
    error NotBorrower(uint256 tokenId);
    /// @notice A token appears twice in the reward lists, or twice in the swap list.
    error DuplicateToken(address token);
    /// @notice The reward lists name more than MAX_REWARD_TOKENS tokens or gauges.
    error TooManyTokens(uint256 count);
    /// @notice The gauge and the two token lists are not one entry per gauge.
    error LengthMismatch();
    /// @notice More than MAX_SWAPS swaps.
    error TooManySwaps(uint256 count);
    /// @notice A swap names MUSD, BTC, a token not in the reward lists, or a token this harvest did not gain.
    error BadSwapToken(address token);
    /// @notice A swap route is empty, longer than MAX_ROUTE_HOPS, does not start at the token sold, does not end
    ///         at MUSD, or has a hop that does not start where the previous one ended.
    error BadRoute(address token);
    /// @notice A swap's minimum is zero.
    error ZeroMinimum(address token);
    /// @notice The MUSD measured arriving from a sale is below its floor.
    error BelowFloor(uint256 received, uint256 floor);
    /// @notice The price feed reverted or returned zero.
    error PriceUnavailable();
    /// @notice Ownership can never be given up, so stray tokens can always be rescued and the settings always
    ///         have an owner.
    error RenounceDisabled();

    /// @notice Claims a position's pool rewards through LoanManager and uses them to pay its loan down. Anyone
    ///         may call; the keeper does weekly.
    /// @dev PayDown must be the position's reward operator, and LoanManager's own claim rules apply: position in
    ///      custody, never in auction. Not paused, under the reentrancy lock. Reads the borrower from LoanManager
    ///      and the oracle price before any other outside call. Records PayDown's balance of MUSD and of every
    ///      listed token, claims, and uses only each measured increase, so tokens PayDown already held are never
    ///      touched. With an open loan: MUSD gained counts toward the repay; BTC gained is sold only as far as
    ///      the debt still needs after that MUSD, on the fixed BTC to MUSD volatile route of this contract's
    ///      factory, with the oracle floor (BTC sold x price x (10,000 - slippageBps) / 10,000) handed to the
    ///      Router as its minimum and checked again against the MUSD measured arriving; then
    ///      min(MUSD gained, owedOf read just before the repay) is repaid through LoanManager. Every approval is
    ///      exact and set back to zero. With no open loan nothing is sold. Every other part of the gains, MUSD
    ///      over the debt, unsold BTC and every other token, goes to the borrower read at the start, in this
    ///      call. Any failing step reverts the whole harvest. Reverts HarvestsPaused, PriceUnavailable,
    ///      LengthMismatch, TooManyTokens, BelowFloor, any LoanManager claim or repay revert (NotBorrower when
    ///      PayDown is not the operator, LoanInAuction), or any Router or token revert. A token listed on both
    ///      sides, or for two gauges, is measured once. Emits Harvested.
    /// @param tokenId Position to harvest.
    /// @param gauges Gauges to claim from, as registered on PoolsVoter.
    /// @param feeTokens Tokens to claim from each gauge's fee reward contract, one list per gauge.
    /// @param bribeTokens Tokens to claim from each gauge's incentive reward contract, one list per gauge.
    /// @return repaid MUSD that went to the loan.
    function harvest(
        uint256 tokenId,
        address[] calldata gauges,
        address[][] calldata feeTokens,
        address[][] calldata bribeTokens
    ) external returns (uint256 repaid);

    /// @notice The borrower's own harvest: as harvest, and it also sells the reward tokens the borrower lists, at
    ///         the borrower's own minimums, and repays with the MUSD they bring.
    /// @dev Recorded borrower only. Each swap names a token gained in this harvest other than MUSD and BTC, at
    ///      most once, at most MAX_SWAPS swaps, a route of 1 to MAX_ROUTE_HOPS hops from that token to MUSD in
    ///      which every hop starts where the previous one ended, and a minimum above zero. With an open loan the
    ///      token's whole measured gain is sold, the Router is handed the borrower's minimum, and the MUSD
    ///      measured arriving must reach it. Swaps run before the BTC sale, so their MUSD shrinks the BTC sold.
    ///      BTC follows exactly the harvest rules; a borrower cannot set its floor. With no open loan nothing is
    ///      sold and every gain goes to the borrower. Reverts as harvest, plus NotBorrower, TooManySwaps,
    ///      BadSwapToken, DuplicateToken, BadRoute, ZeroMinimum and BelowFloor. Emits RewardSwapped per swap,
    ///      then Harvested.
    /// @param tokenId Position to harvest.
    /// @param gauges Gauges to claim from, as registered on PoolsVoter.
    /// @param feeTokens Tokens to claim from each gauge's fee reward contract, one list per gauge.
    /// @param bribeTokens Tokens to claim from each gauge's incentive reward contract, one list per gauge.
    /// @param swaps Reward tokens to sell for MUSD, with the borrower's routes and minimums.
    /// @return repaid MUSD that went to the loan.
    function harvestAndSwap(
        uint256 tokenId,
        address[] calldata gauges,
        address[][] calldata feeTokens,
        address[][] calldata bribeTokens,
        Swap[] calldata swaps
    ) external returns (uint256 repaid);

    /// @notice Owner only. Sets the discount to the oracle price a BTC sale may accept.
    /// @dev Reverts OwnableUnauthorizedAccount or SlippageTooHigh above MAX_SLIPPAGE_BPS. Emits SlippageSet.
    /// @param newSlippageBps New allowance in basis points.
    function setSlippageBps(uint16 newSlippageBps) external;

    /// @notice Owner only. Sets the guardian.
    /// @dev Reverts OwnableUnauthorizedAccount or ZeroAddress. Emits GuardianSet.
    /// @param newGuardian New guardian.
    function setGuardian(address newGuardian) external;

    /// @notice Pauses or resumes harvest and harvestAndSwap. The guardian or the owner may pause; only the owner
    ///         may resume.
    /// @dev A pause touches nothing in LoanManager: the borrower's own claimRewards, setRewardOperator and repay
    ///      keep working (C42). Reverts NotGuardianOrOwner on a pause, OwnableUnauthorizedAccount on a resume.
    ///      Emits PausedSet.
    /// @param newPaused True to pause.
    function setPaused(bool newPaused) external;

    /// @notice Owner only. Sends tokens PayDown holds outside a harvest. A harvest keeps nothing between calls,
    ///         so everything PayDown holds at rest is a stray credited to nobody.
    /// @dev Under the reentrancy lock, so it can never run inside a harvest. Reverts OwnableUnauthorizedAccount,
    ///      ZeroAddress or ZeroAmount. Emits Rescued.
    /// @param token ERC-20 to send.
    /// @param to Receiver.
    /// @param amount Amount to send.
    function rescueToken(address token, address to, uint256 amount) external;

    /// @notice Highest slippage allowance the owner can set, in basis points.
    /// @return The cap.
    function MAX_SLIPPAGE_BPS() external view returns (uint16);

    /// @notice Most swaps one harvestAndSwap may list.
    /// @return The cap.
    function MAX_SWAPS() external view returns (uint256);

    /// @notice Most hops one swap route may have.
    /// @return The cap.
    function MAX_ROUTE_HOPS() external view returns (uint256);

    /// @notice Most tokens, and most gauges, one harvest may list, matching LoanManager's own claim cap.
    /// @return The cap.
    function MAX_REWARD_TOKENS() external view returns (uint256);

    /// @notice The LoanManager whose positions PayDown harvests, fixed at deployment.
    /// @return The LoanManager.
    function loanManager() external view returns (ILoanManager);

    /// @notice Mezo's pool Router, fixed at deployment.
    /// @return The Router.
    function router() external view returns (IMezoRouter);

    /// @notice The Router's default pool factory, read once at deployment, named on the BTC route.
    /// @return The factory.
    function factory() external view returns (address);

    /// @notice The MUSD token, read from LoanManager at deployment.
    /// @return The MUSD token.
    function musd() external view returns (IERC20);

    /// @notice The BTC ERC-20 view, read from LoanManager at deployment.
    /// @return The BTC token.
    function btc() external view returns (IERC20);

    /// @notice MUSD's BTC price feed, read from LoanManager at deployment.
    /// @return The price feed.
    function priceFeed() external view returns (IPriceFeed);

    /// @notice Address that may pause harvests alongside the owner.
    /// @return The guardian.
    function guardian() external view returns (address);

    /// @notice Discount to the oracle price a BTC sale may accept, in basis points.
    /// @return The allowance.
    function slippageBps() external view returns (uint16);

    /// @notice True while harvests are paused.
    /// @return Whether harvests are paused.
    function paused() external view returns (bool);
}
