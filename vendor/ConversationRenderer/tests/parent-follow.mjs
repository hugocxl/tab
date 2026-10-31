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
  await page.emulateMedia({ reducedMotion: "reduce" });
  const items = [],
    turns = [];
  for (let index = 0; index < 25; index++) {
    const id = `history-user-${index}`;
    items.push(
      { id, kind: "user", text: `History question ${index}`, isComplete: true },
      {
        id: `history-assistant-${index}`,
        kind: "assistant",
        text: `History answer ${index}.\n\n` + "Existing readable prose. ".repeat(25),
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
  items.push(
    { id: "active-user", kind: "user", text: "Current streaming question", isComplete: true },
    {
      id: "active-assistant",
      kind: "assistant",
      text:
        Array.from(
          { length: 40 },
          (_, index) => `Streaming paragraph ${index}. Existing answer text.`,
        ).join("\n\n") + "\n\n```swift\nprint(42)\n```",
      isComplete: false,
    },
  );
  turns.push({ userItemID: "active-user", startedAt: "2026-10-31T10:00:05Z", status: "working" });
  const value = {
    ...snapshot,
    items,
    turns,
    messages: items.map((item) => ({ id: item.id, role: item.kind, text: item.text })),
    status: "working",
    capabilities: { nativeActions: true },
    connectionState: "live",
  };
  await page.goto(origin, { waitUntil: "networkidle" });
  await page.evaluate((value) => {
    window.__followSnapshot = value;
    window.TabConversation.update(value);
  }, value);
  const viewport = page.locator(".messages-timeline-scroll");
  await viewport.waitFor();
  await page.evaluate(() => window.TabConversation.scrollToEnd());
  const geometry = () => {
    const viewport = document.querySelector(".messages-timeline-scroll");
    const bounds = viewport.getBoundingClientRect();
    const row = [...viewport.querySelectorAll("[data-timeline-row-id]")].find(
      (node) =>
        node.getBoundingClientRect().bottom > bounds.top + 5 &&
        node.getBoundingClientRect().top < bounds.bottom,
    );
    return {
      scrollTop: viewport.scrollTop,
      scrollHeight: viewport.scrollHeight,
      height: viewport.clientHeight,
      row: row?.dataset.timelineRowId,
      offset: row ? row.getBoundingClientRect().top - bounds.top : null,
    };
  };
  await page.waitForFunction(() => {
    const node = document.querySelector(".messages-timeline-scroll");
    return node && node.scrollHeight - node.clientHeight - node.scrollTop < 3;
  });
  const initialEnd = await page.evaluate(geometry);
  assert.ok(initialEnd.scrollHeight > initialEnd.height + 2000);
  await viewport.hover();
  await page.mouse.wheel(0, -700);
  await page.waitForTimeout(500);
  await page.getByRole("button", { name: "Scroll to end", exact: true }).waitFor();
  const away = await page.evaluate(geometry);
  assert.ok(away.scrollTop < initialEnd.scrollTop - 300);
  await page.evaluate(() => {
    const current = window.__followSnapshot;
    const next = {
      ...current,
      revision: 2,
      items: current.items.map((item) =>
        item.id === "active-assistant"
          ? { ...item, text: item.text + "\n\nNew streaming content. ".repeat(20) }
          : item,
      ),
    };
    window.__followSnapshot = next;
    window.TabConversation.update(next);
  });
  await page.waitForTimeout(500);
  const afterAppend = await page.evaluate(geometry);
  assert.ok(Math.abs(away.scrollTop - afterAppend.scrollTop) <= 2);
  assert.equal(afterAppend.row, away.row);
  assert.ok(Math.abs(away.offset - afterAppend.offset) <= 2);
  await page.evaluate(() => window.TabConversation.scrollToEnd());
  await page.waitForTimeout(100);
  await page.evaluate(() => {
    const current = window.__followSnapshot;
    const next = {
      ...current,
      revision: 3,
      items: [
        ...current.items.map((item) =>
          item.id === "active-assistant" ? { ...item, isComplete: true } : item,
        ),
        { id: "new-user", kind: "user", text: "Accepted new user turn", isComplete: true },
        {
          id: "new-assistant",
          kind: "assistant",
          text: "New turn response begins.",
          isComplete: false,
        },
      ],
      turns: [
        ...current.turns.map((turn) =>
          turn.userItemID === "active-user"
            ? { ...turn, completedAt: "2026-10-31T10:00:09Z", status: "idle" }
            : turn,
        ),
        { userItemID: "new-user", startedAt: "2026-10-31T10:00:10Z", status: "working" },
      ],
    };
    window.__followSnapshot = next;
    window.TabConversation.update(next);
  });
  await page.evaluate(() => window.TabConversation.scrollToEnd());
  await page.getByText("Accepted new user turn", { exact: true }).waitFor();
  await page.waitForFunction(() => {
    const node = document.querySelector(".messages-timeline-scroll");
    return node.scrollHeight - node.clientHeight - node.scrollTop < 3;
  });
  const followed = await page.evaluate(geometry);
  // Keyboard activation uses actual focusable in-message controls.
  const copy = page.getByRole("button", { name: "Copy code", exact: true }).first();
  await copy.focus();
  await page.keyboard.press("Enter");
  await page.waitForFunction(() =>
    window.__copies.some((value) => value.text?.includes("print(42)")),
  );
  await viewport.hover();
  await page.mouse.wheel(0, -500);
  await page.waitForTimeout(350);
  const latest = page.getByRole("button", { name: "Scroll to end", exact: true });
  await latest.waitFor();
  await latest.focus();
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => {
    const node = document.querySelector(".messages-timeline-scroll");
    return node.scrollHeight - node.clientHeight - node.scrollTop < 3;
  });
  assert.ok(await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches));
  const keyboard = { copiedCode: true, latestReachedEnd: true, reducedMotion: true };
  const diagnostics = await page.evaluate(() =>
    window.__bridge.filter((message) => message.type === "error"),
  );
  assert.deepEqual(errors, []);
  assert.deepEqual(network, []);
  assert.deepEqual(diagnostics, []);
  const report = {
    checks: [
      "wheel releases follow",
      "stream append preserves source reader position",
      "accepted user turn plus native scrollToEnd follows latest",
      "source code-copy control activates by keyboard Enter",
      "reduced-motion source latest button reaches end",
    ],
    initialEnd,
    away,
    afterAppend,
    followed,
    keyboard,
    errors,
    network,
    diagnostics,
  };
  const output = resolve(root, ".work/qa/parent-follow");
  mkdirSync(output, { recursive: true });
  writeFileSync(resolve(output, "report.json"), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
} finally {
  await browser.close();
  await new Promise((resolve) => server.close(resolve));
}
