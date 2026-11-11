# DeFi Lending

Overcollateralized lending market with deposit / borrow / repay / withdraw, liquidations, and a **dual oracle** (Chainlink AggregatorV3 primary + Pyth-style secondary with deviation check). Foundry coverage: unit + fuzz + invariants + optional fork tests.

**No UI and no Playwright in this repo.** Browser E2E belongs to [defi-dapp](https://github.com/DiegoCascavita/defi-dapp) (Cascade Lend). Manual testing here is Foundry + Anvil + `cast`.

Repo: [github.com/DiegoCascavita/defi-lending](https://github.com/DiegoCascavita/defi-lending)

---

## Cascade Suite

Related DeFi portfolio (read in order):

| # | Repo | Role |
|---|---|---|
| 1 | [defi-stablecoin](https://github.com/DiegoCascavita/defi-stablecoin) | Overcollateralized DSC engine + `OracleLib` stale guard |
| 2 | **defi-lending** (this repo) | Lending pool + dual oracle + liquidations |
| 3 | [defi-dapp](https://github.com/DiegoCascavita/defi-dapp) | Cascade Lend — Next.js / wagmi UI on Anvil `31337` |

```
defi-stablecoin ──► defi-lending ──► defi-dapp (Cascade Lend)
   DSC / CR~200%      dual-oracle HF      wallet + supply/borrow UI
```

This lending market is a **separate** protocol from DSC (not a wrapper). Shared ideas: health factor, liquidations, Chainlink stale checks.

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
     │ AggregatorV3     │◄─dev≤1%───►│ Pyth-style          │
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
| `HelperConfig` + `DeployLending` | Anvil mocks **or** Sepolia real Chainlink ETH/USD (+ deploy-time secondary / DAI mocks) |

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
  fork/          # Optional: live Chainlink via createSelectFork
  mocks/         # ERC20Mock, MockV3Aggregator, MockSecondaryOracle
```

Forge libs: OpenZeppelin v5, chainlink-brownie-contracts, forge-std.

---

## Testing (7 types)

| Type | Status | How |
|---|---|---|
| Unit | Have | `forge test --match-path 'test/unit/*'` |
| Continuous (CI) | Have | `.github/workflows/test.yml` on push/PR |
| Local (Anvil) | Have | `anvil` + `DeployLending --broadcast` + `cast` |
| Fork | Have (opt-in) | `test/fork/*` when `SEPOLIA_RPC_URL` or `MAINNET_RPC_URL` is set; **skipped** otherwise so CI stays green |
| Real network | Ready (scripted) | Sepolia `HelperConfig` + `--broadcast --verify` checklist below — needs your keys |
| Fuzz | Have | `test/fuzz/OpenInvariantsTest.t.sol` (`fuzz.runs = 256`) |
| Invariant | Have | `test/fuzz/Invariants.t.sol` (`invariant.runs = 128`) |

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

### 3. Fork tests (optional)

```bash
cp -n .env.example .env
# set SEPOLIA_RPC_URL=https://...  (and/or MAINNET_RPC_URL)
source .env
forge test --match-path 'test/fork/*' -vv
```

Without those env vars, fork tests call `vm.skip` and the default `forge test` suite still passes.

What the fork suite covers:

- Live Chainlink ETH/USD freshness (`OracleLib` stale check)
- `DualOracleLib` agreement vs a secondary calibrated to the live answer
- Deviation revert when secondary drifts > 1%
- Borrow / HF using the live primary price
- Liquidation after `vm.mockCall` crashes the primary (Chainlink itself is not writable)

### 4. Anvil + deploy script

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

### 5. Manual flow with `cast`

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

## Sepolia deploy (checklist — do not invent keys)

`HelperConfig` selects Sepolia when `block.chainid == 11155111`.

| Item | Value / source |
|---|---|
| ETH/USD primary | `0x694AA1769357215DE4FAC081bf1f309aDC325306` — [Chainlink Sepolia feeds](https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1#sepolia-testnet) |
| WETH | `0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9` — [Sepolia WETH](https://sepolia.etherscan.io/token/0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9) (or set `SEPOLIA_USE_MOCK_WETH=true` for a mintable mock) |
| Secondary | Deployed by `DeployLending` as `MockSecondaryOracle` synced to the live Chainlink answer (no public Pyth-style `ISecondaryOracle` on Sepolia) |
| DAI | Deployed by `DeployLending` as mintable `ERC20Mock` (no reliable Maker faucet) |

**Secrets** (local `.env` only — see `.env.example`; never commit):

1. `SEPOLIA_RPC_URL` — Alchemy / Infura / public Sepolia RPC  
2. `PRIVATE_KEY` — funded **test** wallet only  
3. `ETHERSCAN_API_KEY` — for `--verify`  

If any of these are missing, **do not broadcast**. The script refuses Sepolia broadcast when `PRIVATE_KEY` is unset.

```bash
cp -n .env.example .env
# fill SEPOLIA_RPC_URL, PRIVATE_KEY, ETHERSCAN_API_KEY on your machine
source .env

forge script script/DeployLending.s.sol:DeployLending \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast \
  --verify \
  -vvvv
```

Post-deploy: record Pool / WETH / DAI / primary / secondary addresses in the table below and point [defi-dapp](https://github.com/DiegoCascavita/defi-dapp) `NEXT_PUBLIC_*` at them when wiring Sepolia mode.

| Contract | Sepolia address |
|---|---|
| LendingPool | _pending broadcast_ |
| WETH | `0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9` (or mock) |
| DAI | _pending broadcast_ |
| Primary ETH/USD | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| Secondary oracle | _pending broadcast_ |

Canonical WETH has no `mint` — wrap Sepolia ETH via `deposit()` or use `SEPOLIA_USE_MOCK_WETH=true`. Mock DAI: call `mint` from the deployer.

---

## Features

- Deposit WETH collateral and withdraw when healthy
- Supply / withdraw DAI liquidity (pool inventory)
- Borrow DAI against collateral (health factor enforced)
- Repay debt
- Liquidate under-collateralized positions (5% bonus)
- Dual oracle: Chainlink AggregatorV3 + secondary Pyth-style feed with 1% deviation + stale/confidence guards
- Anvil + Sepolia-ready deploy scripts (`HelperConfig`)
- Unit, fuzz, invariant, and optional fork tests

---

## Threat model (auditor notes)

| Risk | Current mitigation | Residual |
|---|---|---|
| **Reentrancy** on deposit/borrow/repay/liquidate | `ReentrancyGuard` + CEI + `SafeERC20` | Exotic ERC777/callback tokens |
| **Oracle stale / freeze** | `OracleLib` 3h timeout (primary) + secondary publishTime timeout | No TWAP fallback; dead feed halts pricing |
| **Oracle manipulation / disagreement** | Dual-feed deviation ≤ 1% + secondary confidence width cap | Anvil mocks are admin-trusted; Sepolia secondary is deploy-time mock (ops must refresh or re-deploy if stale); correlated failure of both feeds still possible |
| **Access control** | No privileged mint of debt asset; pool only transfers ERC20s it holds | Deployer of mocks can set prices / mint test DAI |
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
4. Fork opcional: `SEPOLIA_RPC_URL` o `MAINNET_RPC_URL` en `.env` → `forge test --match-path 'test/fork/*' -vv`.
5. Sepolia: completar `.env` con tus claves y usar el checklist de arriba (`--broadcast --verify`). **No inventar keys.**
6. **No hay UI ni Playwright aquí** — eso va en [defi-dapp](https://github.com/DiegoCascavita/defi-dapp).

---

## License

MIT
