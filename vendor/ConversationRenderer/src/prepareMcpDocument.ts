import { htmlRenderFromToolItem } from "@conversation/shared/toolOutput";
import {
  injectMcpAppCsp,
  readMcpAppReference,
  injectMcpAppThemeBootstrap,
  injectMcpAppCookieBootstrap,
  type McpAppReference,
} from "@conversation/shared/mcpApp";

/**
 * Native supplies retained owned bytes and validated reference metadata. Keep
 * source capture/serve transformations unchanged; the native response's opaque
 * sandbox remains independent of these document-level restrictions.
 */
export function prepareMcpDocument(html: string, app: McpAppReference): string {
  const reference = readMcpAppReference(app);
  if (!reference) throw new Error("The retained MCP app reference is invalid.");
  return injectMcpAppCookieBootstrap(
    injectMcpAppThemeBootstrap(injectMcpAppCsp(html, reference.csp)),
  );
}

/** Resolve only actual published HTML references; native validates retained ownership. */
export function htmlRenderReference(toolName: string, output: unknown) {
  return htmlRenderFromToolItem({ toolName, output }) ?? null;
}
