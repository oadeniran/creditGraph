<div align="center">

# CreditGraph

**The onchain credit identity layer for 1.4 billion people that traditional credit bureaus have never heard of.**

[Live app](https://creditgraph-fe-9a4ee699162b.herokuapp.com/) · [Backend](https://github.com/oadeniran/CreditGraph-BackEnd) · [Frontend](https://github.com/oadeniran/CreditGraph-FrontEnd)

</div>

---

## The problem

1.4 billion adults globally have no credit score. In Sub-Saharan Africa alone, more than 70% of adults lack a formal credit history despite having active financial lives — mobile money flows, market trade, rotating savings groups. Traditional credit bureaus (Equifax, TransUnion, CreditRegistry, CRC) can't see this activity.

DeFi hasn't solved this either. Existing onchain lending requires 150%+ collateral, which is meaningless for someone who needs credit precisely because they lack collateral. The recently announced 3jane protocol underwrites against Equifax and TransUnion scores via Plaid — useful for US cryptonatives, but structurally inaccessible to the global unbanked.

## What CreditGraph builds

CreditGraph is a **permissionless, portable, soulbound credit identity** for emerging-market borrowers, powered by three layers:

1. **An onchain credit identity** issued as a non-transferable ERC-5192 token.
2. **An AI agent network** that aggregates alternative data signals (mobile money patterns, onchain activity, social attestations) into a verifiable credit score, with privacy preserved via zero-knowledge proofs.
3. **An undercollateralized lending market** that issues USDC micro-loans against that score, with rates dynamically priced to the borrower's risk tier.

## What makes it novel

| | What it means | Why no one else has it |
|---|---|---|
| **Social attestation graph** | Members of verifiable savings groups (Ajo, Esusu, Chama) attest to each other's credit behavior. Attestation weight scales with the attester's own tier. Defaults slash attesters. | Western credit systems have no analog. No onchain protocol encodes the social graph as a credit signal. |
| **ZK-verified alternative data** | Mobile money inflow regularity, airtime top-up patterns, and merchant diversity are proven via ZK without revealing raw transactions. | 3jane requires raw Plaid + Credit Karma access. The data sources they use don't exist in emerging markets. |
| **Portable soulbound score** | Score is infrastructure, not a product. Any protocol on Arbitrum or Robinhood Chain can read it and underwrite against it. | 3jane's score is closed and used only by 3jane. CreditGraph is a public good — credit infrastructure other DeFi protocols build on. |

## Repository layout

This monorepo contains the smart contracts. The application code lives in separate repositories:

| Component | Repo | Deployment |
|---|---|---|
| **Smart contracts** | this repo | Arbitrum Sepolia |
| **Backend (FastAPI + agents + indexer)** | [<TODO>](<TODO>) | [<TODO>](<TODO>) |
| **Frontend (Next.js)** | [<TODO>](<TODO>) | [<TODO>](<TODO>) |

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                     USER / BORROWER LAYER                    │
│           Mobile app · WhatsApp bot · Web frontend           │
└──────────────────────────────┬───────────────────────────────┘
                               │
┌──────────────────────────────▼───────────────────────────────┐
│                     AGENT NETWORK LAYER                      │
│   Data collector → Underwriting quorum → Recovery agent      │
│              x402 micropayments between agents               │
└──────────────────────────────┬───────────────────────────────┘
                               │
┌──────────────────────────────▼───────────────────────────────┐
│                    SMART CONTRACT LAYER                      │
│                                                              │
│    Identity ── Score ── Attestation ── ZK Verifier           │
│         │        │           │              │                │
│         └────────┴───────────┴──────────────┘                │
│                        │                                     │
│                Credit Limit Engine                           │
│                        │                                     │
│         Lending Pool ── Loan Manager ── Slasher              │
│                        │                                     │
│              Treasury · Insurance Fund                       │
└──────────────────────────────────────────────────────────────┘
                        │
        LayerZero/CCIP bridge to Robinhood Chain
        for institutional read-only score access
```

## Deployed contracts (Arbitrum Sepolia)

| Contract | Address |
|---|---|
| USDC (mock) | `0x539dB5ce86e19C06dE61E158Cf7Fe721436B59A1` |
| AccessController | `0x8B22193E104Da3A651A560E34573e77D5Da4192C` |
| CreditIdentity | `0x2e71F48f3ddd4F52a094F189644b8f03Fb26B9A5` |
| ScoreRegistry | `0x7cb5Fa19CF618efD9593Cd3cca8fD74e889e0325` |
| ScoringOracle | `0x27646d51736DA24FFC25ba3397E83B5d34F5D487` |
| ZKAttestationVerifier | `0xF059d67EA5Df0E050252dd7652E1A9B9C8aD2C1E` |
| DataOracleAdapter | `0xc585585A0EF9DEEA7320896CDb18a3221DFb3489` |
| AgentRegistry | `0x0e469D811BC2fC224ebF68A617e8F1Ca1298322C` |
| X402PaymentRouter | `0x6baD2dd649c97B54b78076E698164A2eDE3e9b7c` |
| RepaymentGraduation | `0xFb17643868D400f6E9e1982cEc24e800F3053965` |
| SocialAttestation | `0x335Db8BdEd69974495f8ce01dCD0959bca4b14E5` |
| InterestRateModel | `0x2Bb87fc28578C258e0C50d49B4ABB9589E93a68D` |
| CreditLimitEngine | `0x680488Fdb8A0c692E35e810c58b16d80D1FCE303` |
| LendingPool | `0x99e27AE174681a7eb1A1beb02E95E233D36fa948` |
| LoanManager | `0x523db7621633B0AB68c74F537f0186c51aa5Cf6A` |
| InsuranceFund | `0x56149E26aD1E4CADC2994833770A687838B3F0A6` |
| CreditSlasher | `0x6eF952e65E6b3aaE522b19DDABC3bFa902d0C8E1` |
| Treasury | `0xcE5624887cdb378c64e23b64E5Fb5B1f9159F985` |

Chain ID: `421614` · RPC: `https://sepolia-rollup.arbitrum.io/rpc` · [Explorer](https://sepolia.arbiscan.io)

## Contract layer highlights

**Identity & Score**
- `CreditIdentity` — ERC-5192 soulbound NFT, one per wallet, admin-minted at onboarding
- `ScoreRegistry` — Canonical score store (300–1000, tier 1–5), read freely by any protocol
- `ScoringOracle` — Bridge between off-chain agent quorum and on-chain score, EIP-712 typed-data signatures, configurable challenge window

**Lending**
- `LendingPool` — ERC-4626 USDC vault, suppliers receive yield-bearing cgUSDC shares
- `LoanManager` — Origination, simple linear interest accrual, repayment routing, default cascade
- `CreditLimitEngine` — Pure-function credit limit = tier base + capped attestation bonus − active exposure
- `InterestRateModel` — Aave-style kinked curve per tier, riskier tiers pay more
- `RepaymentGraduation` — On-time streak → tier promotion. Default → tier demotion with a floor that clears as the streak rebuilds

**Risk**
- `CreditSlasher` — Executes default consequences: score reduction, pro-rata attester bond slashing, insurance fund coverage
- `InsuranceFund` — First-loss reserve. Absorbs default losses before suppliers take a hit

**Social attestation** (the novel piece)
- `SocialAttestation` — On-chain Ajo/Esusu/Chama vouching. Attester's tier multiplies bond weight. Weight decays linearly (100% → 50%) over the attestation term. Two-step revoke with cooldown prevents last-minute exits before a default.

**Agents & payments**
- `AgentRegistry` — USDC-staked whitelisting for the 4 agent roles (data collector, underwriter, pool manager, recovery)
- `X402PaymentRouter` — Unidirectional payment channels for agent-to-agent micropayments. Cumulative vouchers signed off-chain, one on-chain tx claims everything

**Governance & cross-chain**
- `AccessController` — Central role registry + global pause
- `Treasury` — Routes protocol fees by configurable BPS splits (default 50% insurance / 30% ops / 20% agent rewards)
- `RobinhoodScoreMirror` — Read-only score mirror on Robinhood Chain for institutional lenders

## Local development

```bash
# Install
forge install

# Build
forge build

# Test
forge test

# Deploy (edit script/Deploy.s.sol with your config first)
forge script script/Deploy.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC --broadcast
```