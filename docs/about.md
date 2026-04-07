# TrufVault Contract Walkthrough

For Vin and Jarryd. Line-by-line breakdown of what the contract does, why each decision was made, and what the repo contains.

**Repo:** https://github.com/trufonomics/smart-contracts

---

## Repo Structure

```
src/
  TrufVault.sol              -- The vault (~480 lines)
  TrufVaultFactory.sol       -- Factory + registry (~90 lines)
  interfaces/
    ITrufNetworkBridge.sol   -- Bridge interface (37 lines)
test/
  TrufVault.t.sol            -- 89 tests (~1460 lines)
  mocks/
    MockBridge.sol           -- Simulates TrufNetworkBridge for testing
    MockERC20.sol            -- Simulates USDC
script/
  DeployHoodi.s.sol          -- Hoodi testnet deployment
  TestBridge.s.sol           -- Bridge interaction script
  TestDeposit.s.sol          -- Deposit flow script
```

Total custom code: ~2,070 lines. Dependencies: OpenZeppelin v5, forge-std.

---

## TrufVault.sol — What It Is

An ERC-4626 vault. Users deposit USDC, receive share tokens (`tvUSDC`). The operator (Gnosis Safe 2-of-3) bridges USDC to TN via TrufNetworkBridge, where a curator bot trades prediction markets. PnL is recorded back to the vault, changing the share price. A performance fee on gains is minted as shares to the fee recipient.

Inherits from four OpenZeppelin contracts:
- **ERC4626** — standard vault interface (deposit/withdraw/mint/redeem + share price math)
- **ERC20Permit** — gasless approvals via off-chain signatures (EIP-2612)
- **Pausable** — emergency stop
- **ReentrancyGuard** — prevents recursive call exploits

---

## Immutables

```solidity
ITrufNetworkBridge public immutable bridge;
uint8 public immutable DECIMALS_OFFSET;
```

`bridge` is set once at deployment, baked into bytecode. Nobody can redirect funds to a different bridge.

`DECIMALS_OFFSET` protects against the inflation/donation attack. For USDC (6 decimals), this is `12`. It adds a `10^12` virtual multiplier to share calculations, making the rounding-based attack economically infeasible. Without this, a first depositor could deposit 1 wei, donate a large amount, and steal from all subsequent depositors via rounding. This is the single most important security feature for low-decimal tokens like USDC. Taken directly from Morpho's MetaMorpho ($5.8B TVL).

---

## State Variables

```solidity
address public operator;          // Who can call privileged functions (Gnosis Safe on mainnet)
address public pendingOperator;   // Two-step transfer: pending new operator
address public curatorTNAddress;  // Where bridged funds land on TN
uint256 public deployedOnTN;     // Accounting: how much is on TN right now
uint256 public fee;              // Performance fee in WAD (1e18 = 100%), max 50%
address public feeRecipient;     // Address receiving performance fee shares
uint256 public highWaterMarkPPS; // Per-share high-water mark for fee calc
address public skimRecipient;    // Receives accidentally sent tokens
```

`deployedOnTN` is bookkeeping only. It tracks what was bridged out so the vault can report accurate `totalAssets`. It has no control over actual funds — the bridge holds the real tokens.

`highWaterMarkPPS` tracks the per-share high-water mark (assets per 1e18 shares). The performance fee only accrues when the share price exceeds this value. Uses the vault's ERC-4626 conversion math (including DECIMALS_OFFSET) so that deposits and withdrawals don't trigger spurious fees. Inspired by Morpho's fee model, upgraded to true per-share watermarking.

---

## Constructor

```solidity
constructor(
    IERC20 asset_,
    ITrufNetworkBridge bridge_,
    address operator_,
    address curatorTNAddress_,
    string memory name_,
    string memory symbol_
)
```

Name and symbol are parameters (not hardcoded) so the factory can deploy vaults with different names — `tvUSDC`, `tvDAI`, etc.

The constructor does two important things beyond setting state:

1. **Calculates DECIMALS_OFFSET**: `18 - assetDecimals`. For USDC = 12. For DAI = 0.
2. **Grants max approval to bridge**: `IERC20(asset_).forceApprove(address(bridge_), type(uint256).max)`. This is safe because the bridge address is immutable. Saves ~20K gas per bridge operation vs approving each time. Standard pattern (Morpho, Yearn, Aave all do this).

