#!/usr/bin/env node
import { parseArgs } from "node:util";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { encryptDocument, type EvaluatorPublicKey } from "./docs.js";
import { generateEvaluatorKeypair } from "./crypto/ecies.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

/**
 * Encrypts a technical document for a committee of evaluators (SPEC §10 Step 9a item 3).
 *
 * Usage:
 *   npm run docs:encrypt -- --in path/to/doc.pdf [--out-dir tools/out/docs] [--evaluators 3]
 *   npm run docs:encrypt -- --in path/to/doc.pdf --evaluator-keys path/to/pubkeys.json
 *
 * `--evaluator-keys` (optional) is a JSON array of `{"index":0,"publicKeyCompressedHex":"0x02..."}`
 * (real evaluatorEncKeys from a deployed tender). Without it, fresh demo keypairs are
 * generated and their PRIVATE keys are written alongside the ciphertext -- clearly a
 * prototype-only convenience, never how a real evaluator's key would be handled.
 */
function main(): void {
  const { values } = parseArgs({
    options: {
      in: { type: "string" },
      "out-dir": { type: "string" },
      evaluators: { type: "string", default: "3" },
      "evaluator-keys": { type: "string" },
    },
  });

  if (!values.in) {
    console.error("Missing required --in <path-to-plaintext-document>");
    process.exit(1);
  }

  const outDir = values["out-dir"] ?? join(__dirname, "..", "out", "docs");
  mkdirSync(outDir, { recursive: true });

  const plaintext = readFileSync(values.in);

  let evaluatorPublicKeys: EvaluatorPublicKey[];
  let generatedKeypairsForDemo:
    | { index: number; privateKeyHex: string; publicKeyCompressedHex: string }[]
    | undefined;

  if (values["evaluator-keys"]) {
    evaluatorPublicKeys = JSON.parse(readFileSync(values["evaluator-keys"], "utf8"));
  } else {
    const n = Number(values.evaluators);
    generatedKeypairsForDemo = Array.from({ length: n }, (_, index) => ({
      index,
      ...generateEvaluatorKeypair(),
    }));
    evaluatorPublicKeys = generatedKeypairsForDemo.map(({ index, publicKeyCompressedHex }) => ({
      index,
      publicKeyCompressedHex,
    }));
  }

  const bundle = encryptDocument(plaintext, evaluatorPublicKeys);

  const cipherPath = join(outDir, "doc.enc");
  writeFileSync(cipherPath, bundle.paddedCiphertext);

  const envelopesPath = join(outDir, "key-envelopes.json");
  writeFileSync(envelopesPath, bundle.keyEnvelopeBundleJson + "\n");

  const summary = {
    plaintextBytes: plaintext.length,
    paddedCiphertextBytes: bundle.paddedCiphertext.length,
    docHash: bundle.docHash,
    docCipherRef: bundle.docCipherRef,
    docCipherPath: cipherPath,
    keyEnvelopeRef: bundle.keyEnvelopeRef,
    keyEnvelopesPath: envelopesPath,
    evaluatorCount: evaluatorPublicKeys.length,
  };
  const summaryPath = join(outDir, "summary.json");
  writeFileSync(summaryPath, JSON.stringify(summary, null, 2) + "\n");

  if (generatedKeypairsForDemo) {
    const keysPath = join(outDir, "evaluator-keys.SECRET.json");
    writeFileSync(keysPath, JSON.stringify(generatedKeypairsForDemo, null, 2) + "\n");
    console.log(`Generated ${generatedKeypairsForDemo.length} demo evaluator keypairs -> ${keysPath}`);
    console.log("(SECRET: a real evaluator's private key would never leave their own machine)");
  }

  console.log(`Encrypted ${values.in} (${plaintext.length} bytes plaintext)`);
  console.log(`  paddedCiphertext: ${cipherPath} (${bundle.paddedCiphertext.length} bytes, bucketed)`);
  console.log(`  docHash:          ${bundle.docHash} (of the PLAINTEXT)`);
  console.log(`  docCipherRef:     ${bundle.docCipherRef} (of the ciphertext; storage locator only)`);
  console.log(`  keyEnvelopeRef:   ${bundle.keyEnvelopeRef}`);
  console.log(`  keyEnvelopes:     ${envelopesPath}`);
  console.log(`  summary:          ${summaryPath}`);
}

main();
