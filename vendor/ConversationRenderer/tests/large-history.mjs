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
  const history = [];
  const turns = [];
  for (let index = 0; index < 500; index++) {
    const id = `user-${index}`;
    history.push(
      { id, kind: "user", text: `Question ${index}`, isComplete: true },
      {
        id: `assistant-${index}`,
        kind: "assistant",
        text: `Answer ${index}. Stable selectable content.`,
        isComplete: true,
      },
    );
    turns.push({
      userItemID: id,
      startedAt: "2026-10-31T10:00:00Z",
      completedAt: "2026-10-31T10:00:04Z",
      status: "idle",
    });
  }
  history.push(...snapshot.items);
  turns.push(...snapshot.turns);
  const large = {
    ...snapshot,
    items: history,
    turns,
    messages: history
      .filter((item) => item.kind === "user" || item.kind === "assistant")
      .map((item) => ({ id: item.id, role: item.kind, text: item.text })),
    revision: 100,
  };
  await page.goto(origin, { waitUntil: "networkidle" });
  await page.evaluate((value) => {
    window.__snapshot = value;
    window.TabConversation.update(value);
  }, large);
  await page.getByRole("heading", { name: "Final result" }).waitFor();
  await page.waitForTimeout(750);
  const initial = await page.evaluate(() => {
    const rows = [...document.querySelectorAll("[data-timeline-row-id]")];
    window.__retainedRows = new Map(rows.map((node) => [node.dataset.timelineRowId, node]));
    return { mountedRows: rows.length, totalItems: window.__snapshot.items.length };
  });
  assert.ok(initial.mountedRows < 100, "Source list must virtualize 1000+ items.");
  await page
    .getByRole("button", { name: /Worked for|Completed work/i })
    .first()
    .click();
  const aggregate = page.getByRole("button", { name: /Ran 1 command and used 1 tool/i });
  await aggregate.click();
  await page
    .getByRole("button", { name: /printf hello/i })
    .first()
    .click();
  await page.locator('[class~="max-h-80"]').getByText("hello", { exact: true }).waitFor();
  const selected = await page.evaluate(() => {
    const paragraph = [...document.querySelectorAll(".chat-markdown p")].find((node) =>
      node.textContent.startsWith("Selected quotation"),
    );
    const walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
    const text = walker.nextNode();
    const range = document.createRange();
    range.setStart(text, 0);
    range.setEnd(text, 8);
    const selection = getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    return selection.toString();
  });
  const updates = [];
  for (let index = 0; index < 20; index++)
    updates.push(
      await page.evaluate(async (index) => {
        const start = performance.now();
        const current = window.__snapshot;
        const next = {
          ...current,
          revision: 101 + index,
          items: current.items.map((item) =>
            item.id === "a1" ? { ...item, text: item.text + " token" } : item,
          ),
        };
        window.__snapshot = next;
        window.TabConversation.update(next);
        await new Promise(requestAnimationFrame);
        await new Promise(requestAnimationFrame);
        return performance.now() - start;
      }, index),
    );
  const retained = await page.evaluate(() => ({
    rows: [...window.__retainedRows]
      .filter(([id]) => document.querySelector(`[data-timeline-row-id="${id}"]`))
      .map(([id, node]) => ({
        id,
        same: document.querySelector(`[data-timeline-row-id="${id}"]`) === node,
      })),
    selection: getSelection().toString(),
    mountedRows: document.querySelectorAll("[data-timeline-row-id]").length,
    ansi: document.querySelector('[class~="max-h-80"]')?.textContent,
  }));
  assert.ok(retained.rows.length > 0);
  assert.ok(
    retained.rows.every((row) => row.same),
    "Existing mounted source rows must retain DOM identity.",
  );
  assert.equal(retained.selection, selected);
  assert.ok(
    retained.ansi?.includes("hello"),
    "Open source command inspector must survive updates.",
  );
  const diagnostics = await page.evaluate(() =>
    window.__bridge.filter((message) => message.type === "error"),
  );
  const report = {
    initial,
    retained,
    updates,
    meanMs: updates.reduce((sum, value) => sum + value, 0) / updates.length,
    p95Ms: [...updates].sort((a, b) => a - b)[18],
    errors,
    network,
    diagnostics,
  };
  const output = resolve(root, ".work/qa/large-history");
  mkdirSync(output, { recursive: true });
  writeFileSync(resolve(output, "report.json"), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
  assert.deepEqual(errors, []);
  assert.deepEqual(network, []);
  assert.deepEqual(diagnostics, []);
} finally {
  await browser.close();
  await new Promise((resolve) => server.close(resolve));
}
