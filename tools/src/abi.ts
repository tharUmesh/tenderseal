import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import type { Abi } from "viem";

const __dirname = dirname(fileURLToPath(import.meta.url));
// tools/src/ -> ../.. -> repo root -> out/ (forge's compiled artifacts). Loaded at runtime
// rather than hand-copied, so the ABI can never drift from what's actually deployed.
const REPO_ROOT = join(__dirname, "..", "..");

function loadAbi(artifactRelPath: string): Abi {
  const fullPath = join(REPO_ROOT, "out", artifactRelPath);
  let json: { abi: Abi };
  try {
    json = JSON.parse(readFileSync(fullPath, "utf8"));
  } catch (err) {
    throw new Error(
      `Could not read compiled artifact at ${fullPath}. Run "forge build" in the repo root first.\n${String(err)}`,
    );
  }
  return json.abi;
}

export const tenderAbi: Abi = loadAbi("Tender.sol/Tender.json");
export const tenderFactoryAbi: Abi = loadAbi("TenderFactory.sol/TenderFactory.json");
export const vendorRegistryAbi: Abi = loadAbi("VendorRegistry.sol/VendorRegistry.json");
