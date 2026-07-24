import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { copyBuildPayload, parseArguments, resolveInstallPaths, terminateRunningApp, uninstall } from "../lib/cli.js";

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

test("uninstall stops the running app before removing files", async () => {
  const calls = [];
  const paths = { platform: "darwin", executable: "/pet/PetRunner", app: "/pet/App", root: "/pet/Root" };
  await uninstall({
    paths,
    fileExists: () => true,
    execute: (command, args) => calls.push(["cleanup", command, args]),
    remove: async (target) => calls.push(["remove", target]),
    terminate: () => calls.push(["terminate"]),
  });

  assert.deepEqual(calls, [
    ["terminate"],
    ["cleanup", "/pet/PetRunner", ["--agent-monitor-cleanup"]],
    ["remove", "/pet/App"],
    ["remove", "/pet/Root"],
  ]);
});

test("uninstall removes monitor hooks before deleting the macOS app", async () => {
  const calls = [];
  const paths = { platform: "darwin", executable: "/pet/PetRunner", app: "/pet/App", root: "/pet/Root" };
  await uninstall({
    paths,
    fileExists: () => true,
    execute: (command, args) => calls.push(["cleanup", command, args]),
    remove: async (target) => calls.push(["remove", target]),
    terminate: () => false,
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
      terminate: () => false,
    }),
    /app was kept in place: unsafe config/
  );
});

test("terminateRunningApp is a no-op when the app is not running", () => {
  const spawned = [];
  const wasRunning = terminateRunningApp({
    platform: "darwin",
    spawnImpl: (command, args) => {
      spawned.push([command, args]);
      return { status: 1 };
    },
  });

  assert.equal(wasRunning, false);
  assert.deepEqual(spawned, [["pgrep", ["-x", "PetRunner"]]]);
});

test("terminateRunningApp kills a running app and waits for it to exit", () => {
  const spawned = [];
  let probed = 0;
  const wasRunning = terminateRunningApp({
    platform: "darwin",
    spawnImpl: (command) => {
      spawned.push(command);
      if (command === "pgrep") {
        probed += 1;
        return { status: probed <= 2 ? 0 : 1 };
      }
      return { status: 0 };
    },
  });

  assert.equal(wasRunning, true);
  assert.deepEqual(spawned, ["pgrep", "pkill", "pgrep", "pgrep", "pgrep"]);
});

test("terminateRunningApp fails when the app refuses to exit", () => {
  assert.throws(
    () => terminateRunningApp({ platform: "darwin", spawnImpl: () => ({ status: 0 }) }),
    /still running/
  );
});

test("terminateRunningApp uses tasklist and taskkill on Windows", () => {
  const spawned = [];
  let killed = false;
  terminateRunningApp({
    platform: "win32",
    spawnImpl: (command, args) => {
      spawned.push(command);
      if (command === "tasklist") return { status: 0, stdout: killed ? "INFO: no tasks" : "PetRunner.exe 1234 Console" };
      killed = true;
      return { status: 0 };
    },
  });

  assert.deepEqual(spawned, ["tasklist", "taskkill", "tasklist", "tasklist"]);
});
