import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

const ALGO = "aes-256-gcm";
const KEY_LENGTH = 32; // AES-256
const IV_LENGTH = 12; // recommended GCM nonce size
const AUTH_TAG_LENGTH = 16;

/** Generates a random 256-bit AES-GCM key with a CSPRNG. */
export function generateAesKey(): Buffer {
  return randomBytes(KEY_LENGTH);
}

/**
 * Encrypts `plaintext` with AES-256-GCM (Node's built-in, OpenSSL-backed implementation
 * — never a hand-rolled cipher). Returns `iv || authTag || ciphertext` as one buffer, a
 * common self-contained packing so the file on disk needs no side-channel for the IV/tag.
 */
export function aesGcmEncrypt(key: Buffer, plaintext: Buffer): Buffer {
  const iv = randomBytes(IV_LENGTH);
  const cipher = createCipheriv(ALGO, key, iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const authTag = cipher.getAuthTag();
  return Buffer.concat([iv, authTag, ciphertext]);
}

/**
 * Reverses `aesGcmEncrypt`. Throws if the key is wrong or the packed blob was tampered
 * with (GCM's authentication tag covers the whole ciphertext).
 */
export function aesGcmDecrypt(key: Buffer, packed: Buffer): Buffer {
  if (packed.length < IV_LENGTH + AUTH_TAG_LENGTH) {
    throw new Error("packed ciphertext too short to contain iv + authTag");
  }
  const iv = packed.subarray(0, IV_LENGTH);
  const authTag = packed.subarray(IV_LENGTH, IV_LENGTH + AUTH_TAG_LENGTH);
  const ciphertext = packed.subarray(IV_LENGTH + AUTH_TAG_LENGTH);
  const decipher = createDecipheriv(ALGO, key, iv);
  decipher.setAuthTag(authTag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]);
}
