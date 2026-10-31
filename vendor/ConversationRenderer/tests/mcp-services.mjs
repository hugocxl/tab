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
const directory = resolve(root, process.env.CONVERSATION_BUNDLE ?? ".work/mcp-services");
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
  const requests = [];
  page.on("request", (request) => requests.push(request.url()));
  const { injectMcpAppCsp, injectMcpAppThemeBootstrap, injectMcpAppCookieBootstrap } = await import(
    pathToFileURL(resolve(checkout, "packages/shared/src/mcpApp.ts")).href
  );
  const html = `<!doctype html><html><body><p>Supplied MCP app resource</p><pre id="responses"></pre><script>
 let isolated=false;try{void parent.TabConversation;}catch{isolated=true;}document.body.dataset.isolated=String(isolated);
 const replies=[];addEventListener('message',event=>{const message=event.data;if(message.id===1&&message.result){parent.postMessage({jsonrpc:'2.0',method:'ui/notifications/initialized'},'*');for(const [id,method,params]of [[2,'resources/read',{uri:'ui://other'}],[3,'tools/call',{name:'other',arguments:{}}],[4,'ui/update-model-context',{structuredContent:{value:1}}]])parent.postMessage({jsonrpc:'2.0',id,method,params},'*');}else if([2,3,4].includes(message.id)){replies.push(message);document.getElementById('responses').textContent=JSON.stringify(replies);}});
 parent.postMessage({jsonrpc:'2.0',id:1,method:'ui/initialize',params:{protocolVersion:'2026-01-26',appCapabilities:{}}},'*');
 </script></body></html>`;
  await page.route(origin + "/__mcp_fixture", (route) =>
    route.fulfill({
      body: injectMcpAppCookieBootstrap(
        injectMcpAppThemeBootstrap(injectMcpAppCsp(html, undefined)),
      ),
      contentType: "text/html",
      headers: {
        "Content-Security-Policy": "sandbox allow-scripts allow-forms allow-popups allow-downloads",
      },
    }),
  );
  await page.addInitScript((resourceURL) => {
    window.__bridge = [];
    window.webkit = {
      messageHandlers: {
        tabConversation: {
          postMessage(message) {
            window.__bridge.push(message);
            if (message.type !== "action") return;
            const kind = message.action.kind;
            const result =
              kind === "createAssetUrl"
                ? { relativeUrl: resourceURL, expiresAt: Date.now() + 3600000 }
                : kind === "loadTurnItem"
                  ? {
                      item: {
                        id: "mcp-item",
                        type: "dynamic_tool",
                        input: {},
                        output: { result: {} },
                      },
                    }
                  : undefined;
            queueMicrotask(() =>
              window.TabConversation.resolve({
                requestId: message.requestId,
                ok: result !== undefined,
                result,
                error: "Unexpected native operation " + kind,
              }),
            );
          },
        },
      },
    };
  }, origin + "/__mcp_fixture");
  await page.goto(origin, { waitUntil: "networkidle" });
  await page.evaluate((value) => window.TabConversation.update(value), {
    ...snapshot,
    sessionId: "mcp-fixture",
    capabilities: { nativeActions: true },
    connectionState: "live",
  });
  const frame = page.frameLocator('iframe[title="Fixture app"]');
  await frame.getByText("Supplied MCP app resource", { exact: true }).waitFor();
  await frame.locator("#responses").filter({ hasText: "readResource" }).waitFor();
  await page.waitForFunction(() => {
    const element = document.querySelector("iframe");
    return element?.getAttribute("sandbox") === "allow-scripts allow-forms";
  });
  const result = await frame.locator("body").evaluate((node) => ({
    isolated: node.dataset.isolated,
    replies: JSON.parse(node.querySelector("#responses").textContent),
  }));
  assert.equal(result.isolated, "true");
  assert.equal(result.replies.length, 3);
  for (const reply of result.replies) {
    assert.equal(reply.error.code, -32000);
    assert.match(reply.error.message, /native provider does not expose MCP app/);
  }
  await page.waitForTimeout(800);
  const bridge = await page.evaluate(() => window.__bridge);
  assert.ok(
    !bridge.some(
      (message) => message.type === "action" && message.action.kind.startsWith("mcpApps."),
    ),
    "Unavailable operations must fail locally without opening any backend",
  );
  assert.deepEqual(errors, []);
  assert.deepEqual(network, []);
  assert.ok(!bridge.some((message) => message.type === "error"));
  assert.deepEqual(
    requests.filter((url) => {
      const path = new URL(url).pathname;
      return path !== "/" && path !== "/__mcp_fixture" && !path.startsWith("/assets/");
    }),
    [],
    "No upstream discovery/auth/RPC endpoint may be requested",
  );
  const report = { result, errors, network, requests, bridge };
  const output = resolve(root, ".work/qa/mcp-services");
  mkdirSync(output, { recursive: true });
  writeFileSync(resolve(output, "report.json"), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
} finally {
  await browser.close();
  await new Promise((resolve) => server.close(resolve));
}
