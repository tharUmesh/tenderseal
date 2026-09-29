import { keccak256, type Hex } from "viem";
import { aesGcmDecrypt, aesGcmEncrypt, generateAesKey } from "./crypto/aesGcm.js";
import { padToBucket, unpadFromBucket } from "./crypto/docPadding.js";
import { unwrapWithEvaluatorKey, wrapForEvaluator } from "./crypto/ecies.js";

/**
 * Technical-document encryption for evaluators (SPEC §10 Step 9a item 3, revised in
 * item 9a-fix; SPEC §4, §6.4, §8).
 *
 * `docHash` = keccak256(PLAINTEXT), not the ciphertext. Reason: AES-GCM is not
 * key-committing, and each evaluator gets the shared AES key wrapped in its own ECIES
 * envelope. A malicious bidder who controls both the ciphertext AND every envelope could
 * (in principle) craft envelopes such that different evaluators, using their own
 * genuinely-correct private keys, each recover a DIFFERENT plaintext from the exact same
 * ciphertext blob -- every one of them passing AES-GCM's own authentication tag. A
 * ciphertext-hash `docHash` cannot catch this (the ciphertext bytes never changed); a
 * plaintext-hash `docHash` does, because every evaluator's independently-decrypted
 * output is checked against the SAME single on-chain value, so at most one evaluator's
 * result can ever match.
 *
 * `docCipherRef` = keccak256(ciphertext): a content-addressed storage locator (what a
 * real system like IPFS would use as the fetch key), unrelated to integrity.
 */

export interface EvaluatorPublicKey {
  /** Index into the tender's `evaluators()`/`evaluatorEncKeys()` arrays. */
  index: number;
  /** 33-byte compressed secp256k1 public key, hex (SPEC §3's `evaluatorEncKeys[i]`). */
  publicKeyCompressedHex: string;
}

export interface EncryptedDocumentBundle {
  /** `docHash` (SPEC §4): keccak256 of the PLAINTEXT document. */
  docHash: Hex;
  /** `docCipherRef` (SPEC §4): keccak256 of the ciphertext -- a storage locator only. */
  docCipherRef: Hex;
  /** Padded AES-256-GCM ciphertext (iv || authTag || ciphertext, then bucket-padded). */
  paddedCiphertext: Buffer;
  /** One ECIES envelope per evaluator, each wrapping the same raw AES key. */
  envelopes: { index: number; envelopeHex: string }[];
  /** `keyEnvelopeRef` (SPEC §6.4): keccak256 of the envelope bundle's canonical JSON. */
  keyEnvelopeRef: Hex;
  /** The envelope bundle exactly as hashed into `keyEnvelopeRef` (for writing to disk). */
  keyEnvelopeBundleJson: string;
}

export function encryptDocument(
  plaintext: Buffer,
  evaluatorPublicKeys: EvaluatorPublicKey[],
): EncryptedDocumentBundle {
  const docHash = keccak256(plaintext);

  const aesKey = generateAesKey();
  const packed = aesGcmEncrypt(aesKey, plaintext);
  const paddedCiphertext = padToBucket(packed);
  const docCipherRef = keccak256(paddedCiphertext);

  const envelopes = evaluatorPublicKeys.map(({ index, publicKeyCompressedHex }) => ({
    index,
    envelopeHex: `0x${wrapForEvaluator(publicKeyCompressedHex, aesKey).toString("hex")}`,
  }));

  // Canonical (stable key order, no whitespace ambiguity) so keyEnvelopeRef is
  // reproducible from the bundle bytes alone.
  const keyEnvelopeBundleJson = JSON.stringify({ docHash, envelopes });
  const keyEnvelopeRef = keccak256(new TextEncoder().encode(keyEnvelopeBundleJson));

  return { docHash, docCipherRef, paddedCiphertext, envelopes, keyEnvelopeRef, keyEnvelopeBundleJson };
}

export type DecryptFailureReason = "DOC_UNAVAILABLE" | "DOC_HASH_MISMATCH" | "DOC_UNDECRYPTABLE";

export type DecryptResult =
  | { ok: true; plaintext: Buffer }
  | { ok: false; reason: DecryptFailureReason; detail: string };

export interface DecryptDocumentInput {
  /** The fetched ciphertext bytes, or `undefined` if the fetch itself failed. */
  paddedCiphertext: Buffer | undefined;
  /** The `docHash` recorded on-chain for this bid (hash of the PLAINTEXT). */
  expectedDocHash: Hex;
  /** This evaluator's own wrapped-key envelope (from the key envelope bundle). */
  envelope: Buffer;
  /** This evaluator's own secp256k1 private key, hex. */
  evaluatorPrivateKeyHex: string;
}

/**
 * Reproduces the SPEC §8 evaluator failure modes as a typed result rather than only a
 * side effect, so each is independently unit-testable:
 *   - DOC_UNAVAILABLE:    the ciphertext could not be fetched at all.
 *   - DOC_UNDECRYPTABLE:  unwrapping the key or the AES-GCM decryption itself failed
 *                         (wrong evaluator key, or a tampered/corrupted ciphertext --
 *                         GCM's authentication tag covers the whole ciphertext, so any
 *                         tampering is caught HERE, before a docHash comparison is even
 *                         possible).
 *   - DOC_HASH_MISMATCH:  decryption succeeded (a genuine (key, ciphertext) pair, GCM
 *                         auth passed) but the resulting PLAINTEXT does not hash to the
 *                         recorded docHash -- this is the check that specifically catches
 *                         the AES-GCM non-key-commitment attack described above.
 * docHash can only ever be checked AFTER a successful decryption, since it is now a hash
 * of the plaintext, not of something fetched up front.
 */
export function decryptDocument(input: DecryptDocumentInput): DecryptResult {
  if (input.paddedCiphertext === undefined) {
    return { ok: false, reason: "DOC_UNAVAILABLE", detail: "ciphertext file could not be fetched" };
  }

  let plaintext: Buffer;
  try {
    const aesKey = unwrapWithEvaluatorKey(input.evaluatorPrivateKeyHex, input.envelope);
    const packed = unpadFromBucket(input.paddedCiphertext);
    plaintext = aesGcmDecrypt(aesKey, packed);
  } catch (err) {
    return { ok: false, reason: "DOC_UNDECRYPTABLE", detail: String(err) };
  }

  const actualHash = keccak256(plaintext);
  if (actualHash !== input.expectedDocHash) {
    return {
      ok: false,
      reason: "DOC_HASH_MISMATCH",
      detail: `expected ${input.expectedDocHash}, decrypted plaintext hashes to ${actualHash}`,
    };
  }

  return { ok: true, plaintext };
}
