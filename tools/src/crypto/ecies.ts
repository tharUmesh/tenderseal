import { PrivateKey, encrypt as eciesEncrypt, decrypt as eciesDecrypt } from "eciesjs";

/**
 * Thin wrapper around `eciesjs` (ECIES over secp256k1, AES-256-GCM by default — matches
 * SPEC §3's 33-byte compressed secp256k1 `evaluatorEncKeys`). Never a hand-rolled ECDH/AES
 * implementation.
 */

/** Generates a fresh secp256k1 keypair for an evaluator (demo only). */
export function generateEvaluatorKeypair(): { privateKeyHex: string; publicKeyCompressedHex: string } {
  const sk = new PrivateKey();
  return {
    privateKeyHex: sk.toHex(),
    publicKeyCompressedHex: sk.publicKey.toHex(true), // 33-byte compressed, per SPEC §3
  };
}

/** Wraps `secret` (e.g. a raw AES key) for the holder of `publicKeyCompressedHex`. */
export function wrapForEvaluator(publicKeyCompressedHex: string, secret: Uint8Array): Buffer {
  return Buffer.from(eciesEncrypt(publicKeyCompressedHex, secret));
}

/** Unwraps an envelope produced by `wrapForEvaluator`, given the matching private key. */
export function unwrapWithEvaluatorKey(privateKeyHex: string, envelope: Uint8Array): Buffer {
  return Buffer.from(eciesDecrypt(privateKeyHex, envelope));
}
