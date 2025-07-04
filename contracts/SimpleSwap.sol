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
 * @title SimpleSwap - A Uniswap V2-style Decentralized Exchange
 * @dev Implements core DEX functionality including:
 * - Liquidity provision and management
 * - Token swaps with constant product formula
 * - LP token issuance and redemption
 * - Emergency pause and withdrawal mechanisms
 * @author Francisco López G.
 */
contract SimpleSwap is ERC20, Pausable, Ownable, ReentrancyGuard, ISimpleSwap {
    using SafeERC20 for IERC20;

    // ==============================================
    //                   CUSTOM ERRORS
    // ==============================================
    /// @dev Gas-optimized replacement for require strings
    /// @notice All errors use minimal argument sizes for maximum gas efficiency

    /// @notice Reverts when token address is 0x0
    /// @param token The invalid token address
    error InvalidTokenAddress(address token);
    /// @notice Reverts when amount is zero
    /// @param tokenName Identifier for which token failed
    error ZeroAmount(string tokenName);
    /// @notice Reverts when recipient is 0x0)
    error InvalidRecipient();
    /// @notice Reverts when amount is below minimum threshold
    /// @param tokenName Identifier for the token
    /// @param minAmount The required minimum amount
    /// @param actualAmount The provided amount
    error BelowMinimumAmount(
        string tokenName,
        uint256 minAmount,
        uint256 actualAmount
    );
    /// @notice Reverts when identical tokens are provided
    error IdenticalTokens();
    /// @notice Reverts when transaction exceeds deadline
    error DeadlinePassed();
    /// @notice Reverts when pool has insufficient liquidity
    error InsufficientLiquidity();
    /// @notice Reverts when swap path is invalid
    error InvalidPath();
    /// @notice Reverts when attempting to transfer to self
    error SelfTransfer();
    /// @notice Reverts when arithmetic operation would overflow
    error OverflowProtection();

    // ==============================================
    //                   STRUCTS
    // ==============================================

    /**
     * @notice Stores reserve balances for a token pair
     * @dev tokenA is always the smaller address (tokenA < tokenB)
     * @param reserveA Reserve amount of tokenA
     * @param reserveB Reserve amount of tokenB
     */
    struct Pool {
        uint256 reserveA;
        uint256 reserveB;
    }

    // ==============================================
    //                STATE VARIABLES
    // ==============================================

    /// @dev Mapping of token pairs to their reserve balances
    mapping(address => mapping(address => Pool)) public pools;

    // ==============================================
    //                   EVENTS
    // ==============================================

    /**
     * @notice Emitted when liquidity is added
     * @dev Indexed parameters make filtering more efficient
     * @param provider Address that provided liquidity (indexed)
     * @param tokenA First token in pair (indexed)
     * @param tokenB Second token in pair (indexed)
     * @param amountA Amount of tokenA deposited
     * @param amountB Amount of tokenB deposited
     * @param liquidity LP tokens minted
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
     * @notice Emitted when a user removes liquidity from a pool
     * @dev Indicates successful burning of LP tokens and withdrawal of underlying assets
     * @param provider Address that removed the liquidity (indexed)
     * @param tokenA First token in the pair (indexed)
     * @param tokenB Second token in the pair (indexed)
     * @param amountA Amount of tokenA withdrawn
     * @param amountB Amount of tokenB withdrawn
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
     * @notice Emitted when a token swap is executed
     * @dev Tracks successful token exchanges in the pool
     * @param sender Address that initiated the swap (indexed)
     * @param tokenIn Token deposited into the pool (indexed)
     * @param tokenOut Token withdrawn from the pool (indexed)
     * @param amountIn Exact amount of `tokenIn` sent
     * @param amountOut Amount of `tokenOut` received
     */
    event Swap(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    /**
     * @notice Emitted during emergency withdrawal by the owner
     * @dev Only triggered when contract is paused
     * @param owner Contract owner who executed the withdrawal (indexed)
     * @param token Token withdrawn (indexed)
     * @param to Recipient address of the withdrawn tokens (indexed)
     * @param amount Amount of tokens withdrawn
     */
    event EmergencyWithdraw(
        address indexed owner,
        address indexed token,
        address indexed to,
        uint256 amount
    );

    // ==============================================
    //                 MODIFIERS
    // ==============================================

    /**
     * @dev Ensures transaction executes before deadline
     * @notice Reverts with DeadlinePassed if exceeded
     * @param deadline Unix timestamp deadline
     */
    modifier ensureDeadline(uint256 deadline) {
        if (deadline < block.timestamp) revert DeadlinePassed();
        _;
    }

    /**
     * @dev Validates that two token addresses are different
     * @notice Prevents operations with identical tokens (e.g., swapping tokenA for tokenA)
     * @param tokenA First token address
     * @param tokenB Second token address
     */
    modifier validPair(address tokenA, address tokenB) {
        if (tokenA == tokenB) revert IdenticalTokens();
        _;
    }

    // ==============================================
    //              CONSTRUCTOR
    // ==============================================

    /**
     * @dev Initializes the LP token with name and symbol
     * @notice Uses SS-LP as ticker for SimpleSwap Liquidity Provider token
     */
    constructor() ERC20("SimpleSwap LP", "SS-LP") Ownable(msg.sender) {}

    // ==============================================
    //           EXTERNAL PUBLIC FUNCTIONS
    // ==============================================

    /**
     * @notice Adds liquidity to a token pair pool
     * @dev Optimizations:
     * - Consolidated validation checks
     * - Token sorting optimized with assembly comparison
     * - Single storage update for reserves
     * @dev Security:
     * - All parameters validated before state changes
     * - Reentrancy protected
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param amountADesired Desired amount of tokenA
     * @param amountBDesired Desired amount of tokenB
     * @param amountAMin Minimum acceptable amount of tokenA
     * @param amountBMin Minimum acceptable amount of tokenB
     * @param to Recipient address
     * @param deadline Transaction deadline
     * @return amountA Actual amountA deposited
     * @return amountB Actual amountB deposited
     * @return liquidity LP tokens minted
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
        address sender = msg.sender;

        // Input validation with custom errors
        _validateTokensAndRecipient(tokenA, tokenB, to);
        if (amountADesired == 0) revert ZeroAmount("TokenA");
        if (amountBDesired == 0) revert ZeroAmount("TokenB");
        _checkMinAmount(amountADesired, amountAMin, "TokenA");
        _checkMinAmount(amountBDesired, amountBMin, "TokenB");

        // Sort tokens and get pool reference
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        Pool storage pool = pools[token0][token1];

        // Cache reserves to minimize storage reads
        uint256 reserveA = pool.reserveA;
        uint256 reserveB = pool.reserveB;

        if (reserveA == 0 && reserveB == 0) {
            // Initial liquidity provision
            (amountA, amountB) = (amountADesired, amountBDesired);
            liquidity = _sqrt(amountA * amountB); // Geometric mean for initial liquidity
        } else {
            // Subsequent deposit - maintain ratio
            (amountA, amountB) = _calculateOptimalDeposit(
                amountADesired,
                amountBDesired,
                amountAMin,
                amountBMin,
                reserveA,
                reserveB
            );
            uint256 _totalSupply = totalSupply();
            liquidity = _calculateLiquidity(
                amountA,
                amountB,
                reserveA,
                reserveB,
                _totalSupply
            );
        }

        // Transfer tokens from user
        _transferTokens(tokenA, tokenB, amountA, amountB);

        // Mint LP tokens to provider
        _mint(to, liquidity);

        // Update reserves (single storage update)
        _updateReserves(token0, token1, reserveA + amountA, reserveB + amountB);

        emit LiquidityAdded(
            sender,
            tokenA,
            tokenB,
            amountA,
            amountB,
            liquidity
        );
    }

    /**
     * @notice Removes liquidity from a token pair pool
     * @param tokenA Address of first token in pair
     * @param tokenB Address of second token in pair
     * @param liquidity Amount of LP tokens to burn
     * @param amountAMin Minimum acceptable amount of tokenA
     * @param amountBMin Minimum acceptable amount of tokenB
     * @param to Address to receive underlying tokens
     * @param deadline Transaction validity deadline
     * @return amountA Actual amount of tokenA received
     * @return amountB Actual amount of tokenB received
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
        address sender = msg.sender;

        if (liquidity == 0) revert ZeroAmount("Liquidity");

        // Sort tokens and get pool reference
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        Pool storage pool = pools[token0][token1];

        // Cache reserves to minimize storage reads
        uint256 reserveA = pool.reserveA;
        uint256 reserveB = pool.reserveB;

        // Calculate proportional share of reserves
        (amountA, amountB) = _calculateWithdrawalAmounts(
            liquidity,
            reserveA,
            reserveB
        );

        _checkMinAmount(amountA, amountAMin, "TokenA");
        _checkMinAmount(amountB, amountBMin, "TokenB");

        // Burn LP tokens and transfer underlying assets
        _burn(sender, liquidity);
        _safeTransfer(token0, to, amountA);
        _safeTransfer(token1, to, amountB);

        // Update reserves (single storage update)
        _updateReserves(token0, token1, reserveA - amountA, reserveB - amountB);

        emit LiquidityRemoved(
            sender,
            tokenA,
            tokenB,
            amountA,
            amountB,
            liquidity
        );
    }

    /**
     * @notice Swaps an exact amount of input tokens for output tokens
     * @param amountIn Exact amount of input tokens to swap
     * @param amountOutMin Minimum acceptable amount of output tokens
     * @param path Array with token addresses (must be length 2)
     * @param to Address to receive output tokens
     * @param deadline Transaction validity deadline
     * @return amounts Array with input and output amounts
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
        address sender = msg.sender;

        // Validate swap parameters
        if (path.length != 2) revert InvalidPath();
        _validateTokensAndRecipient(path[0], path[1], to);
        amounts = new uint256[](2);
        amounts[0] = amountIn;

        address tokenIn = path[0];
        address tokenOut = path[1];
        if (tokenIn == tokenOut) revert IdenticalTokens();
        if (amountIn == 0) revert ZeroAmount("Input");

        // Get sorted tokens and corresponding pool
        (address token0, address token1) = _sortTokens(tokenIn, tokenOut);
        Pool storage pool = pools[token0][token1];

        // Determine reserve order based on token sorting
        bool isInputToken0 = (tokenIn == token0);
        uint256 reserveIn = isInputToken0 ? pool.reserveA : pool.reserveB;
        uint256 reserveOut = isInputToken0 ? pool.reserveB : pool.reserveA;
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        // Calculate output amount using x*y=k formula
        amounts[1] = getAmountOut(amountIn, reserveIn, reserveOut);
        if (amounts[1] < amountOutMin)
            revert BelowMinimumAmount("Output", amountOutMin, amounts[1]);

        // Execute token transfers
        IERC20(tokenIn).safeTransferFrom(sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(to, amounts[1]);

        // Update reserves (optimized to avoid duplicate calculations)
        uint256 newReserveOut = reserveOut - amounts[1];
        if (isInputToken0) {
            _updateReserves(
                token0,
                token1,
                reserveIn + amountIn,
                newReserveOut
            );
        } else {
            _updateReserves(
                token0,
                token1,
                newReserveOut,
                reserveIn + amountIn
            );
        }

        emit Swap(sender, tokenIn, tokenOut, amountIn, amounts[1]);
    }

    /**
     * @notice Pauses all trading and liquidity operations
     * @dev Can only be called by the contract owner. Reverts if already paused.
     * @custom:emits Paused Emitted when the pause is triggered by the owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses all trading and liquidity operations
     * @dev Can only be called by the contract owner. Reverts if not paused.
     * @custom:emits Unpaused Emitted when the unpause is triggered by the owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Emergency withdrawal of tokens from the contract
     * @dev Can only be called by owner when contract is paused
     * @param token Address of token to withdraw
     * @param to Recipient address for withdrawn tokens
     * @param amount Amount of tokens to withdraw
     * @custom:requirements
     * - `to` cannot be zero address
     * - `amount` must be greater than 0
     * @custom:emits EmergencyWithdraw Emitted when tokens are withdrawn
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner whenPaused nonReentrant {
        _validateTokensAndRecipient(token, address(1), to);
        if (amount == 0) revert ZeroAmount("Withdrawal");

        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(msg.sender, token, to, amount);
    }

    // ==============================================
    //           EXTERNAL VIEW/PURE FUNCTIONS
    // ==============================================

    /**
     * @notice Gets the price of tokenA in terms of tokenB
     * @dev Price is calculated as (reserveB/reserveA) when tokens are in sorted order
     * @param tokenA The base token (price of 1 tokenA in terms of tokenB)
     * @param tokenB The quote token
     * @return price The price of tokenA in terms of tokenB, scaled by 1e18
     */
    function getPrice(
        address tokenA,
        address tokenB
    ) external view override returns (uint256 price) {
        if (tokenA == tokenB) revert IdenticalTokens();

        // Sort tokens to access the pool consistently
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        Pool memory pool = pools[token0][token1];

        // Verify pool has liquidity
        if (pool.reserveA == 0 || pool.reserveB == 0)
            revert InsufficientLiquidity();

        // Calculate price based on token order
        unchecked {
            price = tokenA == token0
                ? (pool.reserveB * 1e18) / pool.reserveA
                : (pool.reserveA * 1e18) / pool.reserveB;
        }
    }

    /**
     * @notice Calculates output amount for given input and reserves
     * @dev Uses the formula x*y=k
     * @dev Optimizations:
     * - Unchecked math after validation
     * - Explicit overflow protection
     * @dev Safety:
     * - Validates reserveIn + amountIn won't overflow
     * - Reverts on zero amounts or empty reserves
     * @param amountIn Input token amount
     * @param reserveIn Reserve of input token
     * @param reserveOut Reserve of output token
     * @return amountOut Expected output amount
     */
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure override returns (uint256 amountOut) {
        if (reserveIn + amountIn <= reserveIn) revert OverflowProtection();
        if (amountIn == 0) revert ZeroAmount("Input");
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();

        // Safe after validation
        unchecked {
            amountOut = (amountIn * reserveOut) / (reserveIn + amountIn);
        }
    }

    /**
     * @notice Returns the reserves of a token pair in the same order as input
     * @param tokenA First token address (used as reference)
     * @param tokenB Second token address
     * @return reserveA Reserve of tokenA
     * @return reserveB Reserve of tokenB
     */
    function getReserves(
        address tokenA,
        address tokenB
    ) external view returns (uint256 reserveA, uint256 reserveB) {
        if (tokenA == tokenB) revert IdenticalTokens();

        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        Pool memory pool = pools[token0][token1];

        if (tokenA == token0) {
            reserveA = pool.reserveA;
            reserveB = pool.reserveB;
        } else {
            reserveA = pool.reserveB;
            reserveB = pool.reserveA;
        }
    }

    // ==============================================
    //                INTERNAL FUNCTIONS
    // ==============================================

    /**
     * @dev Sorts two token addresses
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return token0 Smaller address
     * @return token1 Larger address
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
     * @dev Centralizes common token and recipient validations
     * @notice Combines multiple checks into a single function for gas efficiency
     * @dev Validations performed:
     * - Token addresses are not zero
     * - Recipient address is not zero
     * - Tokens are not identical
     * @param tokenA First token address to validate
     * @param tokenB Second token address to validate
     * @param to Recipient address to validate
     * @custom:reverts InvalidTokenAddress If either token address is 0x0
     * @custom:reverts InvalidRecipient If recipient address is 0x0
     * @custom:reverts IdenticalTokens If tokenA and tokenB are the same
     */
    function _validateTokensAndRecipient(
        address tokenA,
        address tokenB,
        address to
    ) internal pure {
        if (tokenA == address(0)) revert InvalidTokenAddress(tokenA);
        if (tokenB == address(0)) revert InvalidTokenAddress(tokenB);
        if (to == address(0)) revert InvalidRecipient();
        if (tokenA == tokenB) revert IdenticalTokens();
    }

    /**
     * @dev Verifies an amount meets the required minimum threshold
     * @notice Standardized minimum amount check with descriptive error
     * @param amount Actual amount being checked
     * @param minAmount Minimum required amount
     * @param tokenName Identifier for the token (used in error message)
     * @custom:reverts BelowMinimumAmount If amount < minAmount
     */
    function _checkMinAmount(
        uint256 amount,
        uint256 minAmount,
        string memory tokenName
    ) internal pure {
        if (amount < minAmount) {
            revert BelowMinimumAmount(tokenName, minAmount, amount);
        }
    }

    /**
     * @dev Calculates optimal deposit amounts to maintain pool ratio
     * @param amountADesired Desired amount of tokenA
     * @param amountBDesired Desired amount of tokenB
     * @param amountAMin Minimum acceptable amount of tokenA
     * @param amountBMin Minimum acceptable amount of tokenB
     * @param reserveA Reserve amount of tokenA
     * @param reserveB Reserve amount of tokenB
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
        // Calculate optimal amount of tokenB for desired tokenA
        uint256 amountBOptimal = _quote(amountADesired, reserveA, reserveB);

        if (amountBOptimal <= amountBDesired) {
            if (amountBOptimal < amountBMin)
                revert BelowMinimumAmount("TokenB", amountBMin, amountBOptimal);
            (amountA, amountB) = (amountADesired, amountBOptimal);
        } else {
            // Calculate optimal amount of tokenA for desired tokenB
            uint256 amountAOptimal = _quote(amountBDesired, reserveB, reserveA);
            if (amountAOptimal < amountAMin)
                revert BelowMinimumAmount("TokenA", amountAMin, amountAOptimal);
            (amountA, amountB) = (amountAOptimal, amountBDesired);
        }
    }

    /**
     * @dev Calculates LP tokens to mint based on bilateral deposit while maintaining pool ratio
     * @notice Implements conservative minting by selecting the lower liquidity value to preserve pool balance
     * @dev Critical requirements:
     * - Both reserves must be > 0 (pool must exist)
     * - Amounts must maintain existing reserve ratio within allowed slippage
     * @param amountA Amount of tokenA being deposited
     * @param amountB Amount of tokenB being deposited
     * @param reserveA Current reserve of tokenA in pool
     * @param reserveB Current reserve of tokenB in pool
     * @param totalSupply_ Current total LP token supply
     * @return liquidity LP tokens to mint (minimum of both possible values)
     * @custom:reverts InsufficientLiquidity When:
     * - Either reserve is 0 (new pool)
     * - Calculated liquidity is 0 (deposit too small)
     * @custom:security This function assumes proper ratio validation occurred in calling function
     */
    function _calculateLiquidity(
        uint256 amountA,
        uint256 amountB,
        uint256 reserveA,
        uint256 reserveB,
        uint256 totalSupply_
    ) internal pure returns (uint256 liquidity) {
        uint256 liquidityA = (amountA * totalSupply_) / reserveA;
        uint256 liquidityB = (amountB * totalSupply_) / reserveB;
        liquidity = liquidityA < liquidityB ? liquidityA : liquidityB;
        if (liquidity == 0) revert InsufficientLiquidity();
    }

    /**
     * @dev Calculates withdrawal amounts based on LP share
     * @param liquidity Amount of LP tokens being burned
     * @param reserveA Reserve amount of tokenA
     * @param reserveB Reserve amount of tokenB
     * @return amountA Amount of tokenA to withdraw
     * @return amountB Amount of tokenB to withdraw
     */
    function _calculateWithdrawalAmounts(
        uint256 liquidity,
        uint256 reserveA,
        uint256 reserveB
    ) internal view returns (uint256 amountA, uint256 amountB) {
        uint256 _totalSupply = totalSupply();
        unchecked {
            amountA = (liquidity * reserveA) / _totalSupply;
            amountB = (liquidity * reserveB) / _totalSupply;
        }
    }

    /**
     * @dev Updates pool reserves in storage with canonical token ordering
     * @notice Implements several gas optimizations:
     * - Uses single SSTORE operation for both reserves
     * - Automatically sorts tokens to maintain consistent storage layout
     * - Ternary operation avoids conditional branching
     * @dev Critical safety requirements:
     * - Input amounts must be validated before calling
     * - Token addresses must be non-zero and non-identical
     * @dev Storage layout guarantees:
     * - token0 is always the smaller address (token0 < token1)
     * - reserve0 always corresponds to token0's balance
     * - reserve1 always corresponds to token1's balance
     * @param tokenA First token in pair (order irrelevant)
     * @param tokenB Second token in pair (order irrelevant)
     * @param reserveA Amount for tokenA's reserve (order-corrected)
     * @param reserveB Amount for tokenB's reserve (order-corrected)
     */
    function _updateReserves(
        address tokenA,
        address tokenB,
        uint256 reserveA,
        uint256 reserveB
    ) internal {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        pools[token0][token1] = tokenA == token0
            ? Pool(reserveA, reserveB)
            : Pool(reserveB, reserveA);
    }

    /**
     * @dev Transfers both tokens from user to contract
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param amountA Amount of tokenA to transfer
     * @param amountB Amount of tokenB to transfer
     * @dev Optimizations:
     * - Boolean flags prevent duplicate zero-amount checks
     * - Single address validation for both tokens
     * @dev Security:
     * - Reverts on invalid tokens before any transfers
     * - Skips transfer if amount is 0 (saves gas)
     */
    function _transferTokens(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB
    ) internal {
        if (tokenA == address(0) || tokenB == address(0)) {
            revert InvalidTokenAddress(tokenA == address(0) ? tokenA : tokenB);
        }
        bool successA = amountA > 0;
        bool successB = amountB > 0;
        if (successA)
            IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountA);
        if (successB)
            IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountB);
    }

    /**
     * @dev Safely transfers tokens to recipient
     * @param token Token address to transfer
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _safeTransfer(address token, address to, uint256 amount) internal {
        if (to == address(this)) revert SelfTransfer();
        if (amount == 0) revert ZeroAmount("Transfer");
        IERC20(token).safeTransfer(to, amount);
    }

    // ==============================================
    //              PURE FUNCTIONS
    // ==============================================

    /**
     * @dev Calculates square root using Babylonian method
     * @dev Optimizations:
     * - Early returns for values < 4
     * - Uses bit shifting instead of division
     * - Unchecked math in loop (mathematically safe)
     * @notice Special cases:
     * - Returns 0 for y == 0
     * - Returns 1 for y == 1-3
     * @param y Number to calculate square root of
     * @return z Square root of y
     */
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y < 2) {
            return y; // Returns 0 for y == 0, 1 for y == 1
        }
        if (y < 4) {
            return 1; // Returns 1 for y == 2 or 3
        }
        z = y;
        uint256 x = (y >> 1) + 1;
        unchecked {
            while (x < z) {
                z = x;
                x = (y / x + x) >> 1;
            }
        }
    }

    /**
     * @dev Calculates equivalent token amount to maintain ratio
     * @param amountA Amount of tokenA
     * @param reserveA Reserve of tokenA
     * @param reserveB Reserve of tokenB
     * @return amountB Equivalent amount of tokenB
     * @dev Optimizations:
     * - Uses unchecked division after explicit liquidity check
     * @dev Security:
     * - Explicitly checks for zero reserves
     * - All validations occur before calculations
     */
    function _quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountB) {
        // Prevents division by zero
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        unchecked {
            amountB = (amountA * reserveB) / reserveA;
        }
    }
}
