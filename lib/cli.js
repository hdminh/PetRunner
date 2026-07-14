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
  "Cargo.lock",
  "Cargo.toml",
  "Sources",
  "Support",
  "rust",
  "rust-toolchain.toml",
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
  const options = { command: "start", force: false, petsDir: undefined, enableAgentMonitor: false };
  const args = [...argv];

  if (args[0] && !args[0].startsWith("-")) {
    options.command = args.shift();
  }

  while (args.length > 0) {
    const argument = args.shift();
    if (argument === "--force") {
      options.force = true;
    } else if (argument === "--enable-agent-monitor") {
      options.enableAgentMonitor = true;
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

export function doctor({
  platform = process.platform,
  architecture = process.arch,
  commandAvailable = commandExists,
} = {}) {
  if (platform !== "darwin" && platform !== "win32") {
    throw new Error(`unsupported platform: ${platform}. PetRunner supports macOS and Windows.`);
  }
  const rustTarget = platform === "win32"
    ? "x86_64-pc-windows-msvc"
    : architecture === "arm64" ? "aarch64-apple-darwin" : "x86_64-apple-darwin";
  const checks = platform === "darwin"
    ? [
        ["Xcode Command Line Tools", commandAvailable("xcode-select", ["-p"]), "Run: xcode-select --install"],
        ["Swift", commandAvailable("swift"), "Install Xcode Command Line Tools"],
        ["Rust cargo", commandAvailable("cargo"), "Run: pet-runner setup"],
        ["Rust compiler", commandAvailable("rustc"), "Run: pet-runner setup"],
        [`Rust target ${rustTarget}`, commandAvailable("rustc", ["--print", "target-libdir", "--target", rustTarget]), `Install Rust with ${rustTarget} target support`],
      ]
    : [
        [".NET 10 SDK", commandAvailable("dotnet", ["--info"]), "Run: winget install Microsoft.DotNet.SDK.10"],
        ["Rust cargo", commandAvailable("cargo"), "Run: pet-runner setup"],
        ["Rust compiler", commandAvailable("rustc"), "Run: pet-runner setup"],
        [`Rust target ${rustTarget}`, commandAvailable("rustc", ["--print", "target-libdir", "--target", rustTarget]), `Install Rust with ${rustTarget} target support`],
      ];
  return {
    platform,
    architecture,
    rustTarget,
    checks: checks.map(([name, available, remediation]) => ({ name, available, remediation })),
  };
}

function printDoctor(result) {
  console.log(`PetRunner prerequisite report (${result.platform}/${result.architecture})`);
  for (const check of result.checks) {
    console.log(`${check.available ? "OK" : "MISSING"}  ${check.name}${check.available ? "" : ` — ${check.remediation}`}`);
  }
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

function requireCommand(command, message, args = ["--version"]) {
  if (!commandExists(command, args)) throw new Error(message);
}

async function buildMac(paths) {
  requireCommand("xcode-select", "Xcode Command Line Tools are required. Run: xcode-select --install", ["-p"]);
  requireCommand("swift", "Swift is required. Install Xcode Command Line Tools.");
  requireCommand("cargo", "Rust cargo is required. Run: pet-runner setup");
  requireCommand("rustc", "Rust compiler is required. Run: pet-runner setup");

  run("cargo", ["build", "--release", "-p", "petrunner-bridge"], { cwd: paths.source });
  run("swift", ["build", "-c", "release"], { cwd: paths.source });
  const binPath = run("swift", ["build", "-c", "release", "--show-bin-path"], {
    cwd: paths.source,
    capture: true,
  });

  await rm(paths.app, { recursive: true, force: true });
  await mkdir(path.join(paths.app, "Contents", "MacOS"), { recursive: true });
  await mkdir(path.join(paths.app, "Contents", "Frameworks"), { recursive: true });
  await mkdir(path.join(paths.app, "Contents", "Resources"), { recursive: true });
  await cp(path.join(binPath, "PetRunner"), paths.executable);
  await cp(path.join(paths.source, "target", "release", "libpetrunner_bridge.dylib"), path.join(paths.app, "Contents", "Frameworks", "libpetrunner_bridge.dylib"));
  await cp(path.join(paths.source, "Support", "Info.plist"), path.join(paths.app, "Contents", "Info.plist"));
  await cp(path.join(paths.source, "Assets", "AppIcon.icns"), path.join(paths.app, "Contents", "Resources", "AppIcon.icns"));
  run("chmod", ["+x", paths.executable]);
  run("codesign", ["--force", "--deep", "--sign", "-", paths.app]);
}

async function buildWindows(paths) {
  requireCommand("dotnet", ".NET 10 SDK is required. Run: winget install Microsoft.DotNet.SDK.10", ["--info"]);
  requireCommand("cargo", "Rust cargo is required. Run: pet-runner setup");
  requireCommand("rustc", "Rust compiler is required. Run: pet-runner setup");
  requireCommand("rustc", "Rust Windows x64 target is required. Run: pet-runner setup", ["--print", "target-libdir", "--target", "x86_64-pc-windows-msvc"]);

  await rm(paths.app, { recursive: true, force: true });
  await mkdir(paths.app, { recursive: true });
  run("cargo", ["build", "--release", "--target", "x86_64-pc-windows-msvc", "-p", "petrunner-bridge"], { cwd: paths.source });
  run("dotnet", [
    "publish",
    path.join(paths.source, "windows", "PetRunner.Windows", "PetRunner.Windows.csproj"),
    "-c", "Release",
    "--self-contained", "false",
    "-p:PublishSingleFile=false",
    "-o", paths.app,
  ], { cwd: paths.source });
  await cp(path.join(paths.source, "target", "x86_64-pc-windows-msvc", "release", "petrunner_bridge.dll"), path.join(paths.app, "petrunner_bridge.dll"));
}

async function configureAgentMonitor(paths, { execute = run } = {}) {
  if (paths.platform !== "darwin") {
    throw new Error("--enable-agent-monitor is currently available only on macOS; no Windows provider configuration was changed.");
  }
  execute("open", ["-W", "-n", paths.app, "--args", "--configure-agent-monitor"]);
}

export async function install({ force = false, enableAgentMonitor = false } = {}) {
  const paths = resolveInstallPaths();
  const installed = await currentInstallation(paths);
  if (!force && installed?.version === PACKAGE.version && existsSync(paths.executable)) {
    console.log(`PetRunner ${PACKAGE.version} is already installed.`);
    if (enableAgentMonitor) await configureAgentMonitor(paths);
    return paths;
  }

  console.log(`Installing PetRunner ${PACKAGE.version} locally...`);
  await copyBuildPayload(paths.source);
  if (paths.platform === "darwin") await buildMac(paths);
  else await buildWindows(paths);

  await mkdir(paths.root, { recursive: true });
  await writeFile(paths.manifest, `${JSON.stringify({ version: PACKAGE.version, installedAt: new Date().toISOString() }, null, 2)}\n`);
  console.log(`Installed at ${paths.app}`);
  if (enableAgentMonitor) await configureAgentMonitor(paths);
  return paths;
}

export async function start({ petsDir, enableAgentMonitor = false } = {}) {
  const paths = await install({ enableAgentMonitor });
  const appArgs = petsDir ? ["--pets-dir", petsDir] : [];

  if (paths.platform === "darwin") {
    run("open", ["-n", paths.app, ...(appArgs.length ? ["--args", ...appArgs] : [])]);
  } else {
    const child = spawn(paths.executable, appArgs, { detached: true, stdio: "ignore" });
    child.unref();
  }
  console.log("PetRunner started.");
}

export async function setup({
  platform = process.platform,
  confirm = async () => false,
  execute = run,
  commandAvailable = commandExists,
} = {}) {
  const report = doctor({ platform, commandAvailable });
  const missing = new Set(report.checks.filter((check) => !check.available).map((check) => check.name));
  const rustToolchainMissing = missing.has("Rust cargo") || missing.has("Rust compiler");
  const rustTargetCheck = `Rust target ${report.rustTarget}`;
  const actions = platform === "darwin"
    ? [
        missing.has("Xcode Command Line Tools") && {
          question: "Xcode Command Line Tools are missing. Install them now?",
          command: "xcode-select",
          args: ["--install"],
        },
        rustToolchainMissing && {
          question: "The Rust toolchain is missing. Install it now?",
          command: "/bin/sh",
          args: ["-c", "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"],
        },
        !rustToolchainMissing && missing.has(rustTargetCheck) && {
          question: `Rust target ${report.rustTarget} is missing. Install it now?`,
          command: "rustup",
          args: ["target", "add", report.rustTarget],
        },
      ]
    : [
        missing.has(".NET 10 SDK") && {
          question: ".NET 10 SDK is missing. Install it now?",
          command: "winget",
          args: ["install", "--id", "Microsoft.DotNet.SDK.10", "--exact"],
        },
        rustToolchainMissing && {
          question: "The Rust toolchain is missing. Install it now?",
          command: "winget",
          args: ["install", "--id", "Rustlang.Rustup", "--exact"],
        },
        !rustToolchainMissing && missing.has(rustTargetCheck) && {
          question: `Rust target ${report.rustTarget} is missing. Install it now?`,
          command: "rustup",
          args: ["target", "add", report.rustTarget],
        },
      ];

  for (const action of actions.filter(Boolean)) {
    if (await confirm(action.question)) execute(action.command, action.args);
  }
  return report;
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
  npx pet-runner start [--pets-dir PATH] [--enable-agent-monitor]
  npx pet-runner install [--force] [--enable-agent-monitor]
  npx pet-runner update
  npx pet-runner doctor
  npx pet-runner setup
  npx pet-runner uninstall

"start" installs/builds PetRunner automatically on first use. "setup" asks before every installer; normal installation never runs one automatically.`);
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
    case "doctor":
      printDoctor(doctor());
      break;
    case "setup":
      if (!process.stdin.isTTY || !process.stdout.isTTY) {
        throw new Error("pet-runner setup requires an interactive terminal so it can request consent for each installer.");
      }
      {
        const { createInterface } = await import("node:readline/promises");
        const prompt = createInterface({ input: process.stdin, output: process.stdout });
        try {
          await setup({ confirm: async (question) => /^(y|yes)$/i.test((await prompt.question(`${question} [y/N] `)).trim()) });
        } finally {
          prompt.close();
        }
      }
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
