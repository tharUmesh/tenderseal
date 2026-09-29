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
  TenderFactory.sol    deploys Tender instances pinned to one registry/token (SPEC §6.12)
test/
  VendorRegistry.t.sol
  MockTLKR.t.sol
  Tender.t.sol            constructor / configuration validation
  TenderPhase.t.sol       currentPhase / terminalCause / rankedCount
  TenderCommit.t.sol      commit / replaceCommitment / withdraw
  TenderRanking.t.sol     ranking / currentOffer
  TenderSettle.t.sol      settlementOf / settle (SPEC §7)
  TenderVoting.t.sol      postKeyEnvelope / declareConflict / castVote (SPEC §6.4-6.5, §8)
  TenderAppeals.t.sol     fileAppeal / resolveEscalation / resolveAppeal (SPEC §6.6)
  TenderReveal.t.sol      revealPrice: commitment verification (SPEC §6.8, §5)
  TenderCancel.t.sol      cancel: phase x reason-code matrix (SPEC §6.7)
  TenderAward.t.sol       acceptAward / acknowledgeAward (SPEC §6.9)
  TenderFactory.t.sol     pinned registry/token, pe == msg.sender, records/events (SPEC §6.12)
  TenderScenarios.t.sol   end-to-end: full lifecycle, appeal changes winner, ring attack
  TenderReentrancy.t.sol  malicious-token reentrancy into commit/settle
  TenderGas.t.sol         gas benchmarks: creation, 20-bidder flow, n=3 vs n=5, factory
  ScriptSmoke.t.sol       runs every script/demo/*.s.sol stage end to end (Step 8 item 4)
  MaliciousReentrantToken.sol   TEST-ONLY ERC20 with an "arm one reentrant call" hook
  utils/TenderTestBase.sol   shared fixture (actors, registry, token, default config)
  harness/TenderHarness.sol  TEST-ONLY setters for recorded facts
  invariant/TenderHandler.sol         bounded actors/actions/time warps + ghost ledger
  invariant/TenderInvariantsBase.sol  shared deployment/logging/invariant_I1..I12 checks
  invariant/TenderInvariants.t.sol    cold-start invariant suite (SPEC §9)
  invariant/TenderInvariantsCP1..CP4.t.sol  checkpoint invariant suites (same handler/checks)
script/
  DemoConstants.sol       shared Anvil-mnemonic roles + JSON state file read/write helpers
  DeployLocal.s.sol       local demo deploy 1/2: registry, tLKR, factory, demo vendors
  CreateDemoTender.s.sol  local demo deploy 2/2: demo tender + funding (separate broadcast)
  DeploySepolia.s.sol     real-network infra deploy (--account keystore, no raw key)
  demo/01_Commit.s.sol .. 07_Settle.s.sol   one script per lifecycle stage (Step 8 item 3)
demo.ps1                  runs the local demo end to end against a running Anvil node
```

## Deployment

### Local demo (Anvil)

Everything here uses Anvil's well-known default mnemonic
(`test test test test test test test test test test test junk`) for 10 fixed roles
(deployer, registrar, PE, appeals authority, treasury, 3 evaluators, 2 demo bidders) — see
`script/DemoConstants.sol`. Never used beyond `localhost:8545`.

Two terminals, both at the repo root:

```powershell
# Terminal 1
anvil

# Terminal 2
.\demo.ps1
```

`demo.ps1` runs, in order: `DeployLocal.s.sol` (registry, tLKR, factory, vendor
registration), `CreateDemoTender.s.sol` (the demo tender + funding — a separate script/
broadcast from `DeployLocal.s.sol`, since both `registeredAt` and `createdAt` are captured
from the real on-chain block at broadcast time, and I8 requires `registeredAt < createdAt`
strictly), then `script/demo/01_Commit.s.sol` through `07_Settle.s.sol`, advancing Anvil's
clock between stages with `cast rpc evm_increaseTime` / `evm_mine`. It also runs a real
`cast send` late-commit attempt before stage 2, which reverts on-chain (`WrongPhase`) —
expected, demonstrating chain-time-enforced deadlines (SPEC claim 2). One demo bidder
deliberately never reveals its price, so stage 7 shows its deposit forfeited to `treasury`
(F2) while the winning bidder is refunded.

To run any single stage by hand instead:

```powershell
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

`test/ScriptSmoke.t.sol` runs the same sequence (via `vm.warp` instead of real time) as an
ordinary `forge test`, so `forge test` alone verifies every stage script still works.

### Sepolia (real network)

Signs with a Foundry keystore account — **never a raw private key**. Create one once:

```powershell
cast wallet import tenderseal-deployer --interactive
# paste the private key when prompted; it's encrypted at rest under ~/.foundry/keystores
```

Create a `.env` (already gitignored) with the role addresses and your RPC URL, then load it:

```powershell
# .env
SEPOLIA_ADMIN=0x...
SEPOLIA_REGISTRAR=0x...
SEPOLIA_TREASURY=0x...
SEPOLIA_RPC_URL=https://...

Get-Content .env | ForEach-Object {
    if ($_ -match '^\s*([^#=]+)=(.*)$') { Set-Item "env:$($Matches[1])" $Matches[2] }
}
```

Deploy (only `VendorRegistry` + `MockTLKR` + `TenderFactory`; the PE creates the actual
tender afterwards via `TenderFactory.createTender`, e.g. from the Step 9 CLI/UI or `cast send`):

```powershell
forge script script/DeploySepolia.s.sol `
  --rpc-url $env:SEPOLIA_RPC_URL --account tenderseal-deployer --broadcast --verify
```

## Build progress

- [x] Step 1 — Toolchain, VendorRegistry, MockTLKR (25 tests)
- [x] Step 2 — Types, configuration, phase function
- [x] Step 3 — Money in: commit / replace / withdraw
- [x] Step 4 — Money out: ranking, offer rounds, settlement
- [x] Step 5 — Technical path
- [x] Step 6 — Price, award, cancellation
- [x] Step 7 — Security evidence
- [x] Step 8 — Factory and deployment
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
