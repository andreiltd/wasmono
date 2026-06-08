import { spawn } from "node:child_process";
import { copyFile, mkdir, rm } from "node:fs/promises";
import { join } from "node:path";

const [out, packageJson, packageLock, ...npm] = process.argv.slice(2);

await rm(out, { recursive: true, force: true });
await mkdir(out, { recursive: true });
await copyFile(packageJson, join(out, "package.json"));
await copyFile(packageLock, join(out, "package-lock.json"));

const child = spawn(
  npm[0],
  [...npm.slice(1), "ci", "--prefix", out, "--ignore-scripts", "--no-audit", "--no-fund"],
  { stdio: "inherit" },
);

child.on("error", (err) => {
  console.error(err);
  process.exit(1);
});

child.on("exit", (code, signal) => {
  if (signal) {
    console.error(`npm ci terminated by ${signal}`);
    process.exit(1);
  }
  process.exit(code ?? 1);
});
