import http from "node:http";
import crypto from "node:crypto";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import { execSync } from "node:child_process";
import { spawn as childSpawn, spawnSync as childSpawnSync } from "node:child_process";
import { Bonjour } from "bonjour-service";

// ---------------------------------------------------------------------------
// Logging (must be defined before use)
// ---------------------------------------------------------------------------

function log(level, msg, ...args) {
  const ts = new Date().toISOString();
  const prefix = `[${ts}] [${level.toUpperCase()}]`;
  if (args.length) {
    console.log(prefix, msg, ...args);
  } else {
    console.log(prefix, msg);
  }
}

// ---------------------------------------------------------------------------
// Binary discovery
// ---------------------------------------------------------------------------

function findBinary(name, candidates) {
  for (const c of candidates) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch { /* continue */ }
  }
  try {
    return execSync(`which ${name} 2>/dev/null`, { encoding: "utf-8" }).trim();
  } catch { /* fall through */ }
  return null;
}

const CLAUDE_BIN = findBinary("claude", [
  `${os.homedir()}/.local/bin/claude`,
  "/usr/local/bin/claude",
  "/opt/homebrew/bin/claude",
]);

const CODEX_BIN = findBinary("codex", [
  `${os.homedir()}/.local/bin/codex`,
  "/usr/local/bin/codex",
  "/opt/homebrew/bin/codex",
]);

const TMUX_BIN = findBinary("tmux", [
  "/opt/homebrew/bin/tmux",
  "/usr/local/bin/tmux",
  `${os.homedir()}/.local/bin/tmux`,
]);

const PS_BIN = findBinary("ps", [
  "/bin/ps",
  "/usr/bin/ps",
]);

const LSOF_BIN = findBinary("lsof", [
  "/usr/sbin/lsof",
  "/usr/bin/lsof",
]);

if (!CLAUDE_BIN) {
  log("warn", "Could not find 'claude' binary — Claude sessions will not be available.");
}
if (CODEX_BIN) {
  log("info", `Codex binary found: ${CODEX_BIN}`);
} else {
  log("info", "Codex not found — Codex sessions will not be available.");
}
if (TMUX_BIN) {
  log("info", `tmux binary found: ${TMUX_BIN}`);
} else {
  log("warn", "tmux not found — shared desktop terminal sessions will fall back to legacy behavior.");
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const PORT_RANGE_START = 7860;
const PORT_RANGE_END = 7869;
const PAIRING_CODE_TTL_MS = 5 * 60 * 1000;
const RATE_LIMIT_WINDOW_MS = 5 * 60 * 1000;
const RATE_LIMIT_MAX_ATTEMPTS = 5;
const SSE_HEARTBEAT_INTERVAL_MS = 2_000;
const SSE_MIN_CHUNK_BYTES = 1024;
const SSE_PRELUDE_PADDING_BYTES = 2048;
const SSE_BUFFER_SIZE = 500;
const SESSION_REPLAY_BUFFER_SIZE = 1000;
const PERMISSION_TIMEOUT_MS = 600_000; // 10 minutes
const CODEX_SESSION_SCAN_INTERVAL_MS = 1_500;
const CODEX_SESSION_BOOTSTRAP_LOOKBACK_MS = 30 * 60 * 1000;
const CODEX_SESSION_SCAN_LIMIT = 25;
const LIVE_AGENT_PROCESS_SCAN_INTERVAL_MS = 2_000;
const CODEX_SESSION_ROOT = path.join(os.homedir(), ".codex", "sessions");
const CODEX_LOG_FILE = path.join(os.homedir(), ".codex", "log", "codex-tui.log");
const CLAUDE_SESSION_SCAN_INTERVAL_MS = 1_500;
const CLAUDE_SESSION_BOOTSTRAP_LOOKBACK_MS = 30 * 60 * 1000;
const CLAUDE_SESSION_BOOTSTRAP_MAX_BYTES = 512 * 1024;
const CODEX_SESSION_BOOTSTRAP_MAX_BYTES = 512 * 1024;
const CLAUDE_PROJECTS_ROOT = path.join(os.homedir(), ".claude", "projects");
const DESKTOP_PID_ROOT = path.join(os.tmpdir(), "agent-watch-pids");
const TMUX_LOG_ROOT = path.join(os.tmpdir(), "agent-watch-tmux");
const TMUX_LOG_SCAN_INTERVAL_MS = 1_500;
const TMUX_LOG_BOOTSTRAP_LOOKBACK_MS = 30 * 60 * 1000;
const TMUX_LOG_BOOTSTRAP_MAX_BYTES = 128 * 1024;
const TMUX_CONTEXT_REPLAY_MAX_BYTES = 12 * 1024;
const DESKTOP_LAUNCH_MATCH_WINDOW_MS = 60_000;
const SESSION_MATCH_TIME_SKEW_MS = 15_000;
const SESSION_ACTIVITY_GRACE_MS = 45_000;
const RECENT_SESSION_ACTIVITY_WINDOW_MS = 2 * 60_000;
const BRIDGE_ID = crypto.randomUUID();

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const sessionTokens = new Set();
let pairingCode = null;
let pairingCodeExpiresAt = 0;

// Rate limiting
let rateLimitAttempts = 0;
let rateLimitWindowStart = Date.now();

// Bridge-level state: "idle" | "connected"
let bridgeState = "idle";

// Multi-session: each entry is a session slot
// { id, agent, cwd, folderName, ptyProcess, state, createdAt, lastActivityAt?, backend?, managedDesktop?, pidFile?, externalSessionId?, resumeSessionId?, externalProcessPid?, externalTty?, tmuxSessionName?, tmuxPaneTarget?, tmuxPanePid?, tmuxPaneTty?, tmuxLogFile?, tmuxMetaFile?, attachedTmuxPane?, autoTrustState? }
/** @type {Map<string, {id: string, agent: string, cwd: string, folderName: string, ptyProcess: import("child_process").ChildProcess | null, state: string, createdAt: number, lastActivityAt?: number, backend?: string, managedDesktop?: boolean, pidFile?: string | null, externalSessionId?: string | null, resumeSessionId?: string | null, externalProcessPid?: number | null, externalTty?: string | null, tmuxSessionName?: string | null, tmuxPaneTarget?: string | null, tmuxPanePid?: number | null, tmuxPaneTty?: string | null, tmuxLogFile?: string | null, tmuxMetaFile?: string | null, attachedTmuxPane?: boolean, autoTrustState?: string | null}>} */
const sessions = new Map();

// SSE
let sseEventId = 0;
/** @type {Array<{id: number, event: string, data: string}>} */
const sseBuffer = [];
/** @type {Set<http.ServerResponse>} */
const sseClients = new Set();
/** @type {Map<string, Array<{event: string, data: Record<string, any>}>>} */
const sessionReplayBuffers = new Map();
/** @type {Map<string, {filePath: string, offset: number, remainder: string}>} */
const tmuxLogFiles = new Map();

// Permission flow
/** @type {Map<string, {resolve: Function, timer: ReturnType<typeof setTimeout>, sessionId: string | null}>} */
const pendingPermissions = new Map();
/** @type {Map<string, Array>} */
const pendingPermissionBodies = new Map();
/** @type {Map<string, {filePath: string, offset: number, remainder: string, initialized: boolean}>} */
const claudeSessionFiles = new Map();
/** @type {Map<string, {offset: number, remainder: string, sessionId: string | null, cwd?: string, createdAt?: number, initialized: boolean}>} */
const codexSessionFiles = new Map();
/** @type {Map<string, {sessionId: string, name: string, args: Record<string, any>}>} */
const codexPendingToolCalls = new Map();
/** @type {Map<string, {command: string, justification: string, workdir: string, prefixRule: string[], createdAt: number}>} */
const codexExecApprovalCandidates = new Map();
/** @type {Map<string, {command: string, justification: string, workdir: string, prefixRule: string[], createdAt: number}>} */
const codexRecentExecCommands = new Map();
/** @type {Set<string>} */
const codexOpenExecApprovals = new Set();
/** @type {Map<string, Array<{command: string, createdAt: number}>>} */
const queuedPrompts = new Map();
/** @type {Array<{agent: string, cwd: string, pidFile: string, createdAt: number, claimedSessionId: string | null, bridgeSessionId: string}>} */
const desktopLaunchRecords = [];
/** @type {Map<string, string>} */
const externalSessionAliases = new Map();
/** @type {Map<string, {sessionId: string, optionCount: number, payload: Record<string, any>}>} */
const codexSyntheticPermissions = new Map();
/** @type {Map<string, string>} */
const codexSyntheticPermissionBySession = new Map();
/** Track recently resolved approval sessions so the log-file path doesn't re-surface them */
const codexRecentlyResolvedApprovals = new Map(); // sessionId → timestamp
const CODEX_RESOLVED_APPROVAL_TTL_MS = 60_000; // 60 seconds
const codexLogState = { offset: 0, remainder: "", initialized: false };
let codexMonitorInterval = null;
let claudeMonitorInterval = null;
let tmuxMonitorInterval = null;
let liveAgentProcessMonitorInterval = null;
/** @type {Map<string, {pid: number, ppid: number, tty: string, agent: string, command: string, cwd: string | null, startedAt: number}>} */
const liveAgentProcesses = new Map();

// Bonjour
let bonjourInstance = null;
let bonjourService = null;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function generatePairingCode() {
  const code = crypto.randomInt(0, 1_000_000).toString().padStart(6, "0");
  pairingCode = code;
  pairingCodeExpiresAt = Date.now() + PAIRING_CODE_TTL_MS;
  log("info", `Pairing code generated: ${code} (expires in 5 minutes)`);
  return code;
}

function generateSessionToken() {
  const token = crypto.randomBytes(32).toString("hex");
  sessionTokens.add(token);
  return token;
}

function isRateLimited() {
  const now = Date.now();
  if (now - rateLimitWindowStart > RATE_LIMIT_WINDOW_MS) {
    rateLimitAttempts = 0;
    rateLimitWindowStart = now;
  }
  return rateLimitAttempts >= RATE_LIMIT_MAX_ATTEMPTS;
}

function recordRateLimitAttempt() {
  const now = Date.now();
  if (now - rateLimitWindowStart > RATE_LIMIT_WINDOW_MS) {
    rateLimitAttempts = 0;
    rateLimitWindowStart = now;
  }
  rateLimitAttempts++;
}

function requireAuth(req) {
  const auth = req.headers["authorization"];
  if (!auth || !auth.startsWith("Bearer ")) return false;
  const token = auth.slice(7);
  return sessionTokens.has(token);
}

function jsonResponse(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      try {
        const raw = Buffer.concat(chunks).toString("utf-8");
        resolve(raw.length ? JSON.parse(raw) : {});
      } catch (err) {
        reject(err);
      }
    });
    req.on("error", reject);
  });
}

function availableAgentsList() {
  const agents = [];
  if (CLAUDE_BIN) agents.push("claude");
  if (CODEX_BIN) agents.push("codex");
  return agents;
}

// ---------------------------------------------------------------------------
// SSE helpers
// ---------------------------------------------------------------------------

function normalizeSsePayload(data) {
  let payload;
  if (typeof data === "string") {
    try {
      payload = JSON.parse(data);
    } catch {
      payload = { raw: data };
    }
  } else {
    payload = { ...data };
  }
  return payload;
}

function shouldReplayEvent(event) {
  return [
    "session",
    "conversation-message",
    "tool-output",
    "pty-output",
    "permission-request",
    "permission-cleared",
    "stop",
    "task-complete",
    "error",
  ].includes(event);
}

function appendSessionReplayEvent(sessionId, event, payload) {
  if (!sessionId || !shouldReplayEvent(event)) return;

  const buffer = sessionReplayBuffers.get(sessionId) || [];
  buffer.push({ event, data: { ...payload } });

  if (buffer.length > SESSION_REPLAY_BUFFER_SIZE) {
    buffer.splice(0, buffer.length - SESSION_REPLAY_BUFFER_SIZE);
  }

  sessionReplayBuffers.set(sessionId, buffer);
}

function getSortedSessions() {
  return Array.from(sessions.values()).sort((lhs, rhs) => (lhs.createdAt || 0) - (rhs.createdAt || 0));
}

function getSessionReplayEntries(sessionId) {
  return sessionReplayBuffers.get(sessionId) || [];
}

function getTmuxBootstrapText(slot) {
  const paneTarget = getTmuxPaneTarget(slot);
  if (paneTarget) {
    const captured = runTmuxCommand(["capture-pane", "-p", "-S", "-160", "-t", paneTarget], {
      allowFailure: true,
    });
    const stdout = (captured.stdout || "").trim();
    if (captured.ok && stdout) {
      return stdout;
    }
  }

  if (!slot?.tmuxLogFile) return "";

  const stat = safeStat(slot.tmuxLogFile);
  if (!stat?.isFile() || stat.size <= 0) return "";

  const bootstrapSize = Math.min(stat.size, TMUX_CONTEXT_REPLAY_MAX_BYTES);
  const startOffset = Math.max(0, stat.size - bootstrapSize);
  let bootstrapText = bootstrapSize > 0 ? readFileSlice(slot.tmuxLogFile, startOffset, bootstrapSize) : "";
  if (!bootstrapText) return "";

  if (startOffset > 0) {
    const newlineIndex = bootstrapText.indexOf("\n");
    bootstrapText = newlineIndex >= 0 ? bootstrapText.slice(newlineIndex + 1) : "";
  }

  return bootstrapText.trim() ? bootstrapText : "";
}

function resolveSessionSlot(sessionOrId) {
  if (!sessionOrId) return null;
  if (typeof sessionOrId === "string") {
    const canonical = getCanonicalSessionId(sessionOrId);
    return sessions.get(canonical) || sessions.get(sessionOrId) || null;
  }
  return sessionOrId;
}

function touchSessionActivity(sessionOrId, options = {}) {
  const slot = resolveSessionSlot(sessionOrId);
  if (!slot || slot.state === "ended" || slot.state === "removed") return null;

  slot.lastActivityAt = Date.now();
  if (slot.tmuxMetaFile) {
    persistTmuxSessionMetadata(slot);
  }

  if (options.emitHeartbeat === true) {
    pushSseEvent("session-heartbeat", {
      timestamp: new Date(slot.lastActivityAt).toISOString(),
      source: options.source || "bridge",
    }, slot.id);
  }

  return slot;
}

function isSharedTerminalSession(slot) {
  if (!slot || slot.state !== "running") return false;
  return slot.backend === "tmux";
}

function isSessionWritable(slot) {
  if (!slot || slot.state !== "running") return false;
  return slot.backend === "tmux" || slot.backend === "pty";
}

function buildSessionPayload(slot, extra = {}) {
  return {
    state: slot?.state || "unknown",
    agent: slot?.agent || extra.agent || "claude",
    cwd: slot?.cwd || extra.cwd || "",
    folderName: slot?.folderName || extra.folderName || "",
    lastActivityAt: slot?.lastActivityAt || extra.lastActivityAt || null,
    backend: slot?.backend || extra.backend || "external",
    writable: typeof extra.writable === "boolean" ? extra.writable : isSessionWritable(slot),
    sharedTerminal: typeof extra.sharedTerminal === "boolean" ? extra.sharedTerminal : isSharedTerminalSession(slot),
    externalSessionId: slot?.externalSessionId || extra.externalSessionId || null,
    resumeSessionId: slot?.resumeSessionId || extra.resumeSessionId || null,
    tmuxSessionName: slot?.tmuxSessionName || extra.tmuxSessionName || null,
    tmuxPaneTarget: getTmuxPaneTarget(slot) || extra.tmuxPaneTarget || null,
    ...extra,
  };
}

function shellSingleQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function sleepMs(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return;
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function parseProcessStartTimestamp(raw) {
  const value = Date.parse(raw);
  return Number.isFinite(value) ? value : Date.now();
}

function normalizeTty(tty) {
  const raw = String(tty || "").trim();
  if (!raw || raw === "??") return null;
  return raw.startsWith("/dev/") ? raw : `/dev/${raw}`;
}

function classifyAgentProcess(command) {
  if (typeof command !== "string" || !command) return null;
  if (/(^|[\/\s])claude(\s|$)/.test(command)) return "claude";
  if (/(^|[\/\s])codex(\s|$)/.test(command)) return "codex";
  return null;
}

function processSelectionScore(proc) {
  let score = 0;
  if (!proc) return score;
  if (proc.tty && proc.tty !== "??") score += 4;
  if (proc.cwd) score += 5;
  if (!/\bnode\b/.test(proc.command)) score += 3;
  if (new RegExp(`(^|[\\/\\s])${proc.agent}(\\s|$)`).test(proc.command)) score += 2;
  return score;
}

function getProcessCwd(pid) {
  if (!LSOF_BIN || !Number.isFinite(pid) || pid <= 0) return null;
  const result = childSpawnSync(LSOF_BIN, ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], {
    encoding: "utf-8",
    env: { ...process.env },
  });
  if (result.status !== 0) return null;

  for (const line of (result.stdout || "").split("\n")) {
    if (line.startsWith("n") && line.length > 1) {
      return line.slice(1).trim() || null;
    }
  }
  return null;
}

function parseCodexSessionIdFromPath(filePath) {
  const normalized = String(filePath || "").trim();
  if (!normalized || !normalized.endsWith(".jsonl")) return null;
  if (!normalized.startsWith(`${CODEX_SESSION_ROOT}${path.sep}`)) return null;

  const match = normalized.match(/([0-9a-f-]{36})\.jsonl$/i);
  return match ? match[1] : null;
}

function getCodexSessionIdForPid(pid) {
  if (!LSOF_BIN || !Number.isFinite(pid) || pid <= 0) return null;

  const result = childSpawnSync(LSOF_BIN, ["-a", "-p", String(pid), "-Fn"], {
    encoding: "utf-8",
    env: { ...process.env },
  });
  if (result.status !== 0) return null;

  const sessionIds = new Set();
  for (const line of (result.stdout || "").split("\n")) {
    if (!line.startsWith("n") || line.length <= 1) continue;
    const sessionId = parseCodexSessionIdFromPath(line.slice(1));
    if (sessionId) {
      sessionIds.add(sessionId);
    }
  }

  if (sessionIds.size !== 1) return null;
  return [...sessionIds][0];
}

function findCodexSessionIdForProcessBucket(processes = []) {
  const sessionIds = new Set();
  for (const proc of processes) {
    const sessionId = getCodexSessionIdForPid(proc?.pid);
    if (sessionId) {
      sessionIds.add(sessionId);
    }
  }

  if (sessionIds.size !== 1) return null;
  return [...sessionIds][0];
}


function listLiveAgentProcesses() {
  if (!PS_BIN) return [];

  // Force C locale so date strings in lstart= are always English (e.g. "Wed Apr  9 …")
  // regardless of the system locale (e.g. zh_CN.UTF-8).
  const result = childSpawnSync(PS_BIN, ["-axo", "pid=,ppid=,tty=,lstart=,command="], {
    encoding: "utf-8",
    env: { ...process.env, LC_ALL: "C", LANG: "C" },
  });
  if (result.status !== 0) return [];

  const grouped = new Map();
  for (const rawLine of (result.stdout || "").split("\n")) {
    const line = rawLine.trim();
    if (!line) continue;

    const match = line.match(/^(\d+)\s+(\d+)\s+(\S+)\s+([A-Z][a-z]{2}\s+[A-Z][a-z]{2}\s+\d+\s+\d\d:\d\d:\d\d\s+\d{4})\s+(.+)$/);
    if (!match) continue;

    const [, pidRaw, ppidRaw, tty, startedRaw, command] = match;
    if (!tty || tty === "??") continue;

    const agent = classifyAgentProcess(command);
    if (!agent) continue;

    const proc = {
      pid: Number(pidRaw),
      ppid: Number(ppidRaw),
      tty,
      agent,
      command,
      cwd: null,
      startedAt: parseProcessStartTimestamp(startedRaw),
    };
    const key = `${agent}:${tty}`;
    const bucket = grouped.get(key) || [];
    bucket.push(proc);
    grouped.set(key, bucket);
  }

  const selected = [];
  for (const bucket of grouped.values()) {
    bucket.sort((lhs, rhs) => {
      const scoreDiff = processSelectionScore(rhs) - processSelectionScore(lhs);
      if (scoreDiff !== 0) return scoreDiff;
      return (rhs.startedAt || 0) - (lhs.startedAt || 0);
    });
    const selectedProc = { ...bucket[0] };
    if (selectedProc.agent === "codex") {
      selectedProc.exactSessionId = findCodexSessionIdForProcessBucket(bucket);
    }
    selected.push(selectedProc);
  }

  // Resolve cwd for selected processes
  for (const proc of selected) {
    proc.cwd = getProcessCwd(proc.pid);
  }

  return selected;
}

