/**
 * Pads an encrypted-document blob up to a fixed size bucket, so its on-disk/on-wire size
 * doesn't leak the real document's size to an observer. This is data framing, not a
 * cryptographic primitive: a 4-byte big-endian length prefix records the real length, the
 * rest is zero-padding up to the bucket boundary.
 */
const BUCKETS_BYTES = [4, 16, 64, 256, 1024, 4096].map((kib) => kib * 1024);

function bucketFor(length: number): number {
  const LENGTH_PREFIX = 4;
  const needed = length + LENGTH_PREFIX;
  const bucket = BUCKETS_BYTES.find((b) => b >= needed);
  if (bucket !== undefined) return bucket;
  // Larger than the biggest named bucket: round up to the next multiple of it instead of
  // falling back to no padding at all.
  const largest = BUCKETS_BYTES[BUCKETS_BYTES.length - 1]!;
  return Math.ceil(needed / largest) * largest;
}

export function padToBucket(data: Buffer): Buffer {
  const bucket = bucketFor(data.length);
  const out = Buffer.alloc(bucket);
  out.writeUInt32BE(data.length, 0);
  data.copy(out, 4);
  return out;
}

export function unpadFromBucket(padded: Buffer): Buffer {
  if (padded.length < 4) throw new Error("padded blob too short to contain a length prefix");
  const length = padded.readUInt32BE(0);
  if (4 + length > padded.length) {
    throw new Error("padded blob's length prefix exceeds the actual blob size");
  }
  return padded.subarray(4, 4 + length);
}

export const DOC_PADDING_BUCKETS_BYTES = BUCKETS_BYTES;
