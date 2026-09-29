import { encodeAbiParameters, keccak256, type Address, type Hex } from "viem";

/** Inputs to the SPEC §5 price commitment, mirroring `Tender.commit`/`revealPrice`. */
export interface CommitmentInput {
  /** `block.chainid` of the target chain. */
  chainId: bigint;
  /** The Tender contract's own address (`address(this)`). */
  tender: Address;
  /** The bidder's address. */
  bidder: Address;
  /** Price in the deposit token's base units (> 0). */
  price: bigint;
  /** The bid's current `docHash` (SPEC §5: hash of the encrypted technical documents). */
  docHash: Hex;
  /** 256-bit random salt (the only source of hiding — SPEC §5). */
  salt: Hex;
}

const COMMITMENT_ABI_TYPES = [
  { type: "uint256" },
  { type: "address" },
  { type: "address" },
  { type: "uint256" },
  { type: "bytes32" },
  { type: "bytes32" },
] as const;

/**
 * `keccak256(abi.encode(chainid, tender, bidder, price, docHash, salt))` — SPEC §5,
 * verbatim. Uses viem's `encodeAbiParameters` (ABI-spec-compliant static-type encoding,
 * byte-for-byte identical to Solidity's `abi.encode` for these six static types) and
 * `keccak256` — never a hand-rolled hash or encoder.
 */
export function computeCommitment(input: CommitmentInput): Hex {
  const encoded = encodeAbiParameters(COMMITMENT_ABI_TYPES, [
    input.chainId,
    input.tender,
    input.bidder,
    input.price,
    input.docHash,
    input.salt,
  ]);
  return keccak256(encoded);
}
