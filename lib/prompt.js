import readline from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";

import { createStyle } from "./style.js";

export function createPrompter({
  inputStream = input,
  outputStream = output,
  isTTY = Boolean(inputStream.isTTY && outputStream.isTTY),
  style = createStyle({ stream: outputStream }),
} = {}) {
  const rl = readline.createInterface({ input: inputStream, output: outputStream, terminal: isTTY });
  let closed = false;

  function write(text) {
    outputStream.write(text);
  }

  function writeln(text = "") {
    write(`${text}\n`);
  }

  async function ask(question, { defaultValue } = {}) {
    const hint = defaultValue === undefined
      ? ""
      : ` ${style.hint(`[${defaultValue}]`)}`;
    const answer = (await rl.question(`${style.label(question)}${hint}: `)).trim();
    return answer === "" && defaultValue !== undefined ? defaultValue : answer;
  }

  async function confirm(question, { defaultYes = false } = {}) {
    const hint = defaultYes ? "Y/n" : "y/N";
    const answer = (await ask(`${question} ${style.hint(`(${hint})`)}`)).toLowerCase();
    if (answer === "") return defaultYes;
    return answer === "y" || answer === "yes";
  }

  async function select(question, choices, { defaultIndex = 0 } = {}) {
    if (choices.length === 0) {
      throw new Error("select requires at least one choice");
    }
    writeln(style.label(question));
    choices.forEach((choice, index) => {
      const selected = index === defaultIndex;
      const marker = selected ? style.green("❯") : style.dim(" ");
      const number = style.cyan(String(index + 1));
      const label = selected ? style.bold(choice.label) : choice.label;
      const tag = selected ? ` ${style.hint("(default)")}` : "";
      writeln(`  ${marker} ${number}) ${label}${tag}`);
    });
    const answer = await ask("Choice", { defaultValue: String(defaultIndex + 1) });
    const index = Number.parseInt(answer, 10) - 1;
    if (!Number.isInteger(index) || index < 0 || index >= choices.length) {
      writeln(style.yellow("Invalid choice; using default."));
      return choices[defaultIndex].value;
    }
    return choices[index].value;
  }

  async function multiSelect(question, choices, { defaults = [] } = {}) {
    const selected = new Set(defaults);
    writeln(style.label(question));
    writeln(style.hint("  Toggle with numbers or ids; comma-separated. Enter keeps the defaults."));
    choices.forEach((choice, index) => {
      const on = selected.has(choice.value);
      const box = on ? style.green("[x]") : style.dim("[ ]");
      const number = style.cyan(String(index + 1));
      writeln(`  ${box} ${number}) ${choice.label}`);
    });
    const ids = choices.map((choice) => choice.value).join(",");
    const answer = await ask("Enable which?", {
      defaultValue: [...selected].join(",") || ids,
    });
    if (answer.trim() === "") return [...selected];

    const next = new Set();
    for (const token of answer.split(",").map((part) => part.trim()).filter(Boolean)) {
      const asNumber = Number.parseInt(token, 10);
      if (Number.isInteger(asNumber) && asNumber >= 1 && asNumber <= choices.length) {
        next.add(choices[asNumber - 1].value);
        continue;
      }
      const match = choices.find((choice) => choice.value === token || choice.value === token.toLowerCase());
      if (match) next.add(match.value);
    }
    return next.size > 0 ? [...next] : [...selected];
  }

  async function close() {
    if (closed) return;
    closed = true;
    rl.close();
    // readline keeps stdin flowing; pause so the CLI process can exit.
    if (typeof inputStream.pause === "function") {
      inputStream.pause();
    }
  }

  return { ask, confirm, select, multiSelect, close, isTTY, style };
}
