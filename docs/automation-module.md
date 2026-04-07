# Operator Automation — `AutoBridgeModule`

For Vin and Jarryd. The vault ships with a Gnosis Safe module that handles routine bridge operations on behalf of the operator Safe, within hardcoded limits. This document explains why it exists, how it works, what production patterns it borrows, and exactly what gets signed to activate it on mainnet.

**TL;DR** — the vault contracts do not change. The Safe stays as the operator forever. A separate contract (`AutoBridgeModule`) is installed onto the Safe at launch and gets a narrow, capped capability to call `depositToTN` and `claimFromTN` so humans don't have to sign every bridge op once TVL grows. The multisig keeps every other power and can revoke the module instantly with one transaction.

---

## Where the operator role stands

The vault is written so that exactly one address — `operator` — can call the privileged functions:

```solidity
function depositToTN(uint256 amount) external onlyOperator nonReentrant { ... }
function claimFromTN(...)              external onlyOperator nonReentrant { ... }
function recordPnL(int256 pnlDelta)    external onlyOperator { ... }
function pause() / unpause() / setFee(...) / updateCurator(...) ...
```

On mainnet, that single `operator` address is a Gnosis Safe (N-of-M). The Safe never changes — it is the operator forever, baked into the operational architecture.

What changes is how the Safe authorizes its outbound transactions. Initially, every bridge op requires multisig signers to manually:

1. Propose the transaction in the Safe UI
2. Collect 2 signatures
3. Execute on chain

This is fine for the very first deposits, but it does not survive contact with real flow.

## Why manual signing alone doesn't work past launch

Once the vault is open to depositors, integrated with Merkl rewards, and getting real flow:

- **Withdrawals stack up overnight.** The vault keeps a ~20% idle reserve. When a withdrawal exceeds the reserve, the operator has to call `claimFromTN` to refill. If that happens at 3am and signers are asleep, the user waits hours.
- **Reserve drift.** New deposits accumulate into the idle balance. They sit there earning nothing until the operator bridges them out. Manual signing means batched, infrequent bridge ops, which means inefficient capital use.
- **Rebalancing windows are missed.** PnL accounting and curator strategy create natural rebalancing points. Manual signing doesn't hit them reliably.

These aren't theoretical — Merkl integration and the first wave of LP partnerships push deposit/withdraw flow from sporadic to continuous within the first weeks. The system needs an automation layer at launch, not bolted on later.

## The design — module installed on the Safe

The fix is a **Gnosis Safe module** attached to the vault's operator Safe.

A Safe module is a small contract that the multisig signers approve once. Once installed, the module can execute specific transactions on behalf of the Safe (using `safe.execTransactionFromModule`) without requiring fresh signer approval each time. The module's own code enforces the rules. The signers can remove the module at any moment, which reverts the system back to fully manual.

```
                    ┌──────────────────────────┐
                    │   TrufVault.sol          │
                    │   (audited, immutable)   │
                    └────────────▲─────────────┘
                                 │
              calls depositToTN / claimFromTN
                                 │
                    ┌────────────┴─────────────┐
                    │   Gnosis Safe (operator) │
                    │   Address baked into     │
                    │   vault. Never changes.  │
                    └────────────▲─────────────┘
                                 │
                  ┌──────────────┴──────────────┐
                  │                             │
       2-of-3 manual signatures         AutoBridgeModule
       (governance, emergency,          (routine bridge ops,
        installs/removes module)         hardcoded limits)
```

The vault sees one address — the Safe. The Safe internally evolves how it authorizes outbound transactions. The vault contracts have no idea this is happening, and they don't need to.

### Critical distinction — the module is *installed on* the Safe, not *given* the Safe's role

This matters because two architectures look superficially similar but have very different blast radii:

