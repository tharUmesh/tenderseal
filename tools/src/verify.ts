#!/usr/bin/env node
import { parseArgs } from "node:util";
import { createPublicClient, http, isAddress, type Address } from "viem";
import { reconstructTender } from "./verifier/reconstruct.js";
import { runAllChecks } from "./verifier/checks.js";
import type { CheckResult } from "./verifier/model.js";

/**
 * Public verifier CLI (SPEC §10 Step 9a item 4): fetches every event a tender has ever
 * emitted, independently reconstructs its whole bid state machine (never trusting the
 * contract's own derived views for the state being checked), and cross-checks against
 * SPEC §4-§9.
 *
 * Usage:
 *   npm run verify -- --rpc-url http://127.0.0.1:8545 --tender 0xTenderAddress
 */
async function main(): Promise<void> {
  const { values } = parseArgs({
    options: {
      "rpc-url": { type: "string" },
      tender: { type: "string" },
    },
  });

  if (!values["rpc-url"] || !values.tender) {
    console.error("Usage: npm run verify -- --rpc-url <url> --tender 0x<address>");
    process.exitCode = 1;
    return;
  }
  if (!isAddress(values.tender)) {
    console.error(`--tender is not a valid address: ${values.tender}`);
    process.exitCode = 1;
    return;
  }

  const client = createPublicClient({ transport: http(values["rpc-url"]) });
  const tender = values.tender as Address;

  console.log(`== TenderSeal public verifier ==`);
  console.log(`RPC:    ${values["rpc-url"]}`);
  console.log(`Tender: ${tender}\n`);

  const model = await reconstructTender(client, tender);
  console.log(`Reconstructed ${model.events.length} event(s), ${model.bids.size} bid(s).\n`);

  const results = await runAllChecks(model, client);
  printTable(results);

  const allPass = results.every((r) => r.pass);
  process.exitCode = allPass ? 0 : 1;
}

function printTable(results: CheckResult[]): void {
  const idWidth = Math.max(...results.map((r) => r.id.length), 2);
  const nameWidth = Math.max(...results.map((r) => r.name.length), 4);

  const line = (a: string, b: string, c: string) =>
    `| ${a.padEnd(idWidth)} | ${b.padEnd(nameWidth)} | ${c} |`;

  console.log(line("ID", "Check", "Result"));
  console.log(`|${"-".repeat(idWidth + 2)}|${"-".repeat(nameWidth + 2)}|--------|`);
  for (const r of results) {
    console.log(line(r.id, r.name, r.pass ? "PASS" : "FAIL"));
  }
  console.log("");

  for (const r of results) {
    if (r.pass) continue;
    console.log(`${r.id} FAIL details:`);
    for (const d of r.details) console.log(`  - ${d}`);
  }

  const passCount = results.filter((r) => r.pass).length;
  console.log(`\n${passCount}/${results.length} checks passed.`);
}

main().catch((err) => {
  console.error("Verifier crashed:", err);
  process.exitCode = 2;
});
