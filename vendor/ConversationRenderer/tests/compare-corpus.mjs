import { interceptReferencedContent } from "./source-content-routes.mjs";
import { createServer } from "node:http";
import { readFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { resolve, dirname, extname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const { checkout } = JSON.parse(readFileSync(resolve(root, ".work/source.json"), "utf8"));
const corpus = JSON.parse(readFileSync(resolve(root, "tests/corpus.json"), "utf8"));
const { chromium } = await import(
  pathToFileURL(resolve(checkout, "apps/web/node_modules/playwright/index.mjs")).href
);
const directory = resolve(root, process.env.CONVERSATION_BUNDLE ?? ".work/parity");
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
const browser = await chromium.launch({ headless: true });
const output = resolve(root, ".work/qa/corpus");
mkdirSync(output, { recursive: true });
const failures = [];
const allowedReferencedRequests = [];
const unexpectedRemoteRequests = [];
let generatedIdentifierNormalizations = 0;
try {
  for (const width of [360, 800])
    for (const dark of [false, true]) {
      const context = await browser.newContext({ viewport: { width, height: 1100 } });
      const page = await context.newPage();
      await interceptReferencedContent(page);
      page.on("request", (request) => {
        const url = request.url();
        if (url.startsWith("https://www.google.com/s2/favicons?"))
          allowedReferencedRequests.push(url);
        else if (
          /^https?:/.test(url) &&
          !url.startsWith(`http://127.0.0.1:${server.address().port}/`)
        )
          unexpectedRemoteRequests.push(url);
      });
      const errors = [];
      page.on("pageerror", (error) => errors.push(error.message));
      await page.addInitScript(() => {
        window.__bridge = [];
        window.webkit = {
          messageHandlers: {
            tabConversation: {
              postMessage(message) {
                window.__bridge.push(message);
                if (message.type === "action")
                  queueMicrotask(() =>
                    window.TabConversation?.resolve({
                      requestId: message.requestId,
                      ok: false,
                      error: "Native action intentionally unavailable in static parity fixture",
                    }),
                  );
              },
            },
          },
        };
      });
      await page.goto(`http://127.0.0.1:${server.address().port}/`, { waitUntil: "networkidle" });
      await page.waitForFunction(() => window.TabConversation);
      const results = [];
      for (const [index, fixture] of corpus.entries()) {
        await page.evaluate(
          ({ fixture, dark, index }) =>
            window.TabConversation.update({
              bridgeVersion: 1,
              sessionId: "parity",
              revision: index,
              theme: dark ? "dark" : "light",
              items: [],
              turns: [],
              status: "idle",
              messages: [{ id: fixture.name, ...fixture }],
              font: { interfaceSize: 16, promptSize: 14, codeSize: 13 },
              settings: { mathRenderingEnabled: true },
              capabilities: {},
            }),
          { fixture, dark, index },
        );
        await page.waitForSelector(".chat-markdown");
        if (fixture.name === "math-diagram-syntax") {
          await page.waitForSelector(".katex");
          await page.waitForSelector("[data-markdown-mermaid] svg");
        }
        await page.evaluate(() => document.fonts.ready);
        await page.waitForFunction(() =>
          Array.from(document.images).every((image) => image.complete && image.naturalWidth > 0),
        );
        await page.waitForTimeout(150);
        const result = await page.evaluate((name) => {
          const root = document.querySelector(".chat-markdown");
          const origin = root.getBoundingClientRect();
          return {
            name,
            text: root.textContent,
            nodes: Array.from(
              root.querySelectorAll(
                "p,h1,h2,h3,ul,ol,li,blockquote,table,th,td,details,summary,pre,code,a[id],.katex,[data-markdown-mermaid]",
              ),
            ).map((node) => {
              const rect = node.getBoundingClientRect();
              return {
                tag: node.tagName,
                id: node.id || undefined,
                text: node.textContent,
                x: rect.x - origin.x,
                y: rect.y - origin.y,
                width: rect.width,
                height: rect.height,
              };
            }),
          };
        }, fixture.name);
        results.push(result);
        await page.screenshot({
          path: resolve(output, `${fixture.name}-${width}-${dark}.png`),
          fullPage: true,
        });
      }
      const expected = JSON.parse(
        readFileSync(
          resolve(
            checkout,
            `apps/web/src/components/chat/__snapshots__/tab-source-corpus-${width}-${dark}.json`,
          ),
          "utf8",
        ),
      );
      const differences = [];
      for (let i = 0; i < expected.length; i++) {
        if (expected[i].text !== results[i].text)
          differences.push({
            name: expected[i].name,
            kind: "text",
            expected: expected[i].text,
            actual: results[i].text,
          });
        if (expected[i].nodes.length !== results[i].nodes.length)
          differences.push({
            name: expected[i].name,
            kind: "node-count",
            expected: expected[i].nodes.length,
            actual: results[i].nodes.length,
          });
        for (let j = 0; j < Math.min(expected[i].nodes.length, results[i].nodes.length); j++)
          for (const key of ["tag", "id", "text", "x", "y", "width", "height"]) {
            const wanted = expected[i].nodes[j][key],
              actual = results[i].nodes[j][key];
            if (
              key === "id" &&
              typeof wanted === "string" &&
              typeof actual === "string" &&
              wanted.startsWith("base-ui-_r_") &&
              actual.startsWith("base-ui-_r_")
            ) {
              generatedIdentifierNormalizations++;
              continue;
            }
            if (
              typeof wanted === "number" && typeof actual === "number"
                ? Math.abs(wanted - actual) > 0.03125
                : wanted !== actual
            )
              differences.push({ name: expected[i].name, node: j, key, expected: wanted, actual });
          }
      }
      if (differences.length || errors.length) failures.push({ width, dark, differences, errors });
      writeFileSync(
        resolve(output, `bundle-${width}-${dark}.json`),
        JSON.stringify(results, null, 2),
      );
      await context.close();
    }
  writeFileSync(
    resolve(output, "comparison.json"),
    JSON.stringify(
      {
        generatedIdentifierNormalizations,
        allowedReferencedRequests,
        unexpectedRemoteRequests,
        failures,
      },
      null,
      2,
    ),
  );
  console.log(
    JSON.stringify(
      {
        states: 4,
        fixtures: corpus.length,
        generatedIdentifierNormalizations,
        allowedReferencedRequests,
        unexpectedRemoteRequests,
        failures,
      },
      null,
      2,
    ),
  );
  if (failures.length || unexpectedRemoteRequests.length || allowedReferencedRequests.length === 0)
    process.exitCode = 1;
} finally {
  await browser.close();
  await new Promise((resolve) => server.close(resolve));
}
