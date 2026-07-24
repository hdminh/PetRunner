import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  applyWindowsSettingsFromSetup,
  defaultPetsDirectory,
  detectProviderInstalls,
  listPets,
  normalizeSetupAnswers,
  shouldRunInteractiveSetup,
  writeCLISetup,
} from "../lib/setup.js";
import { parseArguments } from "../lib/cli.js";

test("interactive setup runs on TTY unless skipped", () => {
  assert.equal(shouldRunInteractiveSetup({ isTTY: true }), true);
  assert.equal(shouldRunInteractiveSetup({ isTTY: true, yes: true }), false);
  assert.equal(shouldRunInteractiveSetup({ isTTY: true, noSetup: true }), false);
  assert.equal(shouldRunInteractiveSetup({ isTTY: false }), false);
  assert.equal(shouldRunInteractiveSetup({ isTTY: false, forceSetup: true }), true);
});

test("parses setup skip and force flags", () => {
  assert.deepEqual(parseArguments(["start", "--yes"]), {
    command: "start",
    force: false,
    petsDir: undefined,
    yes: true,
    noSetup: false,
    setup: false,
  });
  assert.equal(parseArguments(["install", "--setup"]).setup, true);
  assert.equal(parseArguments(["setup"]).command, "setup");
});

test("default pets directory honors CODEX_HOME", () => {
  assert.equal(
    defaultPetsDirectory({ env: { CODEX_HOME: "/tmp/codex-home" }, home: "/Users/pet", platform: "darwin" }),
    "/tmp/codex-home/pets",
  );
  assert.equal(
    defaultPetsDirectory({ env: {}, home: "/Users/pet", platform: "darwin" }),
    "/Users/pet/.codex/pets",
  );
});

test("lists pets from pet.json packages", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "pet-runner-pets-"));
  try {
    const packageDir = path.join(root, "maomao");
    await mkdir(packageDir);
    await writeFile(path.join(packageDir, "pet.json"), JSON.stringify({
      id: "maomao",
      displayName: "大开门",
    }));
    assert.deepEqual(listPets(root), [{
      id: "maomao",
      displayName: "大开门",
      packageDir,
    }]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("detects provider installs from home markers", async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), "pet-runner-home-"));
  try {
    await mkdir(path.join(home, ".codex"));
    await writeFile(path.join(home, ".codex", "hooks.json"), "{}");
    const detected = detectProviderInstalls({ home });
    assert.equal(detected.codex, true);
    assert.equal(detected.claude, false);
    assert.equal(detected.cursor, false);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test("normalizes setup answers and strips monitor on Windows", () => {
  const mac = normalizeSetupAnswers({
    petsDirectory: "~/pets",
    selectedPetID: "maomao",
    monitorEnabled: true,
    monitorProvider: "cursor",
    usageProviders: { claude: true, codex: false, cursor: true },
    autonomyEnabled: false,
    showsStatusItem: false,
  }, { platform: "darwin" });
  assert.equal(mac.monitorEnabled, true);
  assert.equal(mac.monitorProvider, "cursor");
  assert.equal(mac.usageProviders.codex, false);

  const win = normalizeSetupAnswers({
    monitorEnabled: true,
    monitorProvider: "codex",
    usageProviders: { claude: true, codex: true, cursor: true },
  }, { platform: "win32" });
  assert.equal(win.monitorEnabled, false);
  assert.equal(win.monitorProvider, null);
  assert.equal(win.usageProviders.cursor, false);
});

test("writes cli-setup.json and applies Windows settings", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "pet-runner-setup-"));
  try {
    const setupPath = path.join(root, "cli-setup.json");
    const settingsPath = path.join(root, "settings.json");
    const { setup } = await writeCLISetup({
      petsDirectory: path.join(root, "pets"),
      selectedPetID: "maomao",
      monitorEnabled: false,
      usageProviders: { claude: true, codex: false, cursor: false },
      autonomyEnabled: true,
      showsStatusItem: true,
    }, { path: setupPath, platform: "win32" });

    assert.equal(setup.selectedPetID, "maomao");
    assert.equal(JSON.parse(await readFile(setupPath, "utf8")).version, 1);

    const settings = await applyWindowsSettingsFromSetup(setup, {
      path: setupPath,
      settingsPath,
      platform: "win32",
    });
    assert.equal(settings.SelectedPetId, "maomao");
    assert.equal(settings.ClaudeEnabled, true);
    assert.equal(settings.CodexEnabled, false);
    await assert.rejects(readFile(setupPath), /ENOENT/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
