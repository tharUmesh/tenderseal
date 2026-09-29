#!/usr/bin/env node
import { parseArgs } from "node:util";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { isAddress, type Address, type Hex } from "viem";
import { computeCommitment } from "./crypto/commitment.js";
import { generateSalt } from "./crypto/salt.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

/**
 * Generates a bidder's private bid receipt (SPEC §10 Step 9a item 1): a fresh 256-bit
 * salt (CSPRNG) and the exact SPEC §5 price commitment. The receipt is what a bidder
 * keeps to itself and later replays into `revealPrice` -- losing it, or its salt leaking
 * early, breaks hiding or (if lost entirely) the deposit.
 *
 * Usage:
 *   npm run receipt -- --chain-id 31337 --tender 0xTender --bidder 0xBidder \
 *     --price 25000000 --doc-hash 0xDocHash [--out path.json]
 */
function main(): void {
  const { values } = parseArgs({
    options: {
      "chain-id": { type: "string" },
      tender: { type: "string" },
      bidder: { type: "string" },
      price: { type: "string" },
      "doc-hash": { type: "string" },
      out: { type: "string" },
    },
  });

  const missing = (["chain-id", "tender", "bidder", "price", "doc-hash"] as const).filter(
    (k) => values[k] === undefined,
  );
  if (missing.length > 0) {
    console.error(`Missing required argument(s): ${missing.map((k) => `--${k}`).join(", ")}`);
    console.error(
      "Usage: npm run receipt -- --chain-id 31337 --tender 0x... --bidder 0x... --price 25000000 --doc-hash 0x... [--out path.json]",
    );
    process.exit(1);
  }

  const tender = values.tender as string;
  const bidder = values.bidder as string;
  const docHash = values["doc-hash"] as string;
  if (!isAddress(tender)) throw new Error(`--tender is not a valid address: ${tender}`);
  if (!isAddress(bidder)) throw new Error(`--bidder is not a valid address: ${bidder}`);
  if (!/^0x[0-9a-fA-F]{64}$/.test(docHash)) {
    throw new Error(`--doc-hash must be a 32-byte 0x-hex value: ${docHash}`);
  }

  const chainId = BigInt(values["chain-id"] as string);
  const price = BigInt(values.price as string);
  if (price <= 0n) throw new Error("--price must be > 0 (SPEC §5)");

  const salt = generateSalt();
  const commitment = computeCommitment({
    chainId,
    tender: tender as Address,
    bidder: bidder as Address,
    price,
    docHash: docHash as Hex,
    salt,
  });

  const receipt = {
    chainId: chainId.toString(),
    tender,
    bidder,
    price: price.toString(),
    docHash,
    salt,
    priceCommitment: commitment,
    generatedAt: new Date().toISOString(),
    warning:
      "PRIVATE: keep this file secret until you intend to call revealPrice. The salt is the only source of hiding (SPEC §5).",
  };

  const outPath = values.out ?? join(__dirname, "..", "out", `receipt-${Date.now()}.json`);
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, JSON.stringify(receipt, null, 2) + "\n");

  console.log(`Wrote receipt to ${outPath}`);
  console.log(`  priceCommitment: ${commitment}`);
  console.log(`  salt (SECRET):   ${salt}`);
}

main();
