import assert from "node:assert/strict";
import test from "node:test";

import { applyBump, bumpSemver, updateInfoPlist } from "../script/bump_version.mjs";

test("bumps semver levels and exact versions", () => {
  assert.equal(bumpSemver("1.2.3", "patch"), "1.2.4");
  assert.equal(bumpSemver("1.2.3", "minor"), "1.3.0");
  assert.equal(bumpSemver("1.2.3", "major"), "2.0.0");
  assert.equal(bumpSemver("1.2.3", "9.8.7"), "9.8.7");
  assert.throws(() => bumpSemver("1.2.3", "nope"), /unsupported bump/);
});

test("updates Info.plist marketing and build versions", () => {
  const plist = `  <key>CFBundleShortVersionString</key>
  <string>0.3.3</string>
  <key>CFBundleVersion</key>
  <string>7</string>
`;
  const updated = updateInfoPlist(plist, "0.3.4");
  assert.equal(updated.build, "8");
  assert.match(updated.contents, /<string>0\.3\.4<\/string>/);
  assert.match(updated.contents, /<string>8<\/string>/);
});

test("applyBump rewrites package metadata", () => {
  const result = applyBump({
    bump: "patch",
    packageJson: { name: "@hdminh/pet-runner", version: "0.3.4" },
    infoPlist: `  <key>CFBundleShortVersionString</key>
  <string>0.3.4</string>
  <key>CFBundleVersion</key>
  <string>8</string>
`,
  });
  assert.equal(result.previous, "0.3.4");
  assert.equal(result.version, "0.3.5");
  assert.equal(result.tag, "v0.3.5");
  assert.equal(result.packageJson.version, "0.3.5");
  assert.equal(result.build, "9");
  assert.equal(result.changed, true);
});

test("current keeps the existing package version", () => {
  const result = applyBump({
    bump: "current",
    packageJson: { name: "@hdminh/pet-runner", version: "0.3.4" },
    infoPlist: `  <key>CFBundleShortVersionString</key>
  <string>0.3.4</string>
  <key>CFBundleVersion</key>
  <string>8</string>
`,
  });
  assert.equal(result.version, "0.3.4");
  assert.equal(result.build, "8");
  assert.equal(result.changed, false);
});
