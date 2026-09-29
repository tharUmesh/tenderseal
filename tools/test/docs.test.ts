import { test } from "node:test";
import assert from "node:assert/strict";
import { keccak256 } from "viem";
import { decryptDocument, encryptDocument } from "../src/docs.js";
import { generateEvaluatorKeypair } from "../src/crypto/ecies.js";

function setup(plaintextText = "technical proposal contents, not a price anywhere") {
  const evalA = generateEvaluatorKeypair();
  const evalB = generateEvaluatorKeypair();
  const plaintext = Buffer.from(plaintextText, "utf8");
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

test("DOC_UNDECRYPTABLE: a tampered ciphertext fails GCM authentication", () => {
  const { evalA, bundle, envelopeFor } = setup();
  const tampered = Buffer.from(bundle.paddedCiphertext);
  // Byte 4 is the first byte of the real iv||authTag||ciphertext region (bytes 0-3 are
  // the bucket-padding length prefix, unauthenticated and never read back out) -- must
  // land inside GCM's authenticated region, not the unused zero-padding tail.
  tampered[4] = tampered[4]! ^ 0xff;
  const result = decryptDocument({
    paddedCiphertext: tampered,
    expectedDocHash: bundle.docHash,
    envelope: envelopeFor(0),
    evaluatorPrivateKeyHex: evalA.privateKeyHex,
  });
  // GCM's auth tag covers the whole ciphertext, so tampering is caught at decryption --
  // BEFORE a docHash comparison is even reachable (docHash is now over the plaintext).
  assert.equal(result.ok, false);
  assert.ok(!result.ok && result.reason === "DOC_UNDECRYPTABLE");
});

test("DOC_UNDECRYPTABLE: hash matches expectations but the wrong key is used", () => {
  const { evalB, bundle, envelopeFor } = setup();
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

/**
 * The whole point of item 9a-fix: a ciphertext that decrypts successfully (genuine
 * (key, ciphertext) pair, GCM authentication passes) but whose PLAINTEXT does not match
 * the docHash on record must still be rejected. This is exactly the shape of an
 * AES-GCM non-key-commitment attack: two evaluators, each with their own genuinely
 * correct (key, ciphertext) pair, could otherwise recover two DIFFERENT documents from
 * what looks like "the same" encrypted bid. Simulated here by substituting a completely
 * unrelated (but internally 100% valid) encrypted document's docHash, rather than by
 * actually breaking AES-GCM -- this tests the CHECK's ability to catch the mismatch, not
 * an attempt to construct a real non-commitment collision.
 */
test("DOC_HASH_MISMATCH: decrypts successfully, but the plaintext doesn't match the recorded docHash", () => {
  const documentA = setup("Document A: the real technical proposal");
  const documentB = setup("Document B: a completely different document");

  const result = decryptDocument({
    paddedCiphertext: documentB.bundle.paddedCiphertext,
    expectedDocHash: documentA.bundle.docHash, // wrong docHash: belongs to document A
    envelope: documentB.envelopeFor(0),
    evaluatorPrivateKeyHex: documentB.evalA.privateKeyHex, // document B's own, correct key
  });

  assert.equal(result.ok, false);
  assert.ok(!result.ok && result.reason === "DOC_HASH_MISMATCH");
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

test("docHash is over the plaintext; docCipherRef is over the ciphertext (distinct values)", () => {
  const { plaintext, bundle } = setup();
  assert.equal(bundle.docHash, keccak256(plaintext));
  assert.equal(bundle.docCipherRef, keccak256(bundle.paddedCiphertext));
  assert.notEqual(bundle.docHash, bundle.docCipherRef);
});