| Question | "Module becomes operator" (NOT what we do) | "Module installed on Safe" (what we do) |
|---|---|---|
| Who is the vault's operator? | The module contract | The Safe, unchanged |
| What can the module do? | Everything operator can do | Only `depositToTN` / `claimFromTN`, within hardcoded caps |
| What can the multisig still do directly? | Nothing — they handed it over | Everything — `pause`, `setFee`, `recordPnL`, `transferOperator`, etc. |
| How to kill the module if bugged? | Redeploy operator, multi-step ceremony | One Safe transaction: `disableModule` |
| Worst-case blast radius of a module bug | Whole vault | Per-tx cap, capped further by daily cap, gated by reserve floor |

The "module installed on Safe" pattern is what Safe Allowance Module, Lido Easy Track, Zodiac, and every production Safe-module setup uses. The multisig stays sovereign. The module is a limited tool the multisig holds and can drop at any moment.

### What the module does not protect against

The module constrains only the **module-routed path**: keeper-triggered calls that go through `safe.execTransactionFromModule(...)`.

It does **not** constrain the Safe's normal signed transaction path. Because the Safe remains the vault's operator, threshold-level multisig signers can still call `vault.depositToTN(...)` directly with a standard Safe transaction and bypass the module's `bridgedThisPeriod` accounting entirely.

That means the real threat model is:

- Compromised keeper key: constrained by per-tx cap, daily cap, reserve floor, and claim cooldown
- Misconfigured module parameters by the Safe: constrained by the module's hardcoded setter bounds
- Threshold-level multisig compromise: **not** constrained by the module; the Safe is sovereign by design

This is an intentional architectural tradeoff. We keep the vault unchanged and preserve the Safe's full operator authority, instead of inserting the module into every privileged vault path.

## What the module does

`AutoBridgeModule.sol` exposes exactly two operational entry points:

```solidity
function autoBridgeToTN(uint256 amount) external onlyKeeper nonReentrant { ... }

function autoClaimFromTN(
    uint256 amount,
    bytes32 kwilBlockHash,
    bytes32 root,
    bytes32[] calldata proof,
    ITrufNetworkBridge.Signature[] calldata signatures
) external onlyKeeper nonReentrant { ... }
```

Each one routes through a single internal helper that calls `safe.execTransactionFromModule(address(vault), 0, data, Operation.Call)`. There is exactly one place in the contract that touches the Safe.

### Enforcement on `autoBridgeToTN`

In order:

1. **Period rollover** — if the UTC day has changed since `currentPeriodStart`, reset `bridgedThisPeriod` to zero and snapshot `periodStartTotalAssets`. Lazy reset (no cron), interval-aligned (no drift).
2. **Per-tx cap** — `amount <= totalAssets * perTxBridgeBps / 10000`. Default 10% of total assets per call.
3. **Daily cap** — `bridgedThisPeriod + amount <= periodStartTotalAssets * dailyBridgeBps / 10000`. Default 30% of the period-start asset base per UTC day. If the day starts at zero TVL, the first bridge of the day lazily initializes the snapshot from current `totalAssets()`.
4. **Reserve floor** — `idleAfterBridge >= totalAssets * minReserveBps / 10000`. Default 15% reserve. Check is post-bridge: the contract simulates the idle balance after the bridge action and refuses to proceed if it would breach the floor.
5. **Effects before interaction** — `bridgedThisPeriod += amount` happens before the Safe call.
6. **Safe call** — `_execVaultCall(abi.encodeCall(TrufVault.depositToTN, (amount)))`.

### Enforcement on `autoClaimFromTN`

In order:

1. **Cooldown** — `block.timestamp >= lastClaimAt + claimCooldown`. Default 1 hour.
2. **Cap against deployedOnTN** — `amount <= vault.deployedOnTN()`. Cheaper to fail fast in the module than to waste a Safe transaction.
3. **Effects before interaction** — `lastClaimAt = block.timestamp`.
4. **Safe call** — `_execVaultCall(abi.encodeCall(TrufVault.claimFromTN, (amount, ...)))`.

There is no daily cap on claims because claims only bring funds *back into* the vault. They cannot move funds out. Cooldown alone is sufficient to prevent claim spam / gas waste.