let lastRefreshLiveAgentProcessesAt = 0;
const REFRESH_LIVE_AGENT_THROTTLE_MS = 2_000;

function refreshLiveAgentProcesses(force = false) {
  const now = Date.now();
  if (!force && now - lastRefreshLiveAgentProcessesAt < REFRESH_LIVE_AGENT_THROTTLE_MS) {
    return; // Use cached results
  }
  lastRefreshLiveAgentProcessesAt = now;

  liveAgentProcesses.clear();
  for (const proc of listLiveAgentProcesses()) {
    liveAgentProcesses.set(`${proc.agent}:${proc.pid}`, proc);
  }
}

function findMatchingLiveAgentProcess(agent, cwd = null, hints = {}) {
  const matches = Array.from(liveAgentProcesses.values()).filter((proc) => proc.agent === agent);
  if (matches.length === 0) return null;

  if (Number.isFinite(hints.pid)) {
    const exactPid = matches.find((proc) => proc.pid === hints.pid);
    if (exactPid) return exactPid;
  }

  if (hints.tty) {
    const normalizedTty = normalizeTty(hints.tty);
    const exactTty = matches.find((proc) => normalizeTty(proc.tty) === normalizedTty);
    if (exactTty) return exactTty;
  }

  if (cwd) {
    const exactCwdMatches = matches.filter((proc) => proc.cwd === cwd);
    if (exactCwdMatches.length === 1) {
      return exactCwdMatches[0];
    }
  }

  return null;
}

function findExactLiveAgentProcess(agent, stableExternalSessionId, cwd = null) {
  if (!stableExternalSessionId) return null;

  const matches = Array.from(liveAgentProcesses.values()).filter((proc) => {
    if (proc.agent !== agent) return false;
    if (proc.exactSessionId !== stableExternalSessionId) return false;
    if (cwd && proc.cwd && proc.cwd !== cwd) return false;
    return true;
  });

  if (matches.length !== 1) return null;
  return matches[0];
}

function findTimeCompatibleLiveAgentProcess(agent, cwd = null, externalCreatedAt = null) {
  if (!Number.isFinite(externalCreatedAt)) return null;

  const matches = Array.from(liveAgentProcesses.values()).filter((proc) => {
    if (proc.agent !== agent) return false;
    if (!isSessionTimingCompatible(proc.startedAt, externalCreatedAt)) return false;
    if (cwd && proc.cwd && proc.cwd !== cwd) return false;
    return true;
  });

  if (matches.length !== 1) return null;
  return matches[0];
}

function sessionOwnershipScore(slot) {
  let score = 0;
  if (!slot) return score;
  if (slot.managedDesktop === true && slot.attachedTmuxPane !== true) score += 100;
  if (!isSyntheticExternalSessionId(slot.id)) score += 30;
  if (slot.attachedTmuxPane !== true) score += 20;
  if (slot.managedDesktop === true) score += 10;
  if (slot.externalSessionId && !isSyntheticExternalSessionId(slot.externalSessionId)) score += 5;
  return score;
}

function compareSessionOwnershipPreference(lhs, rhs) {
  const scoreDiff = sessionOwnershipScore(rhs) - sessionOwnershipScore(lhs);
  if (scoreDiff !== 0) return scoreDiff;
  return getSessionActivityTimestamp(rhs) - getSessionActivityTimestamp(lhs);
}

function findSessionForLiveProcess(proc) {
  if (!proc) return null;
  const procTty = normalizeTty(proc.tty);
  const matches = [];

  for (const [, slot] of sessions) {
    if (slot.state !== "running") continue;
    if (slot.agent !== proc.agent) continue;
    if (slot.externalProcessPid && slot.externalProcessPid === proc.pid) {
      matches.push(slot);
      continue;
    }
    if (normalizeTty(slot.externalTty) && normalizeTty(slot.externalTty) === procTty) {
      matches.push(slot);
      continue;
    }
    if (slot.tmuxPanePid && slot.tmuxPanePid === proc.pid) {
      matches.push(slot);
      continue;
    }
    if (normalizeTty(slot.tmuxPaneTty) && normalizeTty(slot.tmuxPaneTty) === procTty) {
      matches.push(slot);
    }
  }

  matches.sort(compareSessionOwnershipPreference);
  return matches[0] || null;
}

function dedupeSessionsByTmuxPane() {
  const grouped = new Map();

  for (const slot of sessions.values()) {
    if (slot.state !== "running") continue;
    const paneTarget = getTmuxPaneTarget(slot);
    if (!paneTarget) continue;
    const bucket = grouped.get(paneTarget) || [];
    bucket.push(slot);
    grouped.set(paneTarget, bucket);
  }

  for (const [paneTarget, bucket] of grouped.entries()) {
    if (bucket.length <= 1) continue;
    bucket.sort(compareSessionOwnershipPreference);
    const keeper = bucket[0];

    for (const duplicate of bucket.slice(1)) {
      log("info", `Removing duplicate session ${duplicate.id} — same tmux pane ${paneTarget} as ${keeper.id}`);
      duplicate.state = "removed";
      duplicate.ptyProcess = null;
      queuedPrompts.delete(duplicate.id);
      claudeSessionFiles.delete(duplicate.id);
      unregisterTmuxLogFile(duplicate);
      sessionReplayBuffers.delete(duplicate.id);
      clearCodexSyntheticPermissionForSession(duplicate.id, "duplicate-pane");
      cleanupTmuxFiles(duplicate);

      for (const [alias, target] of externalSessionAliases.entries()) {
        if (target === duplicate.id || alias === duplicate.externalSessionId) {
          externalSessionAliases.delete(alias);
        }
      }

      sessions.delete(duplicate.id);
      pushSseEvent("session-removed", { agent: duplicate.agent, folderName: duplicate.folderName, reason: "duplicate-pane" }, duplicate.id);
    }
  }
}

function reconcileExternalSessionsWithLiveProcesses() {
  refreshLiveAgentProcesses();
  const tmuxPanes = listAllTmuxPanes();

  for (const [, slot] of sessions) {
    const isMirrorCandidate = (
      slot.state === "running"
      && slot.backend === "tmux"
      && slot.attachedTmuxPane !== true
      && !slot.managedDesktop
      && Boolean(slot.externalProcessPid || slot.externalTty)
    );
    const tracksExternalProcess = slot.state === "running" && (slot.backend === "external" || slot.attachedTmuxPane === true || isMirrorCandidate);
    if (!tracksExternalProcess) continue;

    const liveProcess = findMatchingLiveAgentProcess(slot.agent, slot.cwd, {
      pid: slot.externalProcessPid,
      tty: slot.externalTty,
    });

    if (liveProcess) {
      const previousBackend = slot.backend;
      const previousPaneTarget = getTmuxPaneTarget(slot);
      slot.externalProcessPid = liveProcess.pid;
      slot.externalTty = liveProcess.tty;
      slot.lastActivityAt = Date.now();
      const matchedPane = findTmuxPaneForTty(liveProcess.tty, tmuxPanes);
      if (matchedPane) {
        adoptExistingTmuxPane(slot, matchedPane, { preserveResumeSessionId: true });
        if (previousBackend !== "tmux" || previousPaneTarget !== getTmuxPaneTarget(slot)) {
          pushSseEvent("session", {
            state: "running",
            agent: slot.agent,
            cwd: slot.cwd,
            folderName: slot.folderName,
          }, slot.id);
        }
      }
      continue;
    }

    const lastActivityAt = slot.lastActivityAt || slot.createdAt || 0;
    if (Date.now() - lastActivityAt < SESSION_ACTIVITY_GRACE_MS) {
      continue;
    }

    if (!isMirrorCandidate) {
      endExternalSession(slot.externalSessionId || slot.id, "agent-process-exit");
    }
  }

  let newSessionCreated = false;
  for (const proc of liveAgentProcesses.values()) {
    if (findSessionForLiveProcess(proc)) continue;
    const resolvedCwd = proc.cwd || process.env.HOME || process.cwd();
    const stableExternalSessionId = proc.agent === "codex"
      ? proc.exactSessionId || null
      : null;
    const record = stableExternalSessionId
      ? findRecentExternalSessionRecord(proc.agent, resolvedCwd, stableExternalSessionId)
      : findRecentExternalSessionRecord(proc.agent, resolvedCwd);
    const knownSessionIds = new Set(sessions.keys());
    const discoveredSessionId = stableExternalSessionId
      || (proc.agent === "claude" ? record?.sessionId || null : null)
      || `external-${proc.agent}-${proc.pid}`;
    const slot = touchExternalSession(
      discoveredSessionId,
      resolvedCwd,
      record?.createdAt || proc.startedAt,
      proc.agent,
      {
        externalProcessPid: proc.pid,
        externalTty: proc.tty,
        matchedTmuxPane: findTmuxPaneForTty(proc.tty, tmuxPanes),
      }
    );
    if (!slot) continue;
    if (!knownSessionIds.has(slot.id)) {
      log("info", `Detected live ${proc.agent} process pid=${proc.pid} tty=${proc.tty}${proc.cwd ? ` cwd=${proc.cwd}` : ""} -> ${slot.backend}`);
      newSessionCreated = true;
    }
  }

  // After creating new sessions, retry any Codex approvals that were previously deferred
  // because no session slot existed yet.
  if (newSessionCreated && codexOpenExecApprovals.size > 0) {
    for (const sessionId of codexOpenExecApprovals) {
      const canonicalId = getCanonicalSessionId(sessionId);
      if (!codexSyntheticPermissionBySession.has(canonicalId)) {
        surfaceCodexExecApproval(sessionId);
      }
    }
  }

  dedupeSessionsByTmuxPane();
}

function ensureTmuxLogRoot() {
  try {
    fs.mkdirSync(TMUX_LOG_ROOT, { recursive: true });
    return true;
  } catch (err) {
    log("error", `Failed to create tmux log directory: ${err.message}`);
    return false;
  }
}

function ensureDesktopPidRoot() {
  try {
    fs.mkdirSync(DESKTOP_PID_ROOT, { recursive: true });
    return true;
  } catch (err) {
    log("error", `Failed to create desktop pid directory: ${err.message}`);
    return false;
  }
}

function getDesktopPidFile(sessionId) {
  return path.join(DESKTOP_PID_ROOT, `${sessionId}.pid`);
}

function getTmuxLogFile(sessionId) {
  return path.join(TMUX_LOG_ROOT, `${sessionId}.log`);
}

function getTmuxMetaFile(sessionId) {
  return path.join(TMUX_LOG_ROOT, `${sessionId}.json`);
}

function buildTmuxSessionName(sessionId, agent) {
  return `agent-watch-${agent}-${sessionId}`;
}

function getTmuxPaneTarget(slot) {
  return slot?.tmuxPaneTarget || (slot?.tmuxSessionName ? `${slot.tmuxSessionName}:0.0` : null);
}

function runTmuxCommand(args, options = {}) {
  if (!TMUX_BIN) {
    return { ok: false, code: 127, stdout: "", stderr: "tmux binary not found" };
  }

  const result = childSpawnSync(TMUX_BIN, args, {
    encoding: "utf-8",
    input: options.input,
    env: { ...process.env },
  });

  const stdout = result.stdout || "";
  const stderr = result.stderr || "";
  const ok = result.status === 0;

  if (!ok && options.allowFailure !== true) {
    log("warn", `tmux ${args.join(" ")} failed: ${stderr.trim() || `exit ${result.status}`}`);
  }

  return {
    ok,
    code: result.status ?? 1,
    stdout,
    stderr,
  };
}

function persistTmuxSessionMetadata(slot) {
  if (!slot?.tmuxMetaFile) return;
  try {
    fs.writeFileSync(slot.tmuxMetaFile, JSON.stringify({
      id: slot.id,
      agent: slot.agent,
      cwd: slot.cwd,
      folderName: slot.folderName,
      createdAt: slot.createdAt,
      lastActivityAt: slot.lastActivityAt || null,
      managedDesktop: slot.managedDesktop === true,
      externalSessionId: slot.externalSessionId || null,
      resumeSessionId: slot.resumeSessionId || null,
      tmuxSessionName: slot.tmuxSessionName || null,
      tmuxPaneTarget: getTmuxPaneTarget(slot),
      tmuxPanePid: slot.tmuxPanePid || null,
      tmuxPaneTty: slot.tmuxPaneTty || null,
      tmuxLogFile: slot.tmuxLogFile || null,
      attachedTmuxPane: slot.attachedTmuxPane === true,
    }));
  } catch (err) {
    log("warn", `Failed to persist tmux metadata for ${slot.id}: ${err.message}`);
  }
}

function cleanupTmuxFiles(slot) {
  if (!slot) return;
  const targets = [slot.tmuxLogFile, slot.tmuxMetaFile];
  for (const target of targets) {
    if (!target) continue;
    try { fs.unlinkSync(target); } catch { /* ignore */ }
  }
}

function registerTmuxLogFile(slot) {
  if (!slot?.tmuxLogFile) return;
  tmuxLogFiles.set(slot.id, {
    filePath: slot.tmuxLogFile,
    offset: 0,
    remainder: "",
    initialized: false,
  });
}

function unregisterTmuxLogFile(slot) {
  if (!slot) return;
  tmuxLogFiles.delete(slot.id);
}

function parseTmuxPaneDescriptor(line) {
  const trimmed = String(line || "").trim();
  if (!trimmed) return null;

  const parts = trimmed.split("\t");
  if (parts.length < 6) return null;

  const [sessionName, windowIndex, paneIndex, paneId, panePidRaw, paneTtyRaw] = parts;
  return {
    sessionName,
    paneTarget: `${sessionName}:${windowIndex}.${paneIndex}`,
    paneId: paneId || null,
    panePid: Number(panePidRaw) || null,
    paneTty: normalizeTty(paneTtyRaw),
  };
}

function listAllTmuxPanes() {
  if (!TMUX_BIN) return [];

  const listed = runTmuxCommand([
    "list-panes",
    "-a",
    "-F",
    "#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_id}\t#{pane_pid}\t#{pane_tty}",
  ], { allowFailure: true });
  if (!listed.ok) return [];

  return listed.stdout
    .split("\n")
    .map(parseTmuxPaneDescriptor)
    .filter(Boolean);
}

function findTmuxPaneForTty(tty, panes = null) {
  const normalizedTty = normalizeTty(tty);
  if (!normalizedTty) return null;

  const candidates = Array.isArray(panes) ? panes : listAllTmuxPanes();
  return candidates.find((pane) => pane.paneTty === normalizedTty) || null;
}

function refreshTmuxPaneIdentity(slot) {
  if (!slot || !TMUX_BIN) return false;
  const target = getTmuxPaneTarget(slot);
  if (!target && !slot.tmuxSessionName) return false;

  const listed = runTmuxCommand([
    "list-panes",
    "-t",
    target || slot.tmuxSessionName,
    "-F",
    "#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_id}\t#{pane_pid}\t#{pane_tty}",
  ], { allowFailure: true });
  if (!listed.ok) return false;

  const firstLine = listed.stdout.split("\n").map((line) => line.trim()).find(Boolean);
  if (!firstLine) return false;

  const pane = parseTmuxPaneDescriptor(firstLine);
  if (!pane) return false;

  slot.tmuxSessionName = pane.sessionName;
  slot.tmuxPaneTarget = pane.paneTarget;
  slot.tmuxPanePid = pane.panePid;
  slot.tmuxPaneTty = pane.paneTty;
  return true;
}

function maybeCleanupManagedTmuxMirror(slot, nextPane = null) {
  if (!slot) return;

  const currentTarget = getTmuxPaneTarget(slot);
  const nextTarget = nextPane?.paneTarget || nextPane?.paneId || null;
  const currentSessionName = slot.tmuxSessionName || null;
  const nextSessionName = nextPane?.sessionName || null;
  const samePane = currentTarget && nextTarget && currentTarget === nextTarget;
  const sameSession = currentSessionName && nextSessionName && currentSessionName === nextSessionName;
  const ownsTmuxSession = slot.attachedTmuxPane !== true;

  if (ownsTmuxSession && !samePane && !sameSession && slot.tmuxSessionName && (slot.tmuxLogFile || slot.tmuxMetaFile)) {
    runTmuxCommand(["kill-session", "-t", slot.tmuxSessionName], { allowFailure: true });
  }

  unregisterTmuxLogFile(slot);
  if (ownsTmuxSession) {
    cleanupTmuxFiles(slot);
  }
}

function adoptExistingTmuxPane(slot, pane, extra = {}) {
  if (!slot || !pane) return false;

  const nextTarget = pane.paneTarget || pane.paneId || null;
  const currentTarget = getTmuxPaneTarget(slot);
  const samePane = (
    slot.backend === "tmux"
    && currentTarget
    && nextTarget
    && currentTarget === nextTarget
    && normalizeTty(slot.tmuxPaneTty) === pane.paneTty
  );

  if (!samePane) {
    maybeCleanupManagedTmuxMirror(slot, pane);
  }

  slot.backend = "tmux";
  slot.attachedTmuxPane = true;
  slot.tmuxSessionName = pane.sessionName;
  slot.tmuxPaneTarget = nextTarget;
  slot.tmuxPanePid = pane.panePid || null;
  slot.tmuxPaneTty = pane.paneTty || null;
  slot.tmuxLogFile = slot.tmuxLogFile || getTmuxLogFile(slot.id);
  slot.tmuxMetaFile = slot.tmuxMetaFile || getTmuxMetaFile(slot.id);

  if (extra.externalSessionId) {
    slot.externalSessionId = extra.externalSessionId;
  }
  if (extra.resumeSessionId) {
    slot.resumeSessionId = extra.resumeSessionId;
  } else if (extra.preserveResumeSessionId !== true) {
    slot.resumeSessionId = slot.resumeSessionId || slot.externalSessionId || null;
  }

  ensureTmuxPaneLogging(slot);
  persistTmuxSessionMetadata(slot);
  return true;
}

function shouldAdoptMatchedTmuxPane(slot, pane) {
  if (!slot || !pane) return false;

  // Bridge-created desktop sessions already own their tmux session lifecycle.
  // Never rebind them onto a discovered tmux pane; that turns a managed shared
  // session into an external mirror and causes approvals/output to drift.
  if (slot.managedDesktop === true) {
    return false;
  }

  // Bridge-managed tmux sessions already have a dedicated tmux session name.
  // Do not let a later live-process scan rebind them onto some unrelated pane
  // that happens to share cwd/agent, or approvals/output will jump sessions.
  if (
    slot.backend === "tmux"
    && slot.attachedTmuxPane !== true
    && slot.tmuxSessionName
    && pane.sessionName
    && pane.sessionName !== slot.tmuxSessionName
  ) {
    log("info", `Ignoring conflicting tmux pane ${pane.paneTarget} for managed session ${slot.id}; keeping ${slot.tmuxSessionName}`);
    return false;
  }

  return true;
}

function buildAgentTmuxCommand(slot) {
  const bin = slot.agent === "codex" ? CODEX_BIN : CLAUDE_BIN;
  if (!bin) return null;

  const resumeSessionId = slot.resumeSessionId
    || (slot.agent === "codex"
      ? slot.externalSessionId || null
      : (slot.externalSessionId && slot.externalSessionId !== slot.id ? slot.externalSessionId : null));

  if (slot.agent === "codex") {
    if (resumeSessionId) {
      return `exec ${shellSingleQuote(bin)} --no-alt-screen resume ${shellSingleQuote(resumeSessionId)}`;
    }
    return `exec ${shellSingleQuote(bin)} --no-alt-screen`;
  }

  if (resumeSessionId) {
    return `exec ${shellSingleQuote(bin)} --resume ${shellSingleQuote(resumeSessionId)}`;
  }

  return `exec ${shellSingleQuote(bin)} --session-id ${shellSingleQuote(slot.id)}`;
}

function maybeAutoTrustClaudeSession(slot, text) {
  if (!slot || slot.agent !== "claude" || slot.backend !== "tmux") return;
  if (slot.autoTrustState === "confirmed") return;

  if (typeof text !== "string" || text.length === 0) return;

  const normalized = text.toLowerCase();
  const looksLikeTrustPrompt = (
    normalized.includes("quick safety check:")
    || normalized.includes("yes, i trust this folder")
    || normalized.includes("is this a project you created or one you trust")
    || normalized.includes("trust this folder")
    || normalized.includes("trust the files in this folder")
  );
  if (!looksLikeTrustPrompt) return;

  const prefersOptionOne = (
    /\b1[.)]\s*(yes|trust|continue)\b/i.test(text)
    || /\b(?:type|enter|press)\s+1\b/i.test(text)
  );
  const submitted = sendTmuxInput(slot, prefersOptionOne ? "1\n" : "\n");
  if (!submitted) return;

  slot.autoTrustState = "confirmed";
  log("info", `Auto-confirmed Claude trust prompt for session ${slot.id} (${prefersOptionOne ? "1" : "enter"})`);
}

