#!/usr/bin/env node
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import fs from "node:fs";
import { promises as fsp } from "node:fs";
import path from "node:path";
import process from "node:process";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

process.title = "fm-cursor-acp";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const OPERATIONAL_INPUT = path.join(SCRIPT_DIR, "fm-operational-input.sh");
const DEFAULT_BUSY_EVENT = path.join(SCRIPT_DIR, "fm-busy-event.sh");
const TOKEN_PATTERN = /^[A-Za-z0-9._-]+$/;
const ROLES = new Set(["crew", "scout", "secondmate"]);
const ACP_STOP_REASONS = new Set([
  "end_turn",
  "max_tokens",
  "max_turn_requests",
  "refusal",
  "cancelled",
]);
const STATUS_PREFIXES = new Set(["failed", "blocked", "needs-decision"]);
const STATUS_LINE_MAX = 1000;
const SHUTDOWN_GRACE_MS = 2000;
const BUSY_EVENT_TIMEOUT_MS = 5000;
const COMMAND_TERM_GRACE_MS = 250;
const COMMAND_KILL_GRACE_MS = 500;

function usageError(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  const valueOptions = new Set([
    "--cwd",
    "--task-id",
    "--state-dir",
    "--brief",
    "--busy-gen",
    "--model",
    "--agent-bin",
    "--role",
  ]);
  const parsed = { role: "crew", agentBin: "agent" };
  const seen = new Set();

  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (!valueOptions.has(option)) {
      usageError(`unknown option: ${option}`);
    }
    if (seen.has(option)) {
      usageError(`duplicate option: ${option}`);
    }
    if (index + 1 >= argv.length || argv[index + 1].startsWith("--")) {
      usageError(`${option} requires a value`);
    }
    seen.add(option);
    const value = argv[index + 1];
    index += 1;
    switch (option) {
      case "--cwd":
        parsed.cwd = value;
        break;
      case "--task-id":
        parsed.taskId = value;
        break;
      case "--state-dir":
        parsed.stateDir = value;
        break;
      case "--brief":
        parsed.brief = value;
        break;
      case "--busy-gen":
        parsed.busyGen = value;
        break;
      case "--model":
        parsed.model = value;
        break;
      case "--agent-bin":
        parsed.agentBin = value;
        parsed.agentBinExplicit = true;
        break;
      case "--role":
        parsed.role = value;
        break;
      default:
        usageError(`unknown option: ${option}`);
    }
  }

  for (const required of ["cwd", "taskId", "stateDir", "brief", "busyGen"]) {
    if (!parsed[required]) {
      usageError(`missing required option for ${required}`);
    }
  }
  return parsed;
}

async function statRequired(target, description, type) {
  let stat;
  try {
    stat = await fsp.stat(target);
  } catch {
    throw new Error(`${description} not found: ${target}`);
  }
  if (type === "directory" && !stat.isDirectory()) {
    throw new Error(`${description} is not a directory: ${target}`);
  }
  if (type === "file" && !stat.isFile()) {
    throw new Error(`${description} is not a file: ${target}`);
  }
}

async function requireAccess(target, mode, description) {
  try {
    await fsp.access(target, mode);
  } catch {
    throw new Error(`${description} is not accessible: ${target}`);
  }
}

async function validateBaseOptions(options, busyEvent) {
  const nodeMajor = Number(process.versions.node.split(".")[0]);
  if (!Number.isInteger(nodeMajor) || nodeMajor < 18) {
    throw new Error(`Node >=18 is required (found ${process.versions.node})`);
  }
  for (const [name, value] of [
    ["--cwd", options.cwd],
    ["--state-dir", options.stateDir],
    ["--brief", options.brief],
    ["FM_CURSOR_BUSY_EVENT", busyEvent],
  ]) {
    if (!path.isAbsolute(value)) {
      throw new Error(`${name} must be an absolute path`);
    }
  }
  if (options.agentBinExplicit && !path.isAbsolute(options.agentBin)) {
    throw new Error("--agent-bin must be an absolute path when provided");
  }
  if (!TOKEN_PATTERN.test(options.taskId)) {
    throw new Error("unsafe --task-id token");
  }
  if (!TOKEN_PATTERN.test(options.busyGen)) {
    throw new Error("unsafe --busy-gen token");
  }
  if (!ROLES.has(options.role)) {
    throw new Error("--role must be crew, scout, or secondmate");
  }
  if (options.model !== undefined && options.model.length === 0) {
    throw new Error("--model must not be empty");
  }

  await statRequired(options.stateDir, "state directory", "directory");
  await requireAccess(
    options.stateDir,
    fs.constants.W_OK | fs.constants.X_OK,
    "state directory",
  );
  await statRequired(busyEvent, "busy event writer", "file");
  await requireAccess(busyEvent, fs.constants.X_OK, "busy event writer executable");
}

async function validateRuntimeDependencies(options) {
  await Promise.all([
    statRequired(options.cwd, "cwd", "directory"),
    statRequired(options.brief, "brief", "file"),
    statRequired(OPERATIONAL_INPUT, "operational input encoder", "file"),
  ]);
  await Promise.all([
    requireAccess(options.cwd, fs.constants.X_OK, "cwd"),
    requireAccess(options.brief, fs.constants.R_OK, "brief"),
    requireAccess(OPERATIONAL_INPUT, fs.constants.X_OK, "operational input encoder"),
  ]);
  if (options.agentBinExplicit) {
    await statRequired(options.agentBin, "agent binary", "file");
    await requireAccess(options.agentBin, fs.constants.X_OK, "agent binary");
  }
}

function statusPath(options) {
  return path.join(options.stateDir, `${options.taskId}.status`);
}