### What the module cannot do

The module has no code path to call any other vault function. **It physically cannot:**

- pause / unpause the vault
- record PnL
- set or change the fee
- update the curator address
- transfer or accept the operator role
- change the skim recipient
- skim tokens
- approve any token to any address

All of those remain manual-multisig-only. They go through the normal Safe signing ceremony with the same 2-of-3 threshold as the vault has used since launch.

### Hardcoded ceilings

Even the multisig itself cannot lift these. They are constants in the module bytecode:

| Constant | Value | What it caps |
|---|---|---|
| `MAX_PER_TX_BRIDGE_BPS` | 1000 (10%) | Maximum per-tx bridge cap. Setter `setPerTxBridgeBps` reverts if asked for more. |
| `MAX_DAILY_BRIDGE_BPS` | 3000 (30%) | Maximum daily bridge cap. Setter `setDailyBridgeBps` reverts if asked for more. |
| `MIN_ALLOWED_RESERVE_BPS` | 500 (5%) | Floor on the reserve floor — prevents the multisig from setting the reserve to zero and sweeping. |
| `MAX_ALLOWED_RESERVE_BPS` | 5000 (50%) | Ceiling on the reserve floor — beyond this the bot is mostly redundant. |
| `MIN_CLAIM_COOLDOWN` | 5 minutes | Floor on cooldown — prevents zero-cooldown spam. |
| `MAX_CLAIM_COOLDOWN` | 1 day | Ceiling on cooldown — prevents bricking the bot with an unreasonably long delay. |

Even if the multisig misconfigures a setter, the most permissive module configuration it can apply is the one we already reviewed at design time. This protects the module-controlled path, not direct Safe-signed vault calls.

### Two-role separation

The module strictly distinguishes who can do what:

