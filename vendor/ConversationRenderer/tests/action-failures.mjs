import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { resolve, dirname, extname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const { checkout } = JSON.parse(readFileSync(resolve(root, ".work/source.json"), "utf8"));
const { chromium } = await import(
  pathToFileURL(resolve(checkout, "apps/web/node_modules/playwright/index.mjs")).href
);
const directory = resolve(root, process.env.CONVERSATION_BUNDLE ?? ".work/services");
const mime = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".wasm": "application/wasm",
  ".woff2": "font/woff2",
  ".woff": "font/woff",
  ".svg": "image/svg+xml",
  ".json": "application/json",
};
const server = createServer((request, response) => {
  const path = resolve(
    directory,
    "." + decodeURIComponent(new URL(request.url, "http://localhost").pathname),
  );
  if (!path.startsWith(directory + "/") && path !== directory) {
    response.writeHead(403);
    response.end();
    return;
  }
  const file = path === directory ? resolve(directory, "index.html") : path;
  if (!existsSync(file)) {
    response.writeHead(404);
    response.end();
    return;
  }
  response.setHeader("Content-Type", mime[extname(file)] ?? "application/octet-stream");
  response.end(readFileSync(file));
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 900, height: 1100 } });
const page = await context.newPage();
const errors = [],
  network = [],
  failures = [],
  checks = [],
  consoleMessages = [];
page.on("console", (message) =>
  consoleMessages.push({ type: message.type(), text: message.text() }),
);
page.on("pageerror", (error) => errors.push(error.message));
page.on("request", (request) => {
  if (
    !request.url().startsWith(origin) &&
    !request.url().startsWith("data:") &&
    !request.url().startsWith("blob:")
  )
    network.push(request.url());
});
page.on("websocket", (socket) => network.push(socket.url()));
const text =
  "## Final result\n\nSelected quotation with **bold** and `inline code`.\n\n```swift\nlet value = 42\nprint(value)\n```\n\n| Name | Value |\n| --- | ---: |\n| **Alpha** | 12 |\n| Beta | 34 |\n\nFormula $x^2$.";
