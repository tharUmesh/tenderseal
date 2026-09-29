#!/usr/bin/env node
import { parseArgs } from "node:util";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { decryptDocument } from "./docs.js";

/**
 * Evaluator-side document decryption (SPEC §10 Step 9a item 3).
 *
 * Usage:
 *   npm run docs:decrypt -- --summary tools/out/docs/summary.json \
 *     --envelopes tools/out/docs/key-envelopes.json --evaluator-index 0 \
 *     --private-key 0x<evaluator's secp256k1 private key> [--out plaintext.pdf]
 */
function main(): void {
  const { values } = parseArgs({
    options: {
      summary: { type: "string" },
      envelopes: { type: "string" },
      "evaluator-index": { type: "string" },
      "private-key": { type: "string" },
      out: { type: "string" },
    },
  });

  const missing = (["summary", "envelopes", "evaluator-index", "private-key"] as const).filter(
    (k) => values[k] === undefined,
  );
  if (missing.length > 0) {
    console.error(`Missing required argument(s): ${missing.map((k) => `--${k}`).join(", ")}`);
    process.exit(1);
  }

  const summary = JSON.parse(readFileSync(values.summary as string, "utf8"));
  const envelopeBundle = JSON.parse(readFileSync(values.envelopes as string, "utf8"));
  const index = Number(values["evaluator-index"]);
  const envelopeEntry = envelopeBundle.envelopes.find((e: { index: number }) => e.index === index);
  if (!envelopeEntry) {
    console.error(`No envelope for evaluator index ${index} in ${values.envelopes}`);
    process.exit(1);
  }

  const cipherPath: string = summary.docCipherPath;
  const paddedCiphertext = existsSync(cipherPath) ? readFileSync(cipherPath) : undefined;

  const result = decryptDocument({
    paddedCiphertext,
    expectedDocHash: summary.docHash,
    envelope: Buffer.from((envelopeEntry.envelopeHex as string).slice(2), "hex"),
    evaluatorPrivateKeyHex: values["private-key"] as string,
  });

  if (!result.ok) {
    console.error(`FAIL: ${result.reason} -- ${result.detail}`);
    process.exit(1);
  }

  if (values.out) {
    mkdirSync(dirname(values.out), { recursive: true });
    writeFileSync(values.out, result.plaintext);
    console.log(`OK: decrypted ${result.plaintext.length} bytes -> ${values.out}`);
  } else {
    console.log(`OK: decrypted ${result.plaintext.length} bytes (pass --out to save to a file)`);
  }
}

main();
