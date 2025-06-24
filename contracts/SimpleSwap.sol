// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// OpenZeppelin imports for core functionality
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/ISimpleSwap.sol";

/**
 * @title SimpleSwap
 * @dev A Uniswap V2-style decentralized exchange implementation featuring:
 * - Liquidity pool creation and management
 * - Token swap functionality
 * - LP token issuance
 * - Emergency safety features
 * @author Francisco López G.
 */
contract SimpleSwap is ERC20, Pausable, Ownable, ReentrancyGuard, ISimpleSwap {
    using SafeERC20 for IERC20;

    // ==============================================
    //                   STRUCTS
    // ==============================================

    /**
     * @dev Struct to store token pair reserves
     */
    struct Pool {
        uint256 reserveA; // Reserve amount of tokenA
        uint256 reserveB; // Reserve amount of tokenB
    }

    // ==============================================
    //                STATE VARIABLES
    // ==============================================

    // Mapping of token pairs to their reserve balances
    mapping(address => mapping(address => Pool)) public pools;

    // ==============================================
    //                   EVENTS
    // ==============================================

    event LiquidityAdded(
        address indexed provider,
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );

    event LiquidityRemoved(
        address indexed provider,
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );

    event Swap(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    event EmergencyWithdraw(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    // ==============================================
    //                 MODIFIERS
    // ==============================================

    modifier ensureDeadline(uint256 deadline) {
        require(deadline >= block.timestamp, "Deadline passed");
        _;
    }

    modifier validPair(address tokenA, address tokenB) {
        require(tokenA != tokenB, "Identical tokens");
        _;
    }

    // ==============================================
    //              CONSTRUCTOR
    // ==============================================

    /**
     * @dev Initializes the LP token with name and symbol
     */
    constructor() ERC20("SimpleSwap LP", "SS-LP") Ownable(msg.sender) {}

    // ==============================================
    //           EXTERNAL PUBLIC FUNCTIONS
    // ==============================================

    /**
     * @notice Adds liquidity to a token pair pool
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
        whenNotPaused
        nonReentrant
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        // Validate input amounts
        require(amountADesired > 0 && amountBDesired > 0, "Invalid amounts");
        require(
            amountADesired >= amountAMin && amountBDesired >= amountBMin,
            "Min not met"
        );

        // Sort tokens to ensure consistent ordering
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        Pool storage pool = pools[token0][token1];

        // Get current reserves from storage
        uint256 reserveA = pool.reserveA;
        uint256 reserveB = pool.reserveB;

        // Check if this is initial liquidity provision
        if (reserveA == 0 && reserveB == 0) {
            // For initial deposit, use desired amounts directly
            (amountA, amountB) = (amountADesired, amountBDesired);
            // Calculate initial liquidity using geometric mean (sqrt(x*y))
            liquidity = _sqrt(amountA * amountB);
        } else {
            // For subsequent deposits, maintain the existing ratio
            (amountA, amountB) = _calculateOptimalDeposit(
                amountADesired,
                amountBDesired,
                amountAMin,
                amountBMin,
                reserveA,
                reserveB
            );
            // Calculate liquidity proportional to the deposit
            liquidity = _calculateLiquidity(amountA, reserveA, totalSupply());
        }

        // Transfer tokens from user to contract
        _transferTokens(tokenA, tokenB, amountA, amountB);

        // Mint LP tokens to liquidity provider
        _mint(to, liquidity);

        // Update pool reserves
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
     * @notice Removes liquidity from a token pair pool
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
        whenNotPaused
        nonReentrant
        returns (uint256 amountA, uint256 amountB)
    {
        require(liquidity > 0, "Invalid liquidity");

        // Sort tokens and get pool reserves
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        Pool storage pool = pools[token0][token1];

        // Get current reserves from storage
        uint256 reserveA = pool.reserveA;
        uint256 reserveB = pool.reserveB;

        // Calculate proportional share of reserves
        (amountA, amountB) = _calculateWithdrawalAmounts(
            liquidity,
            reserveA,
            reserveB
        );
        require(amountA >= amountAMin && amountB >= amountBMin, "Min not met");

        // Burn LP tokens and transfer underlying assets
        _burn(msg.sender, liquidity);
        _safeTransfer(token0, to, amountA);
        _safeTransfer(token1, to, amountB);

        // Update pool reserves
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
        whenNotPaused
        nonReentrant
        returns (uint256[] memory amounts)
    {
        // Validate swap path (only direct pairs supported)
        require(path.length == 2, "Invalid path");

        amounts = new uint256[](2);
        amounts[0] = amountIn;

        // Extract input and output tokens from path
        (address tokenIn, address tokenOut) = (path[0], path[1]);
        Pool storage pool = pools[tokenIn][tokenOut];

        // Get current reserves from storage
        uint256 reserveIn = pool.reserveA;
        uint256 reserveOut = pool.reserveB;

        // Basic input validation
        require(amountIn > 0, "Invalid amount");
        require(reserveIn > 0 && reserveOut > 0, "No liquidity");

        // Calculate output amount using constant product formula
        amounts[1] = getAmountOut(amountIn, reserveIn, reserveOut);
        require(amounts[1] >= amountOutMin, "Insufficient output");

        // Execute the swap:
        // 1. Take input tokens from user
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        // 2. Send output tokens to recipient
        IERC20(tokenOut).safeTransfer(to, amounts[1]);

        // Update reserves:
        // - Increase input token reserve
        // - Decrease output token reserve
        _updateReserves(
            tokenIn,
            tokenOut,
            reserveIn + amountIn,
            reserveOut - amounts[1]
        );

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amounts[1]);
    }

    /**
     * @notice Pauses all trading and liquidity operations
     * @dev Only callable by owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses all trading and liquidity operations
     * @dev Only callable by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Emergency withdrawal of tokens from the contract
     * @dev Only callable by owner when paused
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner whenPaused nonReentrant {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");

        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }

    // ==============================================
    //           EXTERNAL VIEW/PURE FUNCTIONS
    // ==============================================

    /**
     * @notice Gets the price of tokenA in terms of tokenB
     */
    function getPrice(
        address tokenA,
        address tokenB
    ) external view override returns (uint256 price) {
        require(tokenA != tokenB, "Identical tokens");

        Pool memory pool = pools[tokenA][tokenB];
        require(pool.reserveA > 0 && pool.reserveB > 0, "No liquidity");

        // Price is calculated as (reserveB * 1e18) / reserveA
        price = (pool.reserveB * 1e18) / pool.reserveA;
    }

    /**
     * @notice Calculates output amount for a given input and reserves
     * @dev Uses constant product formula: amountOut = (amountIn * reserveOut) / (reserveIn + amountIn)
     */
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure override returns (uint256 amountOut) {
        require(amountIn > 0, "Invalid amount");
        require(reserveIn > 0 && reserveOut > 0, "No liquidity");

        // Constant product formula calculation
        amountOut = (amountIn * reserveOut) / (reserveIn + amountIn);
    }

    // ==============================================
    //                INTERNAL FUNCTIONS
    // ==============================================

    /**
     * @dev Sorts two token addresses
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
     */
    function _calculateOptimalDeposit(
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountA, uint256 amountB) {
        // Calculate optimal amount of tokenB for desired tokenA
        uint256 amountBOptimal = _quote(amountADesired, reserveA, reserveB);

        if (amountBOptimal <= amountBDesired) {
            require(amountBOptimal >= amountBMin, "Insufficient B");
            (amountA, amountB) = (amountADesired, amountBOptimal);
        } else {
            // Calculate optimal amount of tokenA for desired tokenB
            uint256 amountAOptimal = _quote(amountBDesired, reserveB, reserveA);
            require(amountAOptimal >= amountAMin, "Insufficient A");
            (amountA, amountB) = (amountAOptimal, amountBDesired);
        }
    }

    /**
     * @dev Calculates LP tokens to mint based on deposit
     */
    function _calculateLiquidity(
        uint256 amount,
        uint256 reserve,
        uint256 totalSupply
    ) internal pure returns (uint256 liquidity) {
        // Calculate liquidity proportional to deposit amount
        liquidity = (amount * totalSupply) / reserve;
        require(liquidity > 0, "Insufficient liquidity");
    }

    /**
     * @dev Calculates withdrawal amounts based on LP share
     */
    function _calculateWithdrawalAmounts(
        uint256 liquidity,
        uint256 reserveA,
        uint256 reserveB
    ) internal view returns (uint256 amountA, uint256 amountB) {
        // Calculate proportional share of reserves
        uint256 _totalSupply = totalSupply();
        amountA = (liquidity * reserveA) / _totalSupply;
        amountB = (liquidity * reserveB) / _totalSupply;
    }

    /**
     * @dev Updates pool reserves in storage
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
     */
    function _safeTransfer(address token, address to, uint256 amount) internal {
        IERC20(token).safeTransfer(to, amount);
    }

    // ==============================================
    //              PURE FUNCTIONS
    // ==============================================

    /**
     * @dev Calculates square root using Babylonian method
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
     */
    function _quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountB) {
        amountB = (amountA * reserveB) / reserveA;
    }
}
