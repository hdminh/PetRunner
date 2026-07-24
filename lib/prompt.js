import readline from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";

export function createPrompter({
  inputStream = input,
  outputStream = output,
  isTTY = Boolean(inputStream.isTTY && outputStream.isTTY),
} = {}) {
  const rl = readline.createInterface({ input: inputStream, output: outputStream, terminal: isTTY });

  async function ask(question, { defaultValue } = {}) {
    const suffix = defaultValue === undefined ? "" : ` [${defaultValue}]`;
    const answer = (await rl.question(`${question}${suffix}: `)).trim();
    return answer === "" && defaultValue !== undefined ? defaultValue : answer;
  }

  async function confirm(question, { defaultYes = false } = {}) {
    const hint = defaultYes ? "Y/n" : "y/N";
    const answer = (await ask(`${question} (${hint})`)).toLowerCase();
    if (answer === "") return defaultYes;
    return answer === "y" || answer === "yes";
  }

  async function select(question, choices, { defaultIndex = 0 } = {}) {
    if (choices.length === 0) {
      throw new Error("select requires at least one choice");
    }
    outputStream.write(`${question}\n`);
    choices.forEach((choice, index) => {
      const marker = index === defaultIndex ? "*" : " ";
      outputStream.write(`  ${marker}${index + 1}) ${choice.label}\n`);
    });
    const answer = await ask("Choice", { defaultValue: String(defaultIndex + 1) });
    const index = Number.parseInt(answer, 10) - 1;
    if (!Number.isInteger(index) || index < 0 || index >= choices.length) {
      outputStream.write("Invalid choice; using default.\n");
      return choices[defaultIndex].value;
    }
    return choices[index].value;
  }

  async function multiSelect(question, choices, { defaults = [] } = {}) {
    const selected = new Set(defaults);
    outputStream.write(`${question}\n`);
    choices.forEach((choice, index) => {
      const on = selected.has(choice.value) ? "on" : "off";
      outputStream.write(`  ${index + 1}) ${choice.label} [${on}]\n`);
    });
    const ids = choices.map((choice) => choice.value).join(",");
    const answer = await ask("Enable which? comma-separated ids/numbers", {
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
    rl.close();
  }

  return { ask, confirm, select, multiSelect, close, isTTY };
}
