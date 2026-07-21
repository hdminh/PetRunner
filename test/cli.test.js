import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import test from "node:test";

import { parseArguments, resolveInstallPaths, uninstall } from "../lib/cli.js";

test("start is the default command", () => {
  assert.deepEqual(parseArguments([]), {
    command: "start",
    force: false,
    petsDir: undefined,
  });
});

test("bin entrypoint reports the package version", () => {
  const output = execFileSync(process.execPath, ["bin/pet-runner.js", "--version"], { encoding: "utf8" });
  assert.equal(output.trim(), "0.2.0");
});

test("parses a custom pet directory", () => {
  const parsed = parseArguments(["start", "--pets-dir", "fixtures/pets"]);
  assert.equal(parsed.command, "start");
  assert.equal(parsed.petsDir.endsWith("fixtures/pets"), true);
});

test("uses the per-user macOS application directories", () => {
  const paths = resolveInstallPaths({ platform: "darwin", home: "/Users/pet", version: "1.2.3" });
  assert.equal(paths.source, "/Users/pet/Library/Application Support/PetRunner/source/1.2.3");
  assert.equal(paths.app, "/Users/pet/Applications/PetRunner.app");
});

test("uses LOCALAPPDATA on Windows", () => {
  const paths = resolveInstallPaths({
    platform: "win32",
    env: { LOCALAPPDATA: "C:\\Users\\pet\\AppData\\Local" },
    home: "C:\\Users\\pet",
    version: "1.2.3",
  });
  assert.equal(paths.root, "C:\\Users\\pet\\AppData\\Local\\PetRunner");
  assert.equal(paths.executable.endsWith("PetRunner\\app\\PetRunner.exe"), true);
});

test("rejects unsupported platforms", () => {
  assert.throws(() => resolveInstallPaths({ platform: "linux" }), /unsupported platform/);
});

test("uninstall removes monitor hooks before deleting the macOS app", async () => {
  const calls = [];
  const paths = { platform: "darwin", executable: "/pet/PetRunner", app: "/pet/App", root: "/pet/Root" };
  await uninstall({
    paths,
    fileExists: () => true,
    execute: (command, args) => calls.push(["cleanup", command, args]),
    remove: async (target) => calls.push(["remove", target]),
  });

  assert.deepEqual(calls, [
    ["cleanup", "/pet/PetRunner", ["--agent-monitor-cleanup"]],
    ["remove", "/pet/App"],
    ["remove", "/pet/Root"],
  ]);
});

test("uninstall keeps the app when monitor cleanup fails", async () => {
  await assert.rejects(
    uninstall({
      paths: { platform: "darwin", executable: "/pet/PetRunner", app: "/pet/App", root: "/pet/Root" },
      fileExists: () => true,
      execute: () => { throw new Error("unsafe config"); },
      remove: async () => assert.fail("must not delete after cleanup failure"),
    }),
    /app was kept in place: unsafe config/
  );
});
