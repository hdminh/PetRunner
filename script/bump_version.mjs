#!/usr/bin/env node
/**
 * Bumps package.json + Support/Info.plist together.
 *
 * Usage:
 *   node script/bump_version.mjs patch
 *   node script/bump_version.mjs minor
 *   node script/bump_version.mjs major
 *   node script/bump_version.mjs 1.2.3
 *   node script/bump_version.mjs current   # keep package.json version as-is
 */
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const PACKAGE_JSON = path.join(ROOT, "package.json");
const INFO_PLIST = path.join(ROOT, "Support", "Info.plist");

export function parseSemver(version) {
  const match = String(version).trim().match(/^(\d+)\.(\d+)\.(\d+)$/);
  if (!match) throw new Error(`invalid semver: ${version}`);
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
  };
}

export function bumpSemver(current, spec) {
  const value = String(spec).trim();
  if (value === "current") return String(current).trim();
  if (/^\d+\.\d+\.\d+$/.test(value)) return value;

  const parsed = parseSemver(current);
  switch (value) {
    case "major":
      return `${parsed.major + 1}.0.0`;
    case "minor":
      return `${parsed.major}.${parsed.minor + 1}.0`;
    case "patch":
      return `${parsed.major}.${parsed.minor}.${parsed.patch + 1}`;
    default:
      throw new Error(`unsupported bump: ${spec} (use patch|minor|major|current|x.y.z)`);
  }
}

export function updateInfoPlist(contents, version, { incrementBuild = true } = {}) {
  let next = contents.replace(
    /(<key>CFBundleShortVersionString<\/key>\s*<string>)[^<]+(<\/string>)/,
    `$1${version}$2`,
  );
  const buildMatch = next.match(/<key>CFBundleVersion<\/key>\s*<string>(\d+)<\/string>/);
  if (!buildMatch) throw new Error("CFBundleVersion not found in Support/Info.plist");
  const build = incrementBuild ? String(Number(buildMatch[1]) + 1) : buildMatch[1];
  next = next.replace(
    /(<key>CFBundleVersion<\/key>\s*<string>)\d+(<\/string>)/,
    `$1${build}$2`,
  );
  return { contents: next, build };
}

export function applyBump({
  bump,
  packageJson = JSON.parse(readFileSync(PACKAGE_JSON, "utf8")),
  infoPlist = readFileSync(INFO_PLIST, "utf8"),
} = {}) {
  if (!bump) throw new Error("bump argument is required");
  const previous = packageJson.version;
  const version = bumpSemver(previous, bump);
  const keepCurrent = String(bump).trim() === "current";
  if (!keepCurrent && version === previous) {
    throw new Error(`version is already ${previous}; choose a higher bump`);
  }
  parseSemver(version);

  const nextPackage = { ...packageJson, version };
  const { contents: nextPlist, build } = updateInfoPlist(infoPlist, version, {
    incrementBuild: !keepCurrent,
  });
  return {
    previous,
    version,
    build,
    tag: `v${version}`,
    changed: !keepCurrent,
    packageJson: nextPackage,
    infoPlist: nextPlist,
  };
}

function main(argv = process.argv.slice(2)) {
  const bump = argv[0];
  if (!bump || bump === "--help" || bump === "-h") {
    console.log(`Usage: node script/bump_version.mjs <patch|minor|major|current|x.y.z>`);
    process.exit(bump ? 0 : 1);
  }

  const result = applyBump({ bump });
  writeFileSync(PACKAGE_JSON, `${JSON.stringify(result.packageJson, null, 2)}\n`);
  writeFileSync(INFO_PLIST, result.infoPlist);
  console.log(JSON.stringify({
    previous: result.previous,
    version: result.version,
    build: result.build,
    tag: result.tag,
    changed: result.changed,
  }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main();
}
