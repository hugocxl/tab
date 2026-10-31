import { writeFileSync } from "node:fs";
import { resolve } from "node:path";

// Identical bytes are served by the upstream browser command and bundled-port
// Playwright route. Real source favicon rendering stays enabled in both.
export const faviconPng =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j3ioAAAAASUVORK5CYII=";
export const faviconPattern = "https://www.google.com/s2/favicons?**";
export function writeSourceContentConfig(checkout) {
  writeFileSync(
    resolve(checkout, "apps/web/TabSourceParity.vite.config.ts"),
    `import original from './vite.config';\nimport {defineConfig} from 'vite-plus';\nexport default defineConfig(async env=>{const config=await (original as any)(env);for(const project of config.test.projects){if(project.test?.browser?.enabled){project.test.browser.commands={...project.test.browser.commands,interceptReferencedContent:async({page}:any)=>{await page.route('${faviconPattern}',(route:any)=>route.fulfill({status:200,contentType:'image/png',body:Buffer.from('${faviconPng}','base64')}));}};}}return config;});\n`,
  );
}
export async function interceptReferencedContent(page) {
  await page.route(faviconPattern, (route) =>
    route.fulfill({
      status: 200,
      contentType: "image/png",
      body: Buffer.from(faviconPng, "base64"),
    }),
  );
}
