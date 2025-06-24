// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ISimpleSwap.sol";

/**
 * @title SimpleSwap
 * @dev Implements a basic Uniswap V2-style decentralized exchange with:
 * - Liquidity pool creation
 * - Token swapping functionality
 * - LP (Liquidity Provider) token issuance
 * @author Francisco López G.
 */
contract SimpleSwap is ERC20, ISimpleSwap {
    using SafeERC20 for IERC20;

    // ==============================================
    //                   STRUCTS
    // ==============================================

    /**
     * @dev Structure to store token pair reserves
     * @param reserveA Reserve amount of first token
     * @param reserveB Reserve amount of second token
     */
    struct Pool {
        uint256 reserveA;
        uint256 reserveB;
    }

    // ==============================================
    //                STATE VARIABLES
    // ==============================================

    /**
     * @notice Mapping of token pairs to their reserve balances
     * @dev pools[token0][token1] stores reserves for sorted token pair
     */
    mapping(address => mapping(address => Pool)) public pools;

    // ==============================================
    //                   EVENTS
    // ==============================================

    /**
     * @notice Emitted when liquidity is added to a pool
     * @param provider Address providing the liquidity
     * @param tokenA First token in pair
     * @param tokenB Second token in pair
     * @param amountA Amount of first token added
     * @param amountB Amount of second token added
     * @param liquidity Amount of LP tokens minted
     */
    event LiquidityAdded(
        address indexed provider,
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );

    /**
     * @notice Emitted when liquidity is removed from a pool
     * @param provider Address removing the liquidity
     * @param tokenA First token in pair
     * @param tokenB Second token in pair
     * @param amountA Amount of first token withdrawn
     * @param amountB Amount of second token withdrawn
     * @param liquidity Amount of LP tokens burned
     */
    event LiquidityRemoved(
        address indexed provider,
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );

    /**
     * @notice Emitted when a token swap occurs
     * @param sender Address initiating the swap
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input tokens
     * @param amountOut Amount of output tokens
     */
    event Swap(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    // ==============================================
    //                 MODIFIERS
    // ==============================================

    /**
     * @dev Ensures transaction is executed before deadline
     * @param deadline Timestamp after which transaction should fail
     */
    modifier ensureDeadline(uint256 deadline) {
        require(deadline >= block.timestamp, "Deadline passed");
        _;
    }

    /**
     * @dev Ensures token addresses are different
     * @param tokenA First token address
     * @param tokenB Second token address
     */
    modifier validPair(address tokenA, address tokenB) {
        require(tokenA != tokenB, "Identical tokens");
        _;
    }

    // ==============================================
    //              CONSTRUCTOR
    // ==============================================

    /**
     * @dev Initializes contract with LP token name and symbol
     */
    constructor() ERC20("SimpleSwap LP", "SS-LP") {}

    // ==============================================
    //              EXTERNAL FUNCTIONS
    // ==============================================

    /**
     * @notice Adds liquidity to a token pair
     * @dev For initial deposit, uses square root of token amount product
     * @dev For subsequent deposits, maintains existing reserve ratio
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param amountADesired Desired amount of first token to deposit
     * @param amountBDesired Desired amount of second token to deposit
     * @param amountAMin Minimum acceptable amount of first token
     * @param amountBMin Minimum acceptable amount of second token
     * @param to Address to receive LP tokens
     * @param deadline Transaction expiry timestamp
     * @return amountA Actual amount of first token deposited
     * @return amountB Actual amount of second token deposited
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
        override
        ensureDeadline(deadline)
        validPair(tokenA, tokenB)
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        // Validate input amounts first (require at top)
        require(amountADesired > 0 && amountBDesired > 0, "Invalid amounts");
        require(
            amountADesired >= amountAMin && amountBDesired >= amountBMin,
            "Min not met"
        );

        // Sort tokens to ensure consistent ordering
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        Pool storage pool = pools[token0][token1];

        // Cache reserve values to minimize storage reads
        uint256 reserveA = pool.reserveA;
        uint256 reserveB = pool.reserveB;

        if (reserveA == 0 && reserveB == 0) {
            // Initial liquidity provision
            (amountA, amountB) = (amountADesired, amountBDesired);
            liquidity = _sqrt(amountA * amountB); // Geometric mean for initial LP tokens
        } else {
            // Subsequent liquidity provision - maintain ratio
            (amountA, amountB) = _calculateOptimalDeposit(
                amountADesired,
                amountBDesired,
                amountAMin,
                amountBMin,
                reserveA,
                reserveB
            );
            liquidity = _calculateLiquidity(amountA, reserveA, totalSupply());
        }

        // Transfer tokens from user and mint LP tokens
        _transferTokens(tokenA, tokenB, amountA, amountB);
        _mint(to, liquidity);

        // Single state variable update
        _updateReserves(token0, token1, reserveA + amountA, reserveB + amountB);

        emit LiquidityAdded(
            msg.sender,
            tokenA,
            tokenB,
            amountA,
            amountB,
            liquidity
        );
    }

    /**
     * @notice Removes liquidity from a token pair
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param liquidity Amount of LP tokens to burn
     * @param amountAMin Minimum acceptable amount of first token to receive
     * @param amountBMin Minimum acceptable amount of second token to receive
     * @param to Address to receive withdrawn tokens
     * @param deadline Transaction expiry timestamp
     * @return amountA Amount of first token withdrawn
     * @return amountB Amount of second token withdrawn
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        override
        ensureDeadline(deadline)
        validPair(tokenA, tokenB)
        returns (uint256 amountA, uint256 amountB)
    {
        require(liquidity > 0, "Invalid liquidity");

        // Sort tokens and get pool reserves
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        Pool storage pool = pools[token0][token1];

        // Cache reserve values
        uint256 reserveA = pool.reserveA;
        uint256 reserveB = pool.reserveB;

        // Calculate proportional share of reserves
        (amountA, amountB) = _calculateWithdrawalAmounts(
            liquidity,
            reserveA,
            reserveB
        );
        require(amountA >= amountAMin && amountB >= amountBMin, "Min not met");

        // Burn LP tokens and transfer underlying tokens
        _burn(msg.sender, liquidity);
        _safeTransfer(token0, to, amountA);
        _safeTransfer(token1, to, amountB);

        // Single state variable update
        _updateReserves(token0, token1, reserveA - amountA, reserveB - amountB);

        emit LiquidityRemoved(
            msg.sender,
            tokenA,
            tokenB,
            amountA,
            amountB,
            liquidity
        );
    }

    /**
     * @notice Swaps an exact amount of input tokens for output tokens
     * @param amountIn Exact amount of input tokens
     * @param amountOutMin Minimum acceptable amount of output tokens
     * @param path Array containing [inputToken, outputToken] addresses
     * @param to Address to receive output tokens
     * @param deadline Transaction expiry timestamp
     * @return amounts Array containing [inputAmount, outputAmount]
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        override
        ensureDeadline(deadline)
        returns (uint256[] memory amounts)
    {
        require(path.length == 2, "Invalid path");

        amounts = new uint256[](2);
        amounts[0] = amountIn;

        (address tokenIn, address tokenOut) = (path[0], path[1]);
        Pool storage pool = pools[tokenIn][tokenOut];

        // Cache reserve values
        uint256 reserveIn = pool.reserveA;
        uint256 reserveOut = pool.reserveB;

        require(amountIn > 0, "Invalid amount");
        require(reserveIn > 0 && reserveOut > 0, "No liquidity");

        // Calculate output amount based on constant product formula
        amounts[1] = getAmountOut(amountIn, reserveIn, reserveOut);
        require(amounts[1] >= amountOutMin, "Insufficient output");

        // Transfer tokens
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(to, amounts[1]);

        // Single state variable update
        _updateReserves(
            tokenIn,
            tokenOut,
            reserveIn + amountIn,
            reserveOut - amounts[1]
        );

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amounts[1]);
    }

    // ==============================================
    //              VIEW FUNCTIONS
    // ==============================================

    /**
     * @notice Gets the price of tokenA in terms of tokenB
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return price Price of tokenA in terms of tokenB (with 18 decimals)
     */
    function getPrice(
        address tokenA,
        address tokenB
    ) external view override returns (uint256 price) {
        require(tokenA != tokenB, "Identical tokens");

        Pool memory pool = pools[tokenA][tokenB];
        require(pool.reserveA > 0 && pool.reserveB > 0, "No liquidity");

        price = (pool.reserveB * 1e18) / pool.reserveA;
    }

    /**
     * @notice Calculates output amount for a given input and reserves
     * @dev Uses constant product formula: amountOut = (amountIn * reserveOut) / (reserveIn + amountIn)
     * @param amountIn Input token amount
     * @param reserveIn Reserve of input token
     * @param reserveOut Reserve of output token
     * @return amountOut Expected output token amount
     */
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure override returns (uint256 amountOut) {
        require(amountIn > 0, "Invalid amount");
        require(reserveIn > 0 && reserveOut > 0, "No liquidity");

        amountOut = (amountIn * reserveOut) / (reserveIn + amountIn);
    }

    // ==============================================
    //              INTERNAL FUNCTIONS
    // ==============================================

    /**
     * @dev Sorts two token addresses
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return token0 Lower address
     * @return token1 Higher address
     */
    function _sortTokens(
        address tokenA,
        address tokenB
    ) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
    }

    /**
     * @dev Calculates optimal deposit amounts to maintain pool ratio
     * @param amountADesired Desired amount of tokenA
     * @param amountBDesired Desired amount of tokenB
     * @param amountAMin Minimum acceptable amount of tokenA
     * @param amountBMin Minimum acceptable amount of tokenB
     * @param reserveA Current reserve of tokenA
     * @param reserveB Current reserve of tokenB
     * @return amountA Optimal amount of tokenA to deposit
     * @return amountB Optimal amount of tokenB to deposit
     */
    function _calculateOptimalDeposit(
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountA, uint256 amountB) {
        uint256 amountBOptimal = _quote(amountADesired, reserveA, reserveB);

        if (amountBOptimal <= amountBDesired) {
            require(amountBOptimal >= amountBMin, "Insufficient B");
            (amountA, amountB) = (amountADesired, amountBOptimal);
        } else {
            uint256 amountAOptimal = _quote(amountBDesired, reserveB, reserveA);
            require(amountAOptimal >= amountAMin, "Insufficient A");
            (amountA, amountB) = (amountAOptimal, amountBDesired);
        }
    }

    /**
     * @dev Calculates LP tokens to mint based on deposit
     * @param amount Deposit amount
     * @param reserve Existing reserve amount
     * @param totalSupply Current total LP token supply
     * @return liquidity LP tokens to mint
     */
    function _calculateLiquidity(
        uint256 amount,
        uint256 reserve,
        uint256 totalSupply
    ) internal pure returns (uint256 liquidity) {
        liquidity = (amount * totalSupply) / reserve;
        require(liquidity > 0, "Insufficient liquidity");
    }

    /**
     * @dev Calculates withdrawal amounts based on LP share
     * @param liquidity LP tokens to burn
     * @param reserveA Reserve of tokenA
     * @param reserveB Reserve of tokenB
     * @return amountA Amount of tokenA to withdraw
     * @return amountB Amount of tokenB to withdraw
     */
    function _calculateWithdrawalAmounts(
        uint256 liquidity,
        uint256 reserveA,
        uint256 reserveB
    ) internal view returns (uint256 amountA, uint256 amountB) {
        uint256 _totalSupply = totalSupply();
        amountA = (liquidity * reserveA) / _totalSupply;
        amountB = (liquidity * reserveB) / _totalSupply;
    }

    /**
     * @dev Updates pool reserves
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param newReserveA New reserve for tokenA
     * @param newReserveB New reserve for tokenB
     */
    function _updateReserves(
        address tokenA,
        address tokenB,
        uint256 newReserveA,
        uint256 newReserveB
    ) internal {
        pools[tokenA][tokenB] = Pool(newReserveA, newReserveB);
    }

    /**
     * @dev Transfers both tokens from user to contract
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param amountA Amount of tokenA
     * @param amountB Amount of tokenB
     */
    function _transferTokens(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB
    ) internal {
        IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountB);
    }

    /**
     * @dev Safely transfers tokens to recipient
     * @param token Token address
     * @param to Recipient address
     * @param amount Transfer amount
     */
    function _safeTransfer(address token, address to, uint256 amount) internal {
        IERC20(token).safeTransfer(to, amount);
    }

    // ==============================================
    //              PURE FUNCTIONS
    // ==============================================

    /**
     * @dev Calculates square root (for initial liquidity calculation)
     * @param y Number to calculate square root of
     * @return z Square root of y
     */
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    /**
     * @dev Calculates equivalent token amount to maintain ratio
     * @param amountA Amount of tokenA
     * @param reserveA Reserve of tokenA
     * @param reserveB Reserve of tokenB
     * @return amountB Equivalent amount of tokenB
     */
    function _quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountB) {
        amountB = (amountA * reserveB) / reserveA;
    }
}