---

## Total Assets

```solidity
function totalAssets() public view override returns (uint256) {
    return IERC20(asset()).balanceOf(address(this)) + deployedOnTN;
}
```

`idle USDC in vault + what's on TN = total`. This drives the share price. When `deployedOnTN` increases (positive PnL), share price goes up. When it decreases (loss), share price goes down.

---

## User Functions (ERC-4626)

Four standard operations. All paused when vault is paused. All have reentrancy guards. All accrue performance fees before executing.

**deposit / mint** — User sends USDC, vault mints share tokens. Fee accrual happens automatically. First deposit initializes the per-share high-water mark.

**withdraw / redeem** — User burns shares, receives USDC. One constraint:

```solidity
uint256 idle = IERC20(asset()).balanceOf(address(this));
if (assets > idle) revert InsufficientIdle(assets, idle);
```

Withdrawals can only use idle USDC sitting in the vault. If 80% is bridged to TN, users can only withdraw from the 20% reserve. To serve larger withdrawals, the operator must claim funds back from TN first.

**Why:** The vault can't pull from TN on demand — bridge withdrawals require validator proofs and take 15-30 minutes. Blocking the user transaction until that completes isn't viable.

### maxWithdraw / maxRedeem

```solidity
function maxWithdraw(address owner_) public view override returns (uint256) {
    uint256 ownerAssets = _convertToAssets(balanceOf(owner_), Math.Rounding.Floor);
    uint256 idle = IERC20(asset()).balanceOf(address(this));
    return ownerAssets < idle ? ownerAssets : idle;
}
```

Returns the lesser of what the user owns and what's actually available. This is critical for composability — integrators like Pendle, Aave, and Merkl call `maxWithdraw` to know how much a user can actually pull. If this returns more than the idle balance, those integrations break.

---

## Operator Functions

Three functions. All gated by `onlyOperator`. All have reentrancy guards.

### depositToTN

```solidity
function depositToTN(uint256 amount) external onlyOperator nonReentrant {
    if (amount == 0) revert ZeroAmount();
    uint256 idle = IERC20(asset()).balanceOf(address(this));
    if (amount > idle) revert InsufficientIdle(amount, idle);

    deployedOnTN += amount;
    bridge.deposit(amount, curatorTNAddress);
    emit BridgedToTN(amount, curatorTNAddress);
}
```

Sends idle USDC to the bridge. Bridge already has max approval from constructor, so no per-call approve needed. Funds can only go to the bridge, which sends them to `curatorTNAddress`. No other destination exists in the code.

### claimFromTN

```solidity
function claimFromTN(
    uint256 amount,
    bytes32 kwilBlockHash,
    bytes32 root,
    bytes32[] calldata proof,
    ITrufNetworkBridge.Signature[] calldata signatures
) external onlyOperator nonReentrant {
    if (amount == 0) revert ZeroAmount();
    if (amount > deployedOnTN) revert InsufficientDeployed(amount, deployedOnTN);

    deployedOnTN -= amount;
    bridge.withdraw(address(this), amount, kwilBlockHash, root, proof, signatures);
    emit ClaimedFromTN(amount);
}
```

Calls the bridge's `withdraw` with a validator-signed proof. The bridge verifies the proof and releases USDC to the vault (`address(this)` — not to any external address).

The proof parameters come from TN validators after an epoch finalizes. The bridge contract validates them — our vault passes them through.

**Key point:** `claimFromTN` always sends funds back to the vault itself. There is no parameter to redirect to another address. Even a compromised operator can only bring money home.

### recordPnL

```solidity
function recordPnL(int256 pnlDelta) external onlyOperator {
    // Enforce max PnL delta as % of deployedOnTN
    if (deployedOnTN > 0) {
        uint256 absDelta = pnlDelta >= 0 ? uint256(pnlDelta) : uint256(-pnlDelta);
        uint256 deltaBps = (absDelta * 10000) / deployedOnTN;
        if (deltaBps > MAX_PNL_DELTA_BPS) {
            revert PnLDeltaExceedsMax(deltaBps, MAX_PNL_DELTA_BPS);
        }
    } else {
        if (pnlDelta != 0) revert PnLDeltaExceedsMax(type(uint256).max, MAX_PNL_DELTA_BPS);
    }
    // ... adjust deployedOnTN, accrue fees if share price > HWM
}
```

