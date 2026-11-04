// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IMezoRouter
/// @notice The calls PayDown makes on Mezo's pool Router (Velodrome V2 style, not upgradeable), copied from the
///         verified IRouter.sol and Router.sol on both networks (reference/briefs/swap-brief.md section 3).
/// @dev The docs' swap example passes an address array; the deployed Router takes Route[] and the verified code
///      wins (swap brief ruling S2). Routes run through basic pools only; concentrated-liquidity pools have their
///      own router.
interface IMezoRouter {
    /// @notice One hop: the pool for `from` and `to` of the given type, made by `factory`. A zero factory means
    ///         the Router's default factory.
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    /// @notice Sells exactly `amountIn` of `routes[0].from` along `routes` and sends the last hop's output to `to`.
    /// @dev The caller must have approved the Router for `amountIn`. Reverts InsufficientOutputAmount when the
    ///      Router's own quote at execution is below `amountOutMin`, Expired when `deadline` has passed, and
    ///      InvalidPath for an empty route.
    /// @param amountIn Exact amount of the first token to sell.
    /// @param amountOutMin Least output of the last token the call accepts.
    /// @param routes Hops in order, one pool each.
    /// @param to Receiver of the output.
    /// @param deadline Last timestamp at which the swap may run.
    /// @return amounts The input followed by each hop's output, as the Router computed them.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice The Router's quote for selling `amountIn` along `routes` at the pools' current reserves.
    /// @dev A hop whose pool does not exist quotes 0 rather than reverting.
    /// @param amountIn Amount of the first token to sell.
    /// @param routes Hops in order.
    /// @return amounts The input followed by each hop's quoted output.
    function getAmountsOut(uint256 amountIn, Route[] memory routes) external view returns (uint256[] memory amounts);

    /// @notice The pool factory the Router uses when a route names the zero factory.
    /// @return The default factory.
    function defaultFactory() external view returns (address);
}