function sanitizeStatusDetail(value) {
  const collapsed = String(value)
    .replace(/[\u0000-\u001f\u007f]/gu, " ")
    .replace(/\s+/gu, " ")
    .trim();
  return collapsed || "unspecified";
}

async function appendStatus(options, prefix, detail) {
  if (!STATUS_PREFIXES.has(prefix)) {
    throw new Error(`invalid internal status prefix: ${prefix}`);
  }
  const line = Array.from(`${prefix}: ${sanitizeStatusDetail(detail)}`)
    .slice(0, STATUS_LINE_MAX)
    .join("");
  const target = statusPath(options);
  let flags = fs.constants.O_WRONLY | fs.constants.O_APPEND | fs.constants.O_CREAT;
  if (Number.isInteger(fs.constants.O_NOFOLLOW)) {
    flags |= fs.constants.O_NOFOLLOW;
  }
  if (Number.isInteger(fs.constants.O_NONBLOCK)) {
    flags |= fs.constants.O_NONBLOCK;
  }
  const handle = await fsp.open(target, flags, 0o600);
  try {
    const [opened, current] = await Promise.all([
      handle.stat(),
      fsp.lstat(target),
    ]);
    if (
      !opened.isFile()
      || !current.isFile()
      || current.isSymbolicLink()
      || opened.dev !== current.dev
      || opened.ino !== current.ino
      || opened.nlink !== 1
    ) {
      throw new Error(`status target must remain one regular non-symlink file: ${target}`);
    }
    await handle.write(`${line}\n`);
  } finally {
    await handle.close();
  }
}

function sidecarPath(options) {
  return path.join(options.stateDir, `${options.taskId}.cursor-session.json`);
}

async function validateOptionalStateFile(target, description, accessMode, privateFile) {
  let stat;
  try {
    stat = await fsp.lstat(target);
  } catch (error) {
    if (error?.code === "ENOENT") {
      return;
    }
    throw new Error(`could not inspect ${description}: ${error.message}`);
  }
  if (stat.isSymbolicLink() || !stat.isFile()) {
    throw new Error(`${description} must be a regular non-symlink file: ${target}`);
  }
  if (privateFile && (stat.mode & 0o077) !== 0) {
    throw new Error(`${description} must not grant group or other permissions: ${target}`);
  }
  await requireAccess(target, accessMode, description);
}

async function validateStatusTarget(options) {
  await validateOptionalStateFile(
    statusPath(options),
    "status target",
    fs.constants.W_OK,
    false,
  );
}

async function validateSidecarTarget(options) {
  await validateOptionalStateFile(
    sidecarPath(options),
    "Cursor ACP session sidecar",
    fs.constants.R_OK,
    true,
  );
}

function validUpdatedAt(value) {
  return typeof value === "string" && value.length > 0 && !Number.isNaN(Date.parse(value));
}

function validSessionId(value) {
  return (
    typeof value === "string"
    && value.length > 0
    && value.length <= 512
    && !/[\u0000-\u001f\u007f]/u.test(value)
  );
}

function validCursorQuestion(question) {
  return (
    question !== null
    && typeof question === "object"
    && !Array.isArray(question)
    && typeof question.id === "string"
    && question.id.length > 0
    && typeof question.prompt === "string"
    && Array.isArray(question.options)
    && question.options.every((option) => (
      option !== null
      && typeof option === "object"
      && !Array.isArray(option)
      && typeof option.id === "string"
      && option.id.length > 0
      && typeof option.label === "string"
    ))
    && (
      !("allowMultiple" in question)
      || typeof question.allowMultiple === "boolean"
    )
  );
}

const CURSOR_TODO_STATUSES = new Set([
  "pending",
  "in_progress",
  "completed",
  "cancelled",
]);

function validCursorTodo(todo) {
  return (
    todo !== null
    && typeof todo === "object"
    && !Array.isArray(todo)
    && typeof todo.id === "string"
    && todo.id.length > 0
    && typeof todo.content === "string"
    && CURSOR_TODO_STATUSES.has(todo.status)
  );
}

async function readSidecar(options) {
  const target = sidecarPath(options);
  let raw;
  try {
    raw = await fsp.readFile(target, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") {
      return null;
    }
    throw new Error(`could not read Cursor ACP session sidecar: ${error.message}`);
  }

  let document;
  try {
    document = JSON.parse(raw);
  } catch (error) {
    throw new Error(`invalid Cursor ACP session sidecar JSON: ${error.message}`);
  }
  if (
    document === null
    || typeof document !== "object"
    || Array.isArray(document)
    || document.version !== 1
    || !validSessionId(document.sessionId)
    || typeof document.cwd !== "string"
    || !ROLES.has(document.role)
    || !validUpdatedAt(document.updatedAt)
  ) {
    throw new Error("invalid Cursor ACP session sidecar v1 fields");
  }
  if (document.cwd !== options.cwd) {
    throw new Error(`Cursor ACP session sidecar cwd mismatch: ${document.cwd}`);
  }
  if (document.role !== options.role) {
    throw new Error(`Cursor ACP session sidecar role mismatch: ${document.role}`);
  }
  return document;
}

async function atomicWrite(target, content) {
  const temporary = `${target}.tmp.${process.pid}.${randomBytes(8).toString("hex")}`;
  let handle;
  try {
    handle = await fsp.open(temporary, "wx", 0o600);
    await handle.chmod(0o600);
    await handle.writeFile(content, "utf8");
    await handle.sync();
    await handle.close();
    handle = undefined;
    await fsp.rename(temporary, target);
  } catch (error) {
    if (handle) {
      await handle.close().catch(() => {});
    }
    await fsp.unlink(temporary).catch(() => {});
    throw error;
  }
}

