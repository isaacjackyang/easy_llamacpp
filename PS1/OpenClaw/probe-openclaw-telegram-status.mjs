import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

function readArg(name, fallback) {
  const index = process.argv.indexOf(name);
  if (index < 0 || index + 1 >= process.argv.length) {
    return fallback;
  }

  return process.argv[index + 1];
}

function resolveOpenClawCallModule() {
  const appData = process.env.APPDATA;
  if (!appData) {
    throw new Error("APPDATA is not set");
  }

  const distDir = path.join(appData, "npm", "node_modules", "openclaw", "dist");
  const files = fs.readdirSync(distDir).filter((name) => /^call-.*\.js$/i.test(name));
  for (const name of files) {
    const fullPath = path.join(distDir, name);
    const text = fs.readFileSync(fullPath, "utf8");
    if (text.includes("function callGateway") || text.includes("async function callGateway")) {
      return fullPath;
    }
  }

  throw new Error(`Cannot find OpenClaw callGateway module in ${distDir}`);
}

process.env.OPENCLAW_SKIP_BUNDLED_RUNTIME_DEPS = "1";
process.env.OPENCLAW_SKIP_PLUGIN_SERVICES = "1";
process.env.OPENCLAW_SKIP_STARTUP_MODEL_PREWARM = "1";
process.env.OPENCLAW_PLUGIN_STAGE_DIR = process.env.OPENCLAW_PLUGIN_STAGE_DIR || "F:\\Documents\\GitHub\\easy_llamacpp\\.openclaw-plugin-stage";
process.env.OPENCLAW_TELEGRAM_SKIP_NATIVE_COMMANDS = "1";
process.env.OPENCLAW_TELEGRAM_DISABLE_AUTO_SELECT_FAMILY = "1";
process.env.OPENCLAW_TELEGRAM_DNS_RESULT_ORDER = "ipv4first";
process.env.OPENCLAW_TELEGRAM_FORCE_IPV4 = "1";

const timeoutMs = Math.max(1000, Number(readArg("--timeout-ms", "8000")) || 8000);
const callModulePath = resolveOpenClawCallModule();
const mod = await import(pathToFileURL(callModulePath).href);
const callGateway = mod.r ?? mod.callGateway;
if (typeof callGateway !== "function") {
  throw new Error(`OpenClaw callGateway export not found in ${callModulePath}`);
}

const payload = await callGateway({
  method: "channels.status",
  params: {
    probe: false,
    timeoutMs
  },
  timeoutMs
});

process.stdout.write(JSON.stringify(payload));
