# DeFi Lending

Overcollateralized lending market with deposit / borrow / repay / withdraw, liquidations, and a **dual oracle** (Chainlink AggregatorV3 primary + Pyth-style secondary with deviation check). Foundry coverage: unit + fuzz + invariants.

**No UI and no Playwright in this repo.** Browser E2E belongs to portfolio project 3 (dApp). Manual testing here is Foundry + Anvil + `cast`.

Sibling protocol: [defi-stablecoin](https://github.com/DiegoCascavita/defi-stablecoin) (DSC engine). This repo is a separate lending market, not a wrapper around DSC.

Repo: [github.com/DiegoCascavita/defi-lending](https://github.com/DiegoCascavita/defi-lending)

---

## Architecture

```
Liquidity provider          Borrower                    Liquidator
      │                        │                            │
      │ supplyLiquidity(DAI)   │ depositCollateral(WETH)    │
      │ withdrawLiquidity      │ borrow / repay (DAI)       │ liquidate
      │                        │ withdrawCollateral         │
      ▼                        ▼                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                         LendingPool                             │
│  collateral: WETH   debt/liquidity: DAI   HF + liquidations     │
└──────────────────────────────┬──────────────────────────────────┘
                               │ dual price (WETH/USD)
               ┌───────────────┴────────────────┐
               ▼                                ▼
     ┌──────────────────┐            ┌─────────────────────┐
     │ Chainlink feed   │            │ Secondary oracle    │
     │ AggregatorV3     │◄─dev≤1%───►│ Pyth-style mock     │
     │ (+ OracleLib     │            │ price/conf/time     │
     │  stale check)    │            └─────────────────────┘
     └──────────────────┘
```

| Piece | Role |
|---|---|
| `LendingPool` | Collateral deposit/withdraw, DAI supply/borrow/repay, liquidations, health factor |
| `OracleLib` | Circuit breaker if the Chainlink price is stale (> 3 h) |
| `DualOracleLib` | Requires primary ≈ secondary within `MAX_ORACLE_DEVIATION_BPS` (1%); also checks secondary freshness + confidence width |
| `ISecondaryOracle` | Pyth-style interface (`price`, `conf`, `publishTime`) |
| `HelperConfig` + `DeployLending` | Local Anvil deploy with mock WETH, DAI, Chainlink feed, and secondary oracle |

### Risk parameters

| Constant | Value | Meaning |
|---|---|---|
| Liquidation threshold | 80 | Need ~**125%** collateralization to borrow |
| Min health factor | `1e18` | Below 1 → position is liquidatable |
| Liquidation bonus | 5% | Liquidator incentive |
| Max oracle deviation | 100 bps | Primary vs secondary must agree within 1% |
| Debt asset peg | DAI ≈ $1 | Used for HF math (8-decimal USD convention) |

**Health factor** ≈ `(collateralUsd × 0.80) / debtUsd`

---

## Layout

```
src/
  LendingPool.sol
  interfaces/ISecondaryOracle.sol
  libraries/OracleLib.sol
  libraries/DualOracleLib.sol
script/
  DeployLending.s.sol
  HelperConfig.s.sol
test/
  unit/          # Pool, OracleLib, DualOracleLib
  fuzz/          # Handler + invariants + open fuzz properties
  mocks/         # ERC20Mock, MockV3Aggregator, MockSecondaryOracle
```

Forge libs: OpenZeppelin v5, chainlink-brownie-contracts, forge-std.

---

## How to run

### 1. Install Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge --version   # forge, cast, anvil
```

### 2. Clone, install deps, build, test

```bash
git clone https://github.com/DiegoCascavita/defi-lending.git
cd defi-lending
forge install
forge build
forge test
forge test -vv                 # invariant logs
forge test --gas-report
forge test --match-path 'test/fuzz/*' -vv
```

Fuzz / invariant knobs live in `foundry.toml` (`fuzz.runs = 256`, `invariant.runs = 128`, `depth = 64`).

### 3. Anvil + deploy script

```bash
# Terminal 1 — local chain
anvil

# Terminal 2 — broadcast deploy
forge script script/DeployLending.s.sol:DeployLending \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  -vvvv
```

The script deploys mock WETH + DAI, `MockV3Aggregator` ($2000/ETH), `MockSecondaryOracle`, and `LendingPool`.

Copy the printed addresses for the steps below (or parse `broadcast/.../run-latest.json`).

### 4. Manual flow with `cast`

Use Anvil account #0 (default key shown by `anvil`). Replace placeholders with addresses from the deploy.

```bash
export RPC=http://127.0.0.1:8545
export PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export USER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

export WETH=<weth_address>
export DAI=<dai_address>
export POOL=<pool_address>
export FEED=<primary_feed_address>
export SECONDARY=<secondary_oracle_address>

# Mint tokens
cast send "$WETH" "mint(address,uint256)" "$USER" 10000000000000000000 \
  --rpc-url "$RPC" --private-key "$PK"
cast send "$DAI" "mint(address,uint256)" "$USER" 100000000000000000000000 \
  --rpc-url "$RPC" --private-key "$PK"

# LP: approve + supply DAI liquidity
cast send "$DAI" "approve(address,uint256)" "$POOL" 100000000000000000000000 \
  --rpc-url "$RPC" --private-key "$PK"
cast send "$POOL" "supplyLiquidity(uint256)" 100000000000000000000000 \
  --rpc-url "$RPC" --private-key "$PK"

# Borrower: approve + deposit 10 WETH + borrow 10,000 DAI
cast send "$WETH" "approve(address,uint256)" "$POOL" 10000000000000000000 \
  --rpc-url "$RPC" --private-key "$PK"
cast send "$POOL" "depositCollateral(uint256)" 10000000000000000000 \
  --rpc-url "$RPC" --private-key "$PK"
cast send "$POOL" "borrow(uint256)" 10000000000000000000000 \
  --rpc-url "$RPC" --private-key "$PK"

# Health factor
cast call "$POOL" "getHealthFactor(address)(uint256)" "$USER" --rpc-url "$RPC"

# Optional: crash ETH on BOTH feeds, then liquidate from another account
cast send "$FEED" "updateAnswer(int256)" 100000000000 \
  --rpc-url "$RPC" --private-key "$PK"
cast send "$SECONDARY" "setPrice(int256,uint256)" 100000000000 1000000 \
  --rpc-url "$RPC" --private-key "$PK"
```

Repay / withdraw / liquidate follow the same pattern (`repay`, `withdrawCollateral`, `liquidate`).

---

## Features

- Deposit WETH collateral and withdraw when healthy
- Supply / withdraw DAI liquidity (pool inventory)
- Borrow DAI against collateral (health factor enforced)
- Repay debt
- Liquidate under-collateralized positions (5% bonus)
- Dual oracle: Chainlink AggregatorV3 + secondary Pyth-style feed with 1% deviation + stale/confidence guards
- Anvil deploy scripts + mocks
- Unit, fuzz, and accounting invariant tests

---

## Threat model (auditor notes)

| Risk | Current mitigation | Residual |
|---|---|---|
| **Reentrancy** on deposit/borrow/repay/liquidate | `ReentrancyGuard` + CEI + `SafeERC20` | Exotic ERC777/callback tokens |
| **Oracle stale / freeze** | `OracleLib` 3h timeout (primary) + secondary publishTime timeout | No TWAP fallback; dead feed halts pricing |
| **Oracle manipulation / disagreement** | Dual-feed deviation ≤ 1% + secondary confidence width cap | Both mocks on Anvil are admin-trusted; correlated failure of both feeds still possible |
| **Access control** | No privileged mint of debt asset; pool only transfers ERC20s it holds | Deployer of mocks can set prices in tests |
| **Liquidity shortfall** | `getAvailableLiquidity` gates borrows and LP withdrawals | Bank-run if all LPs exit while debt remains (debt still backed by collateral + liquidations) |
| **Liquidation griefing / bad debt** | 5% bonus + partial liquidations | Sharp price crash can leave bad debt without liquidators |
| **Precision / rounding** | 8 → 18 decimals via `ADDITIONAL_FEED_PRECISION` | Dust edge cases on round-trips |
| **Interest / utilization** | None in v1 (static inventory accounting) | No yield for LPs; intentional scope cut vs Aave |

Key invariants covered in tests:

- `DAI.balanceOf(pool) + totalDebt == totalLiquidity`
- `WETH.balanceOf(pool) == totalCollateral`
- Available liquidity matches `totalLiquidity - totalDebt` (floored at 0)

---

## Slither (optional)

```bash
pip install slither-analyzer
slither . --filter-paths "lib|test|script"

# Or Docker
docker run -v "$PWD":/app trailofbits/eth-security-toolbox
# inside:
cd /app && slither . --filter-paths "lib|test|script"
```

Interpret `arbitrary-send`, `reentrancy-eth`, `timestamp`, and `divide-before-multiply` in context — several are informational for an overcollateralized dual-oracle design.

---

## Cómo probar (resumen)

1. Instalar Foundry (`foundryup`), luego `forge install && forge build && forge test`.
2. En una terminal: `anvil`. En otra: `forge script script/DeployLending.s.sol:DeployLending --rpc-url http://127.0.0.1:8545 --broadcast -vvvv`.
3. Con `cast`: mint WETH/DAI → `supplyLiquidity` → `depositCollateral` → `borrow`. Opcional: bajar **ambos** feeds y llamar `liquidate`.
4. **No hay UI ni Playwright aquí** — eso va en el proyecto dApp.

---

## License

MIT
