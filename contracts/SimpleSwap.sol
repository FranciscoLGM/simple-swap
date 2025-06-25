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
     * @notice Emitted when a user adds liquidity to a pool
     * @dev Indicates successful deposit of tokens and minting of LP tokens
     * @param provider Address that provided the liquidity (indexed)
     * @param tokenA First token in the pair (indexed)
     * @param tokenB Second token in the pair (indexed)
     * @param amountA Amount of tokenA deposited
     * @param amountB Amount of tokenB deposited
     * @param liquidity Amount of LP tokens minted to the provider
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
     * @dev Ensures the transaction is executed before a specified deadline
     * @notice Reverts if `block.timestamp` exceeds the provided `deadline`
     * @param deadline Unix timestamp representing the latest valid execution time
     * @custom:reverts With "Deadline passed" if the current time exceeds the deadline
     */
    modifier ensureDeadline(uint256 deadline) {
        require(deadline >= block.timestamp, "Deadline passed");
        _;
    }

    /**
     * @dev Validates that two token addresses are different
     * @notice Prevents operations with identical tokens (e.g., swapping tokenA for tokenA)
     * @param tokenA First token address
     * @param tokenB Second token address
     * @custom:reverts With "Identical tokens" if `tokenA == tokenB`
     */
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
     * @param tokenA Address of first token in pair
     * @param tokenB Address of second token in pair
     * @param amountADesired Desired amount of tokenA to deposit
     * @param amountBDesired Desired amount of tokenB to deposit
     * @param amountAMin Minimum acceptable amount of tokenA
     * @param amountBMin Minimum acceptable amount of tokenB
     * @param to Address to receive LP tokens
     * @param deadline Transaction validity deadline
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
        override
        ensureDeadline(deadline)
        validPair(tokenA, tokenB)
        whenNotPaused
        nonReentrant
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        // Input validation
        require(
            tokenA != address(0) && tokenB != address(0),
            "Invalid token address"
        );
        require(
            amountADesired > 0 && amountBDesired > 0,
            "Amounts must be > 0"
        );
        require(to != address(0), "Zero address recipient");
        require(
            amountADesired >= amountAMin && amountBDesired >= amountBMin,
            "Amounts below minimum"
        );

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
            liquidity = _calculateLiquidity(amountA, reserveA, totalSupply());
        }

        // Transfer tokens from user
        _transferTokens(tokenA, tokenB, amountA, amountB);

        // Mint LP tokens to provider
        _mint(to, liquidity);

        // Update reserves (single storage update)
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
        require(liquidity > 0, "Liquidity must be > 0");

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
        require(
            amountA >= amountAMin && amountB >= amountBMin,
            "Amounts below minimum"
        );

        // Burn LP tokens and transfer underlying assets
        _burn(msg.sender, liquidity);
        _safeTransfer(token0, to, amountA);
        _safeTransfer(token1, to, amountB);

        // Update reserves (single storage update)
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
        // Validate swap parameters
        require(path.length == 2, "Invalid path");
        require(to != address(0), "Zero address recipient");
        amounts = new uint256[](2);
        amounts[0] = amountIn;

        address tokenIn = path[0];
        address tokenOut = path[1];
        require(tokenIn != tokenOut, "Identical tokens");
        require(amountIn > 0, "Amount must be > 0");

        // Get sorted tokens and corresponding pool
        (address token0, address token1) = _sortTokens(tokenIn, tokenOut);
        Pool storage pool = pools[token0][token1];

        // Determine reserve order based on token sorting
        bool isInputToken0 = (tokenIn == token0);
        uint256 reserveIn = isInputToken0 ? pool.reserveA : pool.reserveB;
        uint256 reserveOut = isInputToken0 ? pool.reserveB : pool.reserveA;
        require(reserveIn > 0 && reserveOut > 0, "No liquidity");

        // Calculate output amount using x*y=k formula
        amounts[1] = getAmountOut(amountIn, reserveIn, reserveOut);
        require(amounts[1] >= amountOutMin, "Output below minimum");

        // Execute token transfers
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
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

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amounts[1]);
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
        require(to != address(0), "Zero address recipient");
        require(amount > 0, "Amount must be > 0");

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
        require(tokenA != tokenB, "Identical tokens");

        // Sort tokens to access the pool consistently
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        Pool memory pool = pools[token0][token1];

        // Verify pool has liquidity
        require(pool.reserveA > 0 && pool.reserveB > 0, "No liquidity");

        // Calculate price based on token order
        price = tokenA == token0
            ? (pool.reserveB * 1e18) / pool.reserveA
            : (pool.reserveA * 1e18) / pool.reserveB;
    }

    /**
     * @notice Calculates output amount for given input and reserves
     * @dev Uses constant product formula: amountOut = (amountIn * reserveOut) / (reserveIn + amountIn)
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
        require(reserveIn + amountIn > reserveIn, "Overflow protection");
        require(amountIn > 0, "Amount must be > 0");
        require(reserveIn > 0 && reserveOut > 0, "No liquidity");

        amountOut = (amountIn * reserveOut) / (reserveIn + amountIn);
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
        require(tokenA != tokenB, "Identical tokens");

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
            require(amountBOptimal >= amountBMin, "AmountB below min");
            (amountA, amountB) = (amountADesired, amountBOptimal);
        } else {
            // Calculate optimal amount of tokenA for desired tokenB
            uint256 amountAOptimal = _quote(amountBDesired, reserveB, reserveA);
            require(amountAOptimal >= amountAMin, "AmountA below min");
            (amountA, amountB) = (amountAOptimal, amountBDesired);
        }
    }

    /**
     * @dev Calculates LP tokens to mint based on deposit
     * @param amount Deposit amount
     * @param reserve Existing reserve amount
     * @param totalSupply Current total supply of LP tokens
     * @return liquidity Amount of LP tokens to mint
     */
    function _calculateLiquidity(
        uint256 amount,
        uint256 reserve,
        uint256 totalSupply
    ) internal pure returns (uint256 liquidity) {
        liquidity = (amount * totalSupply) / reserve;
        require(liquidity > 0, "No liquidity");
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
        amountA = (liquidity * reserveA) / _totalSupply;
        amountB = (liquidity * reserveB) / _totalSupply;
    }

    /**
     * @dev Updates pool reserves in storage
     * @param tokenA First token in pair
     * @param tokenB Second token in pair
     * @param newReserveA New reserve amount for tokenA
     * @param newReserveB New reserve amount for tokenB
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
     * @param amountA Amount of tokenA to transfer
     * @param amountB Amount of tokenB to transfer
     */
    function _transferTokens(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB
    ) internal {
        require(
            tokenA != address(0) && tokenB != address(0),
            "Invalid token address"
        );
        if (amountA > 0)
            IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountA);
        if (amountB > 0)
            IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountB);
    }

    /**
     * @dev Safely transfers tokens to recipient
     * @param token Token address to transfer
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _safeTransfer(address token, address to, uint256 amount) internal {
        require(to != address(this), "Cannot transfer to contract");
        require(amount > 0, "Amount must be > 0");
        IERC20(token).safeTransfer(to, amount);
    }

    // ==============================================
    //              PURE FUNCTIONS
    // ==============================================

    /**
     * @dev Calculates square root using Babylonian method
     * @param y Number to calculate square root of
     * @return z Square root of y
     */
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
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
        // Prevents division by zero
        require(reserveA > 0, "ReserveA must be > 0");
        require(reserveB > 0, "ReserveB must be > 0");
        amountB = (amountA * reserveB) / reserveA;
    }
}
