import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { resolve, posix } from "node:path";
import { createHash } from "node:crypto";

/** Keep the actual used body export without unused application-preview workers. */
export function extractSourcePreview(root, checkout, revision) {
  const path = "apps/web/src/components/files/AttachmentFilePreview.tsx";
  const original = execFileSync("git", ["-C", checkout, "show", `${revision}:${path}`], {
    encoding: "utf8",
  });
  const body = original.match(/^export function ReadOnlySourcePreview\([\s\S]*?^}\n/m)?.[0];
  if (!body) throw new Error("Pinned read-only source preview extraction boundary changed.");
  const generated = `// Unchanged body export from ${path} at ${revision}. upstream MIT license.\nimport {lazy,Suspense} from 'react';\nimport {FileSurfaceLoading} from '@conversation-source/components/files/fileSurfaceChrome';\nconst SourcePreview=lazy(()=>import('@conversation-source/components/files/ReadOnlySourcePreview'));\n${body}`;
  const generatedPath = ".work/readOnlySourcePreview.tsx";
  writeFileSync(resolve(root, generatedPath), generated);
  const readOnly = {
    path,
    revision,
    sha256: createHash("sha256").update(original).digest("hex"),
    functions: ["ReadOnlySourcePreview"],
    generatedPath,
    generatedSHA256: createHash("sha256").update(generated).digest("hex"),
  };
  const htmlPath = "apps/web/src/components/files/BrowserDocumentFrame.tsx";
  const htmlOriginal = execFileSync("git", ["-C", checkout, "show", `${revision}:${htmlPath}`], {
    encoding: "utf8",
  });
  const prefix = htmlOriginal.slice(0, htmlOriginal.indexOf("export const isPdfPreviewFile"));
  const htmlBody = htmlOriginal.slice(htmlOriginal.indexOf("export function HtmlRenderDocument("));
  if (
    !prefix.includes("const HTML_RENDER_SHORTCUT_COMMANDS") ||
    !htmlBody.startsWith("export function HtmlRenderDocument(")
  )
    throw new Error("Pinned HTML document extraction boundary changed.");
  const imports = prefix.replace(
    /from "(\.{1,2}\/[^"]+)"/g,
    (_match, target) =>
      `from "@conversation-source/${posix.normalize(posix.join("components/files", target))}"`,
  );
  const htmlGenerated = `// Unchanged body export/helpers from ${htmlPath} at ${revision}. upstream MIT license.\n${imports}\n${htmlBody}`;
  const htmlGeneratedPath = ".work/htmlRenderDocument.tsx";
  writeFileSync(resolve(root, htmlGeneratedPath), htmlGenerated);
  return [
    readOnly,
    {
      path: htmlPath,
      revision,
      sha256: createHash("sha256").update(htmlOriginal).digest("hex"),
      functions: ["HtmlRenderDocument", "HTML_RENDER_SHORTCUT_COMMANDS"],
      generatedPath: htmlGeneratedPath,
      generatedSHA256: createHash("sha256").update(htmlGenerated).digest("hex"),
    },
  ];
}
