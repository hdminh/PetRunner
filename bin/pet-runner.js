#!/usr/bin/env node

import { runCli } from "../lib/cli.js";

runCli(process.argv.slice(2))
  .then(() => {
    // Explicit exit: setup/readline can leave stdin open and keep Node alive.
    process.exit(process.exitCode ?? 0);
  })
  .catch((error) => {
    console.error(`pet-runner: ${error.message}`);
    process.exit(1);
  });