- **Keeper** (single address, typically the bot's hot wallet): can call `autoBridgeToTN` and `autoClaimFromTN`. Cannot change any parameter. Cannot rotate itself.
- **Safe** (the multisig itself, calling its own admin function on the module): can call `setPerTxBridgeBps`, `setDailyBridgeBps`, `setMinReserveBps`, `setClaimCooldown`, `transferKeeper`. Cannot consume the limits.
- **Pending keeper**: can call `acceptKeeper` to complete a two-step rotation.

The keeper address has zero ability to lift its own caps. To raise a daily cap, the multisig has to sign a Safe transaction targeting the module's admin function — same ceremony as any other governance action.

## How we activate the module once the vault contracts are deployed

The activation timeline runs from "vault is live on mainnet" to "bot is handling routine bridge ops" in a small number of well-defined steps. Nothing here requires changing the vault. Nothing here requires the multisig to give up custody of anything. The whole sequence is two Safe signatures plus one keeper-address call.

```
Day 0 — Vault deployed
        TrufVault and TrufVaultFactory live on mainnet.
        Operator on the vault is the existing Gnosis Safe (2-of-3).
        100% manual signing — every depositToTN / claimFromTN goes through Safe UI.
        AutoBridgeModule does not exist yet.

Day 0 → Day N — Module audit
        Same auditors, same engagement, scoped alongside the vault.
        ~350 lines, only dependency is OpenZeppelin ReentrancyGuard.
        Vault keeps running manually during this window.

Day N — Module deployment
        forge script deploys AutoBridgeModule with constructor args:
          (safe, vault, perTxBridgeBps=1000, dailyBridgeBps=3000,
           minReserveBps=1500, claimCooldown=1 hours)
        Constructor verifies vault.operator() == address(safe). If not, deploy reverts.
        Module exists on chain. Has zero power. Nobody has authorized it yet.

Day N — First multisig transaction (activates the module)
        2 of 3 signers sign one Safe transaction in the Safe UI:
          target:   <safe address>
          function: enableModule(address module)
          arg:      <newly deployed AutoBridgeModule address>
        After this confirms, the Safe will accept calls from the module's
        address through execTransactionFromModule. The module is now armed
        but has no keeper, so it still cannot do anything useful.

Day N — Second multisig transaction (assigns the bot)
        2 of 3 signers sign one more Safe transaction:
          target:   <module address>
          function: transferKeeper(address newKeeper)
          arg:      <keeper address>
        Sets pendingKeeper. The bot is not yet authorized — two-step rotation
        prevents fat-fingering and forces the bot to demonstrate it controls the key.

Day N — Bot accepts (no multisig involvement)
        The keeper address calls module.acceptKeeper().
        Two-step rotation completes. Bot is live.

Day N+ — Bot operates
        Bot calls autoBridgeToTN / autoClaimFromTN within the caps.
        Multisig is no longer in the loop for routine bridge ops.
        Multisig still handles everything else (pause, setFee, recordPnL,
        updateCurator, transferOperator, parameter updates) the same way it
        always has — manual signing through the Safe UI.

Any later day — Kill switch (if anything looks wrong)
        2 of 3 signers sign one Safe transaction:
          target:   <safe address>
          function: disableModule(address prevModule, address module)
        Module instantly loses all power. Vault keeps running unchanged.
        Manual signing resumes.
```

The total ceremony to go from "module audited" to "bot running" is **two multisig transactions plus one keeper-address call**. Both multisig transactions are routine "Contract Interaction" calls in the Safe UI — calldata is generated by the deployment script and pasted into the Safe UI by the signers.

The total ceremony to undo all of that is **one multisig transaction**.

### Tabular form, exactly what gets signed

| Step | Who | Action | What it does |
|---|---|---|---|
| 1 | Deployer EOA | `forge script DeployAutoBridgeModule` | Deploys the module. Constructor verifies `vault.operator() == safe`. **Module exists on chain but has zero power because nobody has authorized it.** |
| 2 | 2-of-3 multisig | Safe tx: `safe.enableModule(moduleAddress)` | After this confirms, the Safe will accept calls from the module's address through `execTransactionFromModule`. **This is the only step that grants the module any capability**, and it grants exactly the narrow capability described above. |
| 3 | 2-of-3 multisig | Safe tx: `module.transferKeeper(keeperAddress)` | Sets `pendingKeeper`. The keeper is not yet authorized. |
| 4 | Keeper address | `module.acceptKeeper()` | Two-step rotation completes. Bot is live. |

That is the entire activation. **Two multisig transactions plus one keeper-address call.** Both multisig transactions are routine Safe UI "Contract Interaction" calls — calldata is generated by the deployment script and pasted into the Safe UI by the signers.

### Kill switch

If anything ever looks wrong, the multisig signs **one** Safe transaction:

```
safe.disableModule(prevModule, moduleAddress)
```

`prevModule` is the linked-list pointer Safe uses internally — the Safe UI fills it in automatically. After this transaction confirms, the module loses every capability instantly. The vault keeps working unchanged. Manual signing resumes immediately.

The module has no internal "emergency stop" function. Disabling the module on the Safe **is** the emergency stop. There is no second mechanism to maintain.

### Parameter changes

To raise/lower a cap or rotate the keeper, the multisig signs a Safe transaction targeting the module's admin function:

- `module.setPerTxBridgeBps(newBps)` — bounded by `MAX_PER_TX_BRIDGE_BPS`
- `module.setDailyBridgeBps(newBps)` — bounded by `MAX_DAILY_BRIDGE_BPS`
- `module.setMinReserveBps(newBps)` — bounded by `[MIN_ALLOWED_RESERVE_BPS, MAX_ALLOWED_RESERVE_BPS]`
- `module.setClaimCooldown(newSeconds)` — bounded by `[MIN_CLAIM_COOLDOWN, MAX_CLAIM_COOLDOWN]`
- `module.transferKeeper(newKeeper)` — sets `pendingKeeper`, new keeper must call `acceptKeeper`

The module's `onlySafe` modifier checks `msg.sender == address(safe)`, so only signed multisig transactions can change parameters.

## What changes in the vault contracts

Nothing.

The operator role is still a single address. The Safe is still that address. The Safe just gains a new way to authorize a narrow subset of its outgoing transactions. The TrufVault.sol you are auditing is the same version that ships at launch. The module is reviewed alongside it but lives in a separate file in `src/automation/`.

---

## Pattern lineage

The `AutoBridgeModule` is not novel work — it composes patterns from four production-audited contracts. Same approach the vault took with Morpho's MetaMorpho — borrow the proven patterns, document the lineage, ship the smaller surface.

### 1. Safe Allowance Module — `safe-global/safe-modules`

**Repo:** [safe-global/safe-modules/modules/allowances](https://github.com/safe-global/safe-modules/tree/main/modules/allowances)
**What it is:** The official Safe module that lets a Safe owner authorize a delegate to transfer tokens out of the Safe up to a periodic limit, without needing fresh signer approval each time.

**Pattern A — Auto-resetting periodic cap.** The allowance struct tracks `spent`, `resetTimeMin`, and `lastResetMin`. When the delegate calls `executeAllowanceTransfer`, the contract first calls `getAllowance()`, which checks:

```solidity
if (allowance.resetTimeMin > 0 &&
    allowance.lastResetMin <= currentMin - allowance.resetTimeMin) {
    allowance.spent = 0;
    allowance.lastResetMin = currentMin -
        ((currentMin - allowance.lastResetMin) % allowance.resetTimeMin);
}
```

Two important properties:

1. **The reset is lazy.** Nobody has to call a separate "tick" function. The reset happens inline the next time the delegate tries to spend.
2. **The reset is interval-aligned.** `lastResetMin` is set to a multiple of `resetTimeMin` so the period boundaries don't drift over time. A daily limit reset at 00:00 UTC stays at 00:00 UTC forever, no matter when the bot first runs.

`AutoBridgeModule._rolloverPeriodIfNeeded` uses the exact same pattern for the daily bridge cap. Day boundary is `block.timestamp / 1 days`, lazy reset, no drift, with a `periodStartTotalAssets` snapshot fixing the day's budget.

**Pattern B — Calling the Safe via `execTransactionFromModule`.** For ETH transfers, the Allowance Module does:

```solidity
require(
    safe.execTransactionFromModule(to, amount, "", Enum.Operation.Call),
    "Could not execute ether transfer"
);
```

For ERC-20 transfers, it ABI-encodes the `transfer` selector and calls the same function:

```solidity
bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", to, amount);
safe.execTransactionFromModule(token, 0, data, Enum.Operation.Call);
```

`AutoBridgeModule._execVaultCall` does the equivalent: ABI-encodes a call to `vault.depositToTN(amount)` or `vault.claimFromTN(...)` and routes it through `safe.execTransactionFromModule(address(vault), 0, data, Operation.Call)`. The Safe is the operator on the vault, so when the Safe forwards the call, the vault sees `msg.sender == safe` and the `onlyOperator` check passes.

**Pattern C — Multisig revocation.** The Allowance Module's `removeDelegate` and `deleteAllowance` functions are protected such that they can only be called by the Safe itself — meaning the multisig has to sign a transaction that targets the module's own admin function. We use this for every parameter update on `AutoBridgeModule`. The multisig's emergency exit is even cleaner — call `disableModule` on the Safe directly and the module loses all power immediately.

### 2. Zodiac Module Base — `gnosisguild/zodiac`

**Repo:** [gnosisguild/zodiac/contracts/core/Module.sol](https://github.com/gnosisguild/zodiac/blob/master/contracts/core/Module.sol)
**What it is:** The canonical abstract base contract for Safe modules, maintained by Gnosis Guild. Production protocols (Reality.eth Realitio module, Roles, Delay, Bridge, Tellor Optimistic Oracle) all extend this.

**Pattern A — `avatar` / `target` separation, but we collapse it.** Zodiac separates the `avatar` (the address the module logically belongs to) from the `target` (the address transactions are routed through). For most use cases — including ours — they are the same Safe instance. **We collapse this to a single immutable `safe` reference.** Single reference = one less attack surface, one less storage slot, one less misconfiguration risk. The auditor knows there is no path to point the module at a different Safe after deployment.

**Pattern B — Internal `_exec` helper.** Zodiac's `Module.sol` defines an internal `exec()` helper that wraps the Safe call so consumer functions never have to think about the avatar/target distinction. We use the same pattern internally — every call from `AutoBridgeModule` to the vault goes through `_execVaultCall`, so there is exactly one place in the code that touches the Safe.

**Why we don't extend Zodiac directly:** Zodiac brings in `FactoryFriendly`, `IAvatar`, `Enum`, and an upgradability story we don't need. Inheriting all of that doubles the dependency surface for a 200-line contract. We borrow the pattern, write the wrapper inline, and avoid the extra code path that an auditor would need to verify.

### 3. Lido Easy Track — `lidofinance/easy-track`

**Repo:** [lidofinance/easy-track/contracts/LimitsChecker.sol](https://github.com/lidofinance/easy-track/blob/master/contracts/LimitsChecker.sol)
**What it is:** Lido DAO's framework for letting committees execute routine treasury operations within hardcoded limits, vetoable by token holders. Production contract managing real DAO treasury flow.

**Pattern A — Two distinct roles for limits.** `LimitsChecker` separates `SET_PARAMETERS_ROLE` (held by the DAO, can change limits) from `UPDATE_SPENT_AMOUNT_ROLE` (held by the committee operator, can consume limits). These are strictly disjoint. The committee that consumes the limit cannot raise its own ceiling.

We adopt the same separation. In our module:

- The Safe (held by the multisig) is the only address that can change parameters: `setPerTxBridgeBps`, `setDailyBridgeBps`, `setMinReserveBps`, `setClaimCooldown`, `transferKeeper`.
- The keeper (a hot bot key) is the only address that can consume the limits: `autoBridgeToTN`, `autoClaimFromTN`.

The keeper has zero ability to lift its own caps. To raise a daily cap, the multisig has to sign a Safe transaction targeting the module's admin function — same ceremony as any other governance action.

**Pattern B — Period rollover via timestamp comparison + reset.** `LimitsChecker.updateSpentAmount` performs:

```solidity
if (block.timestamp >= currentPeriodEndTimestampLocal) {
    currentPeriodEndTimestampLocal = _getPeriodEndFromTimestamp(block.timestamp);
    spentAmountLocal = 0;
}
```

This is the same lazy-reset pattern as the Safe Allowance Module, just expressed in seconds instead of minutes and using calendar boundaries (1st of month) via the BokkyPooBah DateTime library. We don't need calendar awareness — UTC day boundaries are fine — so we use the simpler `block.timestamp / 1 days` approach.

**Pattern C — Hardcoded type bounds as ceilings.** `LimitsChecker` enforces `_limit <= type(uint128).max` even though the storage is already `uint128`, just to make the bound explicit. We do the same for our basis-point parameters: every `set*` function checks against a hardcoded constant ceiling that the multisig itself cannot lift. That keeps the module-controlled path inside a reviewed envelope even if governance misconfigures the knobs.

### 4. Yearn TokenizedStrategy — `yearn/tokenized-strategy`

**Repo:** [yearn/tokenized-strategy/src/TokenizedStrategy.sol](https://github.com/yearn/tokenized-strategy/blob/master/src/TokenizedStrategy.sol)
**What it is:** Yearn V3's standard strategy contract. Most production yield-strategy keeper pattern in DeFi today (~$1B TVL across instances).

**What we borrow.** Yearn's `report()` function is the canonical "keeper-callable accounting update" — a privileged function that a bot calls on a schedule to update strategy state, charge fees, and roll positions. It is protected by `nonReentrant` and a keeper modifier, and it does no token movement to arbitrary addresses. The shape is almost identical to our `autoBridgeToTN` and `autoClaimFromTN`: keeper triggers, contract enforces all the logic, no parameters control destination.

**What we don't borrow.** Yearn's `onlyKeepers` modifier is dual-role:

```solidity
require(_sender == S.keeper || _sender == S.management, "!keeper");
```

Either the keeper bot **or** the management EOA can call any keeper function. The reasoning is operational flexibility — if the keeper is down, management can step in.

**We do not adopt this.** Reasons:

1. Our "management" is a Gnosis Safe, not an EOA. If the keeper is down, the multisig can already trigger `depositToTN` / `claimFromTN` directly on the vault — going through the module for it would be strictly worse (more contract surface) without any benefit.
2. Dual-role keeper functions blur the access model. We want the auditor to be able to read the modifier and immediately know exactly one address can call it.
3. The Safe should not routinely interact with the module — it should interact with the module only for parameter updates and disabling. Routine ops are the keeper's job. Conflating the two paths invites mistakes.

So our `onlyKeeper` is strict. The multisig path stays on the vault directly.

### What none of these patterns give us — and what we add

The references above cover delegate-based authorization, periodic rate limits, role separation, and Safe call invocation. They do not cover one concern that is specific to our setup: **the reserve floor.**

The vault keeps a portion of its assets idle on Ethereum to honor instant withdrawals. If the bot bridges too much to TN, the reserve drops below the safe threshold and ordinary depositor withdrawals start failing until the next claim arrives ~24 hours later. None of our reference contracts has a "preserve some idle balance" concept because none of them have an asymmetric off-chain leg.

We add this directly:

```solidity
require(idleAfterBridge >= totalAssets * minReserveBps / 10000, "would breach reserve")
```

The check uses the vault's own `totalAssets()` and `idleBalance()` views, which the auditor has already verified. There is no separate accounting, no separate state, no separate trust assumption — just a multiplication and comparison against the vault's existing public surface.

### Summary table — pattern → source

| Pattern | Source |
|---|---|
| Auto-resetting periodic cap, lazy reset, interval-aligned | Safe Allowance Module |
| `safe.execTransactionFromModule(target, 0, data, Operation.Call)` | Safe Allowance Module |
| Multisig revokes by calling Safe-only admin function on the module | Safe Allowance Module |
| Multisig revokes by calling `disableModule` directly on the Safe | Safe core |
| Internal `_exec` helper wrapping the Safe call | Zodiac Module base |
| Single immutable `safe` reference (not avatar/target split) | Zodiac, simplified |
| Two roles: Safe sets parameters, keeper consumes | Lido LimitsChecker |
| Period rollover via timestamp comparison + reset | Lido LimitsChecker + Safe Allowance |
| Hardcoded ceilings the admin cannot lift | Lido LimitsChecker |
| Strict single-role `onlyKeeper` (no dual-role) | Diverges from Yearn, by design |
| Reserve floor check using vault's public views | Trufonomics-specific, builds on existing vault surface |

The overall design is roughly: **Safe Allowance Module's rate-limit shape + Lido's role separation + Zodiac's exec wrapper + a reserve-floor check unique to vaults with an off-chain leg.** Each piece is borrowed from a contract that has been audited and is currently holding funds in production.

---

## Two things worth flagging during the audit

1. **Are the events the module needs (`BridgedToTN`, `ClaimedFromTN`, plus reads of `deployedOnTN`, `totalAssets`, `idleBalance`) usable as-is for the module's reserve / cap calculations?** The module reads `vault.totalAssets()`, `vault.idleBalance()`, `vault.deployedOnTN()`, and `vault.operator()` — all existing public surface. If you spot anything that would make the module integration cleaner (an additional view function or event field that costs nothing today), please flag it. Cheaper to add now than to wrap later.

2. **The module is in scope for the same audit engagement.** Same code style, same dependency set (only OpenZeppelin's `ReentrancyGuard`), ~350 lines including NatSpec. It lives in `src/automation/` next to a minimal `ISafe.sol` interface (only `execTransactionFromModule` and `isModuleEnabled` — see the file for the rationale).
