import assert from "node:assert/strict";
import test from "node:test";

import { doctor, parseArguments, resolveInstallPaths, setup, uninstall } from "../lib/cli.js";

test("start is the default command", () => {
  assert.deepEqual(parseArguments([]), {
    command: "start",
    force: false,
    petsDir: undefined,
    enableAgentMonitor: false,
  });
});

test("reports missing Rust prerequisites with remediation", () => {
  const report = doctor({
    platform: "darwin",
    commandAvailable: (command) => command === "xcode-select" || command === "swift",
  });
  assert.equal(report.checks.find((check) => check.name === "Rust cargo")?.available, false);
  assert.match(report.checks.find((check) => check.name === "Rust cargo")?.remediation ?? "", /setup/);
});

test("reports the selected Rust target separately", () => {
  const report = doctor({
    platform: "win32",
    architecture: "x64",
    commandAvailable: (command, args) => command !== "rustc" || args?.includes("target-libdir") !== true,
  });
  assert.equal(report.rustTarget, "x86_64-pc-windows-msvc");
  assert.equal(report.checks.find((check) => check.name === "Rust target x86_64-pc-windows-msvc")?.available, false);
});

test("setup never runs an installer without consent", async () => {
  const calls = [];
  await setup({
    platform: "darwin",
    commandAvailable: () => false,
    confirm: async () => false,
    execute: (...args) => calls.push(args),
  });
  assert.deepEqual(calls, []);
});

test("setup asks for the Rust toolchain once when both cargo and rustc are missing", async () => {
  const prompts = [];
  const calls = [];
  await setup({
    platform: "darwin",
    commandAvailable: (command) => command === "xcode-select" || command === "swift",
    confirm: async (question) => {
      prompts.push(question);
      return true;
    },
    execute: (...args) => calls.push(args),
  });

  assert.deepEqual(prompts, ["The Rust toolchain is missing. Install it now?"]);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], "/bin/sh");
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
