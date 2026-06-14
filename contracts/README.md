# CreditGraph — Smart Contracts

The on-chain credit-identity and undercollateralized lending protocol for the
global unbanked. This folder contains the full Solidity contract suite, deploy
scripts, and configuration.

All contracts target **Solidity 0.8.24** and were compile-verified against
**OpenZeppelin Contracts v5.0.2**.

---

## Layout

```
contracts/
├── src/
│   ├── interfaces/          # Cross-contract interfaces (no circular imports)
│   ├── libraries/           # DataTypes (structs/enums), Roles (role ids)
│   ├── governance/          # AccessController, ProtocolBase, Treasury
│   ├── identity/            # CreditIdentity (ERC-5192), ScoreRegistry
│   ├── scoring/             # ScoringOracle (EIP-712 quorum)
│   ├── verification/        # ZKAttestationVerifier, DataOracleAdapter
│   ├── lending/             # LendingPool (ERC-4626), LoanManager,
│   │                        #   CreditLimitEngine, InterestRateModel,
│   │                        #   RepaymentGraduation
│   ├── risk/                # InsuranceFund, CreditSlasher
│   ├── social/              # SocialAttestation  ← the novel primitive
│   ├── agents/              # AgentRegistry, X402PaymentRouter
│   ├── crosschain/          # RobinhoodScoreMirror
│   └── mocks/               # MockUSDC (testnet/demo only)
├── script/
│   ├── Deploy.s.sol             # Full protocol -> Arbitrum
│   └── DeployRobinhoodMirror.s.sol  # Mirror -> Robinhood Chain
├── foundry.toml
└── remappings.txt
```

---

## Contract map (18 protocol contracts)

| Contract | Layer | Responsibility |
|---|---|---|
| `AccessController` | governance | Central role registry + global pause |
| `ProtocolBase` | governance | Mixin: role checks + pause, wired to AccessController |
| `Treasury` | governance | Fee router (insurance / ops / agent-rewards splits) |
| `CreditIdentity` | identity | Soulbound ERC-5192 identity, one per wallet |
| `ScoreRegistry` | identity | Canonical score store, public read |
| `ScoringOracle` | scoring | EIP-712 quorum of agent sigs → challenge → finalize |
| `ZKAttestationVerifier` | verification | Per-claim Groth16 verifier registry + nullifiers |
| `DataOracleAdapter` | verification | Push oracle for FX / external feeds |
| `LendingPool` | lending | ERC-4626 USDC vault (cgUSDC shares) |
| `LoanManager` | lending | Loan lifecycle: originate / repay / late / default |
| `CreditLimitEngine` | lending | Limit = tier base + capped attestation bonus |
| `InterestRateModel` | lending | Aave-style kinked, tier-priced APR |
| `RepaymentGraduation` | lending | On-time streak → tier promotion/demotion |
| `InsuranceFund` | risk | First-loss reserve; covers pool on default |
| `CreditSlasher` | risk | Default executor: score cut + slash + cover |
| `SocialAttestation` | social | Bonded Ajo/Esusu vouches, decay, slashing |
| `AgentRegistry` | agents | Agent staking, roles, slashing, reputation |
| `X402PaymentRouter` | agents | Agent-to-agent payment channels + receipts |
| `RobinhoodScoreMirror` | crosschain | Read-only score mirror on Robinhood Chain |

---

## Build with Foundry

This repo was scaffolded outside Foundry (compile-verified with solc + the npm
OpenZeppelin package). To wire it into Foundry:

```bash
# from contracts/
forge init --force --no-commit .          # if you don't already have a forge project
forge install foundry-rs/forge-std --no-commit
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-commit
forge build
```

The `foundry.toml` remappings expect OZ at `lib/openzeppelin-contracts`. If you
prefer the npm layout, change the remapping (see the note at the bottom of
`foundry.toml`).

---

## Deploy

### Arbitrum (Sepolia or One)

```bash
export PRIVATE_KEY=0x...
export ARB_SEPOLIA_RPC=https://sepolia-rollup.arbitrum.io/rpc
# optional: export USDC=0x...        # real USDC; omit to deploy MockUSDC
# optional: export OPERATIONS=0x...  # ops multisig (defaults to deployer)
# optional: export AGENT_REWARDS=0x...

forge script script/Deploy.s.sol:DeployCreditGraph \
  --rpc-url $ARB_SEPOLIA_RPC --broadcast
```

`Deploy.s.sol` deploys all contracts in dependency order, performs every
post-deploy setter, and grants every required role (see checklist below).

