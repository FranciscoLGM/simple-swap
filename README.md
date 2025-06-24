# 🦄 SimpleSwap

**SimpleSwap** is a smart contract that implements a decentralized exchange (DEX) similar to Uniswap V2, with support for:

- Adding and removing liquidity.
- Swapping ERC-20 tokens.
- Issuing liquidity provider (LP) tokens.
- Price and balance calculation.

This project was developed in Solidity ^0.8.0 and uses libraries from [OpenZeppelin](https://github.com/OpenZeppelin/openzeppelin-contracts).

---

## 📦 Features

- 🧮 Based on the *Constant Product Market Maker* model (`x * y = k`).
- 🧪 `view` functions for price querying and swap simulation.
- ✅ Minting and burning of LP tokens (based on `ERC20`).
- 🔐 Uses `SafeERC20` for secure token transfers.
- 🧩 Modular `ISimpleSwap` interface for standardized interaction.

---

## 🧠 Main Contract

### `SimpleSwap.sol`

Inherits from `ERC20` and `ISimpleSwap`, and defines the core functions of the DEX. Includes:

- **`Pool` Structure**: Manages reserves of two tokens.
- **Mapping `pools[tokenA][tokenB]`**: Stores reserves for each pair.
- **Events**: `LiquidityAdded`, `LiquidityRemoved`, `Swap`.

---

## ⚙️ Functionality

### 1. Liquidity

#### `addLiquidity(...)`
Allows users to deposit a pair of tokens and mints LP tokens representing their share in the pool.

#### `removeLiquidity(...)`
Burns LP tokens to return a proportional amount of the token pair back to the provider.

### 2. Swapping

#### `swapExactTokensForTokens(...)`
Swaps one token for another using the constant product formula.

### 3. Information Queries

#### `getPrice(tokenA, tokenB)`
Returns the estimated price of token A in terms of token B.

#### `getAmountOut(amountIn, reserveIn, reserveOut)`
Calculates the expected output amount based on input and reserves.

---

## 🛠️ Internal Structure

- `_sortTokens(...)`: Sorts token addresses for consistency.
- `_calculateOptimalDeposit(...)`: Calculates the optimal deposit ratio based on reserves.
- `_calculateLiquidity(...)`: Determines how many LP tokens to mint.
- `_calculateWithdrawalAmounts(...)`: Estimates the return when removing liquidity.
- `_quote(...)`: Calculates token equivalence to maintain pool ratio.
- `_sqrt(...)`: Used to compute the initial LP token amount via geometric mean.

---

## 🪙 LP Token

The `SimpleSwap` contract inherits from `ERC20` and issues a token with:

- **Name:** `SimpleSwap LP`
- **Symbol:** `SS-LP`
- **Decimals:** `18`

---

## 📋 Interface `ISimpleSwap`

Defines the required functions for any contract implementing the protocol:

- `addLiquidity`
- `removeLiquidity`
- `swapExactTokensForTokens`
- `getPrice`
- `getAmountOut`

---

## 🔐 Security

- Extensive use of `require` and modifiers like `ensureDeadline` and `validPair`.
- Validations to prevent reserve manipulation and invalid addresses.
- Uses `SafeERC20` to avoid silent failures in token transfers.

---

## 📄 License

[MIT](https://opensource.org/licenses/MIT)

---

## ✅ Prerequisites

- Solidity ^0.8.0
- Compatible ERC-20 tokens

---

## 🧪 Suggested Tests

- Add initial liquidity and verify LP token issuance.
- Perform multiple swaps and validate constant product formula.
- Remove liquidity and check for exact return proportions.
- Validate `getPrice` and `getAmountOut` against manual simulations.

---