function createTmuxSession(slot) {
  if (!slot || !TMUX_BIN) return false;
  if (!ensureTmuxLogRoot()) return false;

  slot.tmuxSessionName = slot.tmuxSessionName || buildTmuxSessionName(slot.id, slot.agent);
  slot.tmuxPaneTarget = getTmuxPaneTarget(slot);
  slot.tmuxLogFile = slot.tmuxLogFile || getTmuxLogFile(slot.id);
  slot.tmuxMetaFile = slot.tmuxMetaFile || getTmuxMetaFile(slot.id);

  const command = buildAgentTmuxCommand(slot);
  if (!command) return false;

  try { fs.writeFileSync(slot.tmuxLogFile, ""); } catch { /* ignore */ }

  const create = runTmuxCommand([
    "new-session",
    "-d",
    "-s",
    slot.tmuxSessionName,
    "-c",
    slot.cwd,
  ]);
  if (!create.ok) return false;

  if (!refreshTmuxPaneIdentity(slot)) {
    runTmuxCommand(["kill-session", "-t", slot.tmuxSessionName], { allowFailure: true });
    return false;
  }

  if (!ensureTmuxPaneLogging(slot, { truncate: true })) {
    runTmuxCommand(["kill-session", "-t", slot.tmuxSessionName], { allowFailure: true });
    return false;
  }

  slot.backend = "tmux";
  slot.attachedTmuxPane = false;
  refreshTmuxPaneIdentity(slot);
  registerTmuxLogFile(slot);

  if (!sendTmuxInput(slot, `${command}\n`)) {
    unregisterTmuxLogFile(slot);
    runTmuxCommand(["kill-session", "-t", slot.tmuxSessionName], { allowFailure: true });
    cleanupTmuxFiles(slot);
    return false;
  }

  persistTmuxSessionMetadata(slot);
  return true;
}

function ensureTmuxPaneLogging(slot, options = {}) {
  if (!slot || !TMUX_BIN) return false;
  if (!ensureTmuxLogRoot()) return false;

  const paneTarget = getTmuxPaneTarget(slot);
  if (!paneTarget) return false;

  slot.tmuxLogFile = slot.tmuxLogFile || getTmuxLogFile(slot.id);
  slot.tmuxMetaFile = slot.tmuxMetaFile || getTmuxMetaFile(slot.id);

  if (options.truncate === true) {
    try { fs.writeFileSync(slot.tmuxLogFile, ""); } catch { /* ignore */ }
  } else {
    try { fs.closeSync(fs.openSync(slot.tmuxLogFile, "a")); } catch { /* ignore */ }
  }

  const pipe = runTmuxCommand([
    "pipe-pane",
    "-o",
    "-t",
    paneTarget,
    `cat >> ${shellSingleQuote(slot.tmuxLogFile)}`,
  ], { allowFailure: true });
  if (!pipe.ok) {
    return false;
  }

  registerTmuxLogFile(slot);
  return true;
}

function sendTmuxInput(slot, text) {
  const paneTarget = getTmuxPaneTarget(slot);
  if (!slot || !paneTarget || typeof text !== "string" || text.length === 0) return false;

  const shouldSubmit = /[\r\n]$/.test(text);
  const normalizedText = shouldSubmit ? text.replace(/[\r\n]+$/, "") : text;
  const isSingleLine = !/[\r\n]/.test(normalizedText);

  if (normalizedText.length > 0) {
    if (isSingleLine) {
      const typed = runTmuxCommand(["send-keys", "-t", paneTarget, "-l", normalizedText], {
        allowFailure: true,
      });
      if (!typed.ok) return false;
    } else {
      const bufferName = `agent-watch-${slot.id}-${Date.now()}`;
      const loaded = runTmuxCommand(["load-buffer", "-b", bufferName, "-"], {
        input: normalizedText,
      });
      if (!loaded.ok) return false;

      const pasted = runTmuxCommand(["paste-buffer", "-b", bufferName, "-d", "-t", paneTarget], {
        allowFailure: true,
      });
      runTmuxCommand(["delete-buffer", "-b", bufferName], { allowFailure: true });
      if (!pasted.ok) return false;
    }
  }

  if (shouldSubmit) {
    if (normalizedText.length > 0 && isSingleLine) {
      sleepMs(75);
    }
    return runTmuxCommand(["send-keys", "-t", paneTarget, "Enter"], { allowFailure: true }).ok;
  }

  return true;
}

function sendTmuxInterrupt(slot) {
  const paneTarget = getTmuxPaneTarget(slot);
  if (!slot || !paneTarget) return false;
  return runTmuxCommand(["send-keys", "-t", paneTarget, "C-c"], { allowFailure: true }).ok;
}

function listActiveTmuxSessions() {
  const listed = runTmuxCommand(["list-sessions", "-F", "#{session_name}"], { allowFailure: true });
  if (!listed.ok) return new Set();
  return new Set(
    listed.stdout
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean)
  );
}

function readTmuxLogDelta(sessionId, fileState, stat) {
  if (!fileState.initialized) {
    const allowBootstrap = Date.now() - stat.mtimeMs <= TMUX_LOG_BOOTSTRAP_LOOKBACK_MS;
    if (!allowBootstrap) {
      fileState.offset = stat.size;
      fileState.initialized = true;
      return;
    }

    const bootstrapSize = Math.min(stat.size, TMUX_LOG_BOOTSTRAP_MAX_BYTES);
    const startOffset = Math.max(0, stat.size - bootstrapSize);
    const bootstrapText = bootstrapSize > 0 ? readFileSlice(fileState.filePath, startOffset, bootstrapSize) : "";
    fileState.offset = stat.size;
    fileState.initialized = true;

    if (bootstrapText) {
      const slot = sessions.get(sessionId);
      fileState.remainder = bootstrapText.slice(-512);
      if (slot) maybeAutoTrustClaudeSession(slot, fileState.remainder);
      pushSseEvent("pty-output", { text: bootstrapText }, sessionId);
    }
    return;
  }

  if (stat.size < fileState.offset) {
    fileState.offset = 0;
  }
  if (stat.size === fileState.offset) return;

  const delta = readFileSlice(fileState.filePath, fileState.offset, stat.size - fileState.offset);
  fileState.offset = stat.size;
  if (!delta) return;

  const slot = sessions.get(sessionId);
  fileState.remainder = `${fileState.remainder || ""}${delta}`.slice(-512);
  if (slot) maybeAutoTrustClaudeSession(slot, fileState.remainder);
  pushSseEvent("pty-output", { text: delta }, sessionId);
}

function markTmuxSessionEnded(slot, reason = "tmux-exit") {
  if (!slot || slot.state === "ended" || slot.state === "removed") return;
  slot.state = "ended";
  slot.ptyProcess = null;
  queuedPrompts.delete(slot.id);
  tmuxLogFiles.delete(slot.id);
  cleanupTmuxFiles(slot);
  clearCodexSyntheticPermissionForSession(slot.id, reason);
  for (const [alias, target] of externalSessionAliases.entries()) {
    if (target === slot.id || alias === slot.externalSessionId) {
      externalSessionAliases.delete(alias);
    }
  }
  pushSseEvent("session", { state: "ended", agent: slot.agent, folderName: slot.folderName, reason }, slot.id);
  log("info", `Session ${slot.id} ended (${reason})`);
}

function scanTmuxSessions() {
  if (!TMUX_BIN || tmuxLogFiles.size === 0) return;

  const activeSessions = listActiveTmuxSessions();

  for (const [sessionId, fileState] of tmuxLogFiles.entries()) {
    const slot = sessions.get(sessionId);
    if (!slot || slot.state === "removed") {
      tmuxLogFiles.delete(sessionId);
      continue;
    }

    const stat = safeStat(fileState.filePath);
    if (stat?.isFile()) {
      readTmuxLogDelta(sessionId, fileState, stat);
      tmuxLogFiles.set(sessionId, fileState);
    }

    if (slot.tmuxSessionName && !activeSessions.has(slot.tmuxSessionName)) {
      markTmuxSessionEnded(slot);
    }
  }
}

function startTmuxMonitor() {
  if (tmuxMonitorInterval || !TMUX_BIN) return;

  scanTmuxSessions();
  tmuxMonitorInterval = setInterval(() => {
    try {
      scanTmuxSessions();
    } catch (err) {
      log("warn", `tmux monitor scan failed: ${err.message}`);
    }
  }, TMUX_LOG_SCAN_INTERVAL_MS);
}

function stopTmuxMonitor() {
  if (tmuxMonitorInterval) {
    clearInterval(tmuxMonitorInterval);
    tmuxMonitorInterval = null;
  }
}

function recoverTmuxSessions() {
  if (!TMUX_BIN || !ensureTmuxLogRoot()) return;
  refreshLiveAgentProcesses(true);

  let entries = [];
  try {
    entries = fs.readdirSync(TMUX_LOG_ROOT).filter((name) => name.endsWith(".json"));
  } catch {
    return;
  }

  const activeSessions = listActiveTmuxSessions();

  for (const entry of entries) {
    const metaFile = path.join(TMUX_LOG_ROOT, entry);
    let parsed;
    try {
      parsed = JSON.parse(fs.readFileSync(metaFile, "utf-8"));
    } catch {
      continue;
    }

    if (!parsed?.id || !parsed?.tmuxSessionName || !activeSessions.has(parsed.tmuxSessionName)) {
      try { fs.unlinkSync(metaFile); } catch { /* ignore */ }
      continue;
    }

    const slot = {
      id: parsed.id,
      agent: parsed.agent,
      cwd: parsed.cwd || process.env.HOME || process.cwd(),
      folderName: parsed.folderName || path.basename(parsed.cwd || "") || parsed.cwd,
      ptyProcess: null,
      state: "running",
      createdAt: parsed.createdAt || Date.now(),
      lastActivityAt: parsed.lastActivityAt || parsed.createdAt || Date.now(),
      backend: "tmux",
      managedDesktop: parsed.managedDesktop === true,
      pidFile: null,
      externalSessionId: parsed.externalSessionId || (parsed.agent === "claude" ? parsed.id : null),
      resumeSessionId: parsed.resumeSessionId
        || (parsed.externalSessionId && parsed.externalSessionId !== parsed.id ? parsed.externalSessionId : null)
        || null,
      externalProcessPid: parsed.attachedTmuxPane === true && Number.isFinite(parsed.tmuxPanePid)
        ? parsed.tmuxPanePid
        : null,
      externalTty: parsed.attachedTmuxPane === true ? parsed.tmuxPaneTty || null : null,
      tmuxSessionName: parsed.tmuxSessionName,
      tmuxPaneTarget: parsed.tmuxPaneTarget || `${parsed.tmuxSessionName}:0.0`,
      tmuxPanePid: Number.isFinite(parsed.tmuxPanePid) ? parsed.tmuxPanePid : null,
      tmuxPaneTty: parsed.tmuxPaneTty || null,
      tmuxLogFile: parsed.tmuxLogFile || getTmuxLogFile(parsed.id),
      tmuxMetaFile: metaFile,
      attachedTmuxPane: parsed.attachedTmuxPane === true,
      autoTrustState: parsed.agent === "claude" ? null : "confirmed",
    };

    sessions.set(slot.id, slot);
    refreshTmuxPaneIdentity(slot);
    const liveProcess = findMatchingLiveAgentProcess(slot.agent, slot.cwd, {
      pid: slot.tmuxPanePid,
      tty: slot.tmuxPaneTty,
    });
    if (slot.attachedTmuxPane === true && !liveProcess) {
      sessions.delete(slot.id);
      try { fs.unlinkSync(metaFile); } catch { /* ignore */ }
      log("info", `Skipped stale recovered tmux mirror ${slot.id} (${slot.agent}) — no matching live process on ${slot.tmuxPaneTty || slot.tmuxPaneTarget}`);
      continue;
    }
    if (liveProcess) {
      slot.externalProcessPid = liveProcess.pid;
      slot.externalTty = liveProcess.tty;
      if (slot.agent === "codex" && liveProcess.exactSessionId) {
        slot.externalSessionId = liveProcess.exactSessionId;
        slot.resumeSessionId = liveProcess.exactSessionId;
      }
    }
    if (
      slot.agent === "claude"
      && (!slot.externalSessionId || isSyntheticExternalSessionId(slot.externalSessionId))
    ) {
      const record = findRecentClaudeSessionRecord(slot.cwd);
      if (record?.sessionId) {
        slot.externalSessionId = record.sessionId;
        slot.resumeSessionId = record.sessionId;
      }
    }
    registerTmuxLogFile(slot);
    ensureSessionMonitoring(slot);
    pushSseEvent("session", { state: "running", agent: slot.agent, cwd: slot.cwd, folderName: slot.folderName }, slot.id);
    if (
      (slot.externalSessionId && slot.externalSessionId !== slot.id)
      || (slot.resumeSessionId && slot.resumeSessionId !== slot.id)
    ) {
      registerExternalSessionAliases(slot, slot.externalSessionId, slot.resumeSessionId);
    }
    log("info", `Recovered tmux session ${slot.id} (${slot.agent})`);
  }

  dedupeSessionsByTmuxPane();
}

function pruneDesktopLaunchRecords() {
  const cutoff = Date.now() - DESKTOP_LAUNCH_MATCH_WINDOW_MS;
  for (let i = desktopLaunchRecords.length - 1; i >= 0; i--) {
    if (desktopLaunchRecords[i].createdAt < cutoff) {
      desktopLaunchRecords.splice(i, 1);
    }
  }
}

function getCanonicalSessionId(sessionId) {
  if (!sessionId) return sessionId;
  return externalSessionAliases.get(sessionId) || sessionId;
}

function isSyntheticExternalSessionId(sessionId) {
  return typeof sessionId === "string" && /^external-(claude|codex)-\d+$/.test(sessionId);
}

function registerExternalSessionAliases(slot, ...aliases) {
  if (!slot?.id) return;

  const desiredAliases = new Set(
    [slot.externalSessionId, slot.resumeSessionId, ...aliases]
      .filter((alias) => alias && alias !== slot.id)
  );

  for (const [alias, target] of externalSessionAliases.entries()) {
    if (target !== slot.id) continue;
    if (!desiredAliases.has(alias)) {
      externalSessionAliases.delete(alias);
    }
  }

  for (const alias of desiredAliases) {
    externalSessionAliases.set(alias, slot.id);
  }
}

function isSessionTimingCompatible(slotCreatedAt, externalCreatedAt) {
  if (!Number.isFinite(slotCreatedAt) || !Number.isFinite(externalCreatedAt)) return true;
  return Math.abs(slotCreatedAt - externalCreatedAt) <= SESSION_MATCH_TIME_SKEW_MS;
}

function listRecentClaudeSessionFiles(cwd) {
  const projectDir = path.join(CLAUDE_PROJECTS_ROOT, encodeClaudeProjectDir(cwd));
  const stat = safeStat(projectDir);
  if (!stat || !stat.isDirectory()) return [];

  let entries = [];
  try {
    entries = fs.readdirSync(projectDir, { withFileTypes: true });
  } catch {
    return [];
  }

  const results = [];
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".jsonl")) continue;
    const filePath = path.join(projectDir, entry.name);
    const fileStat = safeStat(filePath);
    if (!fileStat?.isFile()) continue;
    results.push({
      filePath,
      sessionId: entry.name.replace(/\.jsonl$/, ""),
      cwd,
      createdAt: fileStat.mtimeMs || Date.now(),
      mtimeMs: fileStat.mtimeMs || 0,
    });
  }

  results.sort((lhs, rhs) => (rhs.mtimeMs || 0) - (lhs.mtimeMs || 0));
  return results;
}

function findRecentClaudeSessionRecord(cwd, preferredSessionId = null) {
  if (!cwd) return null;
  const files = listRecentClaudeSessionFiles(cwd);
  if (files.length === 0) return null;

  if (preferredSessionId && !isSyntheticExternalSessionId(preferredSessionId)) {
    const exact = files.find((entry) => entry.sessionId === preferredSessionId);
    if (exact) return exact;
  }

  return files[0] || null;
}

function parseCodexSessionMetaFromFile(filePath, stat = null) {
  const fileStat = stat || safeStat(filePath);
  if (!fileStat) return null;
  if (typeof fileStat.isFile === "function" && !fileStat.isFile()) return null;

  const headerSize = Math.min(fileStat.size || 0, 64 * 1024);
  const header = headerSize > 0 ? readFileSlice(filePath, 0, headerSize) : "";
  for (const line of header.split("\n")) {
    if (!line.trim()) continue;
    const parsed = parseJsonLine(line);
    if (parsed?.type !== "session_meta" || !parsed.payload?.id) continue;
    return {
      filePath,
      sessionId: parsed.payload.id,
      cwd: parsed.payload.cwd || null,
      createdAt: Date.parse(parsed.payload.timestamp || parsed.timestamp || "") || fileStat.mtimeMs || Date.now(),
      mtimeMs: fileStat.mtimeMs || 0,
    };
  }

  return null;
}

function findRecentCodexSessionRecord(cwd, preferredSessionId = null) {
  const records = [];

  for (const [filePath, fileState] of codexSessionFiles.entries()) {
    const fileStat = safeStat(filePath);
    if (!fileStat?.isFile()) continue;

    const record = fileState.sessionId
      ? {
        filePath,
        sessionId: fileState.sessionId,
        cwd: fileState.cwd || null,
        createdAt: fileState.createdAt || fileStat.mtimeMs || Date.now(),
        mtimeMs: fileStat.mtimeMs || 0,
      }
      : parseCodexSessionMetaFromFile(filePath, fileStat);
    if (!record?.sessionId) continue;
    records.push(record);
  }

  if (records.length === 0) {
    for (const entry of listRecentCodexSessionFiles(CODEX_SESSION_ROOT)) {
      const record = parseCodexSessionMetaFromFile(entry.filePath, entry);
      if (!record?.sessionId) continue;
      records.push(record);
      if (preferredSessionId && record.sessionId === preferredSessionId) break;
    }
  }

  const filtered = records.filter((record) => {
    if (preferredSessionId && record.sessionId === preferredSessionId) return true;
    if (!cwd) return true;
    return !record.cwd || record.cwd === cwd;
  });
  if (filtered.length === 0) return null;

  filtered.sort((lhs, rhs) => (rhs.mtimeMs || rhs.createdAt || 0) - (lhs.mtimeMs || lhs.createdAt || 0));

  if (preferredSessionId && !isSyntheticExternalSessionId(preferredSessionId)) {
    const exact = filtered.find((record) => record.sessionId === preferredSessionId);
    if (exact) return exact;
  }

  return filtered[0] || null;
}

function findRecentExternalSessionRecord(agent, cwd, preferredSessionId = null) {
  if (agent === "claude") {
    return findRecentClaudeSessionRecord(cwd, preferredSessionId);
  }
  if (agent === "codex") {
    return findRecentCodexSessionRecord(cwd, preferredSessionId);
  }
  return null;
}

function resolveResumeSessionId(agent, cwd, sessionId = null, options = {}) {
  const canonicalSessionId = getCanonicalSessionId(sessionId);
  const existing = canonicalSessionId ? sessions.get(canonicalSessionId) : null;
  if (existing?.resumeSessionId) return existing.resumeSessionId;

  if (sessionId && !isSyntheticExternalSessionId(sessionId)) {
    return sessionId;
  }

  const allowRecentLookup = options.allowRecentLookup === true;
  if (!allowRecentLookup) {
    return null;
  }

  const record = findRecentExternalSessionRecord(agent, cwd, sessionId);
  return record?.sessionId || null;
}

function maybePromoteSessionToTmux(slot, resumeSessionId, extra = {}) {
  if (!slot || !TMUX_BIN || !resumeSessionId) return false;

  if (extra.cwd) {
    slot.cwd = extra.cwd;
    slot.folderName = path.basename(extra.cwd) || extra.cwd;
  }
  if (Number.isFinite(extra.createdAt)) {
    slot.createdAt = extra.createdAt;
  }

  slot.resumeSessionId = resumeSessionId;
  slot.externalSessionId = extra.externalSessionId || slot.externalSessionId || resumeSessionId;
  slot.tmuxSessionName = slot.tmuxSessionName || buildTmuxSessionName(slot.id, slot.agent);
  slot.tmuxPaneTarget = slot.tmuxPaneTarget || `${slot.tmuxSessionName}:0.0`;
  slot.tmuxLogFile = slot.tmuxLogFile || getTmuxLogFile(slot.id);
  slot.tmuxMetaFile = slot.tmuxMetaFile || getTmuxMetaFile(slot.id);

  registerExternalSessionAliases(slot, slot.externalSessionId, slot.resumeSessionId);

  if (slot.backend === "tmux") {
    persistTmuxSessionMetadata(slot);
    return true;
  }

  const promoted = createTmuxSession(slot);
  if (!promoted) return false;

  pushSseEvent("session", {
    state: "running",
    agent: slot.agent,
    cwd: slot.cwd,
    folderName: slot.folderName,
  }, slot.id);
  log("info", `Promoted ${slot.agent} session ${slot.id} into tmux via resume ${resumeSessionId}`);
  queueFlushIfReady(slot.id, "tmux-promoted");
  return true;
}

