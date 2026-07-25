import { existsSync, readdirSync, readFileSync } from "node:fs";
import { mkdir, writeFile, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { createPrompter } from "./prompt.js";
import { createStyle } from "./style.js";

export const USAGE_PROVIDERS = ["claude", "codex", "cursor"];
export const MONITOR_PROVIDERS = ["claude", "codex", "cursor"];

export function defaultPetsDirectory({
  env = process.env,
  home = os.homedir(),
  platform = process.platform,
} = {}) {
  const pathApi = platform === "win32" ? path.win32 : path;
  const codexHome = (env.CODEX_HOME || "").trim();
  if (codexHome) {
    return pathApi.resolve(codexHome.replace(/^~(?=$|[/\\])/, home), "pets");
  }
  return pathApi.join(home, ".codex", "pets");
}

export function cliSetupPath({
  platform = process.platform,
  env = process.env,
  home = os.homedir(),
} = {}) {
  const pathApi = platform === "win32" ? path.win32 : path;
  if (platform === "darwin") {
    return pathApi.join(home, "Library", "Application Support", "PetRunner", "cli-setup.json");
  }
  if (platform === "win32") {
    const localAppData = env.LOCALAPPDATA || pathApi.join(home, "AppData", "Local");
    return pathApi.join(localAppData, "PetRunner", "cli-setup.json");
  }
  throw new Error(`unsupported platform: ${platform}`);
}

export function windowsSettingsPath({
  env = process.env,
  home = os.homedir(),
} = {}) {
  const localAppData = env.LOCALAPPDATA || path.win32.join(home, "AppData", "Local");
  return path.win32.join(localAppData, "PetRunner", "settings.json");
}

export function listPets(petsDir) {
  if (!existsSync(petsDir)) return [];
  const entries = readdirSync(petsDir, { withFileTypes: true });
  const pets = [];
  for (const entry of entries) {
    if (!entry.isDirectory() && !entry.isSymbolicLink()) continue;
    const packageDir = path.join(petsDir, entry.name);
    const manifestPath = path.join(packageDir, "pet.json");
    if (!existsSync(manifestPath)) continue;
    try {
      const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
      const id = typeof manifest.id === "string" && manifest.id.trim() ? manifest.id.trim() : entry.name;
      const displayName = typeof manifest.displayName === "string" && manifest.displayName.trim()
        ? manifest.displayName.trim()
        : id;
      pets.push({ id, displayName, packageDir });
    } catch {
      // Skip unreadable manifests; the app validates packages more strictly later.
    }
  }
  return pets.sort((left, right) => left.displayName.localeCompare(right.displayName));
}

export function detectProviderInstalls({ home = os.homedir() } = {}) {
  const checks = {
    claude: [".claude", path.join(".claude", "settings.json")],
    codex: [".codex", path.join(".codex", "hooks.json")],
    cursor: [".cursor", path.join(".cursor", "hooks.json")],
  };
  return Object.fromEntries(
    Object.entries(checks).map(([provider, relatives]) => [
      provider,
      relatives.some((relative) => existsSync(path.join(home, relative))),
    ]),
  );
}

export function shouldRunInteractiveSetup({
  yes = false,
  noSetup = false,
  forceSetup = false,
  isTTY = Boolean(process.stdin.isTTY && process.stdout.isTTY),
  setupExists,
  platform = process.platform,
  env = process.env,
  home = os.homedir(),
} = {}) {
  if (noSetup || yes) return false;
  if (forceSetup) return true;
  if (!isTTY) return false;
  const alreadyConfigured = setupExists ?? existsSync(cliSetupPath({ platform, env, home }));
  return !alreadyConfigured;
}

export function normalizeSetupAnswers(raw = {}, { platform = process.platform } = {}) {
  const petsDirectory = typeof raw.petsDirectory === "string" && raw.petsDirectory.trim()
    ? path.resolve(raw.petsDirectory.trim().replace(/^~(?=$|[/\\])/, os.homedir()))
    : undefined;
  const selectedPetID = typeof raw.selectedPetID === "string" && raw.selectedPetID.trim()
    ? raw.selectedPetID.trim()
    : undefined;

  const usageProviders = {};
  for (const provider of USAGE_PROVIDERS) {
    if (platform === "win32" && provider === "cursor") {
      usageProviders[provider] = false;
      continue;
    }
    const value = raw.usageProviders?.[provider];
    usageProviders[provider] = value === undefined ? true : Boolean(value);
  }

  let monitorEnabled = Boolean(raw.monitorEnabled);
  let monitorProvider = typeof raw.monitorProvider === "string" ? raw.monitorProvider : undefined;
  if (platform !== "darwin") {
    monitorEnabled = false;
    monitorProvider = undefined;
  } else if (monitorEnabled && !MONITOR_PROVIDERS.includes(monitorProvider)) {
    monitorEnabled = false;
    monitorProvider = undefined;
  }

  return {
    version: 1,
    petsDirectory: petsDirectory ?? null,
    selectedPetID: selectedPetID ?? null,
    monitorEnabled,
    monitorProvider: monitorEnabled ? monitorProvider : null,
    usageProviders,
    autonomyEnabled: raw.autonomyEnabled === undefined ? true : Boolean(raw.autonomyEnabled),
    showsStatusItem: raw.showsStatusItem === undefined ? true : Boolean(raw.showsStatusItem),
  };
}

export async function writeCLISetup(answers, options = {}) {
  const setup = normalizeSetupAnswers(answers, options);
  const destination = options.path || cliSetupPath(options);
  await mkdir(path.dirname(destination), { recursive: true });
  await writeFile(destination, `${JSON.stringify(setup, null, 2)}\n`);
  return { path: destination, setup };
}

export async function readCLISetup(options = {}) {
  const destination = options.path || cliSetupPath(options);
  try {
    return JSON.parse(await readFile(destination, "utf8"));
  } catch {
    return undefined;
  }
}

export async function clearCLISetup(options = {}) {
  const destination = options.path || cliSetupPath(options);
  await rm(destination, { force: true });
}

/** Apply Windows settings.json directly from Node (no headless WPF apply path). */
export async function applyWindowsSettingsFromSetup(setup, options = {}) {
  const settingsFile = options.settingsPath || windowsSettingsPath(options);
  let current = {};
  try {
    current = JSON.parse(await readFile(settingsFile, "utf8"));
  } catch {
    current = {};
  }

  if (setup.petsDirectory) current.PetsDirectory = setup.petsDirectory;
  if (setup.selectedPetID) current.SelectedPetId = setup.selectedPetID;
  if (setup.autonomyEnabled !== undefined) current.AutonomyEnabled = setup.autonomyEnabled;
  current.ClaudeEnabled = setup.usageProviders?.claude !== false;
  current.CodexEnabled = setup.usageProviders?.codex !== false;

  await mkdir(path.dirname(settingsFile), { recursive: true });
  await writeFile(settingsFile, `${JSON.stringify(current, null, 2)}\n`);
  await clearCLISetup({ ...options, path: options.path || cliSetupPath(options) });
  return current;
}

function printSetupBanner(style) {
  const rule = style.dim("────────────────────────────────────────");
  console.log("");
  console.log(`${style.brand("PetRunner")} ${style.title("setup")}`);
  console.log(rule);
  console.log(style.hint("Answer once; PetRunner applies these on launch."));
  console.log(style.hint("Skip later with --yes / --no-setup, or re-run with setup / --setup."));
  console.log("");
}

function printSetupSummary(style, setup, destination) {
  const on = (value) => (value ? style.green("on") : style.dim("off"));
  const usage = Object.entries(setup.usageProviders || {})
    .filter(([, enabled]) => enabled)
    .map(([name]) => providerLabel(name))
    .join(", ") || style.dim("none");

  console.log("");
  console.log(style.success("✓ Setup saved"));
  console.log(`  ${style.dim("file")}      ${destination}`);
  console.log(`  ${style.dim("pets")}      ${setup.petsDirectory || style.dim("(default)")}`);
  console.log(`  ${style.dim("pet")}       ${setup.selectedPetID || style.dim("auto")}`);
  if (setup.monitorEnabled) {
    console.log(`  ${style.dim("monitor")}   ${providerLabel(setup.monitorProvider)}`);
  } else {
    console.log(`  ${style.dim("monitor")}   ${on(false)}`);
  }
  console.log(`  ${style.dim("usage")}     ${usage}`);
  console.log(`  ${style.dim("autonomy")}  ${on(setup.autonomyEnabled)}`);
  console.log(`  ${style.dim("menu bar")}  ${on(setup.showsStatusItem)}`);
  console.log("");
}

export async function runInteractiveSetup({
  platform = process.platform,
  petsDir,
  env = process.env,
  home = os.homedir(),
  style = createStyle(),
  prompter = createPrompter({ style }),
} = {}) {
  try {
    const defaultPets = petsDir || defaultPetsDirectory({ env, home, platform });
    printSetupBanner(style);

    const petsDirectoryAnswer = await prompter.ask("Pets directory", { defaultValue: defaultPets });
    const petsDirectory = path.resolve(petsDirectoryAnswer.replace(/^~(?=$|[/\\])/, home));
    const pets = listPets(petsDirectory);

    const petChoices = [
      ...pets.map((pet) => ({
        value: pet.id,
        label: `${pet.displayName} ${style.dim(`(${pet.id})`)}`,
      })),
      {
        value: "",
        label: pets.length === 0
          ? "Auto (seed bundled maomao on first launch)"
          : "Auto (keep current / first available)",
      },
    ];
    const selectedPetID = await prompter.select("Which pet should appear on the desktop?", petChoices, {
      defaultIndex: petChoices.length - 1,
    });

    let monitorEnabled = false;
    let monitorProvider;
    if (platform === "darwin") {
      monitorEnabled = await prompter.confirm("Enable Agent Monitor (session bubbles beside the pet)?", {
        defaultYes: false,
      });
      if (monitorEnabled) {
        const detected = detectProviderInstalls({ home });
        monitorProvider = await prompter.select(
          "Monitor which coding agent?",
          MONITOR_PROVIDERS.map((provider) => ({
            value: provider,
            label: `${providerLabel(provider)}${detected[provider] ? style.green(" · detected") : ""}`,
          })),
          { defaultIndex: preferredMonitorIndex(detected) },
        );
      }
    } else {
      console.log(style.hint("Agent Monitor is macOS-only; skipping."));
    }

    const usageChoices = USAGE_PROVIDERS
      .filter((provider) => !(platform === "win32" && provider === "cursor"))
      .map((provider) => ({
        value: provider,
        label: `${providerLabel(provider)} ${style.dim("— session / project / model cost reports")}`,
      }));
    const enabledUsage = await prompter.multiSelect(
      "Which providers should feed Usage & Analytics?",
      usageChoices,
      { defaults: usageChoices.map((choice) => choice.value) },
    );
    const usageProviders = Object.fromEntries(
      USAGE_PROVIDERS.map((provider) => [provider, enabledUsage.includes(provider)]),
    );

    const autonomyEnabled = await prompter.confirm("Enable autonomous pet motion?", { defaultYes: true });
    const showsStatusItem = platform === "darwin"
      ? await prompter.confirm("Show the menu bar paw icon?", { defaultYes: true })
      : true;

    const answers = {
      petsDirectory,
      selectedPetID: selectedPetID || undefined,
      monitorEnabled,
      monitorProvider,
      usageProviders,
      autonomyEnabled,
      showsStatusItem,
    };

    const written = await writeCLISetup(answers, { platform, env, home });
    printSetupSummary(style, written.setup, written.path);
    return written.setup;
  } finally {
    await prompter.close();
  }
}

function providerLabel(provider) {
  switch (provider) {
    case "claude":
      return "Claude Code";
    case "codex":
      return "Codex";
    case "cursor":
      return "Cursor";
    default:
      return provider;
  }
}

function preferredMonitorIndex(detected) {
  const order = MONITOR_PROVIDERS;
  const detectedIndex = order.findIndex((provider) => detected[provider]);
  return detectedIndex >= 0 ? detectedIndex : 0;
}