async function writeSidecar(options, sessionId) {
  const document = {
    version: 1,
    sessionId,
    cwd: options.cwd,
    role: options.role,
    updatedAt: new Date().toISOString(),
  };
  await atomicWrite(sidecarPath(options), `${JSON.stringify(document)}\n`);
}

async function touchTurnEnded(options) {
  const target = path.join(options.stateDir, `${options.taskId}.turn-ended`);
  await atomicWrite(target, "");
}

function runWithInput(command, args, input) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    const stdout = [];
    const stderr = [];
    child.stdout.on("data", (chunk) => stdout.push(chunk));
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.on("error", reject);
    child.on("close", (code, signal) => {
      if (code === 0) {
        resolve(Buffer.concat(stdout).toString("utf8"));
      } else {
        const detail = Buffer.concat(stderr).toString("utf8").trim();
        reject(new Error(
          `${path.basename(command)} exited ${code ?? `by ${signal}`}${detail ? `: ${detail}` : ""}`,
        ));
      }
    });
    child.stdin.end(input);
  });
}

async function encodeLaunchPrompt(options) {
  const body = `Read the brief at ${options.brief} and follow it exactly.`;
  const encoded = await runWithInput(OPERATIONAL_INPUT, ["encode", "launch-brief"], body);
  if (!encoded) {
    throw new Error("fm-operational-input.sh returned an empty launch-brief");
  }
  return encoded;
}

function stringifyId(id) {
  try {
    return JSON.stringify(id);
  } catch {
    return String(id);
  }
}

function validJsonRpcId(id) {
  return (
    id === null
    || typeof id === "string"
    || (typeof id === "number" && Number.isFinite(id))
  );
}

function validateIncomingJsonRpc(message) {
  if (message === null || typeof message !== "object" || Array.isArray(message)) {
    throw new Error("invalid JSON-RPC message object from ACP child");
  }
  if (message.jsonrpc !== "2.0") {
    throw new Error("invalid JSON-RPC version from ACP child");
  }
  if (
    "params" in message
    && (message.params === null || typeof message.params !== "object")
  ) {
    throw new Error("invalid JSON-RPC params from ACP child");
  }
  const hasMethod = "method" in message;
  const hasId = "id" in message;
  const hasResult = "result" in message;
  const hasError = "error" in message;

  if (hasMethod) {
    if (typeof message.method !== "string" || message.method.length === 0) {
      throw new Error("invalid JSON-RPC method from ACP child");
    }
    if (hasResult || hasError) {
      throw new Error("JSON-RPC request must not contain result or error");
    }
    if (hasId && !validJsonRpcId(message.id)) {
      throw new Error("invalid JSON-RPC request id from ACP child");
    }
    return hasId ? "request" : "notification";
  }

  if (!hasId || !validJsonRpcId(message.id)) {
    throw new Error("invalid JSON-RPC response id from ACP child");
  }
  if (hasResult === hasError) {
    throw new Error("JSON-RPC response must contain exactly one of result or error");
  }
  if (hasError) {
    const error = message.error;
    if (
      error === null
      || typeof error !== "object"
      || Array.isArray(error)
      || !Number.isInteger(error.code)
      || typeof error.message !== "string"
    ) {
      throw new Error("invalid JSON-RPC error object from ACP child");
    }
  }
  return "response";
}

class RpcPeer {
  constructor(child, onFatal) {
    this.child = child;
    this.onFatal = onFatal;
    this.nextId = 1;
    this.pending = new Map();
  }

  write(message) {
    if (!this.child.stdin.writable || this.child.stdin.destroyed) {
      throw new Error("ACP child stdin is not writable");
    }
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  request(method, params) {
    const id = this.nextId;
    this.nextId += 1;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { method, resolve, reject });
      try {
        this.write({ jsonrpc: "2.0", id, method, params });
      } catch (error) {
        this.pending.delete(id);
        reject(error);
      }
    });
  }

  notify(method, params) {
    this.write({ jsonrpc: "2.0", method, params });
  }

  respond(id, result) {
    this.write({ jsonrpc: "2.0", id, result });
  }

  respondError(id, code, message) {
    this.write({ jsonrpc: "2.0", id, error: { code, message } });
  }

  receiveResponse(message) {
    const waiter = this.pending.get(message.id);
    if (!waiter) {
      this.onFatal(new Error(`unknown response id from ACP child: ${stringifyId(message.id)}`));
      return;
    }
    this.pending.delete(message.id);
    if ("error" in message) {
      const code = message.error?.code;
      const detail = message.error?.message || JSON.stringify(message.error);
      waiter.reject(new Error(
        `ACP ${waiter.method} error${code === undefined ? "" : ` ${code}`}: ${detail}`,
      ));
      return;
    }
    waiter.resolve(message.result);
  }

  rejectAll(error) {
    for (const waiter of this.pending.values()) {
      waiter.reject(error);
    }
    this.pending.clear();
  }
}