function registerManagedDesktopSession(agent, cwd) {
  if (!ensureDesktopPidRoot()) return null;

  const sessionId = crypto.randomUUID();
  const resolvedCwd = cwd || process.env.HOME || process.cwd();
  const folderName = path.basename(resolvedCwd) || resolvedCwd;
  const slot = {
    id: sessionId,
    agent,
    cwd: resolvedCwd,
    folderName,
    ptyProcess: null,
    state: "running",
    createdAt: Date.now(),
    backend: TMUX_BIN ? "tmux" : "pty",
    managedDesktop: true,
    pidFile: getDesktopPidFile(sessionId),
    externalSessionId: agent === "claude" ? sessionId : null,
    resumeSessionId: null,
    tmuxSessionName: TMUX_BIN ? buildTmuxSessionName(sessionId, agent) : null,
    tmuxPaneTarget: TMUX_BIN ? `${buildTmuxSessionName(sessionId, agent)}:0.0` : null,
    tmuxLogFile: TMUX_BIN ? getTmuxLogFile(sessionId) : null,
    tmuxMetaFile: TMUX_BIN ? getTmuxMetaFile(sessionId) : null,
    attachedTmuxPane: false,
    autoTrustState: agent === "claude" ? null : "confirmed",
  };

  sessions.set(sessionId, slot);
  pushSseEvent("session", { state: "running", agent, cwd: resolvedCwd, folderName }, sessionId);
  ensureSessionMonitoring(slot);
  return slot;
}

function recordDesktopLaunch(slot, actualSessionId = null) {
  if (!slot?.pidFile) return;

  pruneDesktopLaunchRecords();
  desktopLaunchRecords.push({
    agent: slot.agent,
    cwd: slot.cwd,
    pidFile: slot.pidFile,
    createdAt: Date.now(),
    claimedSessionId: actualSessionId,
    bridgeSessionId: slot.id,
  });
}

function claimDesktopLaunchSession(agent, cwd, actualSessionId = null, externalCreatedAt = null) {
  pruneDesktopLaunchRecords();

  const stableSessionId = isSyntheticExternalSessionId(actualSessionId) ? null : actualSessionId;

  const knownBridgeSessionId = getCanonicalSessionId(stableSessionId);
  if (knownBridgeSessionId && knownBridgeSessionId !== stableSessionId && sessions.has(knownBridgeSessionId)) {
    const slot = sessions.get(knownBridgeSessionId);
    if (stableSessionId) {
      slot.externalSessionId = stableSessionId;
      slot.resumeSessionId = stableSessionId;
      registerExternalSessionAliases(slot, stableSessionId);
    }
    return slot;
  }

  if (!stableSessionId) {
    return null;
  }

  for (let i = desktopLaunchRecords.length - 1; i >= 0; i--) {
    const record = desktopLaunchRecords[i];
    if (record.agent !== agent || record.cwd !== cwd) continue;
    if (record.claimedSessionId && record.claimedSessionId !== stableSessionId) continue;

    const slot = sessions.get(record.bridgeSessionId);
    if (!slot) continue;
    if (!isSessionTimingCompatible(slot.createdAt || record.createdAt, externalCreatedAt)) continue;

    record.claimedSessionId = stableSessionId || record.claimedSessionId || null;
    slot.managedDesktop = true;
    slot.pidFile = record.pidFile;
    if (stableSessionId) {
      slot.externalSessionId = stableSessionId;
      slot.resumeSessionId = stableSessionId;
      registerExternalSessionAliases(slot, stableSessionId);
    }
    return slot;
  }

  return null;
}

function buildLaunchCommand(slot) {
  const resolvedCwd = slot.cwd || process.env.HOME || process.cwd();
  if (slot.backend === "tmux" && slot.tmuxSessionName && TMUX_BIN) {
    const attachCommands = [];
    if (!slot.attachedTmuxPane && slot.pidFile) {
      attachCommands.push(`mkdir -p ${shellSingleQuote(DESKTOP_PID_ROOT)}`);
      attachCommands.push(`printf %s $$ > ${shellSingleQuote(slot.pidFile)}`);
    }
    attachCommands.push(`cd ${shellSingleQuote(resolvedCwd)}`);
    attachCommands.push(`exec ${shellSingleQuote(TMUX_BIN)} attach-session -t ${shellSingleQuote(slot.tmuxSessionName)}`);

    if (slot.attachedTmuxPane && slot.tmuxPaneTarget) {
      attachCommands[attachCommands.length - 1] = [
        `exec ${shellSingleQuote(TMUX_BIN)} attach-session -t ${shellSingleQuote(slot.tmuxSessionName)}`,
        `select-window -t ${shellSingleQuote(slot.tmuxPaneTarget)}`,
        `select-pane -t ${shellSingleQuote(slot.tmuxPaneTarget)}`,
      ].join(" \\; ");
    }

    return attachCommands.join(" && ");
  }

  const base = [];
  if (slot.pidFile) {
    base.push(`mkdir -p ${shellSingleQuote(DESKTOP_PID_ROOT)}`);
    base.push(`printf %s $$ > ${shellSingleQuote(slot.pidFile)}`);
  }
  base.push(`cd ${shellSingleQuote(resolvedCwd)}`);

  const bin = slot.agent === "codex" ? CODEX_BIN : CLAUDE_BIN;
  if (!bin) return null;

  base.push(`exec ${shellSingleQuote(bin)}${
    slot.agent === "codex"
      ? " --no-alt-screen"
      : ` --session-id ${shellSingleQuote(slot.id)}`
  }`);

  return base.join(" && ");
}

function launchDesktopTerminalSession(slot) {
  const shellCommand = buildLaunchCommand(slot);
  if (!shellCommand) return false;

  if (!slot.attachedTmuxPane) {
    recordDesktopLaunch(slot, slot.externalSessionId);
  }

  const osa = childSpawn("osascript", [
    "-e", 'tell application "Terminal"',
    "-e", "activate",
    "-e", `do script ${JSON.stringify(shellCommand)}`,
    "-e", "end tell",
  ], {
    stdio: ["ignore", "ignore", "pipe"],
  });

  osa.stderr.on("data", (data) => {
    log("warn", `Terminal launch stderr: ${data.toString().trim()}`);
  });

  osa.on("error", (err) => {
    log("error", `Failed to launch desktop terminal: ${err.message}`);
  });

  return true;
}

function enqueuePrompt(sessionId, command, front = false) {
  if (!sessionId || typeof command !== "string" || !command.trim()) return 0;

  const queue = queuedPrompts.get(sessionId) || [];
  const entry = { command, createdAt: Date.now() };
  if (front) {
    queue.unshift(entry);
  } else {
    queue.push(entry);
  }
  queuedPrompts.set(sessionId, queue);
  return queue.length;
}

function popQueuedPrompt(sessionId) {
  const queue = queuedPrompts.get(sessionId);
  if (!queue || queue.length === 0) return null;

  const next = queue.shift() || null;
  if (queue.length === 0) {
    queuedPrompts.delete(sessionId);
  } else {
    queuedPrompts.set(sessionId, queue);
  }
  return next;
}

function pushSseEvent(event, data, sessionId = null) {
  sseEventId++;

  // Inject sessionId into the data payload
  const payload = normalizeSsePayload(data);
  if (sessionId !== null && !["session", "session-heartbeat", "session-removed", "stop", "task-complete"].includes(event)) {
    touchSessionActivity(sessionId);
  }
  if (sessionId !== null) {
    payload.sessionId = sessionId;
    if (event === "session") {
      const slot = sessions.get(sessionId);
      if (slot) {
        Object.assign(payload, buildSessionPayload(slot, payload));
      }
    }
  }

  const entry = { id: sseEventId, event, data: JSON.stringify(payload) };
  appendSessionReplayEvent(sessionId, event, payload);

  // Ring buffer
  if (sseBuffer.length >= SSE_BUFFER_SIZE) {
    sseBuffer.shift();
  }
  sseBuffer.push(entry);

  // Broadcast to connected clients
  for (const client of sseClients) {
    if (!writeSseEvent(client, entry)) {
      sseClients.delete(client);
    }
  }
}

function formatSseMessage(entry) {
  let msg = `id: ${entry.id}\n`;
  msg += `event: ${entry.event}\n`;
  for (const line of entry.data.split("\n")) {
    msg += `data: ${line}\n`;
  }
  msg += "\n";
  return msg;
}

function padSseChunk(chunk, minBytes = SSE_MIN_CHUNK_BYTES) {
  const currentBytes = Buffer.byteLength(chunk);
  if (currentBytes >= minBytes) return chunk;

  const paddingBytes = Math.max(0, minBytes - currentBytes - 4);
  return `${chunk}:${" ".repeat(paddingBytes)}\n\n`;
}

function writeSseRaw(res, chunk) {
  if (!res || res.writableEnded || res.destroyed) return false;
  try {
    res.write(chunk);
    return true;
  } catch {
    return false;
  }
}

function writeSsePrelude(res) {
  const padding = " ".repeat(SSE_PRELUDE_PADDING_BYTES);
  return writeSseRaw(res, `: connected ${padding}\n\n`);
}

function writeSseEvent(res, entry) {
  return writeSseRaw(res, padSseChunk(formatSseMessage(entry)));
}

function writeSseHeartbeat(res) {
  return writeSseRaw(res, padSseChunk(`:heartbeat ${Date.now()}\n\n`));
}

// ---------------------------------------------------------------------------
// Multi-session PTY management
// ---------------------------------------------------------------------------

function spawnInteractiveProcess(agent, cwd, args = []) {
  const bin = agent === "codex" ? CODEX_BIN : CLAUDE_BIN;
  if (!bin) {
    return null;
  }
  const cols = parseInt(process.env.COLUMNS, 10) || 120;
  const rows = parseInt(process.env.LINES, 10) || 40;

  return childSpawn("script", ["-q", "/dev/null", bin, ...args], {
    cwd,
    env: {
      ...process.env,
      TERM: "xterm-256color",
      COLUMNS: String(cols),
      LINES: String(rows),
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
}

function hasInteractiveBackend(slot) {
  if (!slot || slot.state !== "running") return false;
  if (slot.backend === "tmux" && slot.tmuxSessionName) return true;
  return Boolean(slot.ptyProcess);
}

function bindPtyProcess(slot, proc) {
  const sessionId = slot.id;
  slot.ptyProcess = proc;
  slot.backend = slot.backend || "pty";

  proc.stdout.on("data", (data) => {
    pushSseEvent("pty-output", { text: data.toString() }, sessionId);
  });

  proc.stderr.on("data", (data) => {
    pushSseEvent("pty-output", { text: data.toString() }, sessionId);
  });

  proc.on("close", (exitCode, signal) => {
    if (slot.state === "removed") return;
    log("info", `Session ${sessionId} (${slot.agent}) PTY exited: code=${exitCode} signal=${signal}`);
    slot.state = "ended";
    slot.ptyProcess = null;
    clearCodexSyntheticPermissionForSession(sessionId, "pty-closed");
    pushSseEvent("session", { state: "ended", exitCode, signal, agent: slot.agent, folderName: slot.folderName }, sessionId);
  });

  proc.on("error", (err) => {
    if (slot.state === "removed") return;
    log("error", `Session ${sessionId} PTY spawn error: ${err.message}`);
    slot.state = "ended";
    slot.ptyProcess = null;
    clearCodexSyntheticPermissionForSession(sessionId, "pty-error");
    pushSseEvent("session", { state: "ended", error: err.message, agent: slot.agent, folderName: slot.folderName }, sessionId);
  });
}

function spawnSession(agent, cwd, options = {}) {
  const sessionId = crypto.randomUUID();
  const folderName = path.basename(cwd) || cwd;

  const slot = {
    id: sessionId,
    agent,
    cwd,
    folderName,
    ptyProcess: null,
    state: "running",
    createdAt: Date.now(),
    lastActivityAt: Date.now(),
    backend: TMUX_BIN ? "tmux" : "pty",
    managedDesktop: options.managedDesktop === true,
    pidFile: options.managedDesktop === true ? getDesktopPidFile(sessionId) : null,
    externalSessionId: agent === "claude" ? sessionId : null,
    resumeSessionId: null,
    tmuxSessionName: TMUX_BIN ? buildTmuxSessionName(sessionId, agent) : null,
    tmuxPaneTarget: TMUX_BIN ? `${buildTmuxSessionName(sessionId, agent)}:0.0` : null,
    tmuxLogFile: TMUX_BIN ? getTmuxLogFile(sessionId) : null,
    tmuxMetaFile: TMUX_BIN ? getTmuxMetaFile(sessionId) : null,
    attachedTmuxPane: false,
    autoTrustState: agent === "claude" ? null : "confirmed",
  };

  if (TMUX_BIN) {
    log("info", `Spawning ${agent} session ${sessionId} in tmux (cwd: ${cwd})`);
    const created = createTmuxSession(slot);
    if (!created) {
      const msg = `Cannot spawn ${agent}: failed to create tmux session`;
      log("error", msg);
      pushSseEvent("error", { error: msg });
      return null;
    }
  } else {
    log("info", `Spawning ${agent} session ${sessionId} in PTY (cwd: ${cwd})`);
    const proc = spawnInteractiveProcess(agent, cwd);
    if (!proc) {
      const msg = `Cannot spawn ${agent}: binary not found`;
      log("error", msg);
      pushSseEvent("error", { error: msg });
      return null;
    }
    bindPtyProcess(slot, proc);
    log("info", `Using binary: ${agent === "codex" ? CODEX_BIN : CLAUDE_BIN}`);
  }

  sessions.set(sessionId, slot);
  ensureSessionMonitoring(slot);

  pushSseEvent("session", { state: "running", agent, cwd, folderName }, sessionId);

  log("info", `${agent} session ${sessionId} started (${folderName})${slot.ptyProcess ? `, pid: ${slot.ptyProcess.pid}` : ""}`);
  return sessionId;
}

function attachPtyToSession(slot) {
  if (slot.backend === "external") return null;
  if (slot.backend === "tmux") return null;
  if (slot.ptyProcess) return slot.ptyProcess;
  if (slot.agent === "claude" && !slot.managedDesktop && !slot.externalSessionId && !slot.resumeSessionId) {
    return null;
  }

  const externalSessionId = slot.resumeSessionId || slot.externalSessionId || slot.id;
  const args = slot.agent === "codex"
    ? ["--no-alt-screen", "resume", externalSessionId]
    : ["--resume", externalSessionId];

  const proc = spawnInteractiveProcess(slot.agent, slot.cwd, args);
  if (!proc) return null;

  bindPtyProcess(slot, proc);
  log("info", `Attached PTY to session ${slot.id} (${slot.agent}), pid: ${proc.pid}`);
  return proc;
}

function killSession(sessionId) {
  const canonicalSessionId = getCanonicalSessionId(sessionId);
  const slot = sessions.get(canonicalSessionId);
  if (!slot) return false;

  const ownsTmuxSession = slot.backend === "tmux" && slot.tmuxSessionName && slot.managedDesktop === true;

  if (ownsTmuxSession) {
    runTmuxCommand(["kill-session", "-t", slot.tmuxSessionName], { allowFailure: true });
  } else if (slot.attachedTmuxPane === true) {
    unregisterTmuxLogFile(slot);
  } else if (slot.backend === "tmux" && slot.tmuxSessionName) {
    runTmuxCommand(["kill-session", "-t", slot.tmuxSessionName], { allowFailure: true });
  } else if (slot.ptyProcess) {
    try { slot.ptyProcess.kill("SIGTERM"); } catch { /* ignore */ }
  } else if (slot.pidFile) {
    try {
      const pid = Number(fs.readFileSync(slot.pidFile, "utf-8").trim());
      if (Number.isFinite(pid) && pid > 1) {
        process.kill(pid, "SIGTERM");
      }
    } catch {
      /* ignore */
    }
  }

  if (slot.pidFile) {
    try { fs.unlinkSync(slot.pidFile); } catch { /* ignore */ }
  }

  slot.state = "removed";
  slot.ptyProcess = null;
  queuedPrompts.delete(slot.id);
  claudeSessionFiles.delete(slot.id);
  unregisterTmuxLogFile(slot);
  sessionReplayBuffers.delete(slot.id);
  clearCodexSyntheticPermissionForSession(slot.id, "session-killed");
  if (ownsTmuxSession || slot.attachedTmuxPane !== true) {
    cleanupTmuxFiles(slot);
  }

  for (const [alias, target] of externalSessionAliases.entries()) {
    if (target === slot.id || alias === slot.externalSessionId) {
      externalSessionAliases.delete(alias);
    }
  }

  for (let i = desktopLaunchRecords.length - 1; i >= 0; i--) {
    if (desktopLaunchRecords[i].bridgeSessionId === slot.id) {
      desktopLaunchRecords.splice(i, 1);
    }
  }

  sessions.delete(slot.id);
  pushSseEvent("session-removed", { agent: slot.agent, folderName: slot.folderName, killed: true }, slot.id);
  log("info", `Session ${slot.id} killed and removed`);
  return true;
}

function queueFlushIfReady(sessionId, reason = "ready") {
  if (!queuedPrompts.has(sessionId)) return;
  setTimeout(() => {
    flushQueuedPrompt(sessionId, reason);
  }, 500);
}

function findManagedSlotForExternalSession(agent, cwd, actualSessionId = null, externalCreatedAt = null) {
  const claimed = claimDesktopLaunchSession(agent, cwd, actualSessionId, externalCreatedAt);
  if (claimed) {
    log("info", `Claimed managed desktop ${agent} slot ${claimed.id} for external session ${actualSessionId || "unknown"}`);
    return claimed;
  }

  const canonicalSessionId = getCanonicalSessionId(actualSessionId);
  if (canonicalSessionId && sessions.has(canonicalSessionId)) {
    return sessions.get(canonicalSessionId);
  }
  return null;
}

function createExternalSession(sessionId, agent, cwd, createdAt, extra = {}) {
  const resolvedCwd = cwd || process.env.HOME || process.cwd();
  const folderName = path.basename(resolvedCwd) || resolvedCwd;
  const slot = {
    id: sessionId,
    agent,
    cwd: resolvedCwd,
    folderName,
    ptyProcess: null,
    state: "running",
    createdAt: createdAt || Date.now(),
    lastActivityAt: extra.lastActivityAt || createdAt || Date.now(),
    backend: extra.backend || "external",
    managedDesktop: extra.managedDesktop === true,
    pidFile: extra.pidFile || null,
    externalSessionId: extra.externalSessionId || null,
    resumeSessionId: extra.resumeSessionId || null,
    externalProcessPid: Number.isFinite(extra.externalProcessPid) ? extra.externalProcessPid : null,
    externalTty: extra.externalTty || null,
    tmuxSessionName: extra.tmuxSessionName || null,
    tmuxPaneTarget: extra.tmuxPaneTarget || null,
    tmuxPanePid: Number.isFinite(extra.tmuxPanePid) ? extra.tmuxPanePid : null,
    tmuxPaneTty: extra.tmuxPaneTty || null,
    tmuxLogFile: extra.tmuxLogFile || null,
    tmuxMetaFile: extra.tmuxMetaFile || null,
    attachedTmuxPane: extra.attachedTmuxPane === true,
    autoTrustState: agent === "claude" ? null : "confirmed",
  };

  sessions.set(sessionId, slot);
  registerExternalSessionAliases(slot, slot.externalSessionId, slot.resumeSessionId);
  pushSseEvent("session", { state: "running", agent, cwd: resolvedCwd, folderName }, sessionId);
  ensureSessionMonitoring(slot);
  return slot;
}

function encodeClaudeProjectDir(cwd) {
  return String(cwd || process.env.HOME || process.cwd()).replace(/[^A-Za-z0-9]/g, "-");
}

function getClaudeSessionFilePath(slotOrSessionId, cwd = null) {
  const sessionId = typeof slotOrSessionId === "string" ? slotOrSessionId : slotOrSessionId?.externalSessionId || slotOrSessionId?.id;
  const resolvedCwd = cwd || (typeof slotOrSessionId === "string" ? null : slotOrSessionId?.cwd) || process.env.HOME || process.cwd();
  if (!sessionId) return null;
  return path.join(CLAUDE_PROJECTS_ROOT, encodeClaudeProjectDir(resolvedCwd), `${sessionId}.jsonl`);
}

function ensureClaudeSessionTracking(slot) {
  if (!slot || slot.agent !== "claude") return;

  const filePath = getClaudeSessionFilePath(slot);
  if (!filePath) return;

  const existing = claudeSessionFiles.get(slot.id);
  if (existing && existing.filePath === filePath) return;

  claudeSessionFiles.set(slot.id, {
    filePath,
    offset: 0,
    remainder: "",
    initialized: false,
  });
}

function ensureSessionMonitoring(slot) {
  if (!slot) return;
  if (slot.agent === "claude") {
    ensureClaudeSessionTracking(slot);
  }
}

function findSessionByCwd(cwd, agent = null) {
  if (!cwd) return null;
  const matches = [];
  for (const [, slot] of sessions) {
    if (slot.state !== "running") continue;
    if (slot.cwd !== cwd) continue;
    if (agent && slot.agent !== agent) continue;
    matches.push(slot);
  }
  return matches.length === 1 ? matches[0] : null;
}

function findUniqueInteractiveSessionByCwd(cwd, agent = null, options = {}) {
  if (!cwd) return null;

  const maxIdleMs = Number.isFinite(options.maxIdleMs) ? options.maxIdleMs : null;
  const matches = [];
  for (const [, slot] of sessions) {
    if (slot.state !== "running") continue;
    if (slot.cwd !== cwd) continue;
    if (agent && slot.agent !== agent) continue;
    if (!hasInteractiveBackend(slot)) continue;
    if (maxIdleMs !== null && Date.now() - getSessionActivityTimestamp(slot) > maxIdleMs) continue;
    matches.push(slot);
  }

  return matches.length === 1 ? matches[0] : null;
}

function getSessionActivityTimestamp(slot) {
  return slot?.lastActivityAt || slot?.createdAt || 0;
}

function findMostRecentlyActiveSessionByCwd(cwd, agent = null, options = {}) {
  if (!cwd) return null;

  const requireInteractive = options.requireInteractive === true;
  const preferSharedTerminal = options.preferSharedTerminal !== false;
  const preferWritable = options.preferWritable !== false;
  const maxIdleMs = Number.isFinite(options.maxIdleMs) ? options.maxIdleMs : null;
  const filter = typeof options.filter === "function" ? options.filter : null;

  const matches = [];
  for (const [, slot] of sessions) {
    if (slot.state !== "running") continue;
    if (slot.cwd !== cwd) continue;
    if (agent && slot.agent !== agent) continue;
    if (requireInteractive && !hasInteractiveBackend(slot)) continue;
    if (filter && !filter(slot)) continue;
    matches.push(slot);
  }

  if (matches.length === 0) return null;

  matches.sort((lhs, rhs) => {
    const activityDelta = getSessionActivityTimestamp(rhs) - getSessionActivityTimestamp(lhs);
    if (activityDelta) return activityDelta;

    if (preferSharedTerminal) {
      const sharedDelta = Number(isSharedTerminalSession(rhs)) - Number(isSharedTerminalSession(lhs));
      if (sharedDelta) return sharedDelta;
    }

    if (preferWritable) {
      const writableDelta = Number(isSessionWritable(rhs)) - Number(isSessionWritable(lhs));
      if (writableDelta) return writableDelta;
    }

    return (rhs.createdAt || 0) - (lhs.createdAt || 0);
  });

  const best = matches[0];
  if (maxIdleMs !== null && Date.now() - getSessionActivityTimestamp(best) > maxIdleMs) {
    return null;
  }

  return best;
}

function findAliasCandidateForStableExternalSession(agent, cwd, stableExternalSessionId) {
  if (!stableExternalSessionId || isSyntheticExternalSessionId(stableExternalSessionId)) {
    return null;
  }

  for (const [, slot] of sessions) {
    if (slot.state !== "running") continue;
    if (slot.agent !== agent) continue;
    if (
      slot.id === stableExternalSessionId
      || slot.externalSessionId === stableExternalSessionId
      || slot.resumeSessionId === stableExternalSessionId
    ) {
      return slot;
    }
  }
  return null;
}

function findMostRecentActiveSession(agent = null) {
  let best = null;
  for (const [, slot] of sessions) {
    if (agent && slot.agent !== agent) continue;
    if (hasInteractiveBackend(slot)) {
      if (!best || slot.createdAt > best.createdAt) {
        best = slot;
      }
    }
  }
  return best;
}

function findMostRecentRunningSession() {
  let best = null;
  for (const [, slot] of sessions) {
    if (slot.state === "running") {
      if (!best || slot.createdAt > best.createdAt) {
        best = slot;
      }
    }
  }
  return best;
}

function inferRecentLineType(text) {
  const trimmed = String(text || "").trim();
  if (!trimmed) return "output";
  if (trimmed.startsWith("> ") || trimmed.startsWith("$ ")) return "command";
  if (
    trimmed.startsWith("[queued prompt]")
    || trimmed.startsWith("[launching]")
    || trimmed.startsWith("Task completed")
    || trimmed.startsWith("Session stopped")
  ) {
    return "system";
  }
  if (trimmed.startsWith("Error:") || trimmed.startsWith("ERR ")) {
    return "error";
  }
  return "output";
}

function buildRecentTerminalLines(slot) {
  const bootstrapText = slot?.backend === "tmux" ? getTmuxBootstrapText(slot) : "";
  if (bootstrapText) {
    const baseTs = Date.now();
    return bootstrapText
      .split("\n")
      .map((line) => line.trimEnd())
      .filter((line) => line.trim().length > 0)
      .slice(-40)
      .map((line, index, arr) => ({
        text: line,
        type: inferRecentLineType(line),
        timestamp: (baseTs - ((arr.length - index) * 250)) / 1000,
      }));
  }

  const replay = getSessionReplayEntries(slot?.id).slice(-30);
  const baseTs = Date.now();
  const lines = [];

  for (const entry of replay) {
    const data = entry.data || {};
    if (entry.event === "conversation-message") {
      const text = String(data.text || "").trim();
      if (!text) continue;
      lines.push({
        text: data.role === "user" ? `> ${text}` : text,
        type: data.role === "user" ? "command" : "output",
        timestamp: baseTs / 1000,
      });
      continue;
    }

    if (entry.event === "pty-output") {
      const text = String(data.text || "");
      for (const line of text.split("\n")) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        lines.push({
          text: trimmed,
          type: inferRecentLineType(trimmed),
          timestamp: baseTs / 1000,
        });
      }
      continue;
    }

    if (entry.event === "error") {
      const message = String(data.error || data.message || "").trim();
      if (!message) continue;
      lines.push({
        text: message,
        type: "error",
        timestamp: baseTs / 1000,
      });
    }
  }

  return lines.slice(-40);
}

function getSessionsSnapshot(options = {}) {
  const includeRecentEvents = options.includeRecentEvents === true;
  const includeRecentLines = options.includeRecentLines === true;
  return getSortedSessions()
    .filter((s) => s.state !== "ended" && s.state !== "removed")
    .map((s) => ({
    id: s.id,
    agent: s.agent,
    cwd: s.cwd,
    folderName: s.folderName,
    state: s.state,
    backend: s.backend || "external",
    writable: isSessionWritable(s),
    sharedTerminal: isSharedTerminalSession(s),
    externalSessionId: s.externalSessionId || null,
    resumeSessionId: s.resumeSessionId || null,
    tmuxSessionName: s.tmuxSessionName || null,
    tmuxPaneTarget: getTmuxPaneTarget(s),
    createdAt: s.createdAt,
    lastActivityAt: s.lastActivityAt || null,
    ...(includeRecentEvents ? { recentEvents: getSessionReplayEntries(s.id) } : {}),
    ...(includeRecentLines ? { recentLines: buildRecentTerminalLines(s) } : {}),
    }));
}

function safeStat(targetPath) {
  try {
    return fs.statSync(targetPath);
  } catch {
    return null;
  }
}

function listRecentCodexSessionFiles(rootDir) {
  const results = [];
  const stack = [rootDir];

  while (stack.length > 0) {
    const current = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
        continue;
      }
      if (!entry.isFile() || !entry.name.endsWith(".jsonl")) continue;
      const stat = safeStat(fullPath);
      if (!stat) continue;
      results.push({ filePath: fullPath, mtimeMs: stat.mtimeMs, size: stat.size });
    }
  }

  results.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return results.slice(0, CODEX_SESSION_SCAN_LIMIT);
}

