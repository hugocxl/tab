import { readFileSync } from "node:fs";
const provenance = JSON.parse(readFileSync(new URL("./provenance.json", import.meta.url), "utf8"));
export { provenance };
/** Product namespace changes only; parser/layout implementations remain upstream. */
export function transformSource(original, path) {
  let code = original;
  for (const [before, after] of provenance.compatibilityTransforms)
    code = code.replaceAll(before, after);
  if (path.endsWith("/packages/shared/src/toolOutput.ts")) {
    const read = "readMcpAppReference(data[MCP_APP_OUTPUT_KEY])";
    if (!code.includes(read)) throw new Error("Pinned MCP compatibility read boundary changed.");
    code = code.replace(
      read,
      `readMcpAppReference(data[MCP_APP_OUTPUT_KEY] ?? data[${JSON.stringify(provenance.legacyMcpOutputKey)}])`,
    );
  }
  if (path.endsWith("/packages/shared/src/assistantCitations.ts")) {
    const legacyPrefix = provenance.legacyCitationProtocol + "//v1/";
    code = code.replace(
      "!href.startsWith(CITATION_HREF_PREFIX)",
      `(!href.startsWith(CITATION_HREF_PREFIX) && !href.startsWith(${JSON.stringify(legacyPrefix)}))`,
    );
    code = code.replace(
      "${CITATION_HREF_PREFIX}[^",
      "(?:${CITATION_HREF_PREFIX}|" + legacyPrefix + ")[^",
    );
    code = code.replace(
      "url.protocol !== CITATION_PROTOCOL ||",
      `(url.protocol !== CITATION_PROTOCOL && url.protocol !== ${JSON.stringify(provenance.legacyCitationProtocol)}) ||`,
    );
  }
  if (path.endsWith("/packages/shared/src/composerContextReferences.ts")) {
    const legacyPrefix = provenance.legacyContextProtocol + "//v1/";
    code = code.replace(
      "  if (!href.startsWith(COMPOSER_CONTEXT_HREF_PREFIX))",
      `  if (href.startsWith(${JSON.stringify(legacyPrefix)})) href = COMPOSER_CONTEXT_HREF_PREFIX + href.slice(${legacyPrefix.length});\n  if (!href.startsWith(COMPOSER_CONTEXT_HREF_PREFIX))`,
    );
    code = code.replace(
      "${COMPOSER_CONTEXT_HREF_PREFIX}[^",
      "(?:${COMPOSER_CONTEXT_HREF_PREFIX}|" + legacyPrefix + ")[^",
    );
    code = code.replace(
      'if (!text.includes("](tab-context:"))',
      `if (!text.includes("](tab-context:") && !text.includes(${JSON.stringify("](" + provenance.legacyContextProtocol)}))`,
    );
  }
  if (path.endsWith("/packages/shared/src/composerContextClipboard.ts"))
    code = code.replace(
      "/data-tab-context-fragment=",
      "/data-(?:tab|" + provenance.legacyClipboardAttribute.slice(5, 7) + ")-context-fragment=",
    );
  if (path.endsWith("/packages/shared/src/markdownPipeline.ts")) {
    code = code.replace(
      '"tab-citation",',
      `"tab-citation", ${JSON.stringify(provenance.legacyCitationProtocol.slice(0, -1))},`,
    );
    code = code.replaceAll(
      '"tab-context"',
      `"tab-context", ${JSON.stringify(provenance.legacyContextProtocol.slice(0, -1))}`,
    );
  }
  return code;
}
export function upstreamOracleImports(code) {
  return code.replaceAll("@conversation/", provenance.packageNamespace);
}
