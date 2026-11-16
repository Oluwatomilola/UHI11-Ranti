# Ranti

**Curators get capital and pay only for proven performance, enforced inside a Uniswap v4 hook.**

Ranti is a Uniswap v4 hook vault where a curator's strategy is first backtested in shadow mode, running on live swaps with the curator's own bonded capital before it touches any LP funds.
Once a strategy graduates, it gets a capped share of LP capital, and the cap grows only as the hook confirms the strategy is beating simply holding the tokens.
Curators earn performance fees only on gains above the vault's previous peak share price. The fees are streamed to them and clawed back if performance turns negative.
A better strategy can replace the live one in place, and LP shares and the fee peak stay untouched, so LPs don't have to exit to migrate.

Built for **UHI Hookathon, Prompt 4: hooks that enable performance fees, backtesting, and strategy migration for curators.**

| Prompt 4 asks for | Ranti |
|---|---|
| Performance fees | High-water-mark fee settled in-hook each epoch, charged only above **both** the previous peak and a HODL benchmark |
| Backtesting | Shadow mode: every strategy runs on its curator's bond in the live pool and is scored against HODL every epoch |
| Strategy migration | A challenger that beats the incumbent's record replaces it in place after a one-epoch timelock; shares and HWM carry over |
| (deep-dive cards) Streaming pay + clawback, performance-gated capacity | Fee shares vest per second from `CuratorEscrow`; escrow, then bond, is clawed back when the vault trails HODL. Deposit cap grows only with verified returns |

---

## Lifecycle

```
 register + bond            >= 3 epochs, mean excess > 1 s.e.,            beats incumbent over
 (curator's own capital)    drawdown < 5%                                 last 3 epochs
        |                          |                                              |
        v                          v                                              v
   [ SHADOW ] ---------------> [ GRADUATED ] -- proposeUpgrade --> [ PROBATION ] --> [ TENURED ]
   bond deployed at the        eligible to                         live on LP capital   after 4 live epochs:
   strategy's ranges,          go live                             cap0 = 2x bond       higher cap ceiling
   scored vs HODL                                                  cap grows only with
   every epoch                                                     verified excess return
                                                                          |
                     replaced by a better challenger <---------------------+
                     (goes back to SHADOW, keeps its record)
```

Every epoch, `settleEpoch()` (permissionless) does, inside one `PoolManager.unlock`:

1. Pulls **all** hook-owned positions (vault + every shadow) into idle balances, which collects fees exactly.
2. Values each bucket at the hook's own **TWAP** and scores it against **HODL**: `x = NAV_end / value(start tokens at end price) - 1`.
3. Vault accounting: HWM fee into escrow, clawback if `x < 0`, capacity update, vesting pause below HWM.
4. Executes a due strategy migration.
5. Re-ranges every bucket with its strategy's range (base) plus a single-sided "limit" range for leftovers.

## Mechanisms

**Valuation and benchmark.** v4 has no oracle, so the hook keeps one: a tick accumulator updated once per block in `beforeSwap` (the only work on the swap path), with ring-buffer checkpoints every `oracleInterval` seconds. Settlement reverts if `|spot - TWAP| > maxTickDeviation`. Each epoch is scored against holding the epoch-start tokens, so curators are never paid for price drift (beta), only for beating HODL.

**High-water-mark fee** (`RantiMath.performanceFee`). With price per share `p`, peak `H`, HODL price per share `p_hodl`, rate `phi`:

```
fee value   F = phi * max(0, p - max(H, p_hodl)) * S
fee shares  f = F * S / (NAV - F)          (Enzyme's dilution formula: pps becomes p - F/S)
new peak    H = max(H, NAV / (S + f))      (never decreases)
```
Recovering a drawdown back to the peak pays nothing. Fee shares are minted to `CuratorEscrow`, never directly to the curator.

**Shadow mode (backtesting on live flow).** A strategy's bond is real liquidity at the strategy's ranges in the same pool, held in its own accounting bucket. That means fees, impermanent loss and rebalancing costs are real, ticks are initialised, and nothing runs on the swap path no matter how many shadows exist. Graduation requires `minShadowEpochs` measured epochs, max drawdown of the excess-return index under `maxDrawdownWad`, and a one-sided significance test: `mean^2 * n > z^2 * variance`.

**Performance-gated capacity** (`StrategyRegistry.recordLive`). On promotion `cap0 = bondValue * capMultiple` (clamped). After each live epoch the cap grows by up to `capGrowthBps`, scaled by verified excess return relative to `targetExcessWad`, and is cut by `capHaircutBps` on drawdown. It can never exceed `cap0 * (1 + g)^liveEpochs`, so one lucky epoch cannot unlock large AUM. Deposits that would push vault value (at TWAP) above the cap revert. Returns can grow the vault past the cap; nobody is forced out.