function readFileSlice(filePath, start, length) {
  const fd = fs.openSync(filePath, "r");
  try {
    const buffer = Buffer.alloc(length);
    const bytesRead = fs.readSync(fd, buffer, 0, length, start);
    return buffer.subarray(0, bytesRead).toString("utf-8");
  } finally {
    fs.closeSync(fd);
  }
}

function emitConversationMessage(sessionId, role, text, meta = {}) {
  const normalizedText = String(text || "").trim();
  if (!sessionId || !normalizedText) return;

  pushSseEvent("conversation-message", {
    source: meta.source || "claude",
    role,
    text: normalizedText,
    phase: meta.phase || null,
    uuid: meta.uuid || null,
    timestamp: meta.timestamp || null,
  }, sessionId);
}

function extractClaudeMessageText(message) {
  if (!message || typeof message !== "object") return "";
  const content = message.content;

  if (typeof content === "string") {
    return content.trim();
  }

  if (!Array.isArray(content)) return "";

  const parts = [];
  for (const item of content) {
    if (!item || typeof item !== "object") continue;

    if (item.type === "text" && typeof item.text === "string") {
      const text = item.text.trim();
      if (text) parts.push(text);
      continue;
    }

    if (item.type === "tool_result" || item.type === "tool_use" || item.type === "thinking") {
      continue;
    }

    if (typeof item.content === "string") {
      const text = item.content.trim();
      if (text) parts.push(text);
    }
  }

  return parts.join("\n\n").trim();
}

function processClaudeSessionLine(sessionId, line) {
  const parsed = parseJsonLine(line);
  if (!parsed) return;

  if (parsed.type === "user" && parsed.message?.role === "user") {
    const text = extractClaudeMessageText(parsed.message);
    if (text) {
      emitConversationMessage(sessionId, "user", text, {
        uuid: parsed.uuid,
        timestamp: parsed.timestamp,
      });
    }
    return;
  }

  if (parsed.type === "assistant" && parsed.message?.role === "assistant") {
    const text = extractClaudeMessageText(parsed.message);
    if (text) {
      emitConversationMessage(sessionId, "assistant", text, {
        uuid: parsed.uuid,
        timestamp: parsed.timestamp,
      });
    }
  }
}

function initializeClaudeSessionFile(sessionId, fileState, stat) {
  const allowBootstrap = Date.now() - stat.mtimeMs <= CLAUDE_SESSION_BOOTSTRAP_LOOKBACK_MS;
  if (!allowBootstrap) {
    fileState.offset = stat.size;
    fileState.remainder = "";
    fileState.initialized = true;
    return;
  }

  const bootstrapSize = Math.min(stat.size, CLAUDE_SESSION_BOOTSTRAP_MAX_BYTES);
  const startOffset = Math.max(0, stat.size - bootstrapSize);
  const bootstrapText = bootstrapSize > 0 ? readFileSlice(fileState.filePath, startOffset, bootstrapSize) : "";
  const lines = bootstrapText.split("\n");

  if (startOffset > 0) {
    lines.shift();
  }

  for (const line of lines) {
    if (!line.trim()) continue;
    processClaudeSessionLine(sessionId, line);
  }

  fileState.offset = stat.size;
  fileState.remainder = "";
  fileState.initialized = true;
}

function readClaudeSessionFileDelta(sessionId, fileState, stat) {
  if (stat.size < fileState.offset) {
    fileState.offset = 0;
    fileState.remainder = "";
    fileState.initialized = false;
  }

  if (!fileState.initialized) {
    initializeClaudeSessionFile(sessionId, fileState, stat);
    return;
  }

  if (stat.size === fileState.offset) return;

  const delta = readFileSlice(fileState.filePath, fileState.offset, stat.size - fileState.offset);
  fileState.offset = stat.size;

  let chunk = fileState.remainder + delta;
  const lines = chunk.split("\n");
  fileState.remainder = lines.pop() ?? "";

  for (const line of lines) {
    if (!line.trim()) continue;
    processClaudeSessionLine(sessionId, line);
  }
}

function scanClaudeSessionFiles() {
  for (const [sessionId, fileState] of claudeSessionFiles.entries()) {
    const slot = sessions.get(sessionId);
    if (!slot || slot.state === "removed") {
      claudeSessionFiles.delete(sessionId);
      continue;
    }

    const stat = safeStat(fileState.filePath);
    if (!stat || !stat.isFile()) continue;

    readClaudeSessionFileDelta(sessionId, fileState, stat);
    claudeSessionFiles.set(sessionId, fileState);
  }
}

function touchExternalSession(sessionId, cwd, createdAt, agent = "codex", extra = {}) {
  const resolvedCwd = cwd || process.env.HOME || process.cwd();
  const folderName = path.basename(resolvedCwd) || resolvedCwd;
  const resumeSessionId = resolveResumeSessionId(agent, resolvedCwd, sessionId, {
    allowRecentLookup: extra.allowRecentLookup === true,
  });
  const actualSessionId = resumeSessionId || sessionId || crypto.randomUUID();
  const stableExternalSessionId = isSyntheticExternalSessionId(actualSessionId) ? null : actualSessionId;
  const effectiveCreatedAt = createdAt || extra.createdAt || Date.now();
  const hasProcessHints = Number.isFinite(extra.externalProcessPid) || Boolean(extra.externalTty);
  const shouldCheckLiveProcesses = hasProcessHints
    || agent !== "codex"
    || isSyntheticExternalSessionId(sessionId)
    || isSyntheticExternalSessionId(actualSessionId)
    || Number.isFinite(effectiveCreatedAt);
  if (shouldCheckLiveProcesses) {
    refreshLiveAgentProcesses();
  }

  const exactLiveProcess = stableExternalSessionId
    ? findExactLiveAgentProcess(agent, stableExternalSessionId, resolvedCwd)
    : null;
  const timeMatchedLiveProcess = !hasProcessHints
    && !exactLiveProcess
    ? findTimeCompatibleLiveAgentProcess(agent, resolvedCwd, effectiveCreatedAt)
    : null;
  const managedSlot = !exactLiveProcess && !timeMatchedLiveProcess && stableExternalSessionId
    ? findManagedSlotForExternalSession(agent, resolvedCwd, stableExternalSessionId, effectiveCreatedAt)
    : null;
  const shouldMatchLiveProcess = !managedSlot && (
    hasProcessHints
    || Boolean(exactLiveProcess)
    || Boolean(timeMatchedLiveProcess)
    || agent !== "codex"
    || isSyntheticExternalSessionId(sessionId)
    || isSyntheticExternalSessionId(actualSessionId)
  );
  const liveProcess = shouldMatchLiveProcess
    ? (exactLiveProcess || timeMatchedLiveProcess || findMatchingLiveAgentProcess(agent, resolvedCwd, {
      pid: extra.externalProcessPid,
      tty: extra.externalTty,
    }))
    : null;
  const matchedTmuxPane = extra.matchedTmuxPane || findTmuxPaneForTty(liveProcess?.tty || extra.externalTty);
  const existingLiveSlot = liveProcess ? findSessionForLiveProcess(liveProcess) : null;
  const aliasCandidate = !managedSlot && !existingLiveSlot && stableExternalSessionId
    ? findAliasCandidateForStableExternalSession(agent, resolvedCwd, stableExternalSessionId)
    : null;
  const allowAutoPromote = extra.allowAutoPromote === true || Boolean(managedSlot);

  // Also allow creating a session from recent session-file data even if the live process
  // isn't visible in `ps` (e.g. different TTY grouping, locale issues, or the scan hasn't
  // caught up yet). "Recent" = modified within the bootstrap look-back window.
  const recencyWindowMs = agent === "claude"
    ? CLAUDE_SESSION_BOOTSTRAP_LOOKBACK_MS
    : CODEX_SESSION_BOOTSTRAP_LOOKBACK_MS;
  const sessionIsRecent = effectiveCreatedAt && (Date.now() - effectiveCreatedAt) <= recencyWindowMs;
  if (!managedSlot && !liveProcess && !sessionIsRecent && !resumeSessionId) {
    return null;
  }
  const canonicalSessionId = managedSlot?.id
    || getCanonicalSessionId(stableExternalSessionId)
    || getCanonicalSessionId(actualSessionId)
    || getCanonicalSessionId(sessionId)
    || actualSessionId;
  // Also match by tmux pane: if another session already owns the same pane,
  // reuse it instead of creating a duplicate (e.g. Codex process restart in the same pane).
  const existingByTmuxPane = !managedSlot && !existingLiveSlot && !aliasCandidate && matchedTmuxPane
    ? [...sessions.values()]
        .filter(s =>
          s.state === "running"
          && s.agent === agent
          && getTmuxPaneTarget(s) === (matchedTmuxPane.paneTarget || matchedTmuxPane.paneId)
        )
        .sort(compareSessionOwnershipPreference)[0]
    : null;
  if (existingByTmuxPane) {
    log("info", `Matched ${agent} session by tmux pane ${getTmuxPaneTarget(existingByTmuxPane)} (existing ${existingByTmuxPane.id}, incoming ${stableExternalSessionId || sessionId})`);
  }
  const existing = sessions.get(canonicalSessionId) || existingLiveSlot || aliasCandidate || existingByTmuxPane;

  if (!existing && agent === "codex" && !managedSlot && !liveProcess && !matchedTmuxPane && extra.allowDetachedCreate !== true) {
    log("info", `Skipped detached codex session ${stableExternalSessionId || actualSessionId || sessionId} (${folderName}) from file-only detection`);
    return null;
  }

  if (existing) {
    const wasEnded = existing.state !== "running";
    const previousBackend = existing.backend;
    const previousPaneTarget = getTmuxPaneTarget(existing);
    existing.agent = agent;
    existing.cwd = resolvedCwd;
    existing.folderName = folderName;
    existing.state = "running";
    existing.createdAt = existing.createdAt || effectiveCreatedAt || Date.now();
    existing.lastActivityAt = Date.now();
    existing.managedDesktop = existing.managedDesktop || Boolean(managedSlot);
    existing.pidFile = existing.pidFile || managedSlot?.pidFile || null;
    existing.externalSessionId = stableExternalSessionId || existing.externalSessionId || null;
    existing.resumeSessionId = stableExternalSessionId || resumeSessionId || existing.resumeSessionId || existing.externalSessionId || null;
    existing.externalProcessPid = liveProcess?.pid || extra.externalProcessPid || existing.externalProcessPid || null;
    existing.externalTty = liveProcess?.tty || extra.externalTty || existing.externalTty || null;
    registerExternalSessionAliases(existing, sessionId, stableExternalSessionId, resumeSessionId);
    if (matchedTmuxPane && shouldAdoptMatchedTmuxPane(existing, matchedTmuxPane)) {
      adoptExistingTmuxPane(existing, matchedTmuxPane, {
        externalSessionId: stableExternalSessionId,
        resumeSessionId: existing.resumeSessionId,
      });
      log("info", `Attached ${agent} session ${existing.id} to tmux pane ${getTmuxPaneTarget(existing)} for external session ${stableExternalSessionId || actualSessionId || sessionId}`);
      if (!wasEnded && (previousBackend !== "tmux" || previousPaneTarget !== getTmuxPaneTarget(existing))) {
        pushSseEvent("session", { state: "running", agent, cwd: resolvedCwd, folderName }, existing.id);
      }
    } else if (existing.backend !== "tmux" && existing.resumeSessionId && (allowAutoPromote || existing.managedDesktop)) {
      maybePromoteSessionToTmux(existing, existing.resumeSessionId, {
        cwd: resolvedCwd,
        createdAt: effectiveCreatedAt,
        externalSessionId: stableExternalSessionId,
      });
    }
    persistTmuxSessionMetadata(existing);
    // Clean up any other sessions that point to the same tmux pane (stale duplicates).
    const currentPaneTarget = getTmuxPaneTarget(existing);
    if (currentPaneTarget) {
      for (const [otherId, other] of sessions) {
        if (otherId !== existing.id && other.state === "running" && getTmuxPaneTarget(other) === currentPaneTarget) {
          log("info", `Ending duplicate session ${otherId} — same tmux pane ${currentPaneTarget} as ${existing.id}`);
          other.state = "ended";
          pushSseEvent("session", { state: "ended", agent: other.agent, folderName: other.folderName, reason: "duplicate-pane" }, otherId);
        }
      }
    }
    if (wasEnded) {
      pushSseEvent("session", { state: "running", agent, cwd: resolvedCwd, folderName }, existing.id);
      log("info", `Revived ${agent} session ${existing.id} (${folderName}) from local session data`);
    }
    ensureSessionMonitoring(existing);
    if (agent === "codex" && sessionId && codexOpenExecApprovals.has(sessionId)) {
      surfaceCodexExecApproval(sessionId);
    }
    queueFlushIfReady(existing.id, "desktop-session-ready");
    return existing;
  }

  const slot = createExternalSession(canonicalSessionId, agent, resolvedCwd, effectiveCreatedAt, {
    backend: matchedTmuxPane ? "tmux" : "external",
    managedDesktop: Boolean(managedSlot),
    pidFile: managedSlot?.pidFile || null,
    externalSessionId: stableExternalSessionId || actualSessionId,
    resumeSessionId: stableExternalSessionId || resumeSessionId,
    externalProcessPid: liveProcess?.pid || extra.externalProcessPid || null,
    externalTty: liveProcess?.tty || extra.externalTty || null,
    tmuxSessionName: matchedTmuxPane?.sessionName || null,
    tmuxPaneTarget: matchedTmuxPane?.paneTarget || matchedTmuxPane?.paneId || null,
    tmuxPanePid: matchedTmuxPane?.panePid || null,
    tmuxPaneTty: matchedTmuxPane?.paneTty || null,
    attachedTmuxPane: Boolean(matchedTmuxPane),
  });
  if (matchedTmuxPane) {
    adoptExistingTmuxPane(slot, matchedTmuxPane, {
      externalSessionId: stableExternalSessionId,
      resumeSessionId: slot.resumeSessionId,
    });
    log("info", `Created ${agent} session ${slot.id} from external session ${stableExternalSessionId || actualSessionId || sessionId} on tmux pane ${getTmuxPaneTarget(slot)}`);
  } else if (slot.resumeSessionId && (allowAutoPromote || slot.managedDesktop)) {
    maybePromoteSessionToTmux(slot, slot.resumeSessionId, {
      cwd: resolvedCwd,
      createdAt: effectiveCreatedAt,
      externalSessionId: stableExternalSessionId,
    });
  }
  persistTmuxSessionMetadata(slot);
  // Clean up any other sessions that point to the same tmux pane (stale duplicates).
  const newPaneTarget = getTmuxPaneTarget(slot);
  if (newPaneTarget) {
    for (const [otherId, other] of sessions) {
      if (otherId !== slot.id && other.state === "running" && getTmuxPaneTarget(other) === newPaneTarget) {
        log("info", `Ending duplicate session ${otherId} — same tmux pane ${newPaneTarget} as new session ${slot.id}`);
        other.state = "ended";
        pushSseEvent("session", { state: "ended", agent: other.agent, folderName: other.folderName, reason: "duplicate-pane" }, otherId);
      }
    }
  }
  log("info", `Detected ${agent} session ${slot.id} (${folderName}) from local session data`);
  if (agent === "codex" && sessionId && codexOpenExecApprovals.has(sessionId)) {
    surfaceCodexExecApproval(sessionId);
  }
  queueFlushIfReady(slot.id, "desktop-session-ready");
  return slot;
}

