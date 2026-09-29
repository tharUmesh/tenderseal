import { randomBytes } from "node:crypto";
import { bytesToHex, type Hex } from "viem";

/** A 256-bit salt (SPEC §5). */
export type Salt = Hex;

/**
 * Generates a 256-bit salt with a CSPRNG (Node's `crypto.randomBytes`, backed by the
 * platform's OS-level CSPRNG — not a custom PRNG).
 */
export function generateSalt(): Salt {
  return bytesToHex(randomBytes(32));
}
