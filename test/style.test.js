import assert from "node:assert/strict";
import test from "node:test";

import { createStyle, supportsColor } from "../lib/style.js";

test("supportsColor respects NO_COLOR and FORCE_COLOR", () => {
  assert.equal(supportsColor({ stream: { isTTY: true }, env: { NO_COLOR: "1" } }), false);
  assert.equal(supportsColor({ stream: { isTTY: false }, env: { FORCE_COLOR: "1" } }), true);
  assert.equal(supportsColor({ stream: { isTTY: true }, env: {} }), true);
  assert.equal(supportsColor({ stream: { isTTY: false }, env: {} }), false);
});

test("createStyle paints only when enabled", () => {
  const colored = createStyle({ enabled: true });
  const plain = createStyle({ enabled: false });
  assert.match(colored.green("ok"), /\u001b\[32mok\u001b\[0m/);
  assert.equal(plain.green("ok"), "ok");
  assert.equal(plain.brand("PetRunner"), "PetRunner");
});