function endExternalSession(sessionId, reason = "codex-exit") {
  const canonicalSessionId = getCanonicalSessionId(sessionId);
  const slot = sessions.get(canonicalSessionId);
  if (!slot || slot.state === "ended") return;
  slot.state = "ended";
  slot.ptyProcess = null;
  queuedPrompts.delete(slot.id);
  clearCodexSyntheticPermissionForSession(slot.id, reason);
  if (sessionId && sessionId !== slot.id) {
    externalSessionAliases.delete(sessionId);
  }
  pushSseEvent("session", { state: "ended", agent: slot.agent, folderName: slot.folderName, reason }, slot.id);
  log("info", `Marked external session ${slot.id} as ended (${reason})`);
}

function parseJsonLine(line) {
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

function parseFunctionCallArgs(rawArgs) {
  if (typeof rawArgs !== "string") return {};
  try {
    const parsed = JSON.parse(rawArgs);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function extractPatchPaths(rawPatch) {
  if (typeof rawPatch !== "string" || rawPatch.length === 0) return [];
  const paths = [];
  for (const line of rawPatch.split("\n")) {
    const match = line.match(/^\*\*\* (?:Update|Add|Delete) File: (.+)$/);
    if (match) paths.push(match[1]);
  }
  return [...new Set(paths)];
}

function emitCodexToolEvent(sessionId, toolName, toolInput = {}, toolOutput = null) {
  pushSseEvent("tool-output", {
    source: "codex",
    tool_name: toolName,
    tool_input: toolInput,
    tool_output: toolOutput,
  }, sessionId);
}

function emitCodexToolResult(sessionId, pendingCall, output) {
  if (!pendingCall || !sessionId) return;

  switch (pendingCall.name) {
    case "exec_command":
      emitCodexToolEvent(sessionId, "Bash", { command: pendingCall.args.cmd || "" }, output);
      break;
    case "apply_patch": {
      const patchPaths = extractPatchPaths(pendingCall.args.patch);
      if (patchPaths.length === 0) {
        emitCodexToolEvent(sessionId, "Edit", {}, output);
        break;
      }
      for (const filePath of patchPaths) {
        emitCodexToolEvent(sessionId, "Edit", { file_path: filePath }, output);
      }
      break;
    }
    default:
      emitCodexToolEvent(sessionId, pendingCall.name, pendingCall.args, output);
      break;
  }
}

function truncateText(value, maxLength = 80) {
  if (typeof value !== "string") return "";
  return value.length > maxLength ? `${value.slice(0, maxLength - 1)}…` : value;
}

function buildCodexApprovalOptions(prefixRule = []) {
  const options = [
    {
      label: "Yes, proceed",
      description: "Run this command once",
    },
  ];

  if (Array.isArray(prefixRule) && prefixRule.length > 0) {
    options.push({
      label: "Yes, don't ask again",
      description: `Trust ${prefixRule.join(" ")} in future`,
    });
  }

  options.push({
    label: "No",
    description: "Deny this command and return to Codex",
  });

  return options;
}

function findCodexSessionStateByExternalId(externalSessionId) {
  if (!externalSessionId) return null;
  for (const fileState of codexSessionFiles.values()) {
    if (fileState.sessionId === externalSessionId) {
      return fileState;
    }
  }
  return null;
}

function recordCodexExecApprovalCandidate(line) {
  const match = line.match(/ToolCall: exec_command (\{.*\}) thread_id=([0-9a-f-]+)/i);
  if (!match) return;

  let args;
  try {
    args = JSON.parse(match[1]);
  } catch {
    return;
  }

  const candidate = {
    command: args.cmd || "",
    justification: args.justification || "Codex requests permission to run this command.",
    workdir: args.workdir || "",
    prefixRule: Array.isArray(args.prefix_rule) ? args.prefix_rule : [],
    createdAt: Date.now(),
  };

  codexRecentExecCommands.set(match[2], candidate);

  if (args?.sandbox_permissions !== "require_escalated") return;
  codexExecApprovalCandidates.set(match[2], candidate);
}

function getCodexExecApprovalCandidate(sessionId) {
  return codexExecApprovalCandidates.get(sessionId)
    || codexRecentExecCommands.get(sessionId)
    || {
      command: "",
      justification: "Codex requests permission to continue.",
      workdir: "",
      prefixRule: [],
      createdAt: Date.now(),
    };
}

function recordCodexExecApprovalCandidateFromArgs(sessionId, args = {}) {
  if (!sessionId || !args || typeof args !== "object") return null;

  const candidate = {
    command: args.cmd || "",
    justification: args.justification || "Codex requests permission to run this command.",
    workdir: args.workdir || "",
    prefixRule: Array.isArray(args.prefix_rule) ? args.prefix_rule : [],
    createdAt: Date.now(),
  };

  codexRecentExecCommands.set(sessionId, candidate);
  if (args?.sandbox_permissions === "require_escalated") {
    codexExecApprovalCandidates.set(sessionId, candidate);
    return candidate;
  }

  return null;
}

function surfaceCodexExecApproval(sessionId) {
  const canonicalSessionId = getCanonicalSessionId(sessionId);
  let slot = sessions.get(canonicalSessionId);
  const candidate = getCodexExecApprovalCandidate(sessionId);
  if (!slot) {
    for (const existing of sessions.values()) {
      if (existing.externalSessionId === sessionId) {
        slot = existing;
        break;
      }
    }
  }
  if (!slot) {
    const fileState = findCodexSessionStateByExternalId(sessionId);
    if (fileState?.cwd) {
      slot = touchExternalSession(sessionId, fileState.cwd, fileState.createdAt, "codex");
    }
  }
  if (!slot) {
    log("info", `Deferred Codex approval for thread ${sessionId} until its session is mapped`);
    return false;
  }

  const targetSessionId = slot.id;
  const existingId = codexSyntheticPermissionBySession.get(targetSessionId);
  if (existingId) return true;

  const permissionId = crypto.randomUUID();
  const options = buildCodexApprovalOptions(candidate.prefixRule);
  const payload = {
    permissionId,
    source: "codex",
    tool_name: "ExecApproval",
    tool_input: {
      command: candidate.command,
      workdir: candidate.workdir,
      questions: [
        {
          header: truncateText(`Run: ${candidate.command}`, 72),
          question: candidate.justification || "Would you like to run this command?",
          options,
        },
      ],
    },
  };
  codexSyntheticPermissions.set(permissionId, { sessionId: targetSessionId, optionCount: options.length, payload });
  codexSyntheticPermissionBySession.set(targetSessionId, permissionId);

  pushSseEvent("permission-request", payload, targetSessionId);

  log("info", `Surfaced Codex approval ${permissionId} for session ${targetSessionId}`);
  return true;
}

function clearCodexSyntheticPermissionForSession(sessionId, reason = "cleared") {
  const canonicalSessionId = getCanonicalSessionId(sessionId);
  let resolvedSessionId = canonicalSessionId;
  let permissionId = codexSyntheticPermissionBySession.get(resolvedSessionId);
  if (!permissionId) {
    for (const existing of sessions.values()) {
      if (existing.externalSessionId === sessionId) {
        resolvedSessionId = existing.id;
        permissionId = codexSyntheticPermissionBySession.get(resolvedSessionId);
        if (permissionId) break;
      }
    }
  }
  if (!permissionId) return false;

  codexSyntheticPermissionBySession.delete(resolvedSessionId);
  codexSyntheticPermissions.delete(permissionId);
  codexExecApprovalCandidates.delete(sessionId);
  codexRecentExecCommands.delete(sessionId);
  codexOpenExecApprovals.delete(sessionId);
  const slot = sessions.get(resolvedSessionId);
  if (slot?.externalSessionId && slot.externalSessionId !== resolvedSessionId) {
    codexExecApprovalCandidates.delete(slot.externalSessionId);
    codexRecentExecCommands.delete(slot.externalSessionId);
    codexOpenExecApprovals.delete(slot.externalSessionId);
  }
  // Remember this session was recently resolved so the log-file path
  // (which may arrive late) doesn't re-surface the same approval.
  codexRecentlyResolvedApprovals.set(sessionId, Date.now());
  if (slot?.externalSessionId && slot.externalSessionId !== sessionId) {
    codexRecentlyResolvedApprovals.set(slot.externalSessionId, Date.now());
  }
  pushSseEvent("permission-cleared", { permissionId, reason }, resolvedSessionId);
  return true;
}

function resolveCodexSyntheticPermission(permissionId, selectedOption, optionIndex) {
  const synthetic = codexSyntheticPermissions.get(permissionId);
  if (!synthetic) return false;

  const slot = sessions.get(synthetic.sessionId);
  if (!slot) return false;

  let input = "\u001b";
  const normalizedIndex = Number.isInteger(optionIndex) ? optionIndex : -1;
  const normalizedOption = String(selectedOption || "").trim().toLowerCase();

  if (
    normalizedIndex === 0
    || /^(y|yes|1)$/.test(normalizedOption)
    || /^yes,?\s*proceed/.test(normalizedOption)
  ) {
    input = "y\n";
  } else if (
    synthetic.optionCount === 3
    && (
      normalizedIndex === 1
      || /^(2|allow all)$/.test(normalizedOption)
      || /^yes,?\s*(don't ask again|allow all)/.test(normalizedOption)
    )
  ) {
    input = "2\n";
  } else if (
    normalizedIndex === synthetic.optionCount - 1
    || /^(n|no|dismiss|esc|escape|0)$/.test(normalizedOption)
  ) {
    input = "\u001b";
  }

  if (!writeToSession(slot, input)) {
    // Session is read-only (e.g. a non-tmux external terminal). We cannot inject keystrokes,
    // so clear the approval UI on the mobile side and let the user respond in their terminal.
    clearCodexSyntheticPermissionForSession(synthetic.sessionId, "read-only-session");
    log("info", `Codex approval ${permissionId} cleared for read-only session ${synthetic.sessionId} — user must respond in terminal`);
    return true;
  }
  clearCodexSyntheticPermissionForSession(synthetic.sessionId, "resolved");
  log("info", `Resolved Codex approval ${permissionId} for session ${synthetic.sessionId}`);
  return true;
}

function clearCodexSyntheticPermissionOnActivity(sessionId, reason = "activity-resumed") {
  const canonicalSessionId = getCanonicalSessionId(sessionId);
  if (!codexSyntheticPermissionBySession.has(canonicalSessionId)) return false;
  codexOpenExecApprovals.delete(sessionId);
  return clearCodexSyntheticPermissionForSession(sessionId, reason);
}

function handleCodexJsonlLine(line, fileState, options = {}) {
  const parsed = parseJsonLine(line);
  if (!parsed) return;

  const bootstrapMetaOnly = options.bootstrap === true;
  const bootstrapReplay = options.bootstrapReplay === true;

  if (parsed.type === "session_meta") {
    const sessionId = parsed.payload?.id;
    if (!sessionId) return;

    fileState.sessionId = sessionId;
    fileState.cwd = parsed.payload?.cwd || fileState.cwd;
    fileState.createdAt = Date.parse(parsed.payload?.timestamp || parsed.timestamp || "") || fileState.createdAt || Date.now();

    // During bootstrap we only learn the session identity from historical files.
    // Do not surface a mobile session yet; otherwise every recent jsonl file
    // appears as a fresh session even when the process has already exited.
    if (bootstrapMetaOnly) return;

    touchExternalSession(sessionId, fileState.cwd, fileState.createdAt, "codex");
    return;
  }

  const rawSessionId = fileState.sessionId;
  if (!rawSessionId || bootstrapMetaOnly) return;

  let sessionId = getCanonicalSessionId(rawSessionId);
  if (!sessions.has(sessionId) || sessions.get(sessionId)?.state !== "running") {
    if (bootstrapReplay) return;
    const slot = touchExternalSession(rawSessionId, fileState.cwd, fileState.createdAt, "codex");
    if (!slot) return;
    sessionId = slot.id;
  }

  if (parsed.type === "response_item" && parsed.payload?.type === "function_call") {
    if (bootstrapReplay) return;
    clearCodexSyntheticPermissionOnActivity(rawSessionId);
    const callId = parsed.payload.call_id;
    if (!callId) return;
    const parsedArgs = parseFunctionCallArgs(parsed.payload.arguments);
    codexPendingToolCalls.set(callId, {
      sessionId,
      name: parsed.payload.name,
      args: parsedArgs,
    });
    if (parsed.payload.name === "exec_command") {
      const candidate = recordCodexExecApprovalCandidateFromArgs(rawSessionId, parsedArgs);
      // Approach A: when JSONL reveals a require_escalated exec_command,
      // surface the approval immediately instead of waiting for the log file
      // (which may be buffered and only flushes on stdin activity).
      if (candidate) {
        codexOpenExecApprovals.add(rawSessionId);
        const surfaced = surfaceCodexExecApproval(rawSessionId);
        log("info", `[ApprovalTiming] JSONL detected require_escalated exec_command for ${rawSessionId}, surfaced=${surfaced}`);
      }
    }
    return;
  }

  if (parsed.type === "response_item" && parsed.payload?.type === "function_call_output") {
    if (bootstrapReplay) return;
    clearCodexSyntheticPermissionOnActivity(rawSessionId);
    const pendingCall = codexPendingToolCalls.get(parsed.payload.call_id);
    emitCodexToolResult(sessionId, pendingCall, parsed.payload.output ?? null);
    if (parsed.payload.call_id) {
      codexPendingToolCalls.delete(parsed.payload.call_id);
    }
    return;
  }

  if (parsed.type !== "event_msg") return;

  const payloadType = parsed.payload?.type;
  if (payloadType === "token_count") {
    if (bootstrapReplay) return;
    touchSessionActivity(sessionId, { emitHeartbeat: true, source: "token-count" });
    return;
  }
  if (payloadType === "task_started") {
    if (bootstrapReplay) return;
    clearCodexSyntheticPermissionOnActivity(rawSessionId);
    touchExternalSession(rawSessionId, fileState.cwd, fileState.createdAt, "codex");
    return;
  }
  if (payloadType === "user_message" && parsed.payload?.message) {
    emitConversationMessage(sessionId, "user", parsed.payload.message, {
      source: "codex",
      timestamp: parsed.timestamp || null,
    });
    return;
  }
  if (payloadType === "agent_message" && parsed.payload?.message) {
    if (!bootstrapReplay) {
      clearCodexSyntheticPermissionOnActivity(rawSessionId);
    }
    emitConversationMessage(sessionId, "assistant", parsed.payload.message, {
      source: "codex",
      phase: parsed.payload.phase || null,
      timestamp: parsed.timestamp || null,
    });
    return;
  }
  if (payloadType === "exec_command_end") {
    if (bootstrapReplay) return;
    clearCodexSyntheticPermissionOnActivity(rawSessionId);
    const pendingCall = codexPendingToolCalls.get(parsed.payload.call_id);
    const command = pendingCall?.args?.cmd
      || (Array.isArray(parsed.payload.command) ? parsed.payload.command.join(" ") : "");
    emitCodexToolEvent(sessionId, "Bash", { command }, parsed.payload.aggregated_output ?? null);
    if (parsed.payload.call_id) {
      codexPendingToolCalls.delete(parsed.payload.call_id);
    }
    return;
  }
  if (payloadType === "task_complete") {
    if (bootstrapReplay) return;
    clearCodexSyntheticPermissionOnActivity(rawSessionId, "task-complete");
    pushSseEvent("task-complete", { source: "codex" }, sessionId);
    flushQueuedPrompt(sessionId, "task-complete");
  }
}

function initializeCodexSessionFile(filePath, stat, fileState) {
  const headerSize = Math.min(stat.size, 64 * 1024);
  const header = headerSize > 0 ? readFileSlice(filePath, 0, headerSize) : "";
  const allowBootstrap = Date.now() - stat.mtimeMs <= CODEX_SESSION_BOOTSTRAP_LOOKBACK_MS;

  for (const line of header.split("\n")) {
    if (!line.trim()) continue;
    handleCodexJsonlLine(line, fileState, { bootstrap: true, allowBootstrap });
    if (fileState.sessionId) break;
  }

  if (allowBootstrap && fileState.sessionId) {
    if (codexOpenExecApprovals.has(fileState.sessionId)) {
      const mapped = touchExternalSession(fileState.sessionId, fileState.cwd, fileState.createdAt, "codex");
      if (mapped) {
        surfaceCodexExecApproval(fileState.sessionId);
      }
    }

    const bootstrapSize = Math.min(stat.size, CODEX_SESSION_BOOTSTRAP_MAX_BYTES);
    const startOffset = Math.max(0, stat.size - bootstrapSize);
    const bootstrapText = bootstrapSize > 0 ? readFileSlice(filePath, startOffset, bootstrapSize) : "";
    const lines = bootstrapText.split("\n");

    if (startOffset > 0) {
      lines.shift();
    }

    for (const line of lines) {
      if (!line.trim()) continue;
      handleCodexJsonlLine(line, fileState, { bootstrapReplay: true });
    }
  }

  fileState.offset = stat.size;
  fileState.remainder = "";
  fileState.initialized = true;
}

function readCodexSessionFileDelta(filePath, stat, fileState) {
  if (stat.size < fileState.offset) {
    fileState.offset = 0;
    fileState.remainder = "";
  }
  if (stat.size === fileState.offset) return;

  const delta = readFileSlice(filePath, fileState.offset, stat.size - fileState.offset);
  fileState.offset = stat.size;

  let chunk = fileState.remainder + delta;
  const lines = chunk.split("\n");
  fileState.remainder = lines.pop() ?? "";

  for (const line of lines) {
    if (!line.trim()) continue;
    handleCodexJsonlLine(line, fileState);
  }
}

function scanCodexSessionFiles() {
  const statRoot = safeStat(CODEX_SESSION_ROOT);
  if (!statRoot || !statRoot.isDirectory()) return;
  refreshLiveAgentProcesses();

  const seen = new Set();
  for (const entry of listRecentCodexSessionFiles(CODEX_SESSION_ROOT)) {
    seen.add(entry.filePath);
    const fileState = codexSessionFiles.get(entry.filePath) || {
      offset: 0,
      remainder: "",
      sessionId: null,
      cwd: undefined,
      createdAt: undefined,
      initialized: false,
    };

    if (!fileState.initialized) {
      initializeCodexSessionFile(entry.filePath, entry, fileState);
      codexSessionFiles.set(entry.filePath, fileState);
      continue;
    }

    readCodexSessionFileDelta(entry.filePath, entry, fileState);
    codexSessionFiles.set(entry.filePath, fileState);
  }

  for (const filePath of codexSessionFiles.keys()) {
    if (!seen.has(filePath)) {
      codexSessionFiles.delete(filePath);
    }
  }
}

function consumeCodexLogChunk(text) {
  const combined = codexLogState.remainder + text;
  const lines = combined.split("\n");
  codexLogState.remainder = lines.pop() ?? "";

  for (const line of lines) {
    recordCodexExecApprovalCandidate(line);

    const approvalMatch = line.match(/thread_id=([0-9a-f-]+).*codex\.op="exec_approval".*codex_core::codex: (new|close)/i);
    if (approvalMatch) {
      const [, sessionId, state] = approvalMatch;
      if (state === "new") {
        // Check if this approval was already surfaced (still pending) or recently resolved.
        const alreadySurfacedViaJsonl = codexSyntheticPermissionBySession.has(getCanonicalSessionId(sessionId))
          || [...sessions.values()].some(s => s.externalSessionId === sessionId && codexSyntheticPermissionBySession.has(s.id));
        const recentlyResolved = codexRecentlyResolvedApprovals.has(sessionId);

        if (alreadySurfacedViaJsonl) {
          log("info", `[ApprovalTiming] Log file detected exec_approval for ${sessionId}, but ALREADY surfaced via JSONL (JSONL was faster ✓)`);
        } else if (recentlyResolved) {
          log("info", `[ApprovalTiming] Log file detected exec_approval for ${sessionId}, but already RESOLVED via JSONL — skipping re-surface`);
        } else {
          log("info", `[ApprovalTiming] Log file detected exec_approval for ${sessionId}, JSONL had NOT surfaced it (log was faster)`);
        }

        codexOpenExecApprovals.add(sessionId);
        // Only surface if not already handled (pending or recently resolved) via JSONL.
        if (!alreadySurfacedViaJsonl && !recentlyResolved) {
          surfaceCodexExecApproval(sessionId);
        }
      } else {
        // Codex can emit "close" before the UI visibly clears in the terminal.
        // Keep the mobile approval alive until actual task activity resumes.
        log("info", `Codex approval close observed for thread ${sessionId}; waiting for activity before clearing`);
      }
    }

    if (line.includes("Shutting down Codex instance")) {
      const match = line.match(/thread_id=([0-9a-f-]+)/i);
      if (match) {
        codexOpenExecApprovals.delete(match[1]);
        clearCodexSyntheticPermissionForSession(match[1], "codex-shutdown");
        endExternalSession(match[1], "codex-shutdown");
      }
    }
  }

}

function scanCodexLog() {
  const stat = safeStat(CODEX_LOG_FILE);
  if (!stat || !stat.isFile()) return;

  if (!codexLogState.initialized) {
    const lookbackSize = Math.min(stat.size, 128 * 1024);
    const startOffset = Math.max(0, stat.size - lookbackSize);
    const bootstrapText = lookbackSize > 0 ? readFileSlice(CODEX_LOG_FILE, startOffset, lookbackSize) : "";
    codexLogState.offset = stat.size;
    codexLogState.remainder = "";
    codexLogState.initialized = true;
    if (bootstrapText) {
      consumeCodexLogChunk(bootstrapText);
    }
    // After bootstrap, do a one-time retry for any approvals that were deferred
    // (session not mapped yet at the time the "new" event was processed).
    for (const sessionId of codexOpenExecApprovals) {
      const canonicalId = getCanonicalSessionId(sessionId);
      if (!codexSyntheticPermissionBySession.has(canonicalId)) {
        surfaceCodexExecApproval(sessionId);
      }
    }
    return;
  }

  if (stat.size < codexLogState.offset) {
    codexLogState.offset = 0;
    codexLogState.remainder = "";
  }
  if (stat.size === codexLogState.offset) return;

  const text = readFileSlice(CODEX_LOG_FILE, codexLogState.offset, stat.size - codexLogState.offset);
  codexLogState.offset = stat.size;
  consumeCodexLogChunk(text);
}



function startCodexMonitor() {
  if (codexMonitorInterval) return;

  scanCodexSessionFiles();
  scanCodexLog();

  codexMonitorInterval = setInterval(() => {
    try {
      scanCodexSessionFiles();
      scanCodexLog();
      // Purge stale entries from the recently-resolved set
      const now = Date.now();
      for (const [sid, ts] of codexRecentlyResolvedApprovals) {
        if (now - ts > CODEX_RESOLVED_APPROVAL_TTL_MS) codexRecentlyResolvedApprovals.delete(sid);
      }
    } catch (err) {
      log("warn", `Codex monitor scan failed: ${err.message}`);
    }
  }, CODEX_SESSION_SCAN_INTERVAL_MS);
}

function stopCodexMonitor() {
  if (codexMonitorInterval) {
    clearInterval(codexMonitorInterval);
    codexMonitorInterval = null;
  }
}

function startClaudeMonitor() {
  if (claudeMonitorInterval) return;

  scanClaudeSessionFiles();

  claudeMonitorInterval = setInterval(() => {
    try {
      scanClaudeSessionFiles();
    } catch (err) {
      log("warn", `Claude monitor scan failed: ${err.message}`);
    }
  }, CLAUDE_SESSION_SCAN_INTERVAL_MS);
}

function stopClaudeMonitor() {
  if (claudeMonitorInterval) {
    clearInterval(claudeMonitorInterval);
    claudeMonitorInterval = null;
  }
}

function startLiveAgentProcessMonitor() {
  if (liveAgentProcessMonitorInterval) return;

  reconcileExternalSessionsWithLiveProcesses();

  liveAgentProcessMonitorInterval = setInterval(() => {
    try {
      reconcileExternalSessionsWithLiveProcesses();
    } catch (err) {
      log("warn", `Live agent process scan failed: ${err.message}`);
    }
  }, LIVE_AGENT_PROCESS_SCAN_INTERVAL_MS);
}

function stopLiveAgentProcessMonitor() {
  if (liveAgentProcessMonitorInterval) {
    clearInterval(liveAgentProcessMonitorInterval);
    liveAgentProcessMonitorInterval = null;
  }
  liveAgentProcesses.clear();
}

// ---------------------------------------------------------------------------
// Permission flow
// ---------------------------------------------------------------------------

function waitForPermission(permissionId) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      pendingPermissions.delete(permissionId);
      log("warn", `Permission ${permissionId} timed out after ${PERMISSION_TIMEOUT_MS / 1000}s, auto-denying`);
      resolve({ behavior: "deny", reason: "Timed out waiting for watch response" });
    }, PERMISSION_TIMEOUT_MS);

    pendingPermissions.set(permissionId, { resolve, timer });
  });
}

