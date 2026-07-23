import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { copyBuildPayload, parseArguments, resolveInstallPaths, uninstall } from "../lib/cli.js";

test("start is the default command", () => {
  assert.deepEqual(parseArguments([]), {
    command: "start",
    force: false,
    petsDir: undefined,
  });
});

test("bin entrypoint reports the package version", () => {
  const output = execFileSync(process.execPath, ["bin/pet-runner.js", "--version"], { encoding: "utf8" });
  const packageVersion = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).version;
  assert.equal(output.trim(), packageVersion);
});

test("npm package allow-list includes the dashboard", () => {
  const packageJson = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
  assert.equal(packageJson.files.includes("DashboardWeb/"), true);
  assert.equal(packageJson.files.includes("Assets/"), true);
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

test("build payload includes local dashboard assets", async () => {
  const fixtureRoot = await mkdtemp(path.join(os.tmpdir(), "pet-runner-package-"));
  const destination = path.join(fixtureRoot, "destination");

  try {
    for (const directory of ["Assets", "DashboardWeb", "Sources", "Support", "windows"]) {
      await mkdir(path.join(fixtureRoot, directory), { recursive: true });
      await writeFile(path.join(fixtureRoot, directory, ".fixture"), directory);
    }
    await writeFile(path.join(fixtureRoot, "DashboardWeb", "index.html"), "dashboard");
    await writeFile(path.join(fixtureRoot, "Support", "Package.runtime.swift"), "manifest");

    await copyBuildPayload(destination, fixtureRoot);

    assert.equal(readFileSync(path.join(destination, "DashboardWeb", "index.html"), "utf8"), "dashboard");
    assert.equal(readFileSync(path.join(destination, "Package.swift"), "utf8"), "manifest");
    assert.equal(existsSync(path.join(destination, "DashboardWeb", ".fixture")), true);
  } finally {
    await rm(fixtureRoot, { recursive: true, force: true });
  }
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
