import { test } from "node:test";
import assert from "node:assert/strict";
import { decryptDocument, encryptDocument } from "../src/docs.js";
import { generateEvaluatorKeypair } from "../src/crypto/ecies.js";

function setup() {
  const evalA = generateEvaluatorKeypair();
  const evalB = generateEvaluatorKeypair();
  const plaintext = Buffer.from("technical proposal contents, not a price anywhere", "utf8");
  const bundle = encryptDocument(plaintext, [
    { index: 0, publicKeyCompressedHex: evalA.publicKeyCompressedHex },
    { index: 1, publicKeyCompressedHex: evalB.publicKeyCompressedHex },
  ]);
  const envelopeFor = (index: number) => {
    const entry = bundle.envelopes.find((e) => e.index === index)!;
    return Buffer.from(entry.envelopeHex.slice(2), "hex");
  };
  return { evalA, evalB, plaintext, bundle, envelopeFor };
}

test("happy path: the intended evaluator recovers the exact plaintext", () => {
  const { evalA, plaintext, bundle, envelopeFor } = setup();
  const result = decryptDocument({
    paddedCiphertext: bundle.paddedCiphertext,
    expectedDocHash: bundle.docHash,
    envelope: envelopeFor(0),
    evaluatorPrivateKeyHex: evalA.privateKeyHex,
  });
  assert.equal(result.ok, true);
  assert.ok(result.ok && result.plaintext.equals(plaintext));
});

test("DOC_UNAVAILABLE: the ciphertext could not be fetched", () => {
  const { evalA, bundle, envelopeFor } = setup();
  const result = decryptDocument({
    paddedCiphertext: undefined,
    expectedDocHash: bundle.docHash,
    envelope: envelopeFor(0),
    evaluatorPrivateKeyHex: evalA.privateKeyHex,
  });
  assert.equal(result.ok, false);
  assert.ok(!result.ok && result.reason === "DOC_UNAVAILABLE");
});

test("DOC_HASH_MISMATCH: the fetched bytes were tampered with after posting docHash", () => {
  const { evalA, bundle, envelopeFor } = setup();
  const tampered = Buffer.from(bundle.paddedCiphertext);
  const lastIdx = tampered.length - 1;
  tampered[lastIdx] = tampered[lastIdx]! ^ 0xff; // flip a byte deep inside the padded region
  const result = decryptDocument({
    paddedCiphertext: tampered,
    expectedDocHash: bundle.docHash, // still the ORIGINAL recorded hash
    envelope: envelopeFor(0),
    evaluatorPrivateKeyHex: evalA.privateKeyHex,
  });
  assert.equal(result.ok, false);
  assert.ok(!result.ok && result.reason === "DOC_HASH_MISMATCH");
});

test("DOC_UNDECRYPTABLE: hash matches (ciphertext authentic) but the wrong key is used", () => {
  const { evalB, bundle, envelopeFor } = setup();
  // Ciphertext and docHash are untouched (hash check passes); but evalA's envelope is
  // unwrapped with evalB's private key -- the wrong evaluator for that envelope.
  const result = decryptDocument({
    paddedCiphertext: bundle.paddedCiphertext,
    expectedDocHash: bundle.docHash,
    envelope: envelopeFor(0), // evalA's envelope
    evaluatorPrivateKeyHex: evalB.privateKeyHex, // evalB's key
  });
  assert.equal(result.ok, false);
  assert.ok(!result.ok && result.reason === "DOC_UNDECRYPTABLE");
});

test("DOC_UNDECRYPTABLE: a corrupted envelope also fails cleanly (not an unhandled throw)", () => {
  const { evalA, bundle, envelopeFor } = setup();
  const corrupted = envelopeFor(0);
  corrupted[0] = corrupted[0]! ^ 0xff;
  const result = decryptDocument({
    paddedCiphertext: bundle.paddedCiphertext,
    expectedDocHash: bundle.docHash,
    envelope: corrupted,
    evaluatorPrivateKeyHex: evalA.privateKeyHex,
  });
  assert.equal(result.ok, false);
  assert.ok(!result.ok && result.reason === "DOC_UNDECRYPTABLE");
});

test("each evaluator's envelope wraps the SAME underlying key (both can decrypt independently)", () => {
  const { evalA, evalB, plaintext, bundle, envelopeFor } = setup();
  const a = decryptDocument({
    paddedCiphertext: bundle.paddedCiphertext,
    expectedDocHash: bundle.docHash,
    envelope: envelopeFor(0),
    evaluatorPrivateKeyHex: evalA.privateKeyHex,
  });
  const b = decryptDocument({
    paddedCiphertext: bundle.paddedCiphertext,
    expectedDocHash: bundle.docHash,
    envelope: envelopeFor(1),
    evaluatorPrivateKeyHex: evalB.privateKeyHex,
  });
  assert.ok(a.ok && b.ok && a.plaintext.equals(plaintext) && b.plaintext.equals(plaintext));
});

test("padded ciphertext is bucketed (does not leak the exact plaintext length)", () => {
  const { bundle, plaintext } = setup();
  assert.notEqual(bundle.paddedCiphertext.length, plaintext.length);
  assert.equal(bundle.paddedCiphertext.length, 4 * 1024); // smallest bucket, for this short doc
});
