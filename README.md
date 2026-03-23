# SigilX — Certification Protocol for Verifiable Computation

> Proofs that outlive promises.

SigilX is a certification protocol on Base. Submit any verifiable work — a mathematical proof, a smart contract, a formal specification. Staked evaluators independently verify it. If they agree it's correct, a permanent certificate gets minted on-chain via ERC-8183. The work and proof go on IPFS so anyone can re-run the verification themselves.

**Live at [sigilx.xyz](https://sigilx.xyz)**

## How It Works

```
Submit proof/contract → Evaluators verify independently → Certificate on-chain
                         (VRF-selected, staked, slashable)
```

1. **Submit** — Send a Lean 4 proof, Solidity contract, or formal spec via the x402 API
2. **Verify** — Staked evaluators are randomly selected via Chainlink VRF. Each independently downloads the proof from IPFS, runs it, and votes
3. **Certify** — If quorum agrees (66.67% by weight), an ERC-8183 certificate is minted atomically with payment settlement. Either both succeed or both revert

## Why On-Chain

The chain matters when you don't trust the verifier:

- **Escrow** — Payment locks until work is verified. No-show evaluators → automatic refund
- **Slashing** — Wrong verdicts lose stake. A multisig can't punish its own majority; the contract enforces it automatically
- **Permissionless challenge** — Anyone can dispute a verdict externally. The contract slashes the guilty party — they can't prevent it

## Evaluator Economics

- Evaluators stake to register (minimum 100 USDC)
- Chainlink VRF randomly selects committees — you can't bribe a judge you can't identify
- Committee size scales with job value: 5 members (<$100), 7 ($100-$1000), 13 ($1000+)
- Quadratic weighting: `weight = sqrt(stake * (reputation + 1))`
- Wrong verdicts → 10% stake slashed. No-shows → slashed after 2 hours
- No token inflation. Evaluators earn fees from real verification work

## Contract Architecture

```
contracts/
├── sigil/                          # Core protocol (23 contracts)
│   ├── SigilXCertificateRegistry   # ERC-8183 certificate storage (UUPS)
│   ├── SigilXFeeRouter             # Fee distribution: evaluators + treasury
│   ├── SigilXJobRouter             # Job submission and lifecycle
│   ├── SigilXQuorumHook            # BFT quorum voting (66.67% threshold)
│   ├── SigilXOracleHook            # Single-evaluator verification
│   ├── SigilXTreasuryManager       # Protocol treasury (UUPS)
│   ├── SigilXGovernor              # OpenZeppelin Governor
│   ├── SigilXTimelock              # Timelock controller (5 min testnet)
│   ├── SigilXStakeDispute          # Bond-to-dispute with escalation ladder
│   ├── DisputeKernel               # Dispute resolution engine
│   └── SimpleReputationRegistry    # ERC-8004 reputation tracking
├── EvaluatorRegistry.sol           # Evaluator staking + registration
├── SigilXEvaluatorV2.sol           # Committee voting + slashing
├── SigilXToken.sol                 # SIGILX governance token (ERC-20)
├── VRFCommitteeSelector.sol        # Chainlink VRF v2.5 committee selection
└── interfaces/                     # Shared interfaces (ERC-8183, etc.)
```

## Standards

| Standard | Usage |
|----------|-------|
| ERC-8183 | Agent Interaction Standard — certificate format |
| ERC-8004 | Decentralized Reputation — evaluator scores |
| UUPS | Upgradeable proxy pattern on all core contracts |
| Chainlink VRF v2.5 | Fair, verifiable committee selection |

## Deployments (Base Sepolia)

| Contract | Address |
|----------|---------|
| CertificateRegistry | `0xc1c20B5507f4F27480Fe580aD7C3dE8A335caBfE` |
| CertRegistrantRouter | `0xc80498A43003F92F911CfdB1EC5e6Eb69D890279` |
| EvaluatorRegistry | `0x2c0F572Fbcb24FD9b5ebFb768678D6f725344919` |
| SigilXEvaluatorV2 | `0xf5D04616ecA3be49feA323c205451936d7816B01` |
| VRFCommitteeSelector | `0x20f84c552CcF538fB16275EBE120902eb2A23C95` |
| OptimisticEscrow | `0xdaE8a643C10392cD85376F999808E8eb67d00757` |
| SigilXJobRouter | `0xB659D06d2E06afFCAeeEd683b0997f9dd8EBA2Ee` |
| SigilXToken (SIGILX) | `0x26213ff340f919ECf7D482847406A5b618Ec45f8` |
| FeeRouter | `0x010F576Ba8BA6f22c7365Eeb9E3a745327f7452F` |
| TreasuryManager | `0xBAd92A83B751F060ed452Ff9725AACBcB8eDb406` |
| Timelock | `0xCe13349EF588116816287dD30eC006A7Db6B3dD0` |
| Governor | `0xa6fC64C68c7E62f420CBDDAe87b3b369C7Ccbf85` |
| DisputeKernel | `0x3aEf85a061832d0720c3Bb6f92Bd20ef4B91be26` |

All contracts owned by Timelock. Governance via Governor + multisig.

## Payment Rails

| Rail | How it works |
|------|-------------|
| x402 | USDC payment header, atomic settlement with certificate minting |
| MPP | Stripe/Tempo micropayments |
| ACP | Virtuals Protocol agent-to-agent payments |
| Privy | Embedded wallet for human users at sigilx.xyz |

## What's Honest

- Zero paying users today
- Competition math benchmarks: 0% automated solve rate (state of the art)
- Protocol verification and contract properties: 100% pass rate
- Premium evaluator tier needs bootstrapping
- Commit-reveal for evaluator votes not shipped yet
- 500+ tests passing, mainnet fork red/blue team all green

## Build

```bash
forge build
forge test
```

## Links

- **Live:** [sigilx.xyz](https://sigilx.xyz)
- **Skill:** [github.com/sigilxyz/sigilx-skill](https://github.com/sigilxyz/sigilx-skill)
- **ERC-8183:** [ethereum-magicians.org](https://ethereum-magicians.org/t/erc-8183-agent-interaction-standard)
