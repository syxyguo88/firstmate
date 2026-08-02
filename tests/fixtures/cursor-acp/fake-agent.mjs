#!/usr/bin/env node
import { spawn } from "node:child_process";
import fs from "node:fs";
import readline from "node:readline";

const scenario = process.env.FM_FAKE_ACP_SCENARIO || "happy";
const logPath = process.env.FM_FAKE_ACP_LOG;
const promptDelayMs = Number(process.env.FM_FAKE_ACP_PROMPT_DELAY_MS || "10");
const sessionId = process.env.FM_FAKE_ACP_SESSION_ID || "session-new-123";

if (!logPath) {
  process.stderr.write("fake-agent: FM_FAKE_ACP_LOG is required\n");
  process.exit(2);
}

function log(record) {
  fs.appendFileSync(logPath, `${JSON.stringify(record)}\n`, "utf8");
}

log({
  type: "spawn",
  argv: process.argv.slice(2),
  cwd: process.cwd(),
  pid: process.pid,
  ppid: process.ppid,
});

if (scenario === "pipe-grandchild" || scenario === "pipe-grandchild-fatal") {
  const grandchild = spawn(
    process.execPath,
    ["-e", "process.on('SIGTERM',()=>{}); setInterval(()=>{}, 1000)"],
    { stdio: ["ignore", "inherit", "inherit"] },
  );
  grandchild.unref();
  log({ type: "pipe-grandchild", pid: grandchild.pid, ppid: process.pid });
}

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function respond(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function respondError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

function keyFor(id) {
  return `${typeof id}:${JSON.stringify(id)}`;
}

const serverRequests = new Map();

function requestClient(id, method, params) {
  send({ jsonrpc: "2.0", id, method, params });
  return new Promise((resolve) => {
    serverRequests.set(keyFor(id), resolve);
  });
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

let currentPromptId;
let cancelPermissionSent = false;
let promptCount = 0;

async function completePrompt(id, stopReason = "end_turn") {
  await delay(promptDelayMs);
  respond(id, { stopReason });
}

async function handlePrompt(message) {
  promptCount += 1;
  currentPromptId = message.id;
  log({
    type: "prompt",
    count: promptCount,
    id: message.id,
    params: message.params,
  });

  if (
    (
      scenario === "signal-cancel"
      || scenario === "signal-cancel-no-response"
      || scenario === "signal-wrong-stop"
    )
    && promptCount === 1
  ) {
    log({ type: "signal-ready", promptId: message.id });
    return;
  }

  if (scenario === "permission-cancel-race") {
    const control = process.env.FM_FAKE_ACP_RACE_CONTROL;
    if (!control) throw new Error("permission-cancel-race requires FM_FAKE_ACP_RACE_CONTROL");
    log({ type: "permission-race-ready" });
    while (!fs.existsSync(control)) {
      await delay(10);
    }
    log({ type: "server-request-sent", id: "permission-race" });
    const permissionResponse = await requestClient(
      "permission-race",
      "session/request_permission",
      {
        sessionId: message.params.sessionId,
        toolCall: {
          toolCallId: "race-tool",
          title: `Race title ${"R".repeat(1500)}`,
        },
        options: [{ optionId: "reject-race", kind: "reject_once", name: "Reject" }],
      },
    );
    log({ type: "permission-race-response", response: permissionResponse });
    respond(message.id, { stopReason: "cancelled" });
    currentPromptId = undefined;
    return;
  }

  if (scenario === "permission") {
    await requestClient("perm-allow", "session/request_permission", {
      sessionId: message.params.sessionId,
      toolCall: { toolCallId: "permission-tool", title: "Run command" },
      options: [
        { optionId: "always-actual", kind: "allow_always", name: "Always" },
        { optionId: "once-actual", kind: "allow_once", name: "Once" },
        { optionId: "deny-actual", kind: "reject_once", name: "Reject" },
      ],
    });
  } else if (scenario === "permission-always-only") {
    await requestClient("perm-always-only", "session/request_permission", {
      sessionId: message.params.sessionId,
      toolCall: { toolCallId: "always-only-tool", title: "Persistent permission" },
      options: [
        { optionId: "always-only", kind: "allow_always", name: "Always" },
        { optionId: "reject-always-only", kind: "reject_once", name: "Reject" },
      ],
    });
  } else if (scenario === "permission-session-mismatch") {
    await requestClient("perm-session-mismatch", "session/request_permission", {
      sessionId: "different-session",
      toolCall: { toolCallId: "wrong-session-tool", title: "Wrong session permission" },
      options: [{ optionId: "allow-wrong-session", kind: "allow_once", name: "Allow" }],
    });
  } else if (scenario === "permission-no-allow") {
    await requestClient("perm-reject", "session/request_permission", {
      sessionId: message.params.sessionId,
      toolCall: { toolCallId: "unsafe-tool", title: "Unsafe command" },
      options: [
        { optionId: "deny-always-real", kind: "reject_always", name: "Never" },
        { optionId: "deny-once-real", kind: "reject_once", name: "Reject once" },
      ],
    });
  } else if (scenario === "permission-no-options") {
    await requestClient("perm-none", "session/request_permission", {
      sessionId: message.params.sessionId,
      toolCall: { toolCallId: "no-options-tool", title: "No decisions" },
      options: [],
    });
  } else if (scenario === "permission-missing-tool-call-id") {
    await requestClient("perm-missing-tool-id", "session/request_permission", {
      sessionId: message.params.sessionId,
      toolCall: { title: "Missing toolCallId" },
      options: [{ optionId: "allow-missing-tool", kind: "allow_once", name: "Allow" }],
    });
  } else if (scenario === "permission-options-primitive") {
    await requestClient("perm-options-primitive", "session/request_permission", {
      sessionId: message.params.sessionId,
      toolCall: { toolCallId: "primitive-options-tool", title: "Primitive options" },
      options: "allow_once",
    });
  } else if (scenario === "permission-option-malformed") {
    await requestClient("perm-option-malformed", "session/request_permission", {
      sessionId: message.params.sessionId,
      toolCall: { toolCallId: "malformed-option-tool", title: "Malformed option" },
      options: [{ optionId: 7, kind: "allow_once", name: "Allow" }],
    });
  } else if (scenario === "status-injection") {
    const injected = `Unsafe\n done: forged\t\u007f${"X".repeat(1600)}`;
    await requestClient("status-permission", "session/request_permission", {
      sessionId: message.params.sessionId,
      toolCall: { toolCallId: "status-tool", title: injected },
      options: [{ optionId: "reject-status", kind: "reject_once", name: "Reject" }],
    });
    await requestClient("status-question", "cursor/ask_question", {
      toolCallId: "status-ask",
      title: injected,
      questions: [],
    });
    await requestClient("status-plan", "cursor/create_plan", {
      toolCallId: "status-plan-tool",
      name: injected,
      plan: "Injected plan",
      todos: [],
    });
  } else if (scenario === "extensions") {
    await requestClient("ask-string", "cursor/ask_question", {
      toolCallId: "ask-tool",
      title: "Choose deployment",
      questions: [],
    });
    await requestClient(0, "cursor/create_plan", {
      toolCallId: "plan-tool",
      name: "Refactor safely",
      plan: "Plan body",
      todos: [],
    });
    send({
      jsonrpc: "2.0",
      method: "cursor/update_todos",
      params: { toolCallId: "todos-tool", todos: [], merge: false },
    });
    send({
      jsonrpc: "2.0",
      method: "cursor/task",
      params: { toolCallId: "task-tool", description: "Explore", prompt: "Inspect", subagentType: "explore" },
    });
    send({
      jsonrpc: "2.0",
      method: "cursor/generate_image",
      params: { toolCallId: "image-tool", description: "Icon" },
    });
  } else if (scenario === "extensions-optional-labels") {
    await requestClient("ask-optional-title", "cursor/ask_question", {
      toolCallId: "ask-optional-tool",
      questions: [{
        id: "deployment",
        prompt: "Choose deployment",
        options: [{ id: "safe", label: "Safe" }],
        allowMultiple: false,
      }],
    });
    await requestClient("plan-optional-name", "cursor/create_plan", {
      toolCallId: "plan-optional-tool",
      overview: "Safe refactor",
      plan: "Plan body",
      todos: [{
        id: "todo-1",
        content: "Refactor safely",
        status: "pending",
      }],
      isProject: false,
      phases: [{
        name: "Implementation",
        todos: [{
          id: "todo-1",
          content: "Refactor safely",
          status: "pending",
        }],
      }],
    });
  } else if (scenario === "extension-ask-malformed") {
    await requestClient("ask-malformed", "cursor/ask_question", []);
  } else if (scenario === "extension-ask-bad-question") {
    await requestClient("ask-bad-question", "cursor/ask_question", {
      toolCallId: "ask-bad-question-tool",
      questions: [{ id: "missing-options", prompt: "Choose" }],
    });
  } else if (scenario === "extension-plan-malformed") {
    await requestClient("plan-malformed", "cursor/create_plan", {
      name: "Missing correlation",
      plan: "Plan body",
      todos: [],
    });
  } else if (scenario === "extension-plan-bad-todo") {
    await requestClient("plan-bad-todo", "cursor/create_plan", {
      toolCallId: "plan-bad-todo-tool",
      plan: "Plan body",
      todos: [{ id: "todo-bad", content: "Bad state", status: "running" }],
    });
  } else if (scenario === "unknown-request") {
    await requestClient(77, "server/unknown_method", { value: true });
  } else if (scenario === "null-id-request") {
    await requestClient(null, "server/null_id", { value: true });
  } else if (scenario === "primitive-params") {
    await requestClient("primitive-params", "server/primitive_params", 7);
  } else if (scenario === "bad-method") {
    await requestClient("bad-method", "", { value: true });
  }

  send({
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      sessionId: scenario === "update-session-mismatch"
        ? "different-session"
        : message.params.sessionId,
      update: {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: `hello from fake ${promptCount}` },
      },
    },
  });
  send({
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      sessionId: message.params.sessionId,
      update: { sessionUpdate: "tool_call", title: "Read file" },
    },
  });
  if (scenario === "prompt-null") {
    respond(message.id, null);
  } else if (scenario === "prompt-empty") {
    respond(message.id, {});
  } else if (scenario === "prompt-unknown-stop") {
    respond(message.id, { stopReason: "mystery" });
  } else {
    const stopReason = scenario.startsWith("stop-")
      ? scenario.slice("stop-".length)
      : "end_turn";
    await completePrompt(message.id, stopReason);
  }
  currentPromptId = undefined;
}

