#!/usr/bin/env node

import { runCli } from "../lib/cli.js";

runCli(process.argv.slice(2)).catch((error) => {
  console.error(`pet-runner: ${error.message}`);
  process.exitCode = 1;
});
