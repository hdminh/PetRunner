import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  root: "DashboardWeb",
  cacheDir: "../node_modules/.vitest-dashboard",
  plugins: [react()],
  // Pure unit tests; jsdom hangs worker startup in some local Node installs.
  test: { environment: "node", include: ["src/**/*.test.{ts,tsx}"] },
});