**Streaming and clawback** (`CuratorEscrow`). Each fee tranche vests linearly over `vestingPeriod`; the curator can `claim()` any block. Vesting pauses while price per share is below the HWM. When the vault trails HODL, the shortfall is covered by burning unvested, then vested-but-unclaimed, escrow shares (their value passes to LPs), then by moving up to `bondSlashBps` of the remainder from the live curator's bond into the vault.

**Migration without exit.** `proposeUpgrade(challenger)` is permissionless: the challenger must be graduated and must have beaten the incumbent over the last `challengeWindow` epochs, both measured on equal-footing shadow buckets. It executes at the settlement after the next one (one full epoch of notice; withdrawals are always open). Within one unlock the hook swaps the vault's ranges to the new strategy. Share supply, LP balances, HWM and escrow are untouched. The old incumbent returns to shadow with its record intact; its escrow keeps vesting and is no longer at risk.

## Architecture

```
LPs ── deposit / withdraw ──► RantiHook  (BaseHook + ERC-20 vault shares, owns all pool liquidity)
                                 │  beforeInitialize   bind to one pool, ERC-20 pairs only
                                 │  afterInitialize    start oracle + epoch clock
                                 │  beforeAddLiquidity revert: no outside LPs, so no JIT
                                 │  beforeSwap         one oracle accrual per block
                                 │  settleEpoch() ─► unlock ─► value, score, fee, clawback, migrate, re-range
Curators ── register + bond ────►│
                                 ├─► StrategyRegistry   track records, graduation test, capacity, stages
                                 ├─► CuratorEscrow      fee-share streams, pause, clawback
                                 └─► IRantiStrategy     view-only: getRange(twapTick, spacing) -> (lower, upper)
Keeper (anyone) ── settleEpoch() once per epoch
```

- `src/RantiHook.sol`: the hook, vault, buckets, oracle wiring and settlement
- `src/StrategyRegistry.sol`: lifecycle, statistics, capacity (hook-only writes)
- `src/CuratorEscrow.sol`: fee streams and clawback (hook-only writes)
- `src/libraries/RantiMath.sol`: valuation, HWM fee, significance test
- `src/libraries/TwapOracle.sol`: tick accumulator and checkpoints
- `src/strategies/CenteredRangeStrategy.sol`: sample strategy (TWAP-centred fixed width)

Strategies hold no funds. The hook calls them with a 100k gas cap and validates ranges (alignment, bounds, ordering). A strategy that reverts, burns gas or returns a bad range is rejected at registration and left idle at settlement, which then shows up in its score.

## Security notes

- **No outside liquidity.** `beforeAddLiquidity` always reverts; v4 does not call a hook for its own `modifyLiquidity`. JIT on this pool is impossible.
- **Deposits and withdrawals are pro-rata** to current holdings, with no price input. Moving the price before depositing costs the manipulator, because AMM holdings at the true price minimise value at that price. Fees are collected (`poke`) before pricing a deposit, so late joiners pay for fees already earned. Holdings round **up** when pricing deposits; withdrawals round down.
- **Settlement uses TWAP** and reverts when spot strays from it. Anyone can settle after the epoch ends, so a curator cannot pick the moment.
- **First-deposit inflation** is blocked by 1,000 dead shares.
- **Solvency invariant** (checked across unit, lifecycle and fuzz tests): the hook's token balances always cover every idle balance it books.

## Setup

```bash
git clone --recursive https://github.com/Oluwatomilola/UHI11-Ranti
cd UHI11-Ranti
forge build
```

Already cloned without `--recursive`? Run `git submodule update --init --recursive`. Dependencies: forge-std and OpenZeppelin `uniswap-hooks` v1.2.1, which brings v4-core, v4-periphery and OpenZeppelin contracts.

## Tests

```bash
forge test                       # 50 tests: unit, lifecycle, adversarial, fuzz
forge test --mc RantiDemo -vv    # narrated end-to-end run (good for the demo video)
forge test --mc RantiGas -vv     # gas profile
```

