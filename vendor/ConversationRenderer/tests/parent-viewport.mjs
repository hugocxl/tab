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
const directory = resolve(root, process.env.CONVERSATION_BUNDLE ?? ".work/parent");
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
            window.TabConversation?.resolve({
              requestId: message.requestId,
              ok: message.action.kind !== "openAttachment",
              result,
              error: "Attachment access was denied.",
            }),
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
    failures.push({ name, error: String(error) });
  }
}
try {
  await page.goto(origin, { waitUntil: "networkidle" });
  snapshot.viewport = {
    mode: "full-pane",
    width: 900,
    height: 1100,
    composer: { x: 0, y: 920, width: 900, height: 180 },
  };
  await page.evaluate((snapshot) => window.TabConversation.update(snapshot), snapshot);
  await page.getByRole("heading", { name: "Final result" }).waitFor();
  await page.waitForTimeout(500);
  await check("versioned native viewport ready negotiation", async () =>
    assert.ok(
      await page.evaluate(() =>
        window.__bridge.some(
          (message) =>
            message.type === "ready" &&
            message.features.nativeViewport === true &&
            message.features.nativeViewportVersion === 1,
        ),
      ),
    ),
  );
  await check(
    "real composer footprint remains transparent below clipped source canvas",
    async () => {
      const backing = await page.evaluate(() => ({
        colors: [
          document.documentElement,
          document.body,
          document.getElementById("root"),
          document.querySelector("[data-tab-conversation]"),
        ].map((node) => getComputedStyle(node).backgroundColor),
        clip: getComputedStyle(document.querySelector("[data-native-canvas-clip]")).clipPath,
        hit: document.elementFromPoint(450, 1000)?.closest("[data-chat-canvas]") !== null,
      }));
      assert.ok(backing.colors.every((color) => color === "rgba(0, 0, 0, 0)"));
      assert.equal(backing.clip, "inset(0px 0px 180px)");
      assert.equal(backing.hit, false);
    },
  );
  await check(
    "source menu portal reports actual hit-test geometry outside canvas clip",
    async () => {
      await page.getByRole("button", { name: "Copy table" }).click();
      await page.getByRole("menuitem", { name: /Markdown/i }).waitFor();
      await page.waitForFunction(
        () =>
          window.__bridge.filter((message) => message.type === "overlays").at(-1)?.rects.length > 0,
      );
      await page.keyboard.press("Escape");
      await page.waitForFunction(
        () =>
          window.__bridge.filter((message) => message.type === "overlays").at(-1)?.rects.length ===
          0,
      );
    },
  );
  await check("native action failure uses actual visible source error toast", async () => {
    await page
      .getByRole("button", { name: /note.txt/ })
      .first()
      .click();
    await page.getByText("Unable to open attachment", { exact: true }).waitFor();
    await page.getByText("Attachment access was denied.", { exact: true }).waitFor();
  });
  await check("source viewport reports semantic reading anchor", async () => {
    await page.locator("[data-assistant-citation-viewport]").evaluate((node) => {
      node.scrollTop = 0;
      node.dispatchEvent(new Event("scroll"));
    });
    await page.waitForFunction(() =>
      window.__bridge.some(
        (message) =>
          message.type === "anchor" &&
          (message.messageId || message.itemId || message.runId) &&
          Number.isFinite(message.offset),
      ),
    );
  });
  const diagnostics = await page.evaluate(() =>
    window.__bridge.filter((message) => message.type === "error"),
  );
  const report = { checks, failures, errors, network, diagnostics, consoleMessages };
  console.log(JSON.stringify(report, null, 2));
  if (failures.length || errors.length || network.length || diagnostics.length)
    process.exitCode = 1;
} finally {
  await browser.close();
  await new Promise((resolve) => server.close(resolve));
}