`MAX_PNL_DELTA_BPS = 1000` (10%). No single call can move the deployed balance by more than 10%. This caps the damage if operator keys are compromised — an attacker would need 10+ calls to inflate or deflate significantly, giving time to detect and pause.

After adjusting `deployedOnTN`, the function accrues any performance fee if the share price exceeds the high-water mark.

**Trust assumption:** There is no on-chain oracle verifying TN PnL. The operator reports it. Our off-chain indexer cross-checks against actual TN state, but that check isn't enforced in the contract. This is the same trust model as every Morpho curator — the curator reports performance, depositors trust or exit.

---

## Performance Fee

```solidity
uint256 public constant MAX_FEE = 0.5e18; // 50% max
uint256 public fee;                         // current fee rate
address public feeRecipient;                // who receives fee shares
uint256 public highWaterMarkPPS;            // per-share high-water mark
```

Fee is charged on gains only (not losses). The mechanism:

1. `highWaterMarkPPS` records the per-share price (assets per 1e18 shares) after each fee event
2. When the vault's share price exceeds `highWaterMarkPPS`, the difference is per-share "interest"
3. Total excess = per-share excess × total supply. Fee = total excess × fee rate
4. Fee is paid by **minting new shares** to `feeRecipient` — dilutive model
5. After minting, HWM is set to the POST-fee share price (diluted)

The per-share model ensures deposits and withdrawals never trigger spurious fees — only real PnL performance counts. The dilutive model (from Morpho) means no USDC is moved. The fee recipient just gets shares proportional to their cut of the gains. When they redeem, they get USDC.

**Why 50% max?** Same as Morpho. Higher than most protocols (Yearn = 20%, Aave = none). Gives flexibility for the curator entity to set competitive rates and split with liquidity partners.

