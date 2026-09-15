import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, unlinkSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const [dispatcher] = process.argv.slice(2);
assert.ok(dispatcher, "expected the npm-bin dispatcher path");
const helper = resolve(dispatcher);
const root = mkdtempSync(join(tmpdir(), "wasmono-npm-bin-"));
const manifest = join(root, "package.json");
const args = [
  "componentize", "source with spaces.js", "--wit",
  String.raw`C:\Users\Example User\project\api.wit`, "--out",
  String.raw`\\server\share\output file.wasm`, "--option=value", "--", "",
  "single ' and double \" quotes", "$literal %PATH% & | ^", "\u96ea",
];

function setBin(bin) {
  writeFileSync(manifest, JSON.stringify({
    name: "@bytecodealliance/jco", version: "1.24.3", type: "module", bin,
  }));
}

function invoke(binName, arguments_ = []) {
  const result = spawnSync(
    process.execPath,
    [helper, root, binName, ...arguments_],
    { encoding: "utf8", shell: false, windowsHide: true, timeout: 30_000 },
  );

  if (result.error) {
    throw result.error;
  }

  assert.equal(result.signal, null, result.stderr);
  return result;
}

function checkCli(entry, marker, arguments_, exitCode = 0) {
  const result = invoke("jco", arguments_);
  assert.equal(result.status, exitCode, result.stderr);
  // Node preserves argv[1], but module URLs resolve filesystem links.
  assert.deepEqual(JSON.parse(result.stdout), {
    args: arguments_, argv0: process.execPath, argv1: join(root, entry),
    modulePath: realpathSync(join(root, entry)), marker,
  });
}

function checkFailure(binName, error) {
  const result = invoke(binName);
  assert.notEqual(result.status, 0, "invalid entrypoint unexpectedly succeeded");
  assert.match(result.stderr, error);
}

try {
  mkdirSync(join(root, "src"));
  writeFileSync(join(root, "report.mjs"), `
    import { fileURLToPath } from "node:url";
    export function report(moduleUrl, marker) {
      const args = process.argv.slice(2);
      if (args[0] === "--exit-code") process.exitCode = Number(args[1]);
      console.log(JSON.stringify({
        args, argv0: process.argv[0], argv1: process.argv[1],
        modulePath: fileURLToPath(moduleUrl), marker,
      }));
    }
  `);
  writeFileSync(join(root, "src/value.js"), 'export const marker = "relative-src-import";');
  writeFileSync(join(root, "src/jco.js"), `
    import { marker } from "./value.js";
    import { report } from "../report.mjs";
    report(import.meta.url, marker);
  `);
  writeFileSync(join(root, "cli with #%.mjs"), `
    import { report } from "./report.mjs";
    report(import.meta.url, "string-bin-import");
  `);

  setBin({ jco: "src/jco.js" });
  checkCli("src/jco.js", "relative-src-import", []);
  checkCli("src/jco.js", "relative-src-import", args);
  checkCli("src/jco.js", "relative-src-import", ["--exit-code", "17"], 17);
  checkFailure("unknown", /does not declare a valid "unknown" bin/);

  // Junctions do not require symlink privileges on Windows.
  symlinkSync(join(root, "src"), join(root, "linked-src"), "junction");
  setBin({ jco: "linked-src/jco.js" });
  checkCli("linked-src/jco.js", "relative-src-import", args);

  setBin("cli with #%.mjs");
  checkCli("cli with #%.mjs", "string-bin-import", args);
  checkFailure("other", /does not declare a valid "other" bin/);

  for (const [bin, error] of [
    [undefined, /does not declare a valid "jco" bin/],
    [{ jco: 42 }, /does not declare a valid "jco" bin/],
    [{ jco: "missing.mjs" }, /ERR_MODULE_NOT_FOUND/],
  ]) {
    setBin(bin);
    checkFailure("jco", error);
  }

  unlinkSync(manifest);
  checkFailure("jco", /ENOENT/);
  console.log("npm-bin layout, argv, imports, and failure checks passed");
} finally {
  rmSync(root, { recursive: true, force: true });
}
