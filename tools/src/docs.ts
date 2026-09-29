import { keccak256, type Hex } from "viem";
import { aesGcmDecrypt, aesGcmEncrypt, generateAesKey } from "./crypto/aesGcm.js";
import { padToBucket, unpadFromBucket } from "./crypto/docPadding.js";
import { unwrapWithEvaluatorKey, wrapForEvaluator } from "./crypto/ecies.js";

/**
 * Technical-document encryption for evaluators (SPEC §10 Step 9a item 3; SPEC §6.4,
 * §8). Resolved interpretation (matches `Tender.sol`'s NatSpec exactly, confirmed with
 * the user rather than guessed): `docHash` is the hash of the ENCRYPTED document (what
 * evaluators fetch and must verify integrity of); `docCipherRef` is a separate locator
 * for where to fetch that ciphertext -- in this prototype (no real off-chain storage
 * network), a hash of the local file path standing in for e.g. a real IPFS CID.
 */

export interface EvaluatorPublicKey {
  /** Index into the tender's `evaluators()`/`evaluatorEncKeys()` arrays. */
  index: number;
  /** 33-byte compressed secp256k1 public key, hex (SPEC §3's `evaluatorEncKeys[i]`). */
  publicKeyCompressedHex: string;
}

export interface EncryptedDocumentBundle {
  /** `docHash` (SPEC §6.1): keccak256 of the padded ciphertext. */
  docHash: Hex;
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
  const aesKey = generateAesKey();
  const packed = aesGcmEncrypt(aesKey, plaintext);
  const paddedCiphertext = padToBucket(packed);
  const docHash = keccak256(paddedCiphertext);

  const envelopes = evaluatorPublicKeys.map(({ index, publicKeyCompressedHex }) => ({
    index,
    envelopeHex: `0x${wrapForEvaluator(publicKeyCompressedHex, aesKey).toString("hex")}`,
  }));

  // Canonical (stable key order, no whitespace ambiguity) so keyEnvelopeRef is
  // reproducible from the bundle bytes alone.
  const keyEnvelopeBundleJson = JSON.stringify({ docHash, envelopes });
  const keyEnvelopeRef = keccak256(new TextEncoder().encode(keyEnvelopeBundleJson));

  return { docHash, paddedCiphertext, envelopes, keyEnvelopeRef, keyEnvelopeBundleJson };
}

/** A locator standing in for a real content-addressed storage reference (SPEC §6.1). */
export function docCipherRefForPath(filePath: string): Hex {
  return keccak256(new TextEncoder().encode(`tenderseal-doc-cipher-ref:${filePath}`));
}

export type DecryptFailureReason = "DOC_UNAVAILABLE" | "DOC_HASH_MISMATCH" | "DOC_UNDECRYPTABLE";

export type DecryptResult =
  | { ok: true; plaintext: Buffer }
  | { ok: false; reason: DecryptFailureReason; detail: string };

export interface DecryptDocumentInput {
  /** The fetched ciphertext bytes, or `undefined` if the fetch itself failed. */
  paddedCiphertext: Buffer | undefined;
  /** The `docHash` recorded on-chain for this bid. */
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
 *   - DOC_HASH_MISMATCH:  the fetched bytes don't hash to the recorded docHash (checked
 *                         BEFORE any decryption attempt -- covers both a tampered
 *                         ciphertext and a wrong hash posted in the first place; the
 *                         on-chain observable effect is identical either way).
 *   - DOC_UNDECRYPTABLE:  the hash matched (so the ciphertext is authentic) but
 *                         unwrapping the key or the AES-GCM decryption itself failed
 *                         (e.g. the wrong evaluator key was used).
 */
export function decryptDocument(input: DecryptDocumentInput): DecryptResult {
  if (input.paddedCiphertext === undefined) {
    return { ok: false, reason: "DOC_UNAVAILABLE", detail: "ciphertext file could not be fetched" };
  }

  const actualHash = keccak256(input.paddedCiphertext);
  if (actualHash !== input.expectedDocHash) {
    return {
      ok: false,
      reason: "DOC_HASH_MISMATCH",
      detail: `expected ${input.expectedDocHash}, fetched bytes hash to ${actualHash}`,
    };
  }

  try {
    const aesKey = unwrapWithEvaluatorKey(input.evaluatorPrivateKeyHex, input.envelope);
    const packed = unpadFromBucket(input.paddedCiphertext);
    const plaintext = aesGcmDecrypt(aesKey, packed);
    return { ok: true, plaintext };
  } catch (err) {
    return { ok: false, reason: "DOC_UNDECRYPTABLE", detail: String(err) };
  }
}