const items = [
  {
    id: "u1",
    kind: "user",
    text: "Review the project and explain the result.",
    isComplete: true,
    attachments: [{ id: "note1", name: "note.txt", mimeType: "text/plain", byteCount: 12 }],
  },
  { id: "a0", kind: "assistant", text: "Earlier finding in completed work.", isComplete: true },
  {
    id: "cmd1",
    kind: "tool",
    text: "printf hello",
    isComplete: true,
    tool: {
      name: "commandExecution",
      category: "command",
      presentation: "command",
      status: "completed",
      input: JSON.stringify({ command: "printf hello" }),
      output: "\u001b[31mhello\u001b[0m\n",
      exitCode: 0,
      startedAt: "2026-10-31T10:00:01Z",
      completedAt: "2026-10-31T10:00:02Z",
    },
  },
  {
    id: "generic1",
    kind: "tool",
    text: "Inspect document",
    isComplete: true,
    tool: {
      name: "mcp__document__inspect",
      category: "other",
      presentation: "dynamicTool",
      status: "completed",
      input: '{"path":"note.txt"}',
      output: '{"summary":"generic output","count":2}',
      outputIsJSON: true,
      startedAt: "2026-10-31T10:00:02Z",
      completedAt: "2026-10-31T10:00:03Z",
    },
  },
  { id: "a1", kind: "assistant", text, isComplete: true },
];
const snapshot = {
  bridgeVersion: 1,
  connectionState: "live",
  sessionId: "session",
  projectId: "project",
  environmentId: "project",
  revision: 1,
  theme: "light",
  cwd: "/workspace",
  items,
  turns: [
    {
      userItemID: "u1",
      startedAt: "2026-10-31T10:00:00Z",
      completedAt: "2026-10-31T10:00:04Z",
      status: "idle",
      checkpoint: {
        id: "checkpoint",
        files: [{ path: "Sources/main.swift", additions: 3, deletions: 1 }, { path: "image.png" }],
        totalFiles: 2,
        additions: 3,
        deletions: 1,
        truncated: false,
      },
    },
  ],
  status: "idle",
  messages: items
    .filter((item) => item.kind === "user" || item.kind === "assistant")
    .map((item) => ({ id: item.id, role: item.kind, text: item.text })),
  font: { interfaceSize: 16, promptSize: 14, codeSize: 13 },
  settings: { mathRenderingEnabled: false },
  capabilities: {
    nativeActions: true,
    attachments: true,
    cite: true,
    runShellCommand: true,
    openToolDiff: true,
    openTurnDiff: true,
    openAttachment: true,
    downloadAttachment: true,
  },
};
await page.addInitScript(() => {
  window.__bridge = [];
  window.__copies = [];
  window.__citations = [];
  window.prompt = (prompt, value) => {
    if (prompt === "__tab_conversation_cite_v1__") {
      window.__citations.push(JSON.parse(value));
      return "true";
    }
    return null;
  };
  window.webkit = {
    messageHandlers: {
      tabConversation: {
        postMessage(message) {
          window.__bridge.push(message);
          if (message.type !== "action") return;
          let result = true;
          if (message.action.kind === "copy") {
            window.__copies.push(message.action);
          } else if (message.action.kind === "loadTurnItem") {
            const id = message.action.itemId ?? message.action.input?.itemId;
            result = {
              item:
                id === "cmd1"
                  ? {
                      id,
                      type: "command_execution",
                      input: "printf hello",
                      output: "\u001b[31mhello\u001b[0m\n",
                      exitCode: 0,
                      status: "completed",
                    }
                  : {
                      id,
                      type: "dynamic_tool",
                      toolName: "mcp__document__inspect",
                      input: { path: "note.txt" },
                      output: { summary: "generic output", count: 2 },
                      status: "completed",
                    },
            };
          }
          queueMicrotask(() =>
            window.TabConversation?.resolve({ requestId: message.requestId, ok: true, result }),
          );
        },
      },
    },
  };
});
async function check(name, run) {
  try {
    await run();
    checks.push(name);
  } catch (error) {
    failures.push({
      name,
      error: String(error),
      buttons: await page.getByRole("button").allTextContents(),
      body: await page.locator("body").innerText(),
    });
  }
}
try {
  await page.addInitScript(() => {
    window.__bridge = [];
    window.webkit = {
      messageHandlers: {
        tabConversation: {
          postMessage(message) {
            window.__bridge.push(message);
            if (message.type === "action")
              queueMicrotask(() =>
                window.TabConversation.resolve({
                  requestId: message.requestId,
                  ok: false,
                  error: "Native approval failed.",
                }),
              );
          },
        },
      },
    };
  });
  await page.goto(origin, { waitUntil: "networkidle" });
  await page.evaluate((value) => window.TabConversation.update(value), {
    ...snapshot,
    items: [
      { id: "u1", kind: "user", text: "Pending native operation", isComplete: true },
      {
        id: "approval-1",
        kind: "approval",
        text: "Approve command",
        detail: "Run the requested command?",
        isComplete: false,
      },
    ],
    messages: [{ id: "u1", role: "user", text: "Pending native operation" }],
    turns: [{ userItemID: "u1", startedAt: "2026-10-31T10:00:00Z", status: "working" }],
    status: "working",
    capabilities: { nativeActions: true, approvals: true },
    connectionState: "live",
  });
  const approve = page.getByRole("button", { name: "Approve", exact: true });
  await approve.waitFor();
  await approve.click();
  await page.getByText("Unable to respond to approval", { exact: true }).waitFor();
  await page.getByText("Native approval failed.", { exact: true }).waitFor();
  assert.equal(await approve.isEnabled(), true);
  const bridge = await page.evaluate(() => window.__bridge);
  assert.ok(
    bridge.some((message) => message.type === "action" && message.action.kind === "approve"),
  );
  assert.ok(
    !bridge.some((message) => message.type === "error"),
    "An ordinary native action failure must not replace the conversation",
  );
  assert.deepEqual(errors, []);
  assert.deepEqual(network, []);
  console.log(
    JSON.stringify(
      {
        checks: [
          "real approval rejection shows source toast",
          "pending approval remains actionable",
          "no whole-body fallback",
        ],
        errors,
        network,
        bridge,
      },
      null,
      2,
    ),
  );
} finally {
  await browser.close();
  await new Promise((resolve) => server.close(resolve));
}
