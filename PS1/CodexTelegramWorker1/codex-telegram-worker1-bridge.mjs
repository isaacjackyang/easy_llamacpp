import fs from "node:fs/promises";
import path from "node:path";

const easyRoot = process.env.EASY_LLAMACPP_ROOT || "F:\\Documents\\GitHub\\easy_llamacpp";
const stateDir = process.env.CODEX_TELEGRAM_WORKER1_STATE_DIR || path.join(easyRoot, ".codex-telegram-worker1");
const tokenFile = process.env.CODEX_TELEGRAM_WORKER1_TOKEN_FILE || path.join(process.env.USERPROFILE || "", ".openclaw", "credentials", "telegram-worker1-token.txt");
const allowFrom = new Set(
  (process.env.CODEX_TELEGRAM_WORKER1_ALLOW_FROM || "878295395")
    .split(/[,\s;]+/)
    .map((value) => value.trim())
    .filter(Boolean)
);

const statePath = path.join(stateDir, "state.json");
const inboxPath = path.join(stateDir, "inbox.jsonl");
const eventLogPath = path.join(stateDir, "events.log");

async function ensureDir() {
  await fs.mkdir(stateDir, { recursive: true });
}

async function readToken() {
  const token = (await fs.readFile(tokenFile, "utf8")).trim();
  if (!token) {
    throw new Error(`Telegram worker1 token file is empty: ${tokenFile}`);
  }
  return token;
}

async function readState() {
  try {
    return JSON.parse(await fs.readFile(statePath, "utf8"));
  } catch {
    return { offset: 0 };
  }
}

async function saveState(state) {
  await fs.writeFile(statePath, JSON.stringify(state, null, 2), "utf8");
}

async function log(message) {
  const line = `[${new Date().toISOString()}] ${message}\n`;
  await fs.appendFile(eventLogPath, line, "utf8").catch(() => {});
}

async function telegramCall(token, method, body) {
  const response = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });

  const text = await response.text();
  let payload;
  try {
    payload = JSON.parse(text);
  } catch {
    payload = { ok: false, description: text };
  }

  if (!response.ok || payload.ok !== true) {
    throw new Error(`${method} failed: ${payload.description || response.status}`);
  }

  return payload.result;
}

function normalizeMessage(update) {
  const message = update.message || update.edited_message || update.channel_post || update.edited_channel_post;
  if (!message) {
    return null;
  }

  const chat = message.chat || {};
  const from = message.from || {};
  const text = message.text || message.caption || "";
  if (!text.trim()) {
    return null;
  }

  return {
    id: `telegram-worker1:${update.update_id}:${message.message_id}`,
    source: "telegram-worker1",
    updateId: update.update_id,
    messageId: message.message_id,
    chatId: chat.id,
    chatType: chat.type || null,
    fromId: from.id != null ? String(from.id) : "",
    username: from.username || null,
    firstName: from.first_name || null,
    text,
    receivedAt: new Date().toISOString(),
    status: "new",
  };
}

async function appendInbox(item) {
  await fs.appendFile(inboxPath, `${JSON.stringify(item)}\n`, "utf8");
}

async function main() {
  await ensureDir();
  const token = await readToken();
  const state = await readState();
  await log(`bridge started; stateDir=${stateDir}`);

  while (true) {
    try {
      const updates = await telegramCall(token, "getUpdates", {
        offset: Number(state.offset || 0),
        timeout: 25,
        allowed_updates: ["message", "edited_message"],
      });

      for (const update of updates) {
        state.offset = Number(update.update_id) + 1;
        const item = normalizeMessage(update);
        if (!item) {
          continue;
        }

        if (allowFrom.size > 0 && !allowFrom.has(item.fromId)) {
          await log(`ignored unauthorized message from=${item.fromId} update=${item.updateId}`);
          continue;
        }

        await appendInbox(item);
        await log(`queued ${item.id} from=${item.fromId} chars=${item.text.length}`);
      }

      await saveState(state);
    } catch (error) {
      await log(`error: ${error?.message || String(error)}`);
      await new Promise((resolve) => setTimeout(resolve, 5000));
    }
  }
}

main().catch(async (error) => {
  await ensureDir().catch(() => {});
  await log(`fatal: ${error?.message || String(error)}`);
  process.exit(1);
});
