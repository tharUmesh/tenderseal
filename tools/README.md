# TenderSeal off-chain tools

Node + TypeScript + [viem](https://viem.sh) (SPEC §10 Step 9a). No cryptographic
primitives are implemented here: salts and AES keys come from Node's built-in CSPRNG
(`crypto.randomBytes`), hashing/ABI-encoding from `viem`, AES-256-GCM from Node's
built-in (OpenSSL-backed) `crypto` module, and ECIES key-wrapping from
[`eciesjs`](https://github.com/ecies/js) (secp256k1, matching SPEC §3's 33-byte
compressed `evaluatorEncKeys`).

See the repo root [README.md](../README.md#off-chain-tools) for commands and the
cross-language test vector. `src/` layout:

```
crypto/commitment.ts   SPEC §5 price commitment: keccak256(abi.encode(...))
crypto/salt.ts          256-bit CSPRNG salt
crypto/aesGcm.ts         AES-256-GCM encrypt/decrypt (Node's built-in crypto)
crypto/docPadding.ts    bucket-padding so ciphertext size doesn't leak document size
crypto/ecies.ts          ECIES key-wrapping for evaluators (eciesjs)
abi.ts                  loads compiled ABIs from ../out/ (forge build output)
docs.ts                 encryptDocument()/decryptDocument() (SPEC §6.4, §8)
receipt.ts              CLI: generate a bidder's private bid receipt
bruteforce.ts            CLI: zero-salt vs. real-salt search demo
docsEncrypt.ts / docsDecrypt.ts   CLIs for the document-encryption flow
verify.ts                CLI: public verifier (fetches events, independently re-checks)
verifier/                verifier's event reconstruction + individual checks (V1-V8)
genCommitmentVector.ts   generates tools/fixtures/commitment-vector.json
```

Requires `forge build` to have been run at least once (the ABI loader and the verifier
read compiled artifacts from `../out/`).
