// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ISimpleSwap
 * @dev Interface for the SimpleSwap decentralized exchange contract
 * @notice Defines the core functionality for:
 * - Adding/removing liquidity from token pairs
 * - Swapping tokens with price calculations
 * - Querying token prices and swap amounts
 */
interface ISimpleSwap {
    // ==============================================
    //              LIQUIDITY FUNCTIONS
    // ==============================================

    /**
     * @notice Adds liquidity to a token pair
     * @dev Mints LP tokens representing pool share
     * @param tokenA First token in pair
     * @param tokenB Second token in pair
     * @param amountADesired Desired amount of tokenA to deposit
     * @param amountBDesired Desired amount of tokenB to deposit
     * @param amountAMin Minimum acceptable amount of tokenA
     * @param amountBMin Minimum acceptable amount of tokenB
     * @param to Recipient of LP tokens
     * @param deadline Transaction expiry timestamp
     * @return amountA Actual amount of tokenA deposited
     * @return amountB Actual amount of tokenB deposited
     * @return liquidity Amount of LP tokens minted
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    /**
     * @notice Removes liquidity from a token pair
     * @dev Burns LP tokens and returns underlying assets
     * @param tokenA First token in pair
     * @param tokenB Second token in pair
     * @param liquidity Amount of LP tokens to burn
     * @param amountAMin Minimum acceptable amount of tokenA
     * @param amountBMin Minimum acceptable amount of tokenB
     * @param to Recipient of withdrawn tokens
     * @param deadline Transaction expiry timestamp
     * @return amountA Amount of tokenA withdrawn
     * @return amountB Amount of tokenB withdrawn
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    // ==============================================
    //                 SWAP FUNCTIONS
    // ==============================================

    /**
     * @notice Swaps exact input tokens for output tokens
     * @dev Uses constant product market maker formula
     * @param amountIn Exact amount of input tokens
     * @param amountOutMin Minimum acceptable output amount
     * @param path Array with [inputToken, outputToken]
     * @param to Recipient of output tokens
     * @param deadline Transaction expiry timestamp
     * @return amounts Array containing [inputAmount, outputAmount]
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    // ==============================================
    //                 VIEW FUNCTIONS
    // ==============================================

    /**
     * @notice Gets price of tokenA in terms of tokenB
     * @dev Price is calculated as reserveB/reserveA
     * @param tokenA First token in pair
     * @param tokenB Second token in pair
     * @return price Price ratio with 18 decimals precision
     */
    function getPrice(address tokenA, address tokenB)
        external
        view
        returns (uint256 price);

    /**
     * @notice Calculates output amount for given input
     * @dev Uses formula: amountOut = (amountIn * reserveOut) / (reserveIn + amountIn)
     * @param amountIn Input token amount
     * @param reserveIn Reserve of input token
     * @param reserveOut Reserve of output token
     * @return amountOut Expected output amount
     */
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountOut);
}
