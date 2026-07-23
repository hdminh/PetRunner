import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  root: "DashboardWeb",
  cacheDir: "../node_modules/.vitest-dashboard",
  plugins: [react()],
  test: { environment: "jsdom", include: ["src/**/*.test.{ts,tsx}"] },
});
