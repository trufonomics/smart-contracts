# TrufVault

ERC-4626 vault that bridges deposited assets to [TN](https://truf.network) prediction markets via TrufNetworkBridge.

Restricted vault (Morpho model): funds can **only** go to the bridge or back to depositors. No arbitrary transfers, no DEX approvals, no external protocol calls.

## Architecture

```
User deposits USDC -> vault mints shares (ERC-4626)
Operator bridges to TN -> curator trades prediction markets
Curator PnL updates totalAssets -> share price changes
Performance fee on gains -> minted as shares to feeRecipient
User redeems shares -> receives proportional USDC
```

## Contracts

| Contract | Description | Lines |
|----------|-------------|-------|
| `TrufVault.sol` | ERC-4626 vault with bridge integration, per-share HWM fees, pause, reentrancy guard | ~480 |
| `TrufVaultFactory.sol` | CREATE2 factory + permissionless registry | ~90 |
| `ITrufNetworkBridge.sol` | Interface for TrufNetworkBridge (deposit/withdraw/token) | ~37 |
| `automation/AutoBridgeModule.sol` | Gnosis Safe module — keeper-driven `depositToTN` / `claimFromTN` within hardcoded caps, reserve floor, and cooldowns | ~350 |
| `automation/ISafe.sol` | Minimal Safe interface (`execTransactionFromModule`, `isModuleEnabled`) | ~40 |

## Key Design Decisions

- **DECIMALS_OFFSET** protects against inflation/donation attacks on low-decimal tokens (USDC). From Morpho.
- **Immutable bridge** — cannot be redirected after deployment. Funds can only go to TN or back to depositors.
- **Per-share high-water mark** — performance fees only accrue when share price exceeds all-time high. Deposits/withdrawals don't trigger spurious fees.
- **10% PnL cap** per call — limits damage from compromised operator keys.
- **Two-step operator transfer** — prevents accidental lockout. From OpenZeppelin Ownable2Step.
- **Idle-only withdrawals** — bridge proofs take 15-30 min, so withdrawals draw from vault reserve only.
- **No proxy/upgradeability** — what you see is what you get.

## Test Suite

150 tests (84 vault + 5 factory + 61 module), including 4 fuzz tests. Covers constructor validation, ERC-4626 operations, bridge flows, PnL bounds, operator transfer, performance fees (HWM recovery, retroactive charge prevention, deposit neutrality), skim, pause, full lifecycle scenarios, factory deployment, and the `AutoBridgeModule` (access control, per-tx / daily / reserve / cooldown enforcement, period rollover, mid-period deposit regression, two-step keeper rotation, kill switch, no-escalation).

```shell
forge test
```

## Hoodi Testnet

| Contract | Address |
|----------|---------|
| TrufVault (deployed) | `0x349E34cf714178C1eFe87C2164d58a7184C23F30` |
| TrufNetworkBridge | `0x878D6aaeB6e746033f50B8dC268d54B4631554E7` |
| TT2 Token (test USDC) | `0x263CE78Fef26600e4e428CEBC91C2a52484B4FBF` |

### End-to-End Flow (Verified on Hoodi)

The full vault lifecycle has been tested on-chain against the live TrufNetworkBridge:

1. **Deploy** — `DeployHoodi.s.sol` deploys the vault with TT2 as the asset and the Hoodi bridge
2. **Deposit** — `TestDeposit.s.sol` mints TT2, approves the vault, deposits, and verifies shares received
3. **Bridge to TN** — `TestBridge.s.sol` calls `depositToTN` to send funds through the bridge to the curator wallet on TN
4. **Withdraw** — user redeems shares against idle vault balance, receives TT2 back

Each script logs pre/post state (idle balance, deployedOnTN, totalAssets, share balances) for verification.

## Build

Requires [Foundry](https://book.getfoundry.sh/).

```shell
forge build        # compile
forge test         # run tests
forge test -vvvv   # verbose (see call traces)
```

## Deploy (Hoodi)

```shell
forge script script/DeployHoodi.s.sol --rpc-url $HOODI_RPC --broadcast --private-key $DEPLOYER_KEY
```

## Operator Automation

The vault ships with a Gnosis Safe module — `AutoBridgeModule` — that handles routine bridge operations on behalf of the operator Safe within hardcoded caps. Manual signing on every `depositToTN` / `claimFromTN` does not survive contact with continuous flow once Merkl rewards and LP partnerships are live. The module solves that without changing anything about the vault.

- The operator role on the vault stays a single address — the Safe — forever.
- The module is **installed onto** the Safe via `enableModule`. It is not given the Safe's role.
- The module can call **only** `depositToTN` and `claimFromTN`, within a per-tx cap (≤10%), daily cap (≤30% of the period-start asset base), reserve floor (≥5%), and claim cooldown — all hardcoded ceilings on the module-controlled path.
- The module **cannot** call `pause`, `setFee`, `recordPnL`, `updateCurator`, `transferOperator`, or any other operator function. Those stay manual-multisig-only.
- The module constrains keeper-routed calls only. The Safe, as the vault's operator, can still call vault functions directly through the normal multisig path.
- Activation is **two multisig transactions plus one keeper-address call**. Kill switch is **one multisig transaction** (`disableModule`).

See [docs/automation-module.md](docs/automation-module.md) for the full design, the activation flow, the production references it borrows from, and the two open questions for the audit.

## Documentation

- [docs/about.md](docs/about.md) — line-by-line contract walkthrough
- [docs/automation-module.md](docs/automation-module.md) — `AutoBridgeModule` design, activation flow, pattern lineage
