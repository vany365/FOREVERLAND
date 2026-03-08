# FOREVERLAND
**Neverland DUST forever**

Foreverland is a Liquid Locker protocol for [Neverland Finance](https://neverland.money) on Monad. Users deposit veDUST NFTs or raw DUST and receive `yDUST` — a fully liquid, transferable ERC-20 that earns weekly USDC revenue from Neverland's protocol fees.

---

## How It Works

1. **Deposit** a veDUST NFT or raw DUST → receive `yDUST` (1:1 with DUST locked)
2. **Stake** `yDUST` in the Staker → earn weekly USDC rewards (7-day ramp to full weight)
3. **Or deposit** `yDUST` in the Vault → auto-compound; share price grows over time

Foreverland pools all deposited DUST into permanent-lock veDUST NFT "buckets" (capped at 1,000,000 DUST each), maximizing governance power and revenue share in Neverland. Buckets enable surgical DAO-controlled withdrawals in the future.

---

## Contracts

| Contract | Description |
|---|---|
| `yDUST.sol` | Liquid ERC-20 receipt token. 1 yDUST = 1 DUST permanently locked. |
| `ForeverlandLocker.sol` | Core engine. Manages bucket NFTs, accepts deposits, runs harvest. |
| `ForeverlandStaker.sol` | Stake yDUST to earn USDC. 7-day ramp-up prevents reward sniping. |
| `ForeverlandVault.sol` | ERC-4626 auto-compounding vault. Issues `fvyDUST` shares. |
| `ForeverlandResolver.sol` | Gelato on-chain resolver for automated harvest + compound. |

---

## Architecture

```
User
 ├── deposit veDUST NFT ──► ForeverlandLocker ──► mints yDUST 1:1
 ├── deposit DUST ─────────►      │
 │                                │ (bucket NFTs: each ≤ 1M DUST)
 │                         Neverland DustLock (0xbb4738...)
 │
 ├── stake yDUST ──────────► ForeverlandStaker ──► earn USDC weekly
 │                                ▲
 │                         harvest() (Gelato, weekly)
 │                         ForeverlandLocker claims from RevenueReward
 │
 └── deposit yDUST ────────► ForeverlandVault (ERC-4626)
                                  │  compound() (Gelato, weekly)
                                  │  USDC → DUST (best of: Kuru / Uniswap V3 / OpenSea NFT)
                                  └► yDUST re-deposited → share price grows
                                     issues fvyDUST shares
```

---

## Bucket System

- DUST is held in multiple veDUST NFTs ("buckets"), each capped at **1,000,000 DUST**
- All buckets are **permanent (infinite) locks** — voting power never decays
- NFT deposits that exceed the cap get their own dedicated bucket
- DUST deposits fill buckets sequentially, overflowing into new ones as needed
- Future DAO governance can vote to retire individual buckets without touching others

---

## Reward Mechanics

- **7-day ramp**: New stakers earn at **0.5x weight** for their first epoch, then **1x permanently**
- **Sniper protection**: Depositing right before harvest only yields half the proportional share
- **Vault whitelist**: The auto-compound vault earns immediate 1x weight
- **Performance fee**: 10% of all USDC harvested goes to the treasury multisig

---

## Automation (Gelato)

Two Gelato Web3 Function tasks run automatically:

| Task | Trigger | Action |
|---|---|---|
| Harvest | Weekly, after Neverland epoch advances | `locker.harvest()` |
| Compound | When vault USDC pending ≥ threshold | Best of: Kuru swap / Uniswap V3 / OpenSea NFT buy |

The compound route selection compares DUST received per USDC across all three options and executes the best one with slippage protection.

---

## Development

### Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Setup
```bash
git clone https://github.com/vany365/FOREVERLAND
cd FOREVERLAND
forge install
cp .env.example .env
# Fill in .env values
```

### Build
```bash
forge build
```

### Test
```bash
forge test -vvv
```

### Deploy
```bash
forge script script/Deploy.s.sol:DeployForeverland \
  --rpc-url monad \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify
```

---

## Post-Deploy Multisig Checklist

After deployment, the following must be executed by the multisig:

- [ ] `yDUST.setLocker(lockerAddress)`
- [ ] `locker.setStaker(stakerAddress)`
- [ ] `locker.setVault(vaultAddress)`
- [ ] `locker.setKeeper(gelatoProxyAddress)`
- [ ] `vault.setKeeper(gelatoProxyAddress)`
- [ ] `staker.setWhitelisted(vaultAddress, true)`
- [ ] Register Gelato tasks pointing at `ForeverlandResolver`
- [ ] Fund Gelato balance with MON
- [ ] Seed first deposit to bootstrap the first bucket NFT
- [ ] Verify all contracts on Monadscan

---

## Ongoing Multisig Responsibilities

- Top up Gelato MON balance monthly
- Monitor for discounted veDUST NFTs on OpenSea when Gelato's auto-selection is borderline
- Emergency pause if exploit is detected
- Update DEX router addresses if better liquidity sources emerge
- Review and execute contract upgrades if bugs are found

---

## License

MIT