Safeguards:
- `setFee` requires `feeRecipient != address(0)` (can't charge fees to nowhere)
- `setFeeRecipient(address(0))` requires `fee == 0` (can't orphan active fees)
- Setting either accrues outstanding fees with the old values first
- Activating fees (from 0 → non-zero) resets HWM to current share price, preventing retroactive charging on pre-fee gains
- Re-enabling fee recipient with active fee also resets HWM for the same reason

---

## Two-Step Operator Transfer

```solidity
function transferOperator(address newOperator) external onlyOperator {
    if (newOperator == address(0)) revert ZeroAddress();
    pendingOperator = newOperator;
    emit OperatorTransferStarted(operator, newOperator);
}

function acceptOperator() external {
    if (msg.sender != pendingOperator) revert OnlyPendingOperator();
    address previous = operator;
    operator = pendingOperator;
    pendingOperator = address(0);
    emit OperatorTransferred(previous, operator);
}
```

Modeled on OpenZeppelin's `Ownable2Step`. The current operator proposes, the new operator must actively accept. This prevents:
- Fat-finger to a wrong address (that address would need to call `acceptOperator`)
- Accidental lockout (operator is still active until accepted)
- Frontrunning attacks on operator changes

The current operator can overwrite `pendingOperator` at any time (change their mind).

---

## Skim (Token Recovery)

```solidity
function skim(address token_) external {
    if (skimRecipient == address(0)) revert NoSkimRecipient();
    // ... recovers accidentally sent tokens
}
```

If someone sends the wrong ERC-20 to the vault, `skim` sends it to a designated recipient. Anyone can call it (tokens go to the recipient, not the caller). For the vault's own asset (USDC), donated tokens increase `totalAssets` and benefit depositors — they can't be skimmed (by design).

---

## Admin Functions

```solidity
function updateCurator(address newCurator) external onlyOperator
function setFee(uint256 newFee) external onlyOperator
function setFeeRecipient(address newFeeRecipient) external onlyOperator
function setSkimRecipient(address newSkimRecipient) external onlyOperator
function pause() external onlyOperator
function unpause() external onlyOperator
```

`pause/unpause` — emergency stop. Blocks all deposits and withdrawals. Does NOT block `claimFromTN` or `depositToTN` — you want to be able to manage TN positions during an emergency.

---

## What the Contract Cannot Do

No function exists to:
- Send tokens to an arbitrary address
- Approve an arbitrary spender
- Change the bridge address (immutable)
- Upgrade the contract code (no proxy)
- Self-destruct
- Report PnL greater than 10% of deployed in a single call

The only way tokens leave the vault is through the bridge (`depositToTN`) or back to a depositor (`withdraw`/`redeem`). This is enforced at the code level. There is no admin override, no escape hatch, no backdoor.

---

## ITrufNetworkBridge.sol — The Interface

```solidity
function deposit(uint256 amount, address recipient) external;
function withdraw(
    address recipient,
    uint256 amount,
    bytes32 kwilBlockHash,
    bytes32 root,
    bytes32[] calldata proof,
    Signature[] calldata signatures
) external;
function token() external view returns (address);
```

This is the interface our vault codes against. The actual bridge contract is TN's — deployed at `0x878D6aaeB6e746033f50B8dC268d54B4631554E7` on Hoodi.

`Signature` struct: `{ bytes32 r, bytes32 s, uint8 v }` — standard ECDSA components from TN validators.

---

## TrufVaultFactory.sol — Vault Deployment

```solidity
function createVault(
    IERC20 asset,
    ITrufNetworkBridge bridge,
    address operator_,
    address curatorTNAddress,
    string memory name,
    string memory symbol,
    bytes32 salt
) external returns (address vault)
```

Deploys a new TrufVault using CREATE2 (deterministic address from salt). Maintains two things:
- `isVault[address]` mapping — on-chain registry for integrators to verify
- `vaults[]` array — enumerable list of all deployed vaults

Each vault is an independent, immutable contract. The factory doesn't control them after deployment — it's purely a deployment tool and registry. Modeled on Morpho's MetaMorphoFactory.

**Why a factory?** One audit covers the template. Deploy unlimited vaults for different assets or strategies. The registry lets indexers, UIs, and partner protocols discover all factory-deployed vaults without manual tracking. Note: the registry is permissionless — `isVault` means "deployed by this factory", not curated or endorsed.

---

## Test Suite — What's Covered

89 tests across 17 categories. All passing.

| Category | Tests | What's Verified |
|----------|-------|----------------|
| Constructor | 8 | State init, decimals offset for USDC and DAI, max bridge approval, zero-address rejection, bridge-asset mismatch revert |
| Inflation attack | 2 | Donation attack fails with offset, first deposit math correct |
| Deposit | 4 | Share minting, multi-user, paused, HWM initialization |
| Withdraw | 3 | Asset return, insufficient idle revert, paused |
| Redeem | 2 | Asset return, insufficient idle revert |
| Mint | 2 | Asset deduction, paused |
| maxWithdraw/maxRedeem | 5 | Capped to idle, capped to owner balance, zero for non-holder |
| depositToTN | 5 | Bridge receives, access control, zero/overflow, multiple bridges |
| claimFromTN | 4 | Funds return, access control, zero/overflow |
| recordPnL + bounds | 8 | Gain, loss, exceeds 10% cap (both directions), exactly at max, zero deployed, zero delta, share price change |
| Two-step operator | 6 | Full flow, old operator acts before accept, wrong caller, no pending, overwrite pending, zero address |
| Performance fee | 12 | Set fee, exceeds max, no recipient, accrues on gain, no accrual on loss, no accrual when zero, HWM-based recovery tests, deposit doesn't trigger fee, no retroactive charge on fee activation, no retroactive charge on recipient activation |
| Skim | 5 | Wrong token, no recipient, accounted untouched, donation benefits depositors, anyone can call |
| Admin | 5 | Curator update, pause/unpause, access control |
| Full lifecycle | 2 | Profit scenario with fees (two users, proportional payouts), loss scenario (two users, proportional losses) |
| ERC20Permit | 1 | Domain separator exists and functional |
| Fuzz | 4 | Random deposit/redeem roundtrip, random bridge %, maxWithdraw never exceeds idle invariant, PnL within bounds |
| Factory | 5 | Create vault, multiple vaults, deterministic addresses, zero asset revert, deployed vault is functional |

**Key tests to read:**

- `test_decimalsOffset_preventsInflationAttack` — proves the classic donation attack fails
- `test_fullLifecycle` — end-to-end: deposit → bridge → PnL → fee accrual → claim → redeem (two users)
- `testFuzz_maxWithdraw_neverExceedsIdle` — invariant: no fuzz input can make maxWithdraw return more than idle

---

## Deployment Scripts

**DeployHoodi.s.sol** — deploys to Hoodi testnet. Sets the deployer as operator (for testing convenience). On mainnet, the operator would be the Gnosis Safe address.

---

## Hoodi Testnet Addresses

| Contract | Address |
|----------|---------|
| TrufNetworkBridge | `0x878D6aaeB6e746033f50B8dC268d54B4631554E7` |
| TT2 Token (test USDC) | `0x263CE78Fef26600e4e428CEBC91C2a52484B4FBF` |

---

## Design Decisions Summary

| Decision | Rationale |
|----------|-----------|
| ERC-4626 | Industry standard. Composable with Pendle, Aave, Merkl out of the box. |
| Immutable bridge | Cannot be redirected. Funds can only go to TN or back to depositors. |
| DECIMALS_OFFSET | Prevents inflation attack on low-decimal tokens (USDC). From Morpho. |
| Two-step operator | Prevents accidental lockout. From OpenZeppelin Ownable2Step. |
| 10% PnL cap | Limits damage from compromised keys. Multiple calls needed = detection time. |
| Dilutive performance fee | No USDC movement. Fee paid as shares. Clean for on-chain accounting. From Morpho. |
| forceApprove in constructor | Bridge is immutable. One-time max approval saves gas on every bridge op. |
| ERC20Permit | Gasless approvals. Expected by modern DeFi integrations. |
| Idle-only withdrawals | Bridge proofs take 15-30 min. Can't block user tx. Operator manages reserve. |
| Factory + registry | One audit, unlimited vaults. On-chain `isVault` for integrator verification. |
| No proxy/upgradeability | What you see is what you get. No governance risk. No upgrade attack surface. |

---

## Operator Automation

The vault ships with a **Gnosis Safe module** — `AutoBridgeModule` — alongside the vault itself. The module is installed onto the operator Safe at launch and handles routine bridge operations on the Safe's behalf within hardcoded caps, reserve floors, and cooldowns. Manual signing on every `depositToTN` / `claimFromTN` does not survive contact with continuous deposit/withdraw flow once Merkl rewards and LP partnerships are live.

**The vault contracts do not change for this.** The operator role on the vault stays a single address — the Safe — forever. The module is *installed onto* the Safe via `enableModule`; it is not given the Safe's role. The Safe still holds every other power (`pause`, `setFee`, `recordPnL`, `updateCurator`, `transferOperator`) and can revoke the module instantly with one transaction.

Key constraints, all enforced in the module's bytecode and bounded by hardcoded ceilings the multisig itself cannot lift:

- Per-tx bridge cap ≤ 10% of total assets (constant `MAX_PER_TX_BRIDGE_BPS`)
- Daily bridge cap ≤ 30% of the period-start asset base (constant `MAX_DAILY_BRIDGE_BPS`), lazy-reset on UTC day boundary
- Reserve floor ≥ 5% of total assets, ≤ 50% (constants `MIN_ALLOWED_RESERVE_BPS` / `MAX_ALLOWED_RESERVE_BPS`)
- Claim cooldown ≥ 5 minutes, ≤ 1 day (constants `MIN_CLAIM_COOLDOWN` / `MAX_CLAIM_COOLDOWN`)
- Strict single-role keeper (one address, typically an EOA, with two-step rotation matching the vault's `transferOperator` pattern)
- Module exposes **only** `autoBridgeToTN` and `autoClaimFromTN`. No code path to `pause`, `setFee`, `recordPnL`, `updateCurator`, `transferOperator`, or any other operator function.

These caps constrain the module-routed keeper path only; the Safe still retains its normal direct operator path. Activation is two multisig transactions plus one keeper-address call. Kill switch is one multisig transaction (`disableModule` on the Safe). See [automation-module.md](automation-module.md) for the full design, the activation flow, the pattern lineage from Safe Allowance Module / Zodiac / Lido LimitsChecker / Yearn TokenizedStrategy, and the two open questions for the audit.
