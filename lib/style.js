const RESET = "\u001b[0m";

const CODES = {
  bold: "\u001b[1m",
  dim: "\u001b[2m",
  cyan: "\u001b[36m",
  green: "\u001b[32m",
  yellow: "\u001b[33m",
  magenta: "\u001b[35m",
  red: "\u001b[31m",
  white: "\u001b[37m",
};

export function supportsColor({
  stream = process.stdout,
  env = process.env,
} = {}) {
  if (env.NO_COLOR != null && env.NO_COLOR !== "") return false;
  if (env.FORCE_COLOR != null && env.FORCE_COLOR !== "0") return true;
  return Boolean(stream && stream.isTTY);
}

function paint(code, text, enabled) {
  if (!enabled) return String(text);
  return `${code}${text}${RESET}`;
}

export function createStyle(options = {}) {
  const enabled = options.enabled ?? supportsColor(options);
  return {
    enabled,
    bold: (text) => paint(CODES.bold, text, enabled),
    dim: (text) => paint(CODES.dim, text, enabled),
    cyan: (text) => paint(CODES.cyan, text, enabled),
    green: (text) => paint(CODES.green, text, enabled),
    yellow: (text) => paint(CODES.yellow, text, enabled),
    magenta: (text) => paint(CODES.magenta, text, enabled),
    red: (text) => paint(CODES.red, text, enabled),
    white: (text) => paint(CODES.white, text, enabled),
    brand: (text) => paint(`${CODES.bold}${CODES.green}`, text, enabled),
    success: (text) => paint(`${CODES.bold}${CODES.green}`, text, enabled),
    title: (text) => paint(`${CODES.bold}${CODES.cyan}`, text, enabled),
    label: (text) => paint(CODES.bold, text, enabled),
    hint: (text) => paint(CODES.dim, text, enabled),
    accent: (text) => paint(CODES.magenta, text, enabled),
  };
}