function resolvePermission(permissionId, decision) {
  const pending = pendingPermissions.get(permissionId);
  if (!pending) return false;
  clearTimeout(pending.timer);
  pendingPermissions.delete(permissionId);
  pending.resolve(decision);
  return true;
}

function writeToSession(slot, text) {
  if (!slot || typeof text !== "string" || text.length === 0) return false;
  touchSessionActivity(slot, { emitHeartbeat: true, source: "input" });

  if (slot.backend === "tmux") {
    return sendTmuxInput(slot, text);
  }

  if (slot.backend === "external") {
    return false;
  }

  const proc = slot.ptyProcess || attachPtyToSession(slot);
  if (!proc?.stdin) return false;

  proc.stdin.write(text);
  return true;
}

function dispatchCommandToSession(targetSession, command, agent = "claude", cwd = null) {
  if (typeof command !== "string" || command.length === 0) {
    return { ok: false, status: 400, error: "Missing 'command'" };
  }

  let slot = targetSession;

  if (!slot) {
    const requestedAgent = agent || "claude";
    const resolvedCwd = cwd || process.argv[2] || process.env.HOME || process.cwd();
    const newId = spawnSession(requestedAgent, resolvedCwd);
    if (!newId) {
      return { ok: false, status: 500, error: `Failed to spawn ${requestedAgent}` };
    }
    slot = sessions.get(newId);
    setTimeout(() => {
      if (slot && writeToSession(slot, command)) {
        log("info", `Command injected into new ${requestedAgent} session ${newId} (${command.length} chars)`);
      }
    }, 500);
    return { ok: true, sessionId: newId, agent: requestedAgent, spawned: true };
  }

  if (slot.backend === "tmux") {
    const wrote = writeToSession(slot, command);
    if (!wrote) {
      return { ok: false, status: 409, error: "tmux session is not writable" };
    }
    log("info", `Command injected into tmux session ${slot.id} (${command.length} chars)`);
    return { ok: true, sessionId: slot.id, agent: slot.agent };
  }

  if (slot.backend === "external") {
    return {
      ok: false,
      status: 409,
      error: "This session was detected from an existing desktop terminal and is read-only in mobile. Create a new session from the app, or use 'Open on Mac' for a bridge-managed tmux session.",
    };
  }

  if (!slot.ptyProcess) {
    const promptText = command.replace(/\n$/, "").trim();
    if (!promptText) {
      return { ok: false, status: 400, error: "Empty command" };
    }

    if (slot.agent === "codex") {
      if (!slot.externalSessionId && slot.managedDesktop) {
        const queueLength = enqueuePrompt(slot.id, command);
        pushSseEvent("pty-output", {
          text: `[launching] queued until desktop session is ready (position ${queueLength})`,
        }, slot.id);
        return { ok: true, sessionId: slot.id, agent: slot.agent, queued: true, waitingForSession: true };
      }

      if (writeToSession(slot, command)) {
        log("info", `Command injected into attached Codex session ${slot.id} (${command.length} chars)`);
        return { ok: true, sessionId: slot.id, agent: slot.agent, attached: true };
      }
    }

    const bin = slot.agent === "codex" ? CODEX_BIN : CLAUDE_BIN;
    if (!bin) {
      return { ok: false, status: 500, error: `No binary found for ${slot.agent}` };
    }

    const canResumeClaude = slot.agent === "claude" && (slot.managedDesktop || Boolean(slot.resumeSessionId || slot.externalSessionId));
    const claudeSessionId = slot.resumeSessionId || slot.externalSessionId || slot.id;
    const args = slot.agent === "codex"
      ? ["exec", promptText]
      : canResumeClaude
        ? ["-p", promptText, "--resume", claudeSessionId]
        : ["-p", promptText, "--continue"];

    log("info", `Running ${slot.agent} prompt in ${slot.cwd}: "${promptText.slice(0, 80)}"`);

    slot.state = "running";
    pushSseEvent("session", { state: "running", agent: slot.agent, cwd: slot.cwd, folderName: slot.folderName }, slot.id);

    const proc = childSpawn(bin, args, {
      cwd: slot.cwd,
      env: { ...process.env },
      stdio: ["ignore", "pipe", "pipe"],
    });

    const shouldMirrorClaudeStdout = !(slot.agent === "claude" && canResumeClaude);
    proc.stdout.on("data", (data) => {
      const text = data.toString().trim();
      if (text && shouldMirrorClaudeStdout) pushSseEvent("pty-output", { text }, slot.id);
    });
    proc.stderr.on("data", (data) => {
      const text = data.toString().trim();
      if (text && !text.includes("tcgetattr")) {
        pushSseEvent("pty-output", { text }, slot.id);
      }
    });
    proc.on("close", (exitCode) => {
      log("info", `Prompt process exited (code ${exitCode}) for session ${slot.id}`);
    });
    proc.on("error", (err) => {
      log("error", `Prompt process error for session ${slot.id}: ${err.message}`);
    });

    return { ok: true, sessionId: slot.id, agent: slot.agent, prompt: true };
  }

  try {
    slot.ptyProcess.stdin.write(command);
    log("info", `Command injected into session ${slot.id} (${command.length} chars)`);
    return { ok: true, sessionId: slot.id, agent: slot.agent };
  } catch (err) {
    return { ok: false, status: 500, error: err.message };
  }
}

function flushQueuedPrompt(sessionId, reason = "ready") {
  const slot = sessions.get(sessionId);
  if (!slot || slot.state === "ended") {
    queuedPrompts.delete(sessionId);
    return false;
  }

  const next = popQueuedPrompt(sessionId);
  if (!next) return false;

  pushSseEvent("pty-output", { text: `[queued prompt] sending next request (${reason})` }, sessionId);
  const result = dispatchCommandToSession(slot, next.command);
  if (!result.ok) {
    pushSseEvent("error", { error: result.error || "Failed to send queued prompt" }, sessionId);
    return false;
  }
  return true;
}

function interruptSession(sessionId, replacementCommand = null) {
  const canonicalSessionId = getCanonicalSessionId(sessionId);
  const slot = sessions.get(canonicalSessionId);
  if (!slot) {
    return { ok: false, status: 404, error: "No session with that ID" };
  }

  if (slot.backend === "tmux") {
    if (replacementCommand && replacementCommand.trim()) {
      enqueuePrompt(slot.id, replacementCommand, true);
    }

    if (!sendTmuxInterrupt(slot)) {
      return { ok: false, status: 409, error: "tmux session is not writable" };
    }

    pushSseEvent("pty-output", { text: "^C" }, slot.id);
    log("info", `Interrupt sent to tmux session ${slot.id}`);
    return { ok: true, sessionId: slot.id };
  }

  const proc = slot.ptyProcess || attachPtyToSession(slot);
  if (!proc?.stdin) {
    return { ok: false, status: 409, error: `Interrupt is not supported for ${slot.agent} sessions without an attached terminal` };
  }

  if (replacementCommand && replacementCommand.trim()) {
    enqueuePrompt(slot.id, replacementCommand, true);
  }

  proc.stdin.write("\u0003");
  pushSseEvent("pty-output", { text: "^C" }, slot.id);
  log("info", `Interrupt sent to session ${slot.id}`);
  return { ok: true, sessionId: slot.id };
}

// ---------------------------------------------------------------------------
// Route handlers
// ---------------------------------------------------------------------------

async function handlePair(req, res) {
  if (req.method !== "POST") {
    return jsonResponse(res, 405, { error: "Method not allowed" });
  }

  if (isRateLimited()) {
    return jsonResponse(res, 429, { error: "Too many pairing attempts. Try again later." });
  }

  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  recordRateLimitAttempt();

  const { code } = body;
  if (!code || typeof code !== "string") {
    return jsonResponse(res, 400, { error: "Missing 'code' field" });
  }

  if (Date.now() > pairingCodeExpiresAt) {
    generatePairingCode();
    return jsonResponse(res, 401, { error: "Pairing code expired. A new code has been generated." });
  }

  if (code !== pairingCode) {
    return jsonResponse(res, 401, { error: "Invalid pairing code" });
  }

  // Success
  const token = generateSessionToken();
  pairingCode = null;
  pairingCodeExpiresAt = 0;
  bridgeState = "connected";
  pushSseEvent("session", { state: "connected" });

  log("info", `Client paired successfully (active tokens: ${sessionTokens.size})`);
  return jsonResponse(res, 200, {
    token,
    bridgeId: BRIDGE_ID,
    sessionId: BRIDGE_ID, // backward compat
    availableAgents: availableAgentsList(),
    sessions: getSessionsSnapshot(),
  });
}

async function handleCommand(req, res) {
  if (req.method !== "POST") {
    return jsonResponse(res, 405, { error: "Method not allowed" });
  }
  if (!requireAuth(req)) {
    return jsonResponse(res, 401, { error: "Unauthorized" });
  }

  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const {
    command,
    permissionId,
    decision,
    allowAll,
    agent,
    sessionId,
    spawn: spawnRequest,
    kill: killRequest,
    selectedOption,
    optionIndex,
    queueNext,
    interrupt,
    openDesktopWindow,
  } = body;
  const resolvedSessionId = sessionId ? getCanonicalSessionId(sessionId) : null;
  if (command !== undefined || spawnRequest || killRequest || queueNext || interrupt || openDesktopWindow) {
    log(
      "info",
      `POST /command session=${sessionId || "none"} resolved=${resolvedSessionId || "none"} spawn=${spawnRequest || "none"} kill=${Boolean(killRequest)} queue=${Boolean(queueNext)} interrupt=${Boolean(interrupt)} openDesktop=${Boolean(openDesktopWindow)}`
    );
  }

  // --- Spawn a new session ---
  if (spawnRequest) {
    const validAgents = ["claude", "codex"];
    if (!validAgents.includes(spawnRequest)) {
      return jsonResponse(res, 400, { error: `Invalid agent: ${spawnRequest}. Use: ${validAgents.join(", ")}` });
    }
    const cwd = body.cwd || process.argv[2] || process.env.HOME || process.cwd();
    const newId = spawnSession(spawnRequest, cwd, { managedDesktop: openDesktopWindow === true });
    if (!newId) {
      return jsonResponse(res, 500, { error: `Failed to spawn ${spawnRequest}` });
    }
    const slot = sessions.get(newId);

    if (openDesktopWindow) {
      const launched = launchDesktopTerminalSession(slot);
      if (!launched) {
        killSession(newId);
        return jsonResponse(res, 500, { error: `Failed to launch desktop ${spawnRequest} terminal` });
      }
    }

    if (typeof command === "string" && command.length > 0) {
      setTimeout(() => {
        const liveSlot = sessions.get(newId);
        if (liveSlot) {
          writeToSession(liveSlot, command);
        }
      }, 500);
    }
    return jsonResponse(res, 200, {
      ok: true,
      sessionId: newId,
      agent: spawnRequest,
      launchedExternal: openDesktopWindow === true,
    });
  }

  if (openDesktopWindow && resolvedSessionId) {
    const slot = sessions.get(resolvedSessionId);
    if (!slot) {
      return jsonResponse(res, 404, { error: "No session with that ID" });
    }
    if (slot.backend !== "tmux") {
      return jsonResponse(res, 409, {
        error: "Only bridge-managed tmux sessions can be reopened on Mac. External detected sessions need to be recreated from the app.",
      });
    }

    const launched = launchDesktopTerminalSession(slot);
    if (!launched) {
      return jsonResponse(res, 500, { error: "Failed to launch desktop terminal" });
    }

    return jsonResponse(res, 200, {
      ok: true,
      sessionId: slot.id,
      agent: slot.agent,
      launchedExternal: true,
    });
  }

  // --- Kill a session ---
  if (killRequest && resolvedSessionId) {
    const killed = killSession(resolvedSessionId);
    if (!killed) {
      return jsonResponse(res, 404, { error: "No session with that ID" });
    }
    return jsonResponse(res, 200, { ok: true });
  }

  // --- Queue next prompt ---
  if (queueNext) {
    if (!resolvedSessionId) {
      return jsonResponse(res, 400, { error: "Missing 'sessionId' for queued prompt" });
    }
    if (typeof command !== "string" || !command.trim()) {
      return jsonResponse(res, 400, { error: "Missing 'command' for queued prompt" });
    }
    if (!sessions.has(resolvedSessionId)) {
      return jsonResponse(res, 404, { error: "No session with that ID" });
    }

    const queueLength = enqueuePrompt(resolvedSessionId, command);
    pushSseEvent("pty-output", { text: `[queued prompt] position ${queueLength}` }, resolvedSessionId);
    return jsonResponse(res, 200, { ok: true, queued: true, queueLength });
  }

  // --- Interrupt current task ---
  if (interrupt) {
    if (!resolvedSessionId) {
      return jsonResponse(res, 400, { error: "Missing 'sessionId' for interrupt" });
    }
    const result = interruptSession(resolvedSessionId, typeof command === "string" ? command : null);
    if (!result.ok) {
      return jsonResponse(res, result.status || 500, { error: result.error || "Interrupt failed" });
    }
    return jsonResponse(res, 200, result);
  }

  // --- Permission response ---
  if (permissionId && (decision || selectedOption !== undefined || Number.isInteger(optionIndex))) {
    if (decision) {
      if (allowAll && decision.behavior === "allow") {
        decision.updatedPermissions = pendingPermissionBodies.get(permissionId) || [];
      }
      pendingPermissionBodies.delete(permissionId);

      // Forward the watch's selected option so the hook response can include it
      if (selectedOption !== undefined) decision.selectedOption = selectedOption;
      if (Number.isInteger(optionIndex)) decision.optionIndex = optionIndex;

      const resolved = resolvePermission(permissionId, decision);
      if (resolved) {
        log("info", `Permission ${permissionId} resolved: ${decision.behavior}${allowAll ? " (allow all)" : ""}`);
        return jsonResponse(res, 200, { ok: true });
      }
    }

    const resolvedSynthetic = resolveCodexSyntheticPermission(permissionId, selectedOption, optionIndex);
    if (resolvedSynthetic) {
      return jsonResponse(res, 200, { ok: true });
    }

    return jsonResponse(res, 404, { error: "No pending permission with that ID" });
  }

  // --- PTY command injection ---
  if (command !== undefined) {
    let targetSession = null;

    if (resolvedSessionId) {
      targetSession = sessions.get(resolvedSessionId);
      if (!targetSession) {
        return jsonResponse(res, 404, { error: "No session with that ID" });
      }
    } else {
      targetSession = findMostRecentActiveSession() || findMostRecentRunningSession();
    }

    log(
      "info",
      `Dispatching command to ${targetSession?.id || "new-session"} backend=${targetSession?.backend || "spawn"} agent=${targetSession?.agent || agent || "claude"}`
    );

    const result = dispatchCommandToSession(
      targetSession,
      command,
      agent || "claude",
      body.cwd || process.argv[2] || process.env.HOME || process.cwd()
    );
    if (!result.ok) {
      return jsonResponse(res, result.status || 500, { error: result.error || "Request failed" });
    }
    return jsonResponse(res, 200, result);
  }

  return jsonResponse(res, 400, { error: "Missing 'command', 'spawn', 'kill', 'queueNext', 'interrupt', or 'permissionId'+'decision'" });
}