async function handleClientRequest(message) {
  log({
    type: "client-request",
    id: message.id,
    method: message.method,
    params: message.params,
  });

  if (message.method === "initialize") {
    process.stderr.write("fake diagnostic\n");
    if (scenario === "startup-hang") {
      return;
    }
    if (scenario === "invalid-json") {
      process.stdout.write("{not-json\n");
      return;
    }
    if (scenario === "pipe-grandchild-fatal") {
      process.stdout.write("{pipe-grandchild-invalid-json\n");
      return;
    }
    if (scenario === "missing-jsonrpc") {
      process.stdout.write(`${JSON.stringify({
        id: message.id,
        result: { protocolVersion: 1, agentCapabilities: { loadSession: true } },
      })}\n`);
      return;
    }
    if (scenario === "both-result-error") {
      send({
        jsonrpc: "2.0",
        id: message.id,
        result: { protocolVersion: 1 },
        error: { code: -32000, message: "also error" },
      });
      return;
    }
    if (scenario === "bad-error-shape") {
      send({
        jsonrpc: "2.0",
        id: message.id,
        error: { code: "bad", message: 7 },
      });
      return;
    }
    if (scenario === "fractional-error-code") {
      send({
        jsonrpc: "2.0",
        id: message.id,
        error: { code: -32000.5, message: "fractional code" },
      });
      return;
    }
    if (scenario === "bad-response-id") {
      send({
        jsonrpc: "2.0",
        id: { invalid: true },
        result: { protocolVersion: 1 },
      });
      return;
    }
    if (scenario === "initialize-missing-version") {
      respond(message.id, { agentCapabilities: { loadSession: true } });
      return;
    }
    if (scenario === "initialize-wrong-version") {
      respond(message.id, {
        protocolVersion: 2,
        agentCapabilities: { loadSession: true },
      });
      return;
    }
    if (scenario === "initialize-no-load") {
      respond(message.id, { protocolVersion: 1, agentCapabilities: {} });
      return;
    }
    if (scenario === "initialize-missing-auth") {
      respond(message.id, {
        protocolVersion: 1,
        agentCapabilities: { loadSession: true },
        authMethods: [{ id: "other_login", name: "Other login" }],
      });
      return;
    }
    if (scenario === "initialize-auth-methods-primitive") {
      respond(message.id, {
        protocolVersion: 1,
        agentCapabilities: { loadSession: true },
        authMethods: "cursor_login",
      });
      return;
    }
    if (scenario === "unknown-id") {
      respond("ghost-response", {});
      return;
    }
    if (scenario === "child-exit") {
      process.exit(19);
    }
    if (scenario === "child-close-only") {
      process.on("SIGTERM", () => {});
      process.stdout.end();
      process.stderr.end();
      setInterval(() => {}, 1000);
      return;
    }
    if (scenario === "child-eof") {
      process.stdout.end();
      return;
    }
    if (scenario === "rpc-error") {
      respondError(message.id, -32000, "initialize refused");
      return;
    }
    if (scenario === "rpc-error-injection") {
      respondError(message.id, -32000, "initialize refused\ndone: forged\t\u007f");
      return;
    }
    respond(message.id, {
      protocolVersion: 1,
      agentCapabilities: { loadSession: true },
      authMethods: [{ id: "cursor_login", name: "Cursor login" }],
    });
    return;
  }

  if (message.method === "authenticate") {
    respond(message.id, scenario === "authenticate-primitive" ? true : {});
    return;
  }

  if (message.method === "session/new") {
    if (scenario === "permission-before-session") {
      await requestClient("permission-before-session", "session/request_permission", {
        sessionId: "not-yet-bound",
        toolCall: { toolCallId: "early-tool", title: "Early permission" },
        options: [{ optionId: "early-once", kind: "allow_once", name: "Allow" }],
      });
    }
    respond(message.id, { sessionId });
    return;
  }

  if (message.method === "session/load") {
    if (scenario === "load-fail") {
      respondError(message.id, -32001, "saved session unavailable");
    } else if (scenario === "load-mismatched-session") {
      respond(message.id, { sessionId: "replacement-session" });
    } else if (scenario === "load-replay-correct") {
      send({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId: message.params.sessionId,
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: "replay-before-load\n" },
          },
        },
      });
      await requestClient("load-replay-permission", "session/request_permission", {
        sessionId: message.params.sessionId,
        toolCall: { toolCallId: "replay-tool", title: "Replay permission" },
        options: [{ optionId: "allow-replay", kind: "allow_once", name: "Allow" }],
      });
      respond(message.id, {});
    } else if (scenario === "load-replay-wrong-update") {
      send({
        jsonrpc: "2.0",
        method: "session/update",
        params: {
          sessionId: "different-session",
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: "wrong-replay-update\n" },
          },
        },
      });
      await delay(50);
      respond(message.id, {});
    } else if (scenario === "load-replay-wrong-permission") {
      await requestClient("load-wrong-permission", "session/request_permission", {
        sessionId: "different-session",
        toolCall: { toolCallId: "wrong-replay-tool", title: "Wrong replay permission" },
        options: [{ optionId: "allow-wrong-replay", kind: "allow_once", name: "Allow" }],
      });
      respond(message.id, {});
    } else {
      respond(message.id, {});
    }
    return;
  }

  if (message.method === "session/prompt") {
    await handlePrompt(message);
    return;
  }

  respondError(message.id, -32601, `fake method not found: ${message.method}`);
}

