import { createHash } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import {
  cp,
  mkdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  applyWindowsSettingsFromSetup,
  readCLISetup,
  runInteractiveSetup,
  shouldRunInteractiveSetup,
  writeCLISetup,
} from "./setup.js";
import { createStyle } from "./style.js";

const PACKAGE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const PACKAGE = JSON.parse(readFileSync(path.join(PACKAGE_ROOT, "package.json"), "utf8"));
const STYLE = createStyle();
const PAYLOAD_PATHS = [
  "Assets",
  "DashboardWeb",
  "Sources",
  "Support",
  "windows",
];

/// Fingerprint of local package sources so `start` rebuilds when git/checkout
/// content changes even if package.json version is unchanged.
export function packageBuildStamp(packageRoot = PACKAGE_ROOT) {
  const hash = createHash("sha256");
  hash.update(PACKAGE.version);
  const contentHashedPrefixes = ["Sources/", "Support/", "windows/", "DashboardWeb/src/"];
  for (const relative of PAYLOAD_PATHS) {
    const root = path.join(packageRoot, relative);
    if (!existsSync(root)) continue;
    const stack = [root];
    while (stack.length > 0) {
      const current = stack.pop();
      let entries;
      try {
        entries = readdirSync(current, { withFileTypes: true });
      } catch {
        continue;
      }
      entries.sort((left, right) => left.name.localeCompare(right.name));
      for (const entry of entries) {
        if (entry.name === "node_modules" || entry.name === "dist" || entry.name === ".build" || entry.name === "bin" || entry.name === "obj") {
          continue;
        }
        const full = path.join(current, entry.name);
        const rel = path.relative(packageRoot, full).split(path.sep).join("/");
        if (entry.isDirectory()) {
          stack.push(full);
          continue;
        }
        if (!entry.isFile()) continue;
        try {
          const stats = statSync(full);
          hash.update(`${rel}:${stats.size}\n`);
          if (contentHashedPrefixes.some((prefix) => rel.startsWith(prefix))) {
            hash.update(readFileSync(full));
          } else {
            hash.update(String(stats.mtimeMs));
          }
        } catch {
          // Skip unreadable files; install still copies what it can.
        }
      }
    }
  }
  return hash.digest("hex").slice(0, 16);
}

export function resolveInstallPaths({
  platform = process.platform,
  env = process.env,
  home = os.homedir(),
  version = PACKAGE.version,
} = {}) {
  const pathApi = platform === "win32" ? path.win32 : path;
  if (platform === "darwin") {
    const root = pathApi.join(home, "Library", "Application Support", "PetRunner");
    return {
      platform,
      root,
      source: pathApi.join(root, "source", version),
      manifest: pathApi.join(root, "installation.json"),
      executable: pathApi.join(home, "Applications", "PetRunner.app", "Contents", "MacOS", "PetRunner"),
      app: pathApi.join(home, "Applications", "PetRunner.app"),
    };
  }

  if (platform === "win32") {
    const localAppData = env.LOCALAPPDATA || pathApi.join(home, "AppData", "Local");
    const root = pathApi.join(localAppData, "PetRunner");
    return {
      platform,
      root,
      source: pathApi.join(root, "source", version),
      manifest: pathApi.join(root, "installation.json"),
      executable: pathApi.join(root, "app", "PetRunner.exe"),
      app: pathApi.join(root, "app"),
    };
  }

  throw new Error(`unsupported platform: ${platform}. PetRunner supports macOS and Windows.`);
}

export function parseArguments(argv) {
  const options = {
    command: "start",
    force: false,
    petsDir: undefined,
    yes: false,
    noSetup: false,
    setup: false,
  };
  const args = [...argv];

  if (args[0] && !args[0].startsWith("-")) {
    options.command = args.shift();
  }

  while (args.length > 0) {
    const argument = args.shift();
    if (argument === "--force") {
      options.force = true;
    } else if (argument === "--pets-dir") {
      const value = args.shift();
      if (!value) throw new Error("--pets-dir requires a directory path");
      options.petsDir = path.resolve(value);
    } else if (argument === "--yes" || argument === "-y") {
      options.yes = true;
    } else if (argument === "--no-setup") {
      options.noSetup = true;
    } else if (argument === "--setup") {
      options.setup = true;
    } else if (argument === "--help" || argument === "-h") {
      options.command = "help";
    } else if (argument === "--version" || argument === "-v") {
      options.command = "version";
    } else {
      throw new Error(`unknown option: ${argument}`);
    }
  }

  return options;
}

