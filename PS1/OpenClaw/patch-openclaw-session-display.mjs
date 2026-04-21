import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

function readUtf8(filePath) {
  return fs.readFileSync(filePath, "utf8");
}

function writeUtf8IfChanged(filePath, nextText) {
  const prevText = readUtf8(filePath);
  if (prevText === nextText) return false;
  fs.writeFileSync(filePath, nextText, "utf8");
  return true;
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function resolveGlobalOpenClawDir() {
  const explicit = process.env.OPENCLAW_GLOBAL_DIR?.trim();
  if (explicit && fs.existsSync(path.join(explicit, "package.json"))) return explicit;

  const candidates = [];
  try {
    const npmRoot = execFileSync(process.platform === "win32" ? "npm.cmd" : "npm", ["root", "-g"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"]
    }).trim();
    if (npmRoot) candidates.push(path.join(npmRoot, "openclaw"));
  } catch {}

  if (process.env.APPDATA) candidates.push(path.join(process.env.APPDATA, "npm", "node_modules", "openclaw"));
  if (process.env.USERPROFILE) candidates.push(path.join(process.env.USERPROFILE, "AppData", "Roaming", "npm", "node_modules", "openclaw"));

  for (const candidate of candidates) {
    if (fs.existsSync(path.join(candidate, "package.json"))) return candidate;
  }

  throw new Error("Could not locate the global openclaw installation.");
}

function findSingleFile(dirPath, matcher) {
  const matches = fs.readdirSync(dirPath).filter((name) => matcher.test(name));
  if (matches.length !== 1) {
    throw new Error(`Expected exactly one match in ${dirPath}, found ${matches.length}.`);
  }
  return path.join(dirPath, matches[0]);
}

function findOptionalSingleFile(dirPath, matcher) {
  const matches = fs.readdirSync(dirPath).filter((name) => matcher.test(name));
  if (matches.length === 0) return null;
  if (matches.length !== 1) {
    throw new Error(`Expected at most one match in ${dirPath}, found ${matches.length}.`);
  }
  return path.join(dirPath, matches[0]);
}

function findSingleFileContaining(dirPath, matcher, needle) {
  const matches = fs.readdirSync(dirPath).filter((name) => {
    if (!matcher.test(name)) return false;
    const filePath = path.join(dirPath, name);
    try {
      return readUtf8(filePath).includes(needle);
    } catch {
      return false;
    }
  });
  if (matches.length !== 1) {
    throw new Error(`Expected exactly one content match in ${dirPath}, found ${matches.length}.`);
  }
  return path.join(dirPath, matches[0]);
}

function findExportAlias(filePath, localName) {
  const text = readUtf8(filePath);
  const match = text.match(new RegExp(`\\b${escapeRegExp(localName)}\\s+as\\s+([A-Za-z0-9_$]+)\\b`));
  if (!match) {
    throw new Error(`Could not find export alias for ${localName} in ${filePath}.`);
  }
  return match[1];
}

function applyCacheBustToRelativeImports(text, cacheBustTag, prefixPattern) {
  return text.replace(prefixPattern, (match) => {
    const clean = match.replace(/\?v=[^"'`)>\s]+$/, "");
    return `${clean}?v=${cacheBustTag}`;
  });
}

function hasPatchedTokenFormatter(text) {
  return /totalTokensFresh\s*!==\s*!1/.test(text) && text.includes("(?%)");
}

function buildEmbeddedFormatterReplacement(fnName, paramName, naExpression) {
  return [
    `function ${fnName}(${paramName}){`,
    `let _ocTotal=typeof ${paramName}?.totalTokens==="number"&&Number.isFinite(${paramName}.totalTokens)&&${paramName}.totalTokens>=0&&${paramName}.totalTokensFresh!==!1?${paramName}.totalTokens:null,`,
    `_ocInput=typeof ${paramName}?.inputTokens==="number"&&Number.isFinite(${paramName}.inputTokens)&&${paramName}.inputTokens>=0?${paramName}.inputTokens:null,`,
    `_ocOutput=typeof ${paramName}?.outputTokens==="number"&&Number.isFinite(${paramName}.outputTokens)&&${paramName}.outputTokens>=0?${paramName}.outputTokens:null,`,
    "_ocResolvedTotal=_ocTotal??(_ocInput!=null||_ocOutput!=null?(_ocInput??0)+(_ocOutput??0):null),",
    `_ocContext=typeof ${paramName}?.contextTokens==="number"&&Number.isFinite(${paramName}.contextTokens)&&${paramName}.contextTokens>0?${paramName}.contextTokens:null;`,
    `if(_ocResolvedTotal==null)return _ocContext?\`unknown / \${_ocContext} (?%)\`:${naExpression};`,
    "let _ocLabel=String(_ocResolvedTotal);",
    "if(!_ocContext)return _ocLabel;",
    "let _ocPercent=Math.min(999,Math.round(_ocResolvedTotal/_ocContext*100));",
    "return`${_ocLabel} / ${_ocContext} (${_ocPercent}%)`}",
  ].join("");
}

function patchEmbeddedTokenFormatter(text) {
  if (hasPatchedTokenFormatter(text)) return text;

  const regexes = [
    {
      regex: /function ([A-Za-z0-9_$]+)\(([A-Za-z0-9_$]+)\)\{if\(\2\.totalTokens==null\)return`n\/a`;let [A-Za-z0-9_$]+=\2\.totalTokens\?\?0,[A-Za-z0-9_$]+=\2\.contextTokens\?\?0;return [A-Za-z0-9_$]+\?`\$\{[A-Za-z0-9_$]+\} \/ \$\{[A-Za-z0-9_$]+\}`:String\([A-Za-z0-9_$]+\)\}/,
      build: (fnName, paramName) => buildEmbeddedFormatterReplacement(fnName, paramName, "`unknown`")
    },
    {
      regex: /function ([A-Za-z0-9_$]+)\(([A-Za-z0-9_$]+)\)\{if\(\2\.totalTokens==null\)return ([A-Za-z0-9_$]+)\(`common\.na`\);let [A-Za-z0-9_$]+=\2\.totalTokens\?\?0,[A-Za-z0-9_$]+=\2\.contextTokens\?\?0;return [A-Za-z0-9_$]+\?`\$\{[A-Za-z0-9_$]+\} \/ \$\{[A-Za-z0-9_$]+\}`:String\([A-Za-z0-9_$]+\)\}/,
      build: (fnName, paramName, naFn) => buildEmbeddedFormatterReplacement(fnName, paramName, `${naFn}(\`common.na\`)`)
    }
  ];

  for (const { regex, build } of regexes) {
    const match = text.match(regex);
    if (!match) continue;
    return text.replace(regex, build(...match.slice(1)));
  }

  throw new Error("Could not patch embedded control-ui token formatter.");
}

function patchControlUiIndex(filePath, cacheBustTag, options = {}) {
  let text = readUtf8(filePath);
  const original = text;

  const defineRegex = /([A-Za-z0-9_$]+)===void 0\?customElements\.define\(e,t\):\1\.addInitializer\(\(\)=>\{customElements\.define\(e,t\)\}\)/;
  if (defineRegex.test(text)) {
    text = text.replace(
      defineRegex,
      (_, initializerName) => `${initializerName}===void 0?(customElements.get(e)||customElements.define(e,t)):${initializerName}.addInitializer(()=>{customElements.get(e)||customElements.define(e,t)})`
    );
  }

  if (options.requiresEmbeddedFormatter) {
    text = patchEmbeddedTokenFormatter(text);
  }

  text = applyCacheBustToRelativeImports(text, cacheBustTag, /\.\/sessions-[^"'`]+\.js(?:\?v=[^"'`]+)?/g);
  text = applyCacheBustToRelativeImports(text, cacheBustTag, /\.\/presenter-[^"'`]+\.js(?:\?v=[^"'`]+)?/g);

  const changed = writeUtf8IfChanged(filePath, text);
  return {
    changed,
    alreadyPatched: original === text
  };
}

function patchControlUiPresenter(filePath) {
  let text = readUtf8(filePath);
  const original = text;

  if (!hasPatchedTokenFormatter(text)) {
    const regexes = [
      {
        regex: /function ([A-Za-z0-9_$]+)\(([A-Za-z0-9_$]+)\)\{if\(\2\.totalTokens==null\)return`n\/a`;let [A-Za-z0-9_$]+=\2\.totalTokens\?\?0,[A-Za-z0-9_$]+=\2\.contextTokens\?\?0;return [A-Za-z0-9_$]+\?`\$\{[A-Za-z0-9_$]+\} \/ \$\{[A-Za-z0-9_$]+\}`:String\([A-Za-z0-9_$]+\)\}/,
        build: (fnName, paramName) => buildEmbeddedFormatterReplacement(fnName, paramName, "`unknown`")
      },
      {
        regex: /function ([A-Za-z0-9_$]+)\(([A-Za-z0-9_$]+)\)\{if\(\2\.totalTokens==null\)return ([A-Za-z0-9_$]+)\(`common\.na`\);let [A-Za-z0-9_$]+=\2\.totalTokens\?\?0,[A-Za-z0-9_$]+=\2\.contextTokens\?\?0;return [A-Za-z0-9_$]+\?`\$\{[A-Za-z0-9_$]+\} \/ \$\{[A-Za-z0-9_$]+\}`:String\([A-Za-z0-9_$]+\)\}/,
        build: (fnName, paramName, naFn) => buildEmbeddedFormatterReplacement(fnName, paramName, `${naFn}(\`common.na\`)`)
      }
    ];

    let matched = false;
    for (const { regex, build } of regexes) {
      if (!regex.test(text)) continue;
      text = text.replace(regex, (_, ...groups) => build(...groups.slice(0, build.length)));
      matched = true;
      break;
    }
    if (!matched) {
      throw new Error("Could not patch control-ui presenter token formatter.");
    }
  }

  if (!hasPatchedTokenFormatter(text)) {
    throw new Error("Could not patch control-ui presenter token formatter.");
  }

  const changed = writeUtf8IfChanged(filePath, text);
  return {
    changed,
    alreadyPatched: original === text
  };
}

function patchControlUiSessions(filePath, cacheBustTag) {
  let text = readUtf8(filePath);
  const original = text;

  const sortOld = "case`tokens`:i=(e.totalTokens??e.inputTokens??e.outputTokens??0)-(n.totalTokens??n.inputTokens??n.outputTokens??0);break";
  const sortNew = "case`tokens`:i=(Number.isFinite(e?.totalTokens)&&e.totalTokens>=0&&e.totalTokensFresh!==!1?e.totalTokens:Number.isFinite(e?.inputTokens)||Number.isFinite(e?.outputTokens)?(e.inputTokens??0)+(e.outputTokens??0):0)-(Number.isFinite(n?.totalTokens)&&n.totalTokens>=0&&n.totalTokensFresh!==!1?n.totalTokens:Number.isFinite(n?.inputTokens)||Number.isFinite(n?.outputTokens)?(n.inputTokens??0)+(n.outputTokens??0):0);break";
  if (text.includes(sortOld)) text = text.replace(sortOld, sortNew);
  if (!text.includes("Number.isFinite(e?.totalTokens)&&e.totalTokens>=0&&e.totalTokensFresh!==!1")) {
    throw new Error("Could not patch control-ui sessions token sort.");
  }

  text = applyCacheBustToRelativeImports(text, cacheBustTag, /\.\/presenter-[^"'`]+\.js(?:\?v=[^"'`]+)?/g);

  const changed = writeUtf8IfChanged(filePath, text);
  return {
    changed,
    alreadyPatched: original === text
  };
}

function buildLoopbackGatewayMigrationScript() {
  return `    <script>
      (function () {
        // openclaw-local-gateway-migration
        try {
          var storage = window.localStorage;
          if (!storage) return;
          var protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
          var path = window.location.pathname || "/";
          path = path.replace(/\\/index\\.html$/i, "/").replace(/\\/+$/, "");
          var currentUrl = protocol + "//" + window.location.host + path;

          function normalize(url) {
            try {
              var base = window.location.protocol + "//" + window.location.host + (window.location.pathname || "/");
              var parsed = new URL(url, base);
              var normalizedPath = parsed.pathname === "/" ? "" : parsed.pathname.replace(/\\/+$/, "") || parsed.pathname;
              return parsed.protocol + "//" + parsed.host + normalizedPath;
            } catch (error) {
              return String(url || "");
            }
          }

          function normalizePath(pathname) {
            return pathname === "/" ? "" : pathname.replace(/\\/+$/, "") || pathname;
          }

          function isLoopbackHost(hostname) {
            var host = String(hostname || "").toLowerCase();
            return host === "localhost" || host === "::1" || host === "[::1]" || /^127(?:\\.\\d{1,3}){3}$/.test(host);
          }

          var currentKey = "openclaw.control.settings.v1:" + normalize(currentUrl);
          if (storage.getItem(currentKey)) return;

          var settingKeys = [];
          for (var index = 0; index < storage.length; index += 1) {
            var key = storage.key(index);
            if (key && key.indexOf("openclaw.control.settings.v1") === 0) settingKeys.push(key);
          }

          for (var keyIndex = 0; keyIndex < settingKeys.length; keyIndex += 1) {
            var settingsKey = settingKeys[keyIndex];
            var raw = storage.getItem(settingsKey);
            if (!raw) continue;

            var settings;
            try {
              settings = JSON.parse(raw);
            } catch (error) {
              continue;
            }

            var savedUrl = typeof settings.gatewayUrl === "string" ? settings.gatewayUrl.trim() : "";
            if (!savedUrl) continue;

            try {
              var currentParsed = new URL(currentUrl, window.location.href);
              var savedParsed = new URL(savedUrl, window.location.href);
              if (!isLoopbackHost(currentParsed.hostname) || !isLoopbackHost(savedParsed.hostname)) continue;
              if (normalizePath(currentParsed.pathname) !== normalizePath(savedParsed.pathname)) continue;
              if (currentParsed.host === savedParsed.host) continue;
            } catch (error) {
              continue;
            }

            settings.gatewayUrl = currentUrl;
            storage.setItem(currentKey, JSON.stringify(settings));
            if (settingsKey === "openclaw.control.settings.v1") {
              storage.setItem(settingsKey, JSON.stringify(settings));
            }

            var oldTokenKey = "openclaw.control.token.v1:" + normalize(savedUrl);
            var newTokenKey = "openclaw.control.token.v1:" + normalize(currentUrl);
            if (!storage.getItem(newTokenKey)) {
              var savedToken = storage.getItem(oldTokenKey) || storage.getItem("openclaw.control.token.v1");
              if (savedToken) storage.setItem(newTokenKey, savedToken);
            }
            break;
          }
        } catch (error) {}
      })();
    </script>`;
}

function patchControlUiHtml(filePath, cacheBustTag) {
  let text = readUtf8(filePath);
  const original = text;

  text = text.replace(/(\.\/assets\/[^"'?]+\.(?:js|css))(?:\?v=[^"' ]+)?/g, (_, assetPath) => `${assetPath}?v=${cacheBustTag}`);

  const migrationMarker = "openclaw-local-gateway-migration";
  if (!text.includes(migrationMarker)) {
    const moduleScriptRegex = /(\s*<script type="module" crossorigin src="\.\/assets\/[^"]+"><\/script>)/;
    if (!moduleScriptRegex.test(text)) {
      throw new Error("Could not find the control-ui module script anchor.");
    }
    text = text.replace(moduleScriptRegex, `\n${buildLoopbackGatewayMigrationScript()}\n$1`);
  }

  if (!text.includes(`?v=${cacheBustTag}`) || !text.includes(migrationMarker)) {
    throw new Error("Could not patch control-ui index.html asset cache bust.");
  }

  const changed = writeUtf8IfChanged(filePath, text);
  return {
    changed,
    alreadyPatched: original === text
  };
}

function patchSessionUtilsFs(filePath) {
  let text = readUtf8(filePath);
  const original = text;

  const importAnchor = /import \{ [^}]*\bas resolveSessionTranscriptCandidates\b[^}]* \} from "\.\/session-transcript-files[^"]+";/;
  const importLine = 'import { estimateTokens } from "@mariozechner/pi-coding-agent";';
  if (!text.includes(importLine)) {
    if (!importAnchor.test(text)) throw new Error("Could not find the transcript import anchor in session-utils.fs.");
    text = text.replace(importAnchor, (match) => `${match}\n${importLine}`);
  }

  const helperName = "function estimateSessionTranscriptTotalTokens(sessionId, storePath, sessionFile)";
  if (!text.includes(helperName)) {
    const helperAnchor = "return messages;\n}\nfunction capArrayByJsonBytes";
    const helperBlock = [
      "return messages;",
      "}",
      "function stripToolResultDetailsForTokenEstimate(messages) {",
      "\tif (messages.length === 0) return messages;",
      "\tlet changed = false;",
      "\tconst next = messages.map((message) => {",
      '\t\tif (!message || typeof message !== "object" || Array.isArray(message) || message.role !== "toolResult" || !("details" in message)) return message;',
      "\t\tconst sanitized = { ...message };",
      "\t\tdelete sanitized.details;",
      "\t\tchanged = true;",
      "\t\treturn sanitized;",
      "\t});",
      "\treturn changed ? next : messages;",
      "}",
      "function estimateSessionTranscriptTotalTokens(sessionId, storePath, sessionFile) {",
      "\tconst messages = stripToolResultDetailsForTokenEstimate(readSessionMessages(sessionId, storePath, sessionFile));",
      "\tif (messages.length === 0) return;",
      "\ttry {",
      "\t\tconst total = messages.reduce((sum, message) => sum + estimateTokens(message), 0);",
      "\t\tconst normalized = Math.ceil(total);",
      "\t\treturn Number.isFinite(normalized) && normalized > 0 ? normalized : void 0;",
      "\t} catch {",
      "\t\treturn;",
      "\t}",
      "}",
      "function capArrayByJsonBytes"
    ].join("\n");
    if (!text.includes(helperAnchor)) throw new Error("Could not find the helper insertion anchor in session-utils.fs.");
    text = text.replace(helperAnchor, helperBlock);
  }

  if (!/\bestimateSessionTranscriptTotalTokens as [A-Za-z0-9_$]+\b/.test(text)) {
    const exportRegex = /export \{ ([\s\S]+) \};/;
    if (!exportRegex.test(text)) throw new Error("Could not find the session-utils.fs export block.");
    text = text.replace(exportRegex, (match, specifiers) => `export { estimateSessionTranscriptTotalTokens as e, ${specifiers} };`);
  }

  const changed = writeUtf8IfChanged(filePath, text);
  return {
    changed,
    alreadyPatched: original === text
  };
}

function patchLegacySessionUtils(filePath) {
  let text = readUtf8(filePath);
  const original = text;

  const importAnchor = /import \{ [^}]*\bas resolveSessionTranscriptCandidates\b[^}]* \} from "\.\/session-transcript-files[^"]+";/;
  const importLine = 'import { estimateTokens } from "@mariozechner/pi-coding-agent";';
  if (!text.includes(importLine)) {
    if (!importAnchor.test(text)) throw new Error("Could not find the transcript import anchor in session-utils.");
    text = text.replace(importAnchor, (match) => `${match}\n${importLine}`);
  }

  const helperName = "function estimateSessionTranscriptTotalTokens(sessionId, storePath, sessionFile)";
  if (!text.includes(helperName)) {
    const helperAnchor = "return messages;\n}\nfunction capArrayByJsonBytes";
    const helperBlock = [
      "return messages;",
      "}",
      "function stripToolResultDetailsForTokenEstimate(messages) {",
      "\tif (messages.length === 0) return messages;",
      "\tlet changed = false;",
      "\tconst next = messages.map((message) => {",
      '\t\tif (!message || typeof message !== "object" || Array.isArray(message) || message.role !== "toolResult" || !("details" in message)) return message;',
      "\t\tconst sanitized = { ...message };",
      "\t\tdelete sanitized.details;",
      "\t\tchanged = true;",
      "\t\treturn sanitized;",
      "\t});",
      "\treturn changed ? next : messages;",
      "}",
      "function estimateSessionTranscriptTotalTokens(sessionId, storePath, sessionFile) {",
      "\tconst messages = stripToolResultDetailsForTokenEstimate(readSessionMessages(sessionId, storePath, sessionFile));",
      "\tif (messages.length === 0) return;",
      "\ttry {",
      "\t\tconst total = messages.reduce((sum, message) => sum + estimateTokens(message), 0);",
      "\t\treturn resolvePositiveNumber(Math.ceil(total));",
      "\t} catch {",
      "\t\treturn;",
      "\t}",
      "}",
      "function capArrayByJsonBytes"
    ].join("\n");
    if (!text.includes(helperAnchor)) throw new Error("Could not find the helper insertion anchor in session-utils.");
    text = text.replace(helperAnchor, helperBlock);
  }

  const fallbackRegex = /function resolveTranscriptUsageFallback\(params\) \{[\s\S]*?\n\}(?=\nfunction )/;
  const fallbackReplacement = [
    "function resolveTranscriptUsageFallback(params) {",
    "\tconst entry = params.entry;",
    "\tif (!entry?.sessionId) return null;",
    "\tconst parsed = parseAgentSessionKey(params.key);",
    "\tconst agentId = parsed?.agentId ? normalizeAgentId(parsed.agentId) : resolveDefaultAgentId(params.cfg);",
    "\tconst snapshot = readLatestSessionUsageFromTranscript(entry.sessionId, params.storePath, entry.sessionFile, agentId);",
    "\tconst estimatedTranscriptTotalTokens = estimateSessionTranscriptTotalTokens(entry.sessionId, params.storePath, entry.sessionFile);",
    "\tif (!snapshot && estimatedTranscriptTotalTokens === void 0) return null;",
    "\tconst modelProvider = snapshot?.modelProvider ?? params.fallbackProvider;",
    "\tconst model = snapshot?.model ?? params.fallbackModel;",
    "\tconst contextTokens = resolveContextTokensForModel({",
    "\t\tcfg: params.cfg,",
    "\t\tprovider: modelProvider,",
    "\t\tmodel,",
    "\t\tallowAsyncLoad: false",
    "\t});",
    "\tconst estimatedCostUsd = snapshot ? resolveEstimatedSessionCostUsd({",
    "\t\tcfg: params.cfg,",
    "\t\tprovider: modelProvider,",
    "\t\tmodel,",
    "\t\texplicitCostUsd: snapshot.costUsd,",
    "\t\tentry: {",
    "\t\t\tinputTokens: snapshot.inputTokens,",
    "\t\t\toutputTokens: snapshot.outputTokens,",
    "\t\t\tcacheRead: snapshot.cacheRead,",
    "\t\t\tcacheWrite: snapshot.cacheWrite",
    "\t\t}",
    "\t}) : void 0;",
    "\tconst totalTokens = resolvePositiveNumber(snapshot?.totalTokens) ?? estimatedTranscriptTotalTokens;",
    "\treturn {",
    "\t\tmodelProvider,",
    "\t\tmodel,",
    "\t\ttotalTokens,",
    "\t\ttotalTokensFresh: typeof totalTokens === \"number\" ? true : snapshot?.totalTokensFresh === true,",
    "\t\tcontextTokens: resolvePositiveNumber(contextTokens),",
    "\t\testimatedCostUsd",
    "\t};",
    "}"
  ].join("\n");
  if (!fallbackRegex.test(text)) throw new Error("Could not find resolveTranscriptUsageFallback in session-utils.");
  text = text.replace(fallbackRegex, fallbackReplacement);

  const changed = writeUtf8IfChanged(filePath, text);
  return {
    changed,
    alreadyPatched: original === text
  };
}

function patchSessionUtils(filePath, sessionUtilsFsPath) {
  if (!sessionUtilsFsPath) {
    return {
      sessionUtilsResult: patchLegacySessionUtils(filePath),
      sessionUtilsFsResult: null
    };
  }

  const sessionUtilsFsResult = patchSessionUtilsFs(sessionUtilsFsPath);
  const estimateSessionTranscriptTotalTokensAlias = findExportAlias(sessionUtilsFsPath, "estimateSessionTranscriptTotalTokens");
  const readSessionTitleFieldsAlias = findExportAlias(sessionUtilsFsPath, "readSessionTitleFieldsFromTranscript");
  const readLatestSessionUsageAlias = findExportAlias(sessionUtilsFsPath, "readLatestSessionUsageFromTranscript");

  let text = readUtf8(filePath);
  const original = text;
  const sessionUtilsFsModulePath = `./${path.basename(sessionUtilsFsPath)}`;
  const fsImportRegex = new RegExp(`import \\{[^}]+\\} from "${escapeRegExp(sessionUtilsFsModulePath)}";`);
  const desiredFsImport = `import { ${readSessionTitleFieldsAlias} as readSessionTitleFieldsFromTranscript, ${readLatestSessionUsageAlias} as readLatestSessionUsageFromTranscript, ${estimateSessionTranscriptTotalTokensAlias} as estimateSessionTranscriptTotalTokens } from "${sessionUtilsFsModulePath}";`;
  if (!text.includes(desiredFsImport)) {
    if (!fsImportRegex.test(text)) throw new Error("Could not find the session-utils.fs import in session-utils.");
    text = text.replace(fsImportRegex, desiredFsImport);
  }

  const fallbackRegex = /function resolveTranscriptUsageFallback\(params\) \{[\s\S]*?\n\}(?=\nfunction )/;
  const fallbackReplacement = [
    "function resolveTranscriptUsageFallback(params) {",
    "\tconst entry = params.entry;",
    "\tif (!entry?.sessionId) return null;",
    "\tconst parsed = parseAgentSessionKey(params.key);",
    "\tconst agentId = parsed?.agentId ? normalizeAgentId(parsed.agentId) : resolveDefaultAgentId(params.cfg);",
    "\tconst snapshot = readLatestSessionUsageFromTranscript(entry.sessionId, params.storePath, entry.sessionFile, agentId);",
    "\tconst estimatedTranscriptTotalTokens = estimateSessionTranscriptTotalTokens(entry.sessionId, params.storePath, entry.sessionFile);",
    "\tif (!snapshot && estimatedTranscriptTotalTokens === void 0) return null;",
    "\tconst modelProvider = snapshot?.modelProvider ?? params.fallbackProvider;",
    "\tconst model = snapshot?.model ?? params.fallbackModel;",
    "\tconst contextTokens = resolveContextTokensForModel({",
    "\t\tcfg: params.cfg,",
    "\t\tprovider: modelProvider,",
    "\t\tmodel,",
    "\t\tallowAsyncLoad: false",
    "\t});",
    "\tconst estimatedCostUsd = snapshot ? resolveEstimatedSessionCostUsd({",
    "\t\tcfg: params.cfg,",
    "\t\tprovider: modelProvider,",
    "\t\tmodel,",
    "\t\texplicitCostUsd: snapshot.costUsd,",
    "\t\tentry: {",
    "\t\t\tinputTokens: snapshot.inputTokens,",
    "\t\t\toutputTokens: snapshot.outputTokens,",
    "\t\t\tcacheRead: snapshot.cacheRead,",
    "\t\t\tcacheWrite: snapshot.cacheWrite",
    "\t\t}",
    "\t}) : void 0;",
    "\tconst totalTokens = resolvePositiveNumber(snapshot?.totalTokens) ?? estimatedTranscriptTotalTokens;",
    "\treturn {",
    "\t\tmodelProvider,",
    "\t\tmodel,",
    "\t\ttotalTokens,",
    "\t\ttotalTokensFresh: typeof totalTokens === \"number\" ? true : snapshot?.totalTokensFresh === true,",
    "\t\tcontextTokens: resolvePositiveNumber(contextTokens),",
    "\t\testimatedCostUsd",
    "\t};",
    "}"
  ].join("\n");
  if (!fallbackRegex.test(text)) throw new Error("Could not find resolveTranscriptUsageFallback in session-utils.");
  text = text.replace(fallbackRegex, fallbackReplacement);

  const changed = writeUtf8IfChanged(filePath, text);
  return {
    sessionUtilsResult: {
      changed,
      alreadyPatched: original === text
    },
    sessionUtilsFsResult
  };
}

function patchSessionsCli(filePath, sessionUtilsPath) {
  let text = readUtf8(filePath);
  const original = text;

  const sessionUtilsModulePath = `./${path.basename(sessionUtilsPath)}`;
  const listSessionsAlias = findExportAlias(sessionUtilsPath, "listSessionsFromStore");
  const resolveSessionModelRefAlias = findExportAlias(sessionUtilsPath, "resolveSessionModelRef");
  const classifySessionKeyAlias = findExportAlias(sessionUtilsPath, "classifySessionKey");
  const sessionUtilsImportRegex = new RegExp(`import \\{[^}]+\\} from "${escapeRegExp(sessionUtilsModulePath)}";`);
  const desiredImport = `import { ${listSessionsAlias} as listSessionsFromStore, ${resolveSessionModelRefAlias} as resolveSessionModelRef, ${classifySessionKeyAlias} as classifySessionKey } from "${sessionUtilsModulePath}";`;
  if (!text.includes(desiredImport)) {
    if (!sessionUtilsImportRegex.test(text)) throw new Error("Could not find the session-utils import in sessions CLI.");
    text = text.replace(sessionUtilsImportRegex, desiredImport);
  }
  if (!text.includes("listSessionsFromStore")) {
    throw new Error("Could not patch sessions CLI import for listSessionsFromStore.");
  }

  const rowsRegex = /const rows = targets\.flatMap\(\(target\) => \{\n\t\tconst store = loadSessionStore\(target\.storePath\);\n[\s\S]*?\n\t\}\)\.filter\(\(row\) => \{/;
  const rowsReplacement = [
    "const rows = targets.flatMap((target) => {",
    "\t\tconst store = loadSessionStore(target.storePath);",
    "\t\treturn listSessionsFromStore({",
    "\t\t\tcfg,",
    "\t\t\tstorePath: target.storePath,",
    "\t\t\tstore,",
    "\t\t\topts: {",
    "\t\t\t\tincludeGlobal: true,",
    "\t\t\t\tincludeUnknown: true",
    "\t\t\t}",
    "\t\t}).sessions.map((row) => ({",
    "\t\t\t...row,",
    "\t\t\tageMs: row.updatedAt ? Date.now() - row.updatedAt : null,",
    "\t\t\tagentId: parseAgentSessionKey(row.key)?.agentId ?? target.agentId,",
    "\t\t\tkind: row.kind ?? classifySessionKey(row.key, store[row.key]),",
    "\t\t\tgroupActivation: row.groupActivation ?? store[row.key]?.groupActivation,",
    "\t\t\tproviderOverride: row.providerOverride ?? store[row.key]?.providerOverride,",
    "\t\t\tmodelOverride: row.modelOverride ?? store[row.key]?.modelOverride",
    "\t\t}));",
    "\t}).filter((row) => {"
  ].join("\n");
  if (!text.includes("listSessionsFromStore({")) {
    if (!rowsRegex.test(text)) {
      throw new Error("Could not patch sessions CLI row builder.");
    }
    text = text.replace(rowsRegex, rowsReplacement);
  }

  const changed = writeUtf8IfChanged(filePath, text);
  return {
    changed,
    alreadyPatched: original === text
  };
}

async function verifyPatchedModule(filePath) {
  const moduleUrl = `${pathToFileURL(filePath).href}?verify=${Date.now()}`;
  await import(moduleUrl);
}

function verifySyntaxOnly(filePath) {
  execFileSync(process.execPath, ["--check", filePath], {
    stdio: ["ignore", "pipe", "pipe"]
  });
}

async function main() {
  const openClawDir = resolveGlobalOpenClawDir();
  const packageJson = JSON.parse(readUtf8(path.join(openClawDir, "package.json")));
  const cacheBustTag = `${String(packageJson.version).replace(/[^a-zA-Z0-9._-]+/g, "-")}-tokenfix3`;
  const distDir = path.join(openClawDir, "dist");
  const sessionUtilsPath = findSingleFile(distDir, /^session-utils-.*\.js$/);
  const sessionUtilsFsPath = findOptionalSingleFile(distDir, /^session-utils\.fs-.*\.js$/);
  const sessionsCliPath = findSingleFileContaining(distDir, /^sessions-.*\.js$/, "async function sessionsCommand(opts, runtime) {");
  const controlUiAssetsDir = path.join(distDir, "control-ui", "assets");
  const controlUiIndexPath = findSingleFile(controlUiAssetsDir, /^index-.*\.js$/);
  const controlUiSessionsPath = findSingleFile(controlUiAssetsDir, /^sessions-.*\.js$/);
  const controlUiPresenterPath = findOptionalSingleFile(controlUiAssetsDir, /^presenter-.*\.js$/);
  const controlUiHtmlPath = path.join(distDir, "control-ui", "index.html");

  const { sessionUtilsResult, sessionUtilsFsResult } = patchSessionUtils(sessionUtilsPath, sessionUtilsFsPath);
  const sessionsCliResult = patchSessionsCli(sessionsCliPath, sessionUtilsPath);
  const controlUiIndexResult = patchControlUiIndex(controlUiIndexPath, cacheBustTag, {
    requiresEmbeddedFormatter: !controlUiPresenterPath
  });
  const controlUiPresenterResult = controlUiPresenterPath ? patchControlUiPresenter(controlUiPresenterPath) : null;
  const controlUiSessionsResult = patchControlUiSessions(controlUiSessionsPath, cacheBustTag);
  const controlUiHtmlResult = patchControlUiHtml(controlUiHtmlPath, cacheBustTag);

  if (sessionUtilsFsPath) await verifyPatchedModule(sessionUtilsFsPath);
  await verifyPatchedModule(sessionUtilsPath);
  await verifyPatchedModule(sessionsCliPath);
  if (controlUiPresenterPath) verifySyntaxOnly(controlUiPresenterPath);

  const patchedFiles = [
    sessionUtilsFsPath ? { path: sessionUtilsFsPath, changed: sessionUtilsFsResult?.changed ?? false } : null,
    { path: sessionUtilsPath, changed: sessionUtilsResult.changed },
    { path: sessionsCliPath, changed: sessionsCliResult.changed },
    { path: controlUiIndexPath, changed: controlUiIndexResult.changed },
    controlUiPresenterPath ? { path: controlUiPresenterPath, changed: controlUiPresenterResult?.changed ?? false } : null,
    { path: controlUiSessionsPath, changed: controlUiSessionsResult.changed },
    { path: controlUiHtmlPath, changed: controlUiHtmlResult.changed }
  ].filter(Boolean);

  console.log(JSON.stringify({
    openclawDir: openClawDir,
    openclawVersion: packageJson.version,
    cacheBustTag,
    patchedFiles
  }, null, 2));
}

main().catch((error) => {
  console.error(error?.stack || String(error));
  process.exit(1);
});
