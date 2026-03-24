# SigilX — Certification Protocol for Verifiable Computation

> Proofs that outlive promises.

SigilX is a certification protocol on Base. Submit verifiable work — a mathematical proof, a smart contract, a formal specification. Staked evaluators independently verify it via VRF-selected committees. Correct work gets a permanent on-chain certificate via ERC-8183. The proof goes on IPFS so anyone can re-verify independently.

## How It Works

```
Submit proof → Evaluators verify independently → Certificate on-chain
                (VRF-selected, staked, slashable)
```

1. **Submit** — Send a Lean 4 proof, Solidity contract, or formal spec via x402
2. **Verify** — Staked evaluators are randomly selected via VRF. Each independently verifies and votes
3. **Certify** — If quorum agrees (66.67% by weight), an ERC-8183 certificate is minted atomically with payment settlement

## Why On-Chain

- **Escrow** — Payment locks until work is verified. No-show evaluators trigger automatic refund
- **Slashing** — Wrong verdicts lose stake. The contract enforces it — no multisig can override
- **Permissionless challenge** — Anyone can dispute a verdict. The contract slashes the guilty party
- **Unanimity circuit breaker** — If all evaluators vote the same way on a non-trivial proof, the contract escalates to a challenge round. Perfect agreement at scale is suspicious, not reassuring

## Evaluator Economics

- Stake SIGILX tokens to register as an evaluator
- VRF randomly selects committees — you can't bribe a judge you can't identify
- Committee size scales with job value: 3 (standard), 7 ($100+), 13 ($1000+)
- Quadratic weighting: `weight = sqrt(stake * (reputation + 1))`
- Wrong verdicts → 10% stake slashed. No-shows → slashed after 2 hours
- Evaluators earn fees from real verification work — no token inflation

## Dual-Token Payment Model

| What you're paying for | Token | Why |
|----------------------|-------|-----|
| Certificates | USDC | Evaluator economics require stable-value escrow |
| Verification jobs | SIGILX or USDC | Protocol token creates buy pressure + 20% discount |
| Compute / sandbox | SIGILX or USDC | Internal operations paid in protocol token |
| Evaluator staking | SIGILX | Governance alignment |

## Contract Architecture

```
contracts/
├── sigil/
│   ├── SigilXCertificateRegistry   # ERC-8183 certificate storage (UUPS)
│   ├── CertRegistrantRouter        # Multi-caller access control
│   ├── SigilXFeeRouter             # Fee distribution: evaluators + treasury
│   ├── SigilXJobRouter             # Job lifecycle (ERC-8183)
│   ├── SigilXQuorumHook            # BFT quorum voting
│   ├── SigilXTreasuryManager       # Protocol treasury (UUPS)
│   ├── SigilXGovernor              # OpenZeppelin Governor
│   ├── SigilXTimelock              # Timelock controller
│   ├── SigilXStakeDispute          # Bond-to-dispute with escalation
│   ├── DisputeKernel               # Dispute resolution engine
│   └── SimpleReputationRegistry    # ERC-8004 reputation tracking
├── EvaluatorRegistry.sol           # Evaluator staking + VRF committee selection
├── SigilXEvaluatorV2.sol           # Committee voting + fee splits + inaction slashing
├── SigilXToken.sol                 # SIGILX governance token (ERC-20)
├── VRFCommitteeSelector.sol        # Chainlink VRF v2.5
├── OptimisticEscrow.sol            # Challenge windows + VRF escalation
├── WorldIDSybilGuard.sol           # World ID proof-of-personhood gate
└── interfaces/
    └── IERC8183.sol                # Agent Interaction Standard
```

## Standards

| Standard | Usage |
|----------|-------|
| [ERC-8183](https://eips.ethereum.org/EIPS/eip-8183) | Agentic commerce — job escrow + certificate format |
| [ERC-8004](https://eips.ethereum.org/EIPS/eip-8004) | Agent identity + reputation |
| UUPS | Upgradeable proxy on all core contracts |
| Chainlink VRF v2.5 | Fair, verifiable committee selection |
| World ID | Sybil-resistant evaluator registration |

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
| Bootstrap EvaluatorRegistry | `0x927ab46ffe72834591032fb259438f4314cf86c3` |

All contracts owned by Timelock. Governance via Governor + multisig.

## Build

```bash
forge build
forge test
```

## Links

- [sigilx.xyz](https://sigilx.xyz)
- [sigilx-skill](https://github.com/sigilxyz/sigilx-skill)
- [sigilx-contracts](https://github.com/sigilxyz/sigilx-contracts)
- [ERC-8183 spec](https://eips.ethereum.org/EIPS/eip-8183)
- [ERC-8004 spec](https://eips.ethereum.org/EIPS/eip-8004)

## License

MIT