function commandExists(command, args = ["--version"]) {
  const result = spawnSync(command, args, { stdio: "ignore" });
  return !result.error && result.status === 0;
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    encoding: "utf8",
    stdio: options.capture ? ["ignore", "pipe", "pipe"] : "inherit",
  });

  if (result.error) {
    throw new Error(`could not run ${command}: ${result.error.message}`);
  }
  if (result.status !== 0) {
    const detail = options.capture ? (result.stderr || result.stdout || "").trim() : "";
    throw new Error(`${command} exited with code ${result.status}${detail ? `: ${detail}` : ""}`);
  }
  return options.capture ? result.stdout.trim() : "";
}

async function currentInstallation(paths) {
  try {
    return JSON.parse(await readFile(paths.manifest, "utf8"));
  } catch {
    return undefined;
  }
}

function probeRunning(platform, spawnImpl) {
  if (platform === "darwin") {
    const result = spawnImpl("pgrep", ["-x", "PetRunner"], { stdio: "ignore" });
    return !result.error && result.status === 0;
  }
  const result = spawnImpl("tasklist", ["/FI", "IMAGENAME eq PetRunner.exe", "/NH"], { encoding: "utf8" });
  return !result.error && result.status === 0 && result.stdout.includes("PetRunner.exe");
}

function terminateCommand(platform) {
  return platform === "darwin"
    ? { command: "pkill", args: ["-x", "PetRunner"] }
    : { command: "taskkill", args: ["/IM", "PetRunner.exe", "/F"] };
}

export function terminateRunningApp({
  platform = process.platform,
  spawnImpl = spawnSync,
} = {}) {
  // A stale process keeps the old version on screen, holds the single-instance
  // lock, and (on Windows) locks the executable, so stop it before replacing it.
  if (!probeRunning(platform, spawnImpl)) return false;
  const { command, args } = terminateCommand(platform);
  const result = spawnImpl(command, args, { stdio: "ignore" });
  if (result.error) {
    throw new Error(`could not stop a running PetRunner: ${result.error.message}`);
  }
  const nap = new Int32Array(new SharedArrayBuffer(4));
  for (let i = 0; i < 50 && probeRunning(platform, spawnImpl); i += 1) {
    Atomics.wait(nap, 0, 0, 100);
  }
  if (probeRunning(platform, spawnImpl)) {
    throw new Error("PetRunner is still running. Quit it from the menu bar, then try again.");
  }
  return true;
}

export async function copyBuildPayload(destination, packageRoot = PACKAGE_ROOT) {
  await rm(destination, { recursive: true, force: true });
  await mkdir(destination, { recursive: true });
  for (const item of PAYLOAD_PATHS) {
    await cp(path.join(packageRoot, item), path.join(destination, item), { recursive: true });
  }
  await cp(
    path.join(destination, "Support", "Package.runtime.swift"),
    path.join(destination, "Package.swift"),
  );
}

function buildDashboard(packageRoot = PACKAGE_ROOT) {
  run("npm", ["run", "dashboard:build"], { cwd: packageRoot });
}