Covered:
- **Shadow mode:** bonds deploy at the next settlement; scoring against HODL; narrow beats wide in mean-reverting flow; trending flow fails graduation.
- **Graduation and promotion:** epoch minimum, significance test, first promotion, cap0.
- **LP flows:** pro-rata deposits, round trip never profits (fuzzed), capacity gate, capacity growth bounded by the time ceiling.
- **Fees and clawback:** HWM fee to escrow, per-second streaming and claim, clawback when trailing HODL, bond slash when escrow runs out, no fee below the peak.
- **Migration:** in-place upgrade keeps LP shares and HWM; challenger must outperform; LPs can exit during the timelock.
- **Adversarial:** same-block price push makes settlement revert; settlement survives an emptied vault; deposit-settle-withdraw sandwich unprofitable; JIT rejected; invalid, gas-bomb and later-broken strategies; bond minimum; max active strategies; hook-only registry and escrow.
- **Math fuzz:** HWM never decreases; fee ≤ rate × gain above base; LPs never pushed below the old peak; floorTick.

Excerpt from `RantiDemo`:

```
== 2. TRACK RECORD: every epoch scored against HODL by the hook itself
  Epoch 1:  Narrow +15.3 bps   Wide +1.0 bps
  ...
== 4. PERFORMANCE-GATED CAPACITY
  LP tries to deposit 250 + 250 (~500 value): REVERTED, CapExceeded
== 5. HIGH-WATER-MARK FEE, streamed from escrow
  HWM: 1.000000 -> 1.000257 (price per share)
  Capacity grew on verified excess return: 401.83 -> 466.54
== 6. CLAWBACK: informed flow pushes price through the range
  Vault vs HODL this epoch: -13.6 bps
  Escrow at risk: 0.008056 -> 0.000000 shares (burned for LPs)
  Curator bond slashed into the vault (value): 0.165892
== 8. MIGRATION WITHOUT LP EXIT
  LP shares: 250.21 -> 250.21 (no action taken)
  HWM carried over: 1.000257 -> 1.000257
```

Gas (measured in-test, warm storage, so indicative only): settlement with the vault and 3 shadows is about 1.5M; a deposit is about 210k; a withdrawal is about 54k. The swap path adds one oracle accrual on the first swap of each block.

## Deploy (Unichain Sepolia)

```bash
export PK=0x...          # funded Unichain Sepolia key
export UNICHAIN_SEPOLIA_RPC_URL=https://sepolia.unichain.org

# Mines the hook address, deploys hook + registry + escrow, two test tokens,
# initialises the pool and registers two shadow strategies with your bond.
forge script script/DeployRanti.s.sol --rpc-url unichain_sepolia --broadcast --private-key $PK

# Generate flow (mean-reverting by default; TREND=true for one-way flow)
HOOK=0x... forge script script/Flow.s.sol --rpc-url unichain_sepolia --broadcast --private-key $PK

# Keeper: close each 10-minute epoch
cast send $HOOK "settleEpoch()" --rpc-url unichain_sepolia --private-key $PK

# Once a strategy graduates
cast send $HOOK "proposeUpgrade(uint256)" 1 --rpc-url unichain_sepolia --private-key $PK
```

Defaults: PoolManager `0x00B036B58a818B1BC34d502D3fE730Db729e62AC`, PoolSwapTest `0x9140a78c1A137c7fF1c151EC8231272aF78a99A4` (Uniswap v4 deployments page, Unichain Sepolia). Demo-speed parameters are in `script/RantiConfig.sol`. The full flow (deploy, shadows, graduation, promotion, deposit, fee) has been run with real transactions on a local anvil chain.

## Known limitations

- **Per-share high-water mark.** LPs who join below the peak ride the recovery without paying fee on it (the classic equalisation problem). Series accounting is future work.
- **Shadow size ≠ live size.** A small bond does not move fee share the way large capital does. That is why capacity ramps rather than jumps.
- **Clawback is bounded** by unvested and unclaimed escrow plus the bond slash fraction.
- **No rebalancing swaps.** Leftovers sit in a single-sided limit range next to the price (Charm-style) rather than being swapped. This is applied the same way to every strategy, so comparisons stay fair.
- **One pool per hook**, ERC-20 pairs only. At most 4 active strategies; bonded slots, no stale-shadow eviction yet.
- **Oracle bootstrap.** Until the TWAP window has history, it uses the history available.
- **Contract size.** `RantiHook` is about 24.5 KB (EIP-170 limit 24.576 KB) with `via_ir` and `optimizer_runs = 1`. Escrow and registry were split out for this reason.
- Not audited. Hackathon code.

## Roadmap

Dashboard (lifecycle timeline, caps, HWM, escrow, clawback log) · backtest replaying real Unichain swaps through the strategies (with a random-strategy null) · Reactive Network / Chainlink Automation keeper for `settleEpoch` · deposit queue for over-cap demand · ZK-proved portable track records (Brevis) · series accounting for the HWM.

## License

MIT
