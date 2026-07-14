import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
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

const PACKAGE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const PACKAGE = JSON.parse(readFileSync(path.join(PACKAGE_ROOT, "package.json"), "utf8"));
const PAYLOAD_PATHS = [
  "Assets",
  "Sources",
  "Support",
  "windows",
];

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
  const options = { command: "start", force: false, petsDir: undefined };
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

async function copyBuildPayload(destination) {
  await rm(destination, { recursive: true, force: true });
  await mkdir(destination, { recursive: true });
  for (const item of PAYLOAD_PATHS) {
    await cp(path.join(PACKAGE_ROOT, item), path.join(destination, item), { recursive: true });
  }
  await cp(
    path.join(destination, "Support", "Package.runtime.swift"),
    path.join(destination, "Package.swift"),
  );
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

export async function install({ force = false } = {}) {
  const paths = resolveInstallPaths();
  const installed = await currentInstallation(paths);
  if (!force && installed?.version === PACKAGE.version && existsSync(paths.executable)) {
    console.log(`PetRunner ${PACKAGE.version} is already installed.`);
    return paths;
  }

  console.log(`Installing PetRunner ${PACKAGE.version} locally...`);
  await copyBuildPayload(paths.source);
  if (paths.platform === "darwin") await buildMac(paths);
  else await buildWindows(paths);

  await mkdir(paths.root, { recursive: true });
  await writeFile(paths.manifest, `${JSON.stringify({ version: PACKAGE.version, installedAt: new Date().toISOString() }, null, 2)}\n`);
  console.log(`Installed at ${paths.app}`);
  return paths;
}

export async function start({ petsDir } = {}) {
  const paths = await install();
  const appArgs = petsDir ? ["--pets-dir", petsDir] : [];

  if (paths.platform === "darwin") {
    run("open", ["-n", paths.app, ...(appArgs.length ? ["--args", ...appArgs] : [])]);
  } else {
    const child = spawn(paths.executable, appArgs, { detached: true, stdio: "ignore" });
    child.unref();
  }
  console.log("PetRunner started.");
}

export async function uninstall({
  paths = resolveInstallPaths(),
  fileExists = existsSync,
  execute = run,
  remove = rm,
} = {}) {
  if (paths.platform === "darwin" && fileExists(paths.executable)) {
    try {
      execute(paths.executable, ["--agent-monitor-cleanup"], { capture: true });
    } catch (error) {
      throw new Error(`PetRunner monitor cleanup failed; app was kept in place: ${error.message}`);
    }
  }
  await remove(paths.app, { recursive: true, force: true });
  await remove(paths.root, { recursive: true, force: true });
  console.log("PetRunner was removed.");
}

function printHelp() {
  console.log(`pet-runner ${PACKAGE.version}

Usage:
  npx pet-runner start [--pets-dir PATH]
  npx pet-runner install [--force]
  npx pet-runner update
  npx pet-runner uninstall

"start" installs/builds PetRunner automatically on first use.`);
}

export async function runCli(argv) {
  const options = parseArguments(argv);
  switch (options.command) {
    case "start":
      await start(options);
      break;
    case "install":
      await install(options);
      break;
    case "update":
      await install({ force: true });
      break;
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
      throw new Error(`unknown command: ${options.command}. Run npx pet-runner --help`);
  }
}
