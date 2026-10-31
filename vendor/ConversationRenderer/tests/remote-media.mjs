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
const remoteRequests = [];
const png = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j3ioAAAAASUVORK5CYII=",
  "base64",
);
const fixtureSource = readFileSync(
  resolve(root, "../../Tests/TabAppTests/AgentConversationMediaFixtures.swift"),
  "utf8",
);
const mp4 = Buffer.from(
  fixtureSource.match(/static let mp4 = Data\(base64Encoded: "([^"]+)"/)[1],
  "base64",
);
const remote = createServer((request, response) => {
  const path = new URL(request.url, "http://localhost").pathname;
  remoteRequests.push({ path, origin: request.headers.origin, range: request.headers.range });
  const bytes = path.endsWith(".mp4") ? mp4 : png;
  response.setHeader("Content-Type", path.endsWith(".mp4") ? "video/mp4" : "image/png");
  if (path !== "/no-cors.png") response.setHeader("Access-Control-Allow-Origin", "*");
  response.setHeader("Accept-Ranges", "bytes");
  const range = /bytes=(\d+)-(\d*)/.exec(request.headers.range ?? "");
  if (range) {
    const start = Number(range[1]),
      end = range[2] ? Math.min(bytes.length - 1, Number(range[2])) : bytes.length - 1;
    response.statusCode = 206;
    response.setHeader("Content-Range", `bytes ${start}-${end}/${bytes.length}`);
    response.setHeader("Content-Length", end - start + 1);
    response.end(bytes.subarray(start, end + 1));
  } else {
    response.setHeader("Content-Length", bytes.length);
    response.end(bytes);
  }
});
await new Promise((resolve) => remote.listen(0, "127.0.0.1", resolve));
const remoteOrigin = `http://127.0.0.1:${remote.address().port}`;
try {
  await page.route("https://www.google.com/s2/favicons?**", (route) =>
    route.fulfill({ body: png, contentType: "image/png" }),
  );
  await page.addInitScript(() => {
    window.__bridge = [];
    window.__copies = [];
    window.webkit = {
      messageHandlers: {
        tabConversation: {
          postMessage(message) {
            window.__bridge.push(message);
            if (message.type !== "action") return;
            if (message.action.kind === "copy") window.__copies.push(message.action);
            queueMicrotask(() =>
              window.TabConversation.resolve({
                requestId: message.requestId,
                ok: true,
                result: message.action.phase === "begin" ? "image-transfer" : true,
              }),
            );
          },
        },
      },
    };
  });
  await page.goto(origin, { waitUntil: "networkidle" });
  const content = `[Remote example](https://example.com/reference)\n\n<img src="${remoteOrigin}/allowed.png" alt="Allowed remote" width="64" height="64">\n\n<img src="${remoteOrigin}/no-cors.png" alt="CORS refused" width="64" height="64">\n\n![Remote video](${remoteOrigin}/clip.mp4)`;
  await page.evaluate((value) => window.TabConversation.update(value), {
    ...snapshot,
    items: [{ id: "remote", kind: "assistant", text: content, isComplete: true }],
    turns: [],
    messages: [{ id: "remote", role: "assistant", text: content }],
    capabilities: { nativeActions: true },
  });
  const allowed = page.getByAltText("Allowed remote", { exact: true });
  await allowed.waitFor();
  await page.waitForFunction(
    () =>
      [...document.images]
        .filter(
          (image) =>
            image.alt === "Allowed remote" ||
            image.alt === "CORS refused" ||
            image.src.includes("google.com/s2/favicons"),
        )
        .every((image) => image.complete && image.naturalWidth > 0) &&
      [...document.images].some((image) => image.src.includes("google.com/s2/favicons")),
  );
  const video = page.locator("video");
  await video.waitFor();
  await video.evaluate((node) => node.load());
  await page.waitForFunction(() => {
    const video = document.querySelector("video");
    return video.readyState >= 1 && video.videoWidth === 32 && video.duration > 0;
  });
  await allowed.click({ button: "right" });
  const copy = page.getByRole("menuitem", { name: "Copy image", exact: true });
  await copy.waitFor();
  await copy.focus();
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => window.__copies.some((value) => value.phase === "commit"));
  const actions = await page.evaluate(() => window.__copies);
  const bytes = Buffer.concat(
    actions
      .filter((value) => value.phase === "chunk")
      .map((value) => Buffer.from(value.dataBase64, "base64")),
  );
  assert.deepEqual(bytes, png);
  await page.getByAltText("CORS refused", { exact: true }).click({ button: "right" });
  const refused = page.getByRole("menuitem", { name: "Copy image", exact: true });
  await refused.waitFor();
  await refused.focus();
  await page.keyboard.press("Enter");
  await page.getByText("Could not copy image", { exact: true }).waitFor();
  await page.getByText(/host may block browser access \(CORS\)/).waitFor();
  assert.equal(
    await page.evaluate(() => window.__copies.filter((value) => value.phase === "commit").length),
    1,
  );
  await video.click({ button: "right" });
  const save = page.getByRole("menuitem", { name: "Save video", exact: true });
  await save.waitFor();
  const downloadPromise = page.waitForEvent("download");
  await save.focus();
  await page.keyboard.press("Enter");
  const download = await downloadPromise;
  const downloaded = readFileSync(await download.path());
  assert.deepEqual(downloaded, mp4);
  const bridge = await page.evaluate(() => window.__bridge);
  assert.ok(!bridge.some((message) => message.type === "error"));
  assert.deepEqual(errors, []);
  const unexpected = network.filter(
    (url) =>
      !url.startsWith(remoteOrigin) && !url.startsWith("https://www.google.com/s2/favicons?"),
  );
  assert.deepEqual(unexpected, []);
  assert.ok(remoteRequests.some((value) => value.path === "/allowed.png" && value.origin));
  assert.ok(remoteRequests.some((value) => value.path === "/clip.mp4" && value.origin));
  const report = {
    checks: [
      "actual remote images and HTTPS favicon load",
      "source video metadata loads over HTTP",
      "source image copy preserves PNG bytes via CORS fetch",
      "CORS denial shows source error and makes no clipboard commit",
      "source video Save preserves fetched bytes",
    ],
    remoteRequests,
    network,
    errors,
    fatal: bridge.filter((message) => message.type === "error"),
  };
  const output = resolve(root, ".work/qa/remote-media");
  mkdirSync(output, { recursive: true });
  writeFileSync(resolve(output, "report.json"), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
} finally {
  await browser.close();
  await new Promise((resolve) => server.close(resolve));
  await new Promise((resolve) => remote.close(resolve));
}