async function buildMac(paths) {
  if (!commandExists("xcode-select", ["-p"]) || !commandExists("swift")) {
    throw new Error("Xcode Command Line Tools are required. Install them with: xcode-select --install");
  }

  run("swift", ["build", "-c", "release"], { cwd: paths.source });
  const binPath = run("swift", ["build", "-c", "release", "--show-bin-path"], {
    cwd: paths.source,
    capture: true,
  });

  await rm(paths.app, { recursive: true, force: true });
  await mkdir(path.join(paths.app, "Contents", "MacOS"), { recursive: true });
  await mkdir(path.join(paths.app, "Contents", "Resources"), { recursive: true });
  await cp(path.join(binPath, "PetRunner"), paths.executable);
  await cp(path.join(paths.source, "Support", "Info.plist"), path.join(paths.app, "Contents", "Info.plist"));
  await cp(path.join(paths.source, "Assets", "AppIcon.icns"), path.join(paths.app, "Contents", "Resources", "AppIcon.icns"));
  await cp(path.join(paths.source, "Assets", "DefaultPets"), path.join(paths.app, "Contents", "Resources", "DefaultPets"), { recursive: true });
  await cp(path.join(paths.source, "DashboardWeb", "dist"), path.join(paths.app, "Contents", "Resources", "DashboardWeb"), { recursive: true });
  run("chmod", ["+x", paths.executable]);
  run("codesign", ["--force", "--deep", "--sign", "-", paths.app]);
}

async function buildWindows(paths) {
  if (!commandExists("dotnet", ["--info"])) {
    throw new Error(".NET 10 SDK is required: https://dotnet.microsoft.com/download/dotnet/10.0");
  }

  await rm(paths.app, { recursive: true, force: true });
  await mkdir(paths.app, { recursive: true });
  run("dotnet", [
    "publish",
    path.join(paths.source, "windows", "PetRunner.Windows", "PetRunner.Windows.csproj"),
    "-c", "Release",
    "--self-contained", "false",
    "-p:PublishSingleFile=false",
    "-o", paths.app,
  ], { cwd: paths.source });
}

export async function maybeRunSetup(options = {}) {
  if (options.command === "setup") {
    return runInteractiveSetup({ petsDir: options.petsDir });
  }

  if (!shouldRunInteractiveSetup({
    yes: options.yes,
    noSetup: options.noSetup,
    forceSetup: options.setup,
  })) {
    return undefined;
  }

  return runInteractiveSetup({ petsDir: options.petsDir });
}

export async function applyPendingSetup(paths = resolveInstallPaths()) {
  const pending = await readCLISetup({ platform: paths.platform });
  if (!pending) return false;

  if (paths.platform === "darwin") {
    if (!existsSync(paths.executable)) {
      throw new Error("PetRunner is not installed yet; cannot apply setup.");
    }
    run(paths.executable, ["--apply-cli-setup"], { capture: true });
    return true;
  }

  await applyWindowsSettingsFromSetup(pending, { platform: paths.platform });
  return true;
}

export async function install({ force = false, terminate = terminateRunningApp } = {}) {
  const paths = resolveInstallPaths();
  const installed = await currentInstallation(paths);
  const buildStamp = packageBuildStamp();
  if (
    !force
    && installed?.version === PACKAGE.version
    && installed?.buildStamp === buildStamp
    && existsSync(paths.executable)
  ) {
    console.log(STYLE.hint(`PetRunner ${PACKAGE.version} is already installed.`));
    return paths;
  }

  if (!force && installed?.version === PACKAGE.version && installed?.buildStamp !== buildStamp) {
    console.log(STYLE.cyan(`Local sources changed since the last install; rebuilding PetRunner ${PACKAGE.version}...`));
  } else {
    console.log(STYLE.cyan(`Installing PetRunner ${PACKAGE.version} locally...`));
  }
  const wasRunning = terminate({ platform: paths.platform });
  buildDashboard();
  await copyBuildPayload(paths.source);
  if (paths.platform === "darwin") await buildMac(paths);
  else await buildWindows(paths);

  await mkdir(paths.root, { recursive: true });
  await writeFile(
    paths.manifest,
    `${JSON.stringify({
      version: PACKAGE.version,
      buildStamp,
      installedAt: new Date().toISOString(),
    }, null, 2)}\n`,
  );
  console.log(STYLE.success(`Installed at ${paths.app}`));
  return { ...paths, wasRunning };
}

function launchApp(paths, petsDir) {
  const appArgs = ["--background", ...(petsDir ? ["--pets-dir", petsDir] : [])];
  if (paths.platform === "darwin") {
    run("open", ["-n", "-g", paths.app, "--args", ...appArgs]);
  } else {
    const child = spawn(paths.executable, appArgs, { detached: true, stdio: "ignore" });
    child.unref();
  }
}