### Robinhood Chain (mirror)

```bash
export PRIVATE_KEY=0x...
export ROBINHOOD_RPC=...                 # via Alchemy Robinhood Chain Testnet
export BRIDGE_ENDPOINT=0x...             # LayerZero/CCIP receiver (defaults to deployer)
export SOURCE_CHAIN_ID=42161             # Arbitrum One

forge script script/DeployRobinhoodMirror.s.sol:DeployRobinhoodMirror \
  --rpc-url $ROBINHOOD_RPC --broadcast
```

---

## Wiring checklist (handled by Deploy.s.sol)

**Post-deploy setters** (break the circular dependencies):

- `CreditLimitEngine.setLoanManager(loanManager)`
- `LoanManager.setSlasher(slasher)`
- `CreditSlasher.setLoanManager(loanManager)`
- `SocialAttestation.setInsuranceFund(insuranceFund)`
- `InsuranceFund.setCoverageRecipient(pool)`

**Role grants:**

- `ScoringOracle`     → `SCORE_UPDATER_ROLE`
- `CreditSlasher`     → `SLASHER_ROLE`, `INSURANCE_SPENDER_ROLE`
- `LoanManager`       → `POOL_MANAGER_ROLE`   (covers pool + graduation calls)
- onboarding backend  → `MINTER_ROLE`
- bridge endpoint     → `BRIDGE_ROLE`         (Robinhood mirror only)

`SCORE_UPDATER_ROLE` and `SLASHER_ROLE` are both accepted by
`ScoreRegistry.updateScore` (the oracle writes new scores; the slasher writes
reduced scores on default).

---

## End-to-end flows the contracts implement

1. **Onboard** — `CreditIdentity.mint` → agents push ZK claims to
   `ZKAttestationVerifier.recordClaim` → underwriter quorum calls
   `ScoringOracle.submitScore` → after challenge window,
   `ScoringOracle.finalizeScore` writes to `ScoreRegistry`.
2. **Borrow** — `LoanManager.originate` checks identity ownership, fresh score,
   and headroom from `CreditLimitEngine`, prices via `InterestRateModel`, then
   `LendingPool.borrowFor` sends USDC to the borrower.
3. **Repay & graduate** — `LoanManager.repay` (interest-first), and on full
   repayment calls `RepaymentGraduation.recordRepayment(onTime)` which can
   promote a tier.
4. **Vouch** — `SocialAttestation.attest` escrows a USDC bond; weight (tier-
   scaled, time-decayed) raises the subject's limit via `CreditLimitEngine`.
5. **Default** — `LoanManager.markDefault` writes down pool principal, demotes
   the tier, and calls `CreditSlasher.processDefault` which reduces the score,
   slashes attesters (recovered USDC → `InsuranceFund`), and draws the fund to
   make the pool whole.

---

## Money & units

- All monetary values are **USDC, 6 decimals**.
- Rates and ratios are in **basis points** (10000 = 100%).
- `cgUSDC` (LendingPool shares) inherits 6 decimals via ERC-4626.

---

## Known limitations / notes for reviewers

These are deliberate scope choices for the hackathon, not oversights:

- **Interest is simple (linear), not compounding.** Computed per loan as
  `principal × aprBps/1e4 × elapsed/365d`. Adequate for short micro-loan terms.
- **`SocialAttestation.totalWeight` and `slashAttestations` iterate a subject's
  attestation list.** Fine at demo scale; for production, cap attestations per
  subject or switch to an incremental running-weight accumulator to bound gas.
- **ERC-4626 inflation attack.** OZ v5's built-in virtual-shares defense applies;
  additionally seed the pool with a small first deposit at deploy to be safe.
- **ZK verifier is pluggable.** `ZKAttestationVerifier` delegates to a deployed
  Groth16 verifier per claim type (`registerVerifier`). The circom-generated
  verifier + circuits live in `../circuits` (Member 2). Until registered, the
  scoring path can run on agent-signed claims alone.
- **Cross-chain transport not bundled.** `RobinhoodScoreMirror.receiveScoreUpdate`
  is gated to `BRIDGE_ROLE`; the LayerZero/CCIP relayer that calls it is wired
  separately. The contract is a clean data sink so the bridge can be swapped.
- **Stylus.** A Rust/Stylus reimplementation of the ZK verifier (for gas) is a
  noted stretch goal; the Solidity path here is the source of truth.
- **No `test/` folder yet** — intentionally deferred per the build plan.

---

## License

MIT