function handleEvents(req, res) {
  if (req.method !== "GET") {
    return jsonResponse(res, 405, { error: "Method not allowed" });
  }
  if (!requireAuth(req)) {
    return jsonResponse(res, 401, { error: "Unauthorized" });
  }

  const lastIdHeader = req.headers["last-event-id"];
  const parsedLastEventId = lastIdHeader ? parseInt(lastIdHeader, 10) : NaN;
  const oldestBufferedEventId = sseBuffer.length > 0 ? sseBuffer[0].id : null;
  const newestBufferedEventId = sseBuffer.length > 0 ? sseBuffer[sseBuffer.length - 1].id : null;
  const lastEventIdMissingFromBuffer = Number.isFinite(parsedLastEventId) && (
    sseBuffer.length === 0
    || oldestBufferedEventId === null
    || newestBufferedEventId === null
    || parsedLastEventId < oldestBufferedEventId
    || parsedLastEventId > newestBufferedEventId
  );
  const shouldBootstrapFresh = !lastIdHeader || !Number.isFinite(parsedLastEventId) || lastEventIdMissingFromBuffer;

  if (shouldBootstrapFresh) {
    try {
      scanCodexSessionFiles();
      scanClaudeSessionFiles();
      reconcileExternalSessionsWithLiveProcesses();
    } catch (err) {
      log("warn", `On-connect pre-bootstrap scan failed: ${err.message}`);
    }
  }

  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache, no-store, must-revalidate, private, no-transform",
    Connection: "keep-alive",
    "Content-Encoding": "identity",
    "X-Accel-Buffering": "no",
  });
  res.flushHeaders?.();
  res.socket?.setNoDelay?.(true);
  res.socket?.setKeepAlive?.(true, 15_000);
  writeSsePrelude(res);

  // Replay from Last-Event-ID if provided
  if (lastIdHeader && !shouldBootstrapFresh) {
    const lastId = parsedLastEventId;
    if (!isNaN(lastId)) {
      for (const entry of sseBuffer) {
        if (entry.id > lastId) {
          if (!writeSseEvent(res, entry)) {
            break;
          }
        }
      }
    }
  }

  sseClients.add(res);
  log("info", `SSE client connected (total: ${sseClients.size})`);

  // Bootstrap fresh clients with the current session list plus recent per-session context.
  if (shouldBootstrapFresh) {
    const bootstrapSessions = getSortedSessions().filter(
      (slot) => slot.state !== "ended" && slot.state !== "removed"
    );
    log("info", `SSE bootstrap: sending ${bootstrapSessions.length} live sessions`);

    for (const slot of bootstrapSessions) {
      const syncEntry = formatSseMessage({
        id: sseEventId++,
        event: "session",
        data: JSON.stringify({
          ...buildSessionPayload(slot),
          sessionId: slot.id,
        }),
      });
      writeSseRaw(res, padSseChunk(syncEntry));

      if (slot.backend === "tmux") {
        const bootstrapText = getTmuxBootstrapText(slot);
        if (bootstrapText) {
          const bootstrapEntry = formatSseMessage({
            id: sseEventId++,
            event: "pty-output",
            data: JSON.stringify({
              sessionId: slot.id,
              text: bootstrapText,
              bootstrap: true,
            }),
          });
          writeSseRaw(res, padSseChunk(bootstrapEntry));
        }
      }
    }

    for (const slot of bootstrapSessions) {
      for (const replayEntry of getSessionReplayEntries(slot.id)) {
        if (replayEntry.event === "session") continue;
        if (slot.backend === "tmux" && replayEntry.event === "pty-output") {
          continue;
        }

        const syncEntry = formatSseMessage({
          id: sseEventId++,
          event: replayEntry.event,
          data: JSON.stringify(replayEntry.data),
        });
        writeSseRaw(res, padSseChunk(syncEntry));
      }
    }
  }

  for (const [permissionId, synthetic] of codexSyntheticPermissions) {
    const syncEntry = formatSseMessage({
      id: sseEventId++,
      event: "permission-request",
      data: JSON.stringify({
        ...synthetic.payload,
        permissionId,
        sessionId: synthetic.sessionId,
      }),
    });
    writeSseRaw(res, padSseChunk(syncEntry));
  }

  const heartbeat = setInterval(() => {
    if (!writeSseHeartbeat(res)) {
      clearInterval(heartbeat);
      sseClients.delete(res);
    }
  }, SSE_HEARTBEAT_INTERVAL_MS);

  req.on("close", () => {
    clearInterval(heartbeat);
    sseClients.delete(res);
    log("info", `SSE client disconnected (total: ${sseClients.size})`);
  });
}

// --- Hook handlers ---
// Hooks come from Claude Code instances. We match by cwd to find the session.

function resolveHookSession(body) {
  const cwd = body.session_cwd || body.cwd || null;
  const source = body.source || "claude";
  const agent = source === "codex" ? "codex" : "claude";
  const hookSessionId = body.session_id || body.sessionId || body.claude_session_id || null;
  const resolvedCwd = cwd || process.argv[2] || process.env.HOME || process.cwd();

  if (hookSessionId) {
    const canonicalSessionId = getCanonicalSessionId(hookSessionId);
    const exact = sessions.get(canonicalSessionId);
    if (exact) {
      exact.externalSessionId = hookSessionId;
      exact.resumeSessionId = exact.resumeSessionId || resolveResumeSessionId(agent, resolvedCwd, hookSessionId);
      registerExternalSessionAliases(exact, hookSessionId, exact.resumeSessionId);
      if (exact.backend !== "tmux" && exact.resumeSessionId) {
        maybePromoteSessionToTmux(exact, exact.resumeSessionId, {
          cwd: resolvedCwd,
          createdAt: Date.now(),
          externalSessionId: hookSessionId,
        });
      }
      persistTmuxSessionMetadata(exact);
      return exact.id;
    }

    const managedSlot = findManagedSlotForExternalSession(agent, resolvedCwd, hookSessionId);
    if (managedSlot) {
      managedSlot.externalSessionId = hookSessionId;
      managedSlot.resumeSessionId = managedSlot.resumeSessionId || resolveResumeSessionId(agent, resolvedCwd, hookSessionId);
      registerExternalSessionAliases(managedSlot, hookSessionId, managedSlot.resumeSessionId);
      if (managedSlot.backend !== "tmux" && managedSlot.resumeSessionId) {
        maybePromoteSessionToTmux(managedSlot, managedSlot.resumeSessionId, {
          cwd: resolvedCwd,
          createdAt: Date.now(),
          externalSessionId: hookSessionId,
        });
      }
      persistTmuxSessionMetadata(managedSlot);
      return managedSlot.id;
    }

    const promoted = touchExternalSession(hookSessionId, resolvedCwd, Date.now(), agent);
    if (promoted) {
      return promoted.id;
    }
  }

  // No session exists — auto-create one for this external Claude/Codex instance
  const sessionId = hookSessionId || crypto.randomUUID();
  const slot = touchExternalSession(sessionId, resolvedCwd, Date.now(), agent, {
    externalSessionId: hookSessionId || null,
  }) || createExternalSession(sessionId, agent, resolvedCwd, Date.now(), {
    externalSessionId: hookSessionId || null,
    resumeSessionId: resolveResumeSessionId(agent, resolvedCwd, hookSessionId || sessionId),
  });

  log("info", `Auto-created session ${slot.id} for external ${agent} (${slot.folderName})`);
  return slot.id;
}

async function handleHookToolOutput(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const sid = resolveHookSession(body);
  const source = body.source || "claude";
  log("info", `Hook: ${source === "codex" ? "Codex" : "PostToolUse"} received [${source}]${sid ? ` session=${sid}` : ""}`, body.tool_name || "");
  pushSseEvent("tool-output", { ...body, source }, sid);
  return jsonResponse(res, 200, { ok: true });
}

async function handleHookPermission(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  // Disable Node.js default 5-minute requestTimeout for this long-lived blocking request.
  // The hook waits up to PERMISSION_TIMEOUT_MS (10 min) for a watch response.
  req.socket.setTimeout(0);

  const sid = resolveHookSession(body);
  const permissionId = crypto.randomUUID();
  log("info", `Hook: PermissionRequest received (id: ${permissionId})${sid ? ` session=${sid}` : ""}`, body.tool_name || "");

  if (body.permission_suggestions) {
    pendingPermissionBodies.set(permissionId, body.permission_suggestions);
  }

  pushSseEvent("permission-request", { permissionId, ...body }, sid);

  const decision = await waitForPermission(permissionId);

  log("info", `Hook: PermissionRequest resolved (id: ${permissionId}): ${decision.behavior}`);

  const hookResponse = {
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: { behavior: decision.behavior },
    },
  };

  if (decision.updatedPermissions && decision.updatedPermissions.length > 0) {
    hookResponse.hookSpecificOutput.decision.updatedPermissions = decision.updatedPermissions;
  }

  if (decision.behavior === "deny" && decision.message) {
    hookResponse.hookSpecificOutput.decision.message = decision.message;
  }

  // For AskUserQuestion: forward the watch-selected option as the answer so Claude
  // Code doesn't fall back to waiting for terminal input.
  if (decision.selectedOption !== undefined && body.tool_name === "AskUserQuestion") {
    const questions = body.tool_input?.questions;
    if (questions && questions.length > 0 && questions[0]?.question) {
      const answers = { [questions[0].question]: decision.selectedOption };
      hookResponse.hookSpecificOutput.decision.updatedInput = { questions, answers };
      log("info", `AskUserQuestion answer forwarded: "${decision.selectedOption}"`);
    }
  }

  return jsonResponse(res, 200, hookResponse);
}

async function handleHookStop(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const sid = resolveHookSession(body);
  log("info", `Hook: Stop received${sid ? ` session=${sid}` : ""}`);
  pushSseEvent("stop", body, sid);
  if (sid) {
    flushQueuedPrompt(sid, "stop");
  }
  return jsonResponse(res, 200, { ok: true });
}

async function handleHookTaskComplete(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const sid = resolveHookSession(body);
  log("info", `Hook: TaskCompleted received${sid ? ` session=${sid}` : ""}`);
  pushSseEvent("task-complete", body, sid);
  if (sid) {
    flushQueuedPrompt(sid, "task-complete");
  }
  return jsonResponse(res, 200, { ok: true });
}

async function handleHookError(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const sid = resolveHookSession(body);
  log("info", `Hook: Error received${sid ? ` session=${sid}` : ""}`, body.error || "");
  pushSseEvent("error", body, sid);
  return jsonResponse(res, 200, { ok: true });
}

function handleStatus(_req, res) {
  const mostRecentRunningSession = findMostRecentRunningSession();
  return jsonResponse(res, 200, {
    bridgeId: BRIDGE_ID,
    sessionId: BRIDGE_ID, // backward compat
    state: bridgeState,
    availableAgents: availableAgentsList(),
    sessions: getSessionsSnapshot({ includeRecentLines: true }),
    sseClients: sseClients.size,
    pendingPermissions: pendingPermissions.size + codexSyntheticPermissions.size,
    eventBufferSize: sseBuffer.length,
    // Backward compat: expose the most recent active session's info
    hasPty: findMostRecentActiveSession() !== null,
    activeAgent: mostRecentRunningSession?.agent || null,
  });
}

async function handleRegisterTerminal(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });

  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const source = body.source || body.agent || "claude";
  const agent = source === "codex" ? "codex" : "claude";
  const cwd = body.cwd || process.env.HOME || process.cwd();
  const pid = Number(body.pid);
  const tty = normalizeTty(body.tty);
  const createdAt = Number(body.createdAt) || Date.now();

  if (!Number.isFinite(pid) || pid <= 0) {
    return jsonResponse(res, 400, { error: "Missing or invalid pid" });
  }

  if (!tty) {
    return jsonResponse(res, 400, { error: "Missing or invalid tty" });
  }

  const matchedPane = findTmuxPaneForTty(tty);
  const syntheticSessionId = `external-${agent}-${pid}`;
  const slot = touchExternalSession(syntheticSessionId, cwd, createdAt, agent, {
    externalProcessPid: pid,
    externalTty: tty,
    matchedTmuxPane: matchedPane,
    allowDetachedCreate: true,
  }) || createExternalSession(syntheticSessionId, agent, cwd, createdAt, {
    backend: matchedPane ? "tmux" : "external",
    externalProcessPid: pid,
    externalTty: tty,
    tmuxSessionName: matchedPane?.sessionName || null,
    tmuxPaneTarget: matchedPane?.paneTarget || null,
    tmuxPanePid: matchedPane?.panePid || null,
    tmuxPaneTty: matchedPane?.paneTty || null,
    attachedTmuxPane: Boolean(matchedPane),
  });

  log("info", `Registered external ${agent} terminal pid=${pid} tty=${tty} -> session ${slot.id}`);
  return jsonResponse(res, 200, {
    ok: true,
    sessionId: slot.id,
    agent: slot.agent,
    tmuxPaneTarget: getTmuxPaneTarget(slot),
  });
}

async function handleHeartbeat(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  if (!requireAuth(req)) return jsonResponse(res, 401, { error: "Unauthorized" });

  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const resolvedSessionId = body.sessionId ? getCanonicalSessionId(body.sessionId) : null;
  if (resolvedSessionId) {
    const slot = sessions.get(resolvedSessionId);
    if (!slot) {
      return jsonResponse(res, 404, { error: "No session with that ID" });
    }
    touchSessionActivity(slot, { emitHeartbeat: true, source: "client-heartbeat" });
    return jsonResponse(res, 200, { ok: true, sessionId: slot.id, lastActivityAt: slot.lastActivityAt || null });
  }

  return jsonResponse(res, 200, { ok: true });
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

const routes = {
  "POST /pair": handlePair,
  "POST /command": handleCommand,
  "POST /heartbeat": handleHeartbeat,
  "GET /events": handleEvents,
  "POST /hooks/register-terminal": handleRegisterTerminal,
  "POST /hooks/tool-output": handleHookToolOutput,
  "POST /hooks/permission": handleHookPermission,
  "POST /hooks/stop": handleHookStop,
  "POST /hooks/task-complete": handleHookTaskComplete,
  "POST /hooks/error": handleHookError,
  "GET /status": handleStatus,
};

async function onRequest(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const routeKey = `${req.method} ${url.pathname}`;

  const handler = routes[routeKey];
  if (handler) {
    try {
      await handler(req, res);
    } catch (err) {
      log("error", `Unhandled error in ${routeKey}:`, err.message);
      if (!res.headersSent) {
        jsonResponse(res, 500, { error: "Internal server error" });
      }
    }
  } else {
    jsonResponse(res, 404, { error: "Not found" });
  }
}

// ---------------------------------------------------------------------------
// Server startup
// ---------------------------------------------------------------------------

function tryListen(server, port) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "0.0.0.0", () => {
      server.removeListener("error", reject);
      resolve(port);
    });
  });
}

async function startServer() {
  const server = http.createServer(onRequest);

  let boundPort = null;
  for (let port = PORT_RANGE_START; port <= PORT_RANGE_END; port++) {
    try {
      boundPort = await tryListen(server, port);
      break;
    } catch (err) {
      if (err.code === "EADDRINUSE") {
        log("warn", `Port ${port} in use, trying next...`);
        continue;
      }
      throw err;
    }
  }

  if (boundPort === null) {
    log("error", `No available port in range ${PORT_RANGE_START}-${PORT_RANGE_END}`);
    process.exit(1);
  }

  log("info", `Bridge server listening on 0.0.0.0:${boundPort}`);

  const code = generatePairingCode();

  // Bonjour
  bonjourInstance = new Bonjour();
  bonjourService = bonjourInstance.publish({
    name: `Agent Watcher Bridge (${os.hostname()})`,
    type: "claude-watch",
    protocol: "tcp",
    port: boundPort,
    txt: {
      version: "2",
      bridgeId: BRIDGE_ID,
      sessionId: BRIDGE_ID, // backward compat
      machineName: os.hostname(),
    },
  });

  log("info", `Bonjour advertising _claude-watch._tcp on port ${boundPort}`);
  recoverTmuxSessions();
  startTmuxMonitor();
  startCodexMonitor();
  startClaudeMonitor();
  startLiveAgentProcessMonitor();

  const agents = [];
  if (CLAUDE_BIN) agents.push("Claude");
  if (CODEX_BIN) agents.push("Codex");
  log("info", `Bridge ready. Available agents: ${agents.join(", ") || "none"}. Sessions spawn on demand.`);

  // Get LAN IP
  const interfaces = os.networkInterfaces();
  let lanIP = "127.0.0.1";
  for (const [, addrs] of Object.entries(interfaces)) {
    for (const addr of addrs) {
      if (addr.family === "IPv4" && !addr.internal) {
        lanIP = addr.address;
        break;
      }
    }
    if (lanIP !== "127.0.0.1") break;
  }

  const agentLine = agents.length ? agents.join(" + ") : "none";
  console.log("");
  console.log("╔═══════════════════════════════════════╗");
  console.log("║        AGENT WATCH BRIDGE             ║");
  console.log("╠═══════════════════════════════════════╣");
  console.log(`║  Pairing Code:  ${code}                ║`);
  console.log(`║  IP Address:    ${lanIP.padEnd(20)}║`);
  console.log(`║  Port:          ${String(boundPort).padEnd(20)}║`);
  console.log(`║  Agents:        ${agentLine.padEnd(20)}║`);
  console.log("╚═══════════════════════════════════════╝");
  console.log("");

  // --- Graceful shutdown ---

  let shuttingDown = false;

  async function shutdown(signal) {
    if (shuttingDown) return;
    shuttingDown = true;
    log("info", `Received ${signal}, shutting down gracefully...`);

    for (const client of sseClients) {
      try { client.end(); } catch { /* ignore */ }
    }
    sseClients.clear();

    // Kill all session PTYs
    for (const [id, slot] of sessions) {
      if (slot.backend === "tmux" && slot.tmuxSessionName) {
        log("info", `Preserving tmux session ${id} (${slot.agent}) for bridge restart`);
      } else if (slot.ptyProcess) {
        try { slot.ptyProcess.kill(); } catch { /* ignore */ }
        log("info", `Killed session ${id} (${slot.agent})`);
      }
    }
    sessions.clear();
    stopTmuxMonitor();
    stopLiveAgentProcessMonitor();
    stopClaudeMonitor();
    stopCodexMonitor();

    if (bonjourService) {
      try { bonjourInstance.unpublishAll(); } catch { /* ignore */ }
    }
    if (bonjourInstance) {
      try { bonjourInstance.destroy(); } catch { /* ignore */ }
    }

    for (const [id, pending] of pendingPermissions) {
      clearTimeout(pending.timer);
      pending.resolve({ behavior: "deny", reason: "Server shutting down" });
    }
    pendingPermissions.clear();

    server.close(() => {
      log("info", "Server closed");
      process.exit(0);
    });

    setTimeout(() => {
      log("warn", "Forced exit after timeout");
      process.exit(1);
    }, 5000);
  }

  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));

  return { server, port: boundPort };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

startServer().catch((err) => {
  log("error", "Failed to start server:", err.message);
  process.exit(1);
});
