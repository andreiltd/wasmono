import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [packageDirectory, binName, ...args] = process.argv.slice(2);

if (!packageDirectory || !binName) {
  throw new Error("Usage: npm_bin.mjs <package-directory> <bin-name> [args...]");
}

const packageJsonPath = resolve(packageDirectory, "package.json");
const manifest = JSON.parse(await readFile(packageJsonPath, "utf8"));

if (manifest === null || typeof manifest !== "object" || Array.isArray(manifest)) {
  throw new Error(`Invalid npm package metadata in ${packageJsonPath}`);
}

let entry;

if (typeof manifest.bin === "string") {
  if (typeof manifest.name === "string" && manifest.name.split("/").pop() === binName) {
    entry = manifest.bin;
  }
} else if (
  manifest.bin !== null &&
  typeof manifest.bin === "object" &&
  !Array.isArray(manifest.bin) &&
  Object.hasOwn(manifest.bin, binName)
) {
  entry = manifest.bin[binName];
}

if (typeof entry !== "string" || entry.length === 0) {
  throw new Error(`${packageJsonPath} does not declare a valid "${binName}" bin`);
}

const cliPath = resolve(packageDirectory, entry);
process.argv = [process.argv[0], cliPath, ...args];

// Import in place to preserve the CLI's package-relative imports.
await import(pathToFileURL(cliPath).href);