function commandResult(command, args, timeoutMs = BUSY_EVENT_TIMEOUT_MS) {
  return new Promise((resolve, reject) => {
    const detached = process.platform !== "win32";
    const child = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      // Busy publication is part of the bridge's cancellation controller, not
      // the terminal foreground job. Keep the helper (and its descendants)
      // outside the bridge PGID so a terminal C-c cannot kill publication.
      detached,
    });
    const stderr = [];
    let settled = false;
    let timedOut = false;
    let timeoutTimer;
    let termTimer;
    let killTimer;
    const timeoutError = new Error(
      `${path.basename(command)} timed out after ${timeoutMs}ms`,
    );
    const terminate = (signal) => {
      try {
        if (detached && child.pid !== undefined) {
          process.kill(-child.pid, signal);
        } else {
          child.kill(signal);
        }
      } catch (error) {
        if (error?.code !== "ESRCH") {
          throw error;
        }
      }
    };
    const settle = (error) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeoutTimer);
      clearTimeout(termTimer);
      clearTimeout(killTimer);
      child.stdout.destroy();
      child.stderr.destroy();
      if (error) {
        reject(error);
      } else {
        resolve();
      }
    };
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.stdout.resume();
    child.once("error", (error) => {
      settle(timedOut ? timeoutError : error);
    });
    child.once("close", (code, signal) => {
      if (timedOut) {
        settle(timeoutError);
        return;
      }
      if (code === 0) {
        settle();
        return;
      }
      const detail = Buffer.concat(stderr).toString("utf8").trim();
      settle(new Error(
        `${path.basename(command)} exited ${code ?? `by ${signal}`}${detail ? `: ${detail}` : ""}`,
      ));
    });
    timeoutTimer = setTimeout(() => {
      if (settled) {
        return;
      }
      timedOut = true;
      terminate("SIGTERM");
      termTimer = setTimeout(() => {
        if (!settled) {
          terminate("SIGKILL");
        }
      }, COMMAND_TERM_GRACE_MS);
      killTimer = setTimeout(() => {
        settle(timeoutError);
      }, COMMAND_TERM_GRACE_MS + COMMAND_KILL_GRACE_MS);
    }, timeoutMs);
  });
}