export async function start({ petsDir, yes, noSetup, setup, force = false } = {}) {
  await maybeRunSetup({ command: "start", petsDir, yes, noSetup, setup });
  const paths = await install({ force });
  await applyPendingSetup(paths);
  launchApp(paths, petsDir);
  console.log(STYLE.success("PetRunner started."));
}

export async function uninstall({
  paths = resolveInstallPaths(),
  fileExists = existsSync,
  execute = run,
  remove = rm,
  terminate = terminateRunningApp,
} = {}) {
  terminate({ platform: paths.platform });
  if (paths.platform === "darwin" && fileExists(paths.executable)) {
    try {
      execute(paths.executable, ["--agent-monitor-cleanup"], { capture: true });
    } catch (error) {
      throw new Error(`PetRunner monitor cleanup failed; app was kept in place: ${error.message}`);
    }
  }
  await remove(paths.app, { recursive: true, force: true });
  await remove(paths.root, { recursive: true, force: true });
  console.log(STYLE.success("PetRunner was removed."));
}

function printHelp() {
  const s = STYLE;
  const cmd = (text) => s.cyan(text);
  const flag = (text) => s.green(text);
  console.log(`${s.brand("pet-runner")} ${s.dim(PACKAGE.version)}

${s.title("Usage")}
  ${cmd("npx @hdminh/pet-runner")} ${s.dim("<command>")} ${s.dim("[options]")}

${s.title("Commands")}
  ${cmd("start")}       Build if needed, run setup when first-time, then launch
  ${cmd("install")}     Build/install locally without launching
  ${cmd("setup")}       Interactive preferences wizard
  ${cmd("update")}      Force rebuild; restart if PetRunner was running
  ${cmd("uninstall")}   Stop PetRunner and remove the local install
  ${cmd("help")}        Show this help ${s.dim("(-h, --help)")}
  ${cmd("version")}     Print package version ${s.dim("(-v, --version)")}

${s.title("Options")}
  ${flag("--pets-dir")} ${s.dim("<path>")}   Override pets directory for this run
  ${flag("--force")}              Rebuild even when already installed
  ${flag("--yes")}, ${flag("-y")}           Skip interactive setup
  ${flag("--no-setup")}           Same as --yes for setup skipping
  ${flag("--setup")}              Force the setup wizard again
  ${flag("-h")}, ${flag("--help")}           Show help
  ${flag("-v")}, ${flag("--version")}        Show version

${s.title("Setup")}
  First TTY start/install opens a colored wizard (pets dir, selected pet,
  Agent Monitor on macOS, usage providers, autonomy, menu bar).
  Answers are saved and reused; re-run ${cmd("setup")} or pass ${flag("--setup")}.`);
}

export async function runCli(argv) {
  const options = parseArguments(argv);
  switch (options.command) {
    case "start":
      await start(options); // options.force rebuilds when local sources changed or --force
      break;
    case "install":
      await maybeRunSetup(options);
      {
        const paths = await install(options);
        await applyPendingSetup(paths);
      }
      break;
    case "setup":
      await maybeRunSetup({ ...options, command: "setup" });
      if (existsSync(resolveInstallPaths().executable)) {
        await applyPendingSetup();
        console.log(STYLE.success("Setup applied to the installed PetRunner."));
      } else {
        console.log(STYLE.hint("Setup saved. Run start/install to build PetRunner and apply it."));
      }
      break;
    case "update": {
      const paths = await install({ force: true });
      if (paths.wasRunning) {
        launchApp(paths);
        console.log(STYLE.success("PetRunner restarted."));
      }
      break;
    }
    case "uninstall":
      await uninstall();
      break;
    case "help":
      printHelp();
      break;
    case "version":
      console.log(PACKAGE.version);
      break;
    default:
      throw new Error(`unknown command: ${options.command}. Run npx @hdminh/pet-runner --help`);
  }
}

export { writeCLISetup };
