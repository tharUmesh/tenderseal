# TenderSeal

Sealed-bid integrity for public procurement — EC8204 Blockchain & Cyber Security, Group 03.

TenderSeal secures the window between bid submission and bid opening: salted price
commitments, price-blind k-of-n technical evaluation with bounded escalation and appeals,
contract-computed awards, and deposits that can only be forfeited under three
predefined, on-chain, bidder-attributable conditions (F1–F3).

## Setup

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) and git.

```bash
unzip tenderseal-step1.zip && cd tenderseal
git init
forge install foundry-rs/forge-std@v1.16.2 OpenZeppelin/openzeppelin-contracts@v5.1.0
forge build
forge test          # expect: 25 tests passed
```

Then push it to a shared GitHub repo so the whole team works from one history.

Forge downloads solc 0.8.28 automatically (`solc_version` in `foundry.toml`). If your network
blocks the compiler download, point Forge at a local binary instead:

```bash
FOUNDRY_SOLC=/path/to/solc-0.8.28 forge test
```

## Useful commands

```bash
forge test -vv                 # run all tests with logs
forge test --match-contract VendorRegistryTest
forge test --gas-report        # gas per function
forge coverage                 # line/branch coverage
```

## Layout

```
src/
  VendorRegistry.sol   vendor IDs, registration cutoff (I8), debarment timestamps (I9)
  MockTLKR.sol         test LKR token (2 decimals) used for bid securities
  TenderTypes.sol      shared enums (Phase, BidState, TerminalCause, Settlement) and Bid struct
  Tender.sol           one sealed-bid tender: config, immutables, derived phase (SPEC §3-4)
test/
  VendorRegistry.t.sol
  MockTLKR.t.sol
  Tender.t.sol            constructor / configuration validation
  TenderPhase.t.sol       currentPhase / terminalCause / rankedCount
  TenderCommit.t.sol      commit / replaceCommitment / withdraw
  TenderRanking.t.sol     ranking / currentOffer
  TenderSettle.t.sol      settlementOf / settle (SPEC §7)
  utils/TenderTestBase.sol   shared fixture (actors, registry, token, default config)
  harness/TenderHarness.sol  TEST-ONLY setters for recorded facts
```

## Build progress

- [x] Step 1 — Toolchain, VendorRegistry, MockTLKR (25 tests)
- [x] Step 2 — Types, configuration, phase function
- [x] Step 3 — Money in: commit / replace / withdraw
- [x] Step 4 — Money out: ranking, offer rounds, settlement
- [ ] Step 5 — Technical path
- [ ] Step 6 — Price, award, cancellation
- [ ] Step 7 — Security evidence
- [ ] Step 8 — Factory and deployment
- [ ] Step 9 — Off-chain tools (TypeScript + viem) and minimal UI

## Registry design notes

| Property | How it is enforced |
|---|---|
| Vendor IDs never change | No re-binding function exists |
| One address ↔ one ID | `AccountAlreadyRegistered` |
| One legal identity ↔ one ID | `IdentityAlreadyRegistered` (registrar still trusted to verify identity off-chain) |
| Registration cutoff | `isRegisteredBefore(id, tenderCreatedAt)` — strict `<` |
| Deterministic debarment | `isDebarredBefore(id, priceRevealStart)` — strict `<` |
| Debarment cannot be moved | Permanent; second debarment reverts |