async function applyBusyEvent(options, busyEvent, state, event) {
  await commandResult(busyEvent, [
    "apply",
    options.stateDir,
    options.taskId,
    state,
    "--gen",
    options.busyGen,
    "--source",
    "cursor-acp",
    "--event",
    event,
  ]);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const busyEvent = process.env.FM_CURSOR_BUSY_EVENT || DEFAULT_BUSY_EVENT;
  await validateBaseOptions(options, busyEvent);

  let statusTargetSafe = false;
  let savedSidecar;
  let launchPrompt;
  try {
    await validateStatusTarget(options);
    statusTargetSafe = true;
    await validateRuntimeDependencies(options);
    await validateSidecarTarget(options);
    savedSidecar = await readSidecar(options);
    launchPrompt = await encodeLaunchPrompt(options);
  } catch (error) {
    try {
      await applyBusyEvent(options, busyEvent, "unknown", "preflight-error");
    } catch (busyError) {
      process.stderr.write(
        `fm-cursor-acp: could not publish preflight unknown state: ${busyError.message}\n`,
      );
    }
    if (statusTargetSafe) {
      try {
        await appendStatus(options, "failed", error.message);
      } catch (statusError) {
        process.stderr.write(
          `fm-cursor-acp: could not append preflight failed status: ${statusError.message}\n`,
        );
      }
    }
    throw error;
  }

  const agentArgs = ["--trust", "--force"];
  if (options.model !== undefined) {
    agentArgs.push("--model", options.model);
  }
  agentArgs.push("acp");

  const child = spawn(options.agentBin, agentArgs, {
    cwd: options.cwd,
    stdio: ["pipe", "pipe", "pipe"],
    // A terminal C-c targets its foreground process group. Keep the ACP server
    // out of the bridge's group so SIGINT reaches this cancellation controller
    // only; shutdown still owns the child directly by PID below.
    detached: process.platform !== "win32",
  });
  const childProcessGroup = (
    process.platform !== "win32" && Number.isInteger(child.pid)
  ) ? child.pid : undefined;

  let childLifecycle;
  let resolveChildLifecycle;
  const childLifecycleSettled = new Promise((resolve) => {
    resolveChildLifecycle = resolve;
  });
  let phase = "starting";
  let sessionId;
  let normalClosing = false;
  let fatalStarted = false;
  let finished = false;
  let exitRequested = false;
  let cancelling = false;
  let publishingAbortRequested = false;
  let shutdownTimer;
  let terminationDeadline;
  let inputLines;
  let stdoutLines;
  let stderrLines;
  let onStdinEnd;
  let onSigint;
  let onSigterm;
  let onSighup;
  const promptQueue = [];
  const pendingPermissions = new Map();
  let finishRun;
  const runFinished = new Promise((resolve) => {
    finishRun = resolve;
  });

  const busyApply = async (state, event) => {
    await applyBusyEvent(options, busyEvent, state, event);
  };

  const settleChildLifecycle = (kind, details = {}) => {
    if (childLifecycle) {
      return false;
    }
    childLifecycle = { kind, ...details };
    resolveChildLifecycle(childLifecycle);
    return true;
  };

  const complete = (code) => {
    if (finished) {
      return;
    }
    finished = true;
    inputLines?.close();
    stdoutLines?.close();
    stderrLines?.close();
    child.stdin.destroy();
    child.stdout.destroy();
    child.stderr.destroy();
    process.stdin.pause();
    if (onStdinEnd) {
      process.stdin.removeListener("end", onStdinEnd);
    }
    if (onSigint) {
      process.removeListener("SIGINT", onSigint);
    }
    if (onSigterm) {
      process.removeListener("SIGTERM", onSigterm);
    }
    if (onSighup) {
      process.removeListener("SIGHUP", onSighup);
    }
    finishRun(code);
  };

  const waitForChildLifecycle = async (timeoutMs) => {
    if (childLifecycle) {
      return true;
    }
    let timer;
    const settled = await Promise.race([
      childLifecycleSettled.then(() => true),
      new Promise((resolve) => {
        timer = setTimeout(() => resolve(false), timeoutMs);
      }),
    ]);
    if (timer) {
      clearTimeout(timer);
    }
    return settled;
  };

  const terminateDirectChild = async () => {
    if (childLifecycle) {
      return;
    }
    if (await waitForChildLifecycle(300)) {
      return;
    }
    child.kill("SIGTERM");
    if (await waitForChildLifecycle(300)) {
      return;
    }
    child.kill("SIGKILL");
    if (await waitForChildLifecycle(500)) {
      return;
    }
    throw new Error("ACP child did not settle after stdin close, SIGTERM, and SIGKILL");
  };

  const processGroupExists = () => {
    if (childProcessGroup === undefined) {
      return false;
    }
    try {
      process.kill(-childProcessGroup, 0);
      return true;
    } catch (error) {
      if (error?.code === "ESRCH") {
        return false;
      }
      if (error?.code === "EPERM") {
        throw new Error(
          `ACP process group ${childProcessGroup} still exists but cannot be verified safely`,
        );
      }
      throw error;
    }
  };

  const signalProcessGroup = (signal) => {
    try {
      process.kill(-childProcessGroup, signal);
      return true;
    } catch (error) {
      if (error?.code === "ESRCH") {
        return false;
      }
      if (error?.code === "EPERM") {
        throw new Error(
          `refusing to treat inaccessible ACP process group ${childProcessGroup} as gone`,
        );
      }
      throw error;
    }
  };

  const waitForProcessGroupGone = async (timeoutMs) => {
    const deadline = Date.now() + timeoutMs;
    while (processGroupExists()) {
      if (Date.now() >= deadline) {
        return false;
      }
      await new Promise((resolve) => {
        setTimeout(resolve, 20);
      });
    }
    return true;
  };

  const terminateChild = async () => {
    if (child.stdin.writable && !child.stdin.destroyed) {
      child.stdin.end();
    } else {
      child.stdin.destroy();
    }
    if (childProcessGroup === undefined) {
      await terminateDirectChild();
      return;
    }
    // The direct child may exit while a descendant retains its ACP pipes.
    // The immutable spawn PID is the POSIX PGID; check that whole group during
    // this short bounded shutdown window instead of trusting the direct exit.
    if (await waitForProcessGroupGone(300)) {
      return;
    }
    signalProcessGroup("SIGTERM");
    if (await waitForProcessGroupGone(300)) {
      return;
    }
    signalProcessGroup("SIGKILL");
    if (await waitForProcessGroupGone(500)) {
      return;
    }
    throw new Error(
      `ACP process group ${childProcessGroup} did not disappear after stdin close, SIGTERM, and SIGKILL`,
    );
  };

  let peer;
  const fatal = async (error, event = "protocol-error") => {
    if (fatalStarted || normalClosing || finished) {
      return;
    }
    fatalStarted = true;
    phase = "fatal";
    if (shutdownTimer) {
      clearTimeout(shutdownTimer);
    }
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`fm-cursor-acp: ${message}\n`);
    if (peer) {
      peer.rejectAll(new Error(message));
    }
    for (const request of pendingPermissions.values()) {
      try {
        peer?.respond(request.id, { outcome: { outcome: "cancelled" } });
      } catch {
        // The fatal protocol path may already have lost the child pipe.
      }
    }
    pendingPermissions.clear();
    try {
      await busyApply("unknown", event);
    } catch (busyError) {
      process.stderr.write(`fm-cursor-acp: could not publish unknown state: ${busyError.message}\n`);
    }
    try {
      await appendStatus(options, "failed", message);
    } catch (statusError) {
      process.stderr.write(`fm-cursor-acp: could not append failed status: ${statusError.message}\n`);
    }
    normalClosing = true;
    try {
      await terminateChild();
    } catch (terminationError) {
      process.stderr.write(`fm-cursor-acp: ${terminationError.message}\n`);
    }
    complete(1);
  };

  peer = new RpcPeer(child, (error) => {
    void fatal(error, "protocol-error");
  });

  const cleanShutdown = async () => {
    if (normalClosing || fatalStarted || finished) {
      return;
    }
    normalClosing = true;
    phase = "closing";
    if (shutdownTimer) {
      clearTimeout(shutdownTimer);
    }
    peer.rejectAll(new Error("Cursor ACP bridge is shutting down"));
    for (const request of pendingPermissions.values()) {
      try {
        peer.respond(request.id, { outcome: { outcome: "cancelled" } });
      } catch {
        // Child closure below is the bounded fallback.
      }
    }
    pendingPermissions.clear();
    try {
      await terminateChild();
      complete(0);
    } catch (error) {
      process.stderr.write(`fm-cursor-acp: ${error.message}\n`);
      complete(1);
    }
  };

  const choosePermission = async (request) => {
    if (!pendingPermissions.has(request.key) || fatalStarted || normalClosing) {
      return;
    }
    if (cancelling) {
      pendingPermissions.delete(request.key);
      peer.respond(request.id, { outcome: { outcome: "cancelled" } });
      return;
    }
    const optionsOffered = Array.isArray(request.params?.options)
      ? request.params.options
      : [];
    const preferredAllow = optionsOffered.find((option) => option?.kind === "allow_once");
    if (preferredAllow && typeof preferredAllow.optionId === "string") {
      pendingPermissions.delete(request.key);
      peer.respond(request.id, {
        outcome: { outcome: "selected", optionId: preferredAllow.optionId },
      });
      return;
    }

    const title = request.params.toolCall.title || "Untitled request";
    await appendStatus(
      options,
      "blocked",
      `Cursor ACP permission request offered no allow option: ${title}`,
    );
    if (
      !pendingPermissions.has(request.key)
      || cancelling
      || fatalStarted
      || normalClosing
    ) {
      return;
    }
    const preferredReject = optionsOffered.find((option) => option?.kind === "reject_once")
      || optionsOffered.find((option) => option?.kind === "reject_always");
    pendingPermissions.delete(request.key);
    if (preferredReject && typeof preferredReject.optionId === "string") {
      peer.respond(request.id, {
        outcome: { outcome: "selected", optionId: preferredReject.optionId },
      });
    } else {
      peer.respond(request.id, { outcome: { outcome: "cancelled" } });
    }
  };

  const cancelPermissions = () => {
    for (const request of pendingPermissions.values()) {
      peer.respond(request.id, { outcome: { outcome: "cancelled" } });
    }
    pendingPermissions.clear();
  };

  const handleServerRequest = async (message) => {
    if (message.method === "session/request_permission") {
      const params = message.params;
      if (params === null || typeof params !== "object" || Array.isArray(params)) {
        throw new Error("Cursor ACP permission params must be an object");
      }
      if (!validSessionId(params.sessionId)) {
        throw new Error("Cursor ACP permission sessionId is invalid");
      }
      if (sessionId === undefined) {
        throw new Error("Cursor ACP permission session is not bound");
      }
      if (params.sessionId !== sessionId) {
        throw new Error("Cursor ACP permission sessionId mismatch");
      }
      if (
        params.toolCall === null
        || typeof params.toolCall !== "object"
        || Array.isArray(params.toolCall)
        || typeof params.toolCall.toolCallId !== "string"
        || params.toolCall.toolCallId.length === 0
        || (
          "title" in params.toolCall
          && typeof params.toolCall.title !== "string"
        )
      ) {
        throw new Error("Cursor ACP permission toolCall is invalid");
      }
      if (
        !Array.isArray(params.options)
        || params.options.some((option) => (
          option === null
          || typeof option !== "object"
          || Array.isArray(option)
          || typeof option.optionId !== "string"
          || option.optionId.length === 0
          || typeof option.kind !== "string"
          || option.kind.length === 0
        ))
      ) {
        throw new Error("Cursor ACP permission options are invalid");
      }
      const key = `${typeof message.id}:${stringifyId(message.id)}`;
      const request = { key, id: message.id, params };
      pendingPermissions.set(key, request);
      setImmediate(() => {
        void choosePermission(request).catch((error) => {
          void fatal(error, "protocol-error");
        });
      });
      return;
    }
    if (message.method === "cursor/ask_question") {
      const params = message.params;
      if (
        params === null
        || typeof params !== "object"
        || Array.isArray(params)
        || typeof params.toolCallId !== "string"
        || params.toolCallId.length === 0
        || ("title" in params && typeof params.title !== "string")
        || !Array.isArray(params.questions)
        || !params.questions.every(validCursorQuestion)
      ) {
        throw new Error("Cursor extension ask_question params are invalid");
      }
      const title = params.title || "Untitled question";
      await appendStatus(
        options,
        "needs-decision",
        `Cursor requested interactive question ${title}; inspect the worker pane`,
      );
      if (cancelling) {
        peer.respond(message.id, { outcome: { outcome: "cancelled" } });
      } else {
        peer.respond(message.id, {
          outcome: {
            outcome: "skipped",
            reason: "Escalated through the Firstmate status protocol; inspect the worker pane.",
          },
        });
      }
      return;
    }
    if (message.method === "cursor/create_plan") {
      const params = message.params;
      if (
        params === null
        || typeof params !== "object"
        || Array.isArray(params)
        || typeof params.toolCallId !== "string"
        || params.toolCallId.length === 0
        || ("name" in params && typeof params.name !== "string")
        || ("overview" in params && typeof params.overview !== "string")
        || typeof params.plan !== "string"
        || !Array.isArray(params.todos)
        || !params.todos.every(validCursorTodo)
        || ("isProject" in params && typeof params.isProject !== "boolean")
        || (
          "phases" in params
          && (
            !Array.isArray(params.phases)
            || params.phases.some((phase) => (
              phase === null
              || typeof phase !== "object"
              || Array.isArray(phase)
              || typeof phase.name !== "string"
              || !Array.isArray(phase.todos)
              || !phase.todos.every(validCursorTodo)
            ))
          )
        )
      ) {
        throw new Error("Cursor extension create_plan params are invalid");
      }
      const title = params.name || "Untitled plan";
      await appendStatus(
        options,
        "needs-decision",
        `Cursor requested plan approval ${title}; inspect the worker pane`,
      );
      if (cancelling) {
        peer.respond(message.id, { outcome: { outcome: "cancelled" } });
      } else {
        peer.respond(message.id, {
          outcome: {
            outcome: "rejected",
            reason: "Escalated through the Firstmate status protocol; inspect the worker pane.",
          },
        });
      }
      return;
    }
    peer.respondError(message.id, -32601, `Method not found: ${message.method}`);
  };

  let stdoutAtLineStart = true;
  const writeAgentText = (text) => {
    process.stdout.write(text);
    if (text.length > 0) {
      stdoutAtLineStart = text.endsWith("\n");
    }
  };
  const writeMarker = (marker) => {
    if (!stdoutAtLineStart) {
      process.stdout.write("\n");
    }
    process.stdout.write(`${marker}\n`);
    stdoutAtLineStart = true;
  };

  const handleNotification = (message) => {
    if (message.method === "session/update") {
      if (sessionId !== undefined && message.params?.sessionId !== sessionId) {
        throw new Error("Cursor ACP session/update sessionId mismatch");
      }
      const update = message.params?.update;
      if (
        update?.sessionUpdate === "agent_message_chunk"
        && typeof update.content?.text === "string"
      ) {
        writeAgentText(update.content.text);
      } else {
        writeMarker(`[update:${update?.sessionUpdate || "unknown"}]`);
      }
      return;
    }
    if (
      message.method === "cursor/update_todos"
      || message.method === "cursor/task"
      || message.method === "cursor/generate_image"
    ) {
      writeMarker(`[cursor:${message.method.slice("cursor/".length)}]`);
      return;
    }
    writeMarker(`[acp:${message.method}]`);
  };

  stdoutLines = readline.createInterface({
    input: child.stdout,
    crlfDelay: Infinity,
  });
  stdoutLines.on("line", (line) => {
    let message;
    let messageKind;
    try {
      message = JSON.parse(line);
    } catch (error) {
      void fatal(new Error(`invalid JSON from ACP child: ${error.message}`), "protocol-error");
      return;
    }
    try {
      messageKind = validateIncomingJsonRpc(message);
    } catch (error) {
      void fatal(error, "protocol-error");
      return;
    }
    if (messageKind === "request") {
      void handleServerRequest(message).catch((error) => {
        void fatal(error, "protocol-error");
      });
      return;
    }
    if (messageKind === "notification") {
      try {
        handleNotification(message);
      } catch (error) {
        void fatal(error, "protocol-error");
      }
      return;
    }
    if (messageKind === "response") {
      peer.receiveResponse(message);
      return;
    }
  });
  stdoutLines.on("close", () => {
    setTimeout(() => {
      if (normalClosing || fatalStarted || finished) {
        return;
      }
      if (!childLifecycle) {
        void fatal(new Error("unexpected ACP child stdout EOF"), "protocol-error");
      }
    }, 20);
  });
  child.stdout.on("error", (error) => {
    void fatal(new Error(`ACP child stdout error: ${error.message}`), "protocol-error");
  });
  child.stdin.on("error", (error) => {
    if (!normalClosing && !fatalStarted) {
      void fatal(new Error(`ACP child stdin error: ${error.message}`), "protocol-error");
    }
  });

  stderrLines = readline.createInterface({
    input: child.stderr,
    crlfDelay: Infinity,
  });
  stderrLines.on("line", (line) => {
    process.stderr.write(`[cursor-acp stderr] ${line}\n`);
  });

  child.once("error", (error) => {
    if (settleChildLifecycle("error", { error }) && !normalClosing && !fatalStarted && !finished) {
      void fatal(new Error(`could not start ACP child: ${error.message}`), "process-exit");
    }
  });
  child.once("exit", (code, signal) => {
    if (
      settleChildLifecycle("exit", { code, signal })
      && !normalClosing
      && !fatalStarted
      && !finished
    ) {
      void fatal(
        new Error(`ACP child exited with ${signal ? `signal ${signal}` : `code ${code}`}`),
        "process-exit",
      );
    }
  });
  child.once("close", (code, signal) => {
    if (
      settleChildLifecycle("close", { code, signal })
      && !normalClosing
      && !fatalStarted
      && !finished
    ) {
      void fatal(
        new Error(`ACP child closed with ${signal ? `signal ${signal}` : `code ${code}`}`),
        "process-exit",
      );
    }
  });

  const runPrompt = async (text) => {
    if (fatalStarted || normalClosing || finished) {
      return;
    }
    phase = "publishing-busy";
    try {
      await busyApply("busy", "prompt-start");
    } catch (error) {
      await fatal(new Error(`busy event prompt-start failed: ${error.message}`), "protocol-error");
      return;
    }
    if (fatalStarted || normalClosing || finished) {
      return;
    }
    if (publishingAbortRequested) {
      try {
        await busyApply("idle", "prompt-abort");
      } catch (error) {
        await fatal(new Error(`busy event prompt-abort failed: ${error.message}`), "protocol-error");
        return;
      }
      phase = "idle";
      publishingAbortRequested = false;
      if (exitRequested) {
        await cleanShutdown();
        return;
      }
      const next = promptQueue.shift();
      if (next !== undefined) {
        void runPrompt(next);
      }
      return;
    }
    phase = "busy";
    try {
      const promptResult = await peer.request("session/prompt", {
        sessionId,
        prompt: [{ type: "text", text }],
      });
      if (shutdownTimer) {
        clearTimeout(shutdownTimer);
        shutdownTimer = undefined;
      }
      if (
        promptResult === null
        || typeof promptResult !== "object"
        || Array.isArray(promptResult)
        || !ACP_STOP_REASONS.has(promptResult.stopReason)
      ) {
        throw new Error("ACP session/prompt returned an invalid v1 stopReason");
      }
      if (cancelling && promptResult.stopReason !== "cancelled") {
        throw new Error(
          `ACP session/prompt returned ${promptResult.stopReason} after session/cancel`,
        );
      }
    } catch (error) {
      await fatal(error, "protocol-error");
      return;
    }
    if (fatalStarted || normalClosing || finished) {
      return;
    }
    // The prompt RPC has completed, so cancellation is no longer meaningful.
    // Keep completion publication explicit: SIGINT is a no-op in this phase,
    // while exit requests wait for prompt-stop + turn-ended before shutdown.
    phase = "publishing-idle";
    try {
      await busyApply("idle", "prompt-stop");
      await touchTurnEnded(options);
    } catch (error) {
      await fatal(new Error(`prompt completion publication failed: ${error.message}`), "protocol-error");
      return;
    }
    phase = "idle";
    cancelling = false;
    if (exitRequested) {
      await cleanShutdown();
      return;
    }
    const next = promptQueue.shift();
    if (next !== undefined) {
      void runPrompt(next);
    }
  };

  const requestGracefulExit = () => {
    if (exitRequested || fatalStarted || normalClosing || finished) {
      return;
    }
    exitRequested = true;
    promptQueue.length = 0;
    if (phase === "idle") {
      void cleanShutdown();
      return;
    }
    if (phase === "publishing-busy") {
      publishingAbortRequested = true;
      return;
    }
    if ((phase === "starting" || phase === "busy") && !cancelling) {
      if (shutdownTimer) {
        clearTimeout(shutdownTimer);
      }
      shutdownTimer = setTimeout(() => {
        shutdownTimer = undefined;
        void cleanShutdown();
      }, SHUTDOWN_GRACE_MS);
    }
  };

  inputLines = readline.createInterface({
    input: process.stdin,
    crlfDelay: Infinity,
  });
  inputLines.on("line", (line) => {
    if (line.length === 0 || fatalStarted || normalClosing || finished) {
      return;
    }
    if (line === "/exit") {
      requestGracefulExit();
      return;
    }
    if (exitRequested) {
      return;
    }
    if (phase === "idle") {
      void runPrompt(line);
    } else {
      promptQueue.push(line);
    }
  });
  inputLines.on("close", () => {
    requestGracefulExit();
  });
  onStdinEnd = requestGracefulExit;
  process.stdin.once("end", onStdinEnd);

  const cancelActivePrompt = (signal) => {
    if (cancelling) {
      return;
    }
    cancelling = true;
    try {
      peer.notify("session/cancel", { sessionId });
      cancelPermissions();
    } catch (error) {
      void fatal(new Error(`${signal} cancellation failed: ${error.message}`), "protocol-error");
      return;
    }
    if (shutdownTimer) {
      clearTimeout(shutdownTimer);
    }
    shutdownTimer = setTimeout(() => {
      void fatal(
        new Error(`${signal} timed out waiting for the cancelled ACP prompt`),
        "protocol-error",
      );
    }, SHUTDOWN_GRACE_MS);
  };

  const handleSigint = () => {
    if (fatalStarted || normalClosing || finished) {
      return;
    }
    if (exitRequested) {
      return;
    }
    if (phase === "busy") {
      cancelActivePrompt("SIGINT");
    } else if (phase === "publishing-busy") {
      publishingAbortRequested = true;
    }
    // Idle/starting/publishing-idle SIGINT is deliberately a no-op. It must
    // not turn a cancellation key into a session exit or cancel a completed
    // prompt while its idle/turn-ended publication is still in progress.
  };

  const armTerminationDeadline = () => {
    if (terminationDeadline !== undefined) {
      return;
    }
    terminationDeadline = Date.now() + SHUTDOWN_GRACE_MS;
    if (shutdownTimer) {
      clearTimeout(shutdownTimer);
    }
    shutdownTimer = setTimeout(() => {
      shutdownTimer = undefined;
      void cleanShutdown();
    }, Math.max(0, terminationDeadline - Date.now()));
  };

  const handleTerminationSignal = (signal) => {
    if (fatalStarted || normalClosing || finished) {
      return;
    }
    exitRequested = true;
    promptQueue.length = 0;
    if (phase === "busy") {
      if (!cancelling) {
        cancelActivePrompt(signal);
      }
      if (fatalStarted) {
        return;
      }
      // A termination signal upgrades an interactive cancellation into an
      // intentional bounded shutdown. The first termination signal replaces
      // any SIGINT cancel-fatal timer and fixes the deadline; later TERM/HUP
      // signals cannot clear or extend it.
      armTerminationDeadline();
    } else if (phase === "publishing-busy") {
      publishingAbortRequested = true;
    } else if (phase === "idle" || phase === "starting") {
      void cleanShutdown();
    }
  };
  onSigint = handleSigint;
  onSigterm = () => handleTerminationSignal("SIGTERM");
  process.on("SIGINT", onSigint);
  process.on("SIGTERM", onSigterm);
  if (process.platform !== "win32") {
    onSighup = () => handleTerminationSignal("SIGHUP");
    process.on("SIGHUP", onSighup);
  }

  try {
    const initialize = await peer.request("initialize", {
      protocolVersion: 1,
      clientCapabilities: {
        fs: {
          readTextFile: false,
          writeTextFile: false,
        },
        terminal: false,
      },
      clientInfo: {
        name: "firstmate-cursor-bridge",
        version: "1",
      },
    });
    if (fatalStarted || normalClosing) {
      return await runFinished;
    }
    if (initialize?.protocolVersion !== 1) {
      throw new Error(`ACP child negotiated unsupported protocolVersion ${initialize.protocolVersion}`);
    }
    if (savedSidecar && initialize.agentCapabilities?.loadSession !== true) {
      throw new Error("ACP child did not advertise agentCapabilities.loadSession=true");
    }
    if (
      !Array.isArray(initialize.authMethods)
      || !initialize.authMethods.some((method) => method?.id === "cursor_login")
    ) {
      throw new Error("ACP initialize authMethods did not advertise cursor_login");
    }

    const authenticated = await peer.request("authenticate", { methodId: "cursor_login" });
    if (
      authenticated === null
      || typeof authenticated !== "object"
      || Array.isArray(authenticated)
    ) {
      throw new Error("ACP authenticate returned a non-object result");
    }
    if (fatalStarted || normalClosing) {
      return await runFinished;
    }

    if (savedSidecar) {
      sessionId = savedSidecar.sessionId;
      const loaded = await peer.request("session/load", {
        sessionId,
        cwd: options.cwd,
        mcpServers: [],
      });
      if (loaded === null || typeof loaded !== "object" || Array.isArray(loaded)) {
        throw new Error("ACP session/load returned a non-object result");
      }
      if ("sessionId" in loaded && loaded.sessionId !== savedSidecar.sessionId) {
        throw new Error("ACP session/load attempted to replace the authoritative sessionId");
      }
    } else {
      const created = await peer.request("session/new", {
        cwd: options.cwd,
        mcpServers: [],
      });
      if (!validSessionId(created?.sessionId)) {
        throw new Error("ACP session/new returned an invalid sessionId");
      }
      sessionId = created.sessionId;
      await writeSidecar(options, sessionId);
    }

    await runPrompt(launchPrompt);
  } catch (error) {
    await fatal(error, "protocol-error");
  }

  return await runFinished;
}

try {
  process.exitCode = await main();
} catch (error) {
  process.stderr.write(`fm-cursor-acp: ${error.message}\n`);
  process.exitCode = 1;
}
