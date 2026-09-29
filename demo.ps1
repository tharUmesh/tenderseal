#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the TenderSeal local demo end to end against a running Anvil node, advancing
    chain time between lifecycle stages, for recording the demo video (SPEC §10 Step 8).

.DESCRIPTION
    Start Anvil in its own terminal first:
        anvil
    Then, from the repo root, in a second terminal:
        .\demo.ps1

    Each stage is its own `forge script --broadcast` call against
    http://127.0.0.1:8545 (Anvil's default), so every transaction is real and visible in
    Anvil's own log -- good for a recording. Between stages this script advances Anvil's
    clock with `cast rpc evm_increaseTime` / `evm_mine`, since the demo tender's whole
    schedule only spans 18 minutes of chain time (see DeployLocal.s.sol) and the real
    wall-clock gap between two `forge script` calls is a few seconds at most.
#>

$ErrorActionPreference = "Stop"

$RpcUrl = "http://127.0.0.1:8545"
$Forge = "$env:USERPROFILE\.foundry\bin\forge.exe"
$Cast = "$env:USERPROFILE\.foundry\bin\cast.exe"

function Write-Stage($text) {
    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host $text -ForegroundColor Cyan
    Write-Host "==================================================================" -ForegroundColor Cyan
}

function Invoke-DemoScript($path) {
    & $Forge script $path --rpc-url $RpcUrl --broadcast -vv
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Script failed: $path" -ForegroundColor Red
        exit 1
    }
}

function Advance-Time($seconds) {
    Write-Host "-- advancing Anvil clock by $seconds s --" -ForegroundColor DarkGray
    & $Cast rpc evm_increaseTime $seconds --rpc-url $RpcUrl | Out-Null
    & $Cast rpc evm_mine --rpc-url $RpcUrl | Out-Null
}

# Anvil's well-known default mnemonic (never used beyond localhost:8545 -- see
# DemoConstants.sol). A real `cast send`, run directly here rather than inside any
# `forge script`, so its revert is genuinely on-chain and visible for the recording
# without tripping `forge script --broadcast`'s "Simulated execution failed" check (see
# 02_TechReveal.s.sol's doc comment for why that check can't be satisfied from inside a
# script for a call that's SUPPOSED to revert).
$AnvilMnemonic = "test test test test test test test test test test test junk"

# Phase enum order (src/TenderTypes.sol) -- index == the ordinal WrongPhase(uint8) reverts
# with, so this only needs updating if that enum's order ever changes.
$PhaseNames = @(
    "Open", "TechReveal", "Evaluation", "AppealFiling", "AppealResolution",
    "PriceReveal", "Acceptance", "Final", "Cancelled", "Failed"
)

function Invoke-LateCommitDemo {
    $state = Get-Content "script/demo/.demo-state.json" | ConvertFrom-Json
    $lateKey = & $Cast wallet private-key --mnemonic $AnvilMnemonic --mnemonic-index 4
    $dummyHash = & $Cast keccak "late-commit-demo"
    Write-Host "Attempting a commit after submissionDeadline (expected to revert on-chain) ..." -ForegroundColor Yellow

    # `2>&1` on a native exe wraps each stderr line as a NativeCommandError under
    # $ErrorActionPreference = "Stop" (PS 5.1), which would abort this whole script for a
    # revert we expect -- so it's scoped to "Continue" just for this one capture.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & $Cast send $state.tender "commit(bytes32,bytes32,bytes32)" $dummyHash $dummyHash $dummyHash `
        --rpc-url $RpcUrl --private-key $lateKey 2>&1 | Out-String
    $ErrorActionPreference = $previousErrorActionPreference
    Write-Host $output

    # cast already decodes the custom error's selector using this project's compiled ABI
    # (e.g. "...: WrongPhase(1)"); pull out just the phase ordinal and map it to its name.
    $match = [regex]::Match($output, "WrongPhase\((\d+)\)")
    if ($match.Success) {
        $phaseNum = [int]$match.Groups[1].Value
        $phaseName = if ($phaseNum -ge 0 -and $phaseNum -lt $PhaseNames.Length) {
            $PhaseNames[$phaseNum]
        } else {
            "Unknown($phaseNum)"
        }
        Write-Host "Rejected: WrongPhase($phaseName) -- submission deadline has passed" -ForegroundColor Yellow
    } else {
        Write-Host "Rejected as expected -- deadlines are chain-time enforced (SPEC claim 2)" -ForegroundColor Yellow
    }
}

Write-Stage "Checking Anvil is reachable at $RpcUrl ..."
try {
    & $Cast chain-id --rpc-url $RpcUrl | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "cast chain-id failed" }
} catch {
    Write-Host "Could not reach Anvil at $RpcUrl. Start it first with:  anvil" -ForegroundColor Red
    exit 1
}
Write-Host "Anvil is up." -ForegroundColor Green

Write-Stage "Deploying registry, tLKR, factory, and registering demo vendors ..."
Invoke-DemoScript "script/DeployLocal.s.sol"

# A real time gap (not just `vm.warp`, which only affects a script's own local
# simulation) must separate "register vendors" from "create tender": both timestamps are
# captured from the real on-chain block at broadcast time, and I8 requires
# registeredAt < createdAt, strictly. See CreateDemoTender.s.sol's doc comment.
Advance-Time 5
Write-Stage "Creating the demo tender and funding both bidders ..."
Invoke-DemoScript "script/CreateDemoTender.s.sol"

Write-Stage "Stage 1/7: Commit (Open)"
Invoke-DemoScript "script/demo/01_Commit.s.sol"

Advance-Time 200
Write-Stage "Stage 2/7: TechReveal (incl. a late-commit revert demo)"
Invoke-LateCommitDemo
Invoke-DemoScript "script/demo/02_TechReveal.s.sol"

Advance-Time 200
Write-Stage "Stage 3/7: Votes (Evaluation)"
Invoke-DemoScript "script/demo/03_Votes.s.sol"

Advance-Time 200
Write-Stage "Stage 4/7: Appeal (AppealFiling)"
Invoke-DemoScript "script/demo/04_Appeal.s.sol"

Advance-Time 400
Write-Stage "Stage 5/7: PriceReveal (incl. a deliberate withheld reveal)"
Invoke-DemoScript "script/demo/05_PriceReveal.s.sol"

Advance-Time 200
Write-Stage "Stage 6/7: Accept (Acceptance -> Final)"
Invoke-DemoScript "script/demo/06_Accept.s.sol"

Write-Stage "Stage 7/7: Settle (F2 forfeiture visible on bidderWithholder)"
Invoke-DemoScript "script/demo/07_Settle.s.sol"

Write-Stage "Demo complete."