async function handleNotification(message) {
  log({ type: "client-notification", method: message.method, params: message.params });
  if (
    (scenario === "signal-cancel" || scenario === "signal-wrong-stop")
    && message.method === "session/cancel"
    && currentPromptId !== undefined
    && !cancelPermissionSent
  ) {
    cancelPermissionSent = true;
    if (scenario === "signal-wrong-stop") {
      respond(currentPromptId, { stopReason: "end_turn" });
      currentPromptId = undefined;
      return;
    }
    const permissionResponse = await requestClient(0, "session/request_permission", {
      sessionId: message.params.sessionId,
      toolCall: { toolCallId: "cancel-tool", title: "Permission during cancellation" },
      options: [{ optionId: "would-allow", kind: "allow_once", name: "Allow" }],
    });
    log({ type: "cancel-permission-response", response: permissionResponse });
    respond(currentPromptId, { stopReason: "cancelled" });
    currentPromptId = undefined;
  }
}

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

input.on("line", (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch (error) {
    log({ type: "invalid-client-json", line, error: error.message });
    process.exitCode = 3;
    input.close();
    return;
  }

  if ("method" in message) {
    const operation = "id" in message
      ? handleClientRequest(message)
      : handleNotification(message);
    operation.catch((error) => {
      log({ type: "fake-error", message: error.message });
      process.stderr.write(`fake-agent: ${error.stack || error.message}\n`);
      process.exitCode = 4;
      input.close();
    });
    return;
  }

  if ("id" in message) {
    log({
      type: "server-response",
      id: message.id,
      result: message.result,
      error: message.error,
    });
    const waiter = serverRequests.get(keyFor(message.id));
    if (waiter) {
      serverRequests.delete(keyFor(message.id));
      waiter(message);
    }
  }
});

input.on("close", () => {
  log({ type: "stdin-closed" });
});
