import { createRoot } from "react-dom/client";
import type { ReactNode } from "react";
import { RenderErrorBoundary } from "@conversation-source/components/RenderErrorBoundary";
import { post } from "./bridge";

/** Keep the source's widget fallbacks while reporting every caught rendering failure. */
export function mountConversation(container: Element, node: ReactNode) {
  const root = createRoot(container, {
    onCaughtError(error, info) {
      post({
        type: info.errorBoundary instanceof RenderErrorBoundary ? "renderDiagnostic" : "error",
        scope: "component",
        message: error instanceof Error ? error.message : String(error),
        componentStack: info.componentStack,
      });
    },
    onUncaughtError(error, info) {
      post({
        type: "error",
        scope: "root",
        message: error instanceof Error ? error.message : String(error),
        componentStack: info.componentStack,
      });
    },
    onRecoverableError(error, info) {
      post({
        type: "renderDiagnostic",
        scope: "recoverable",
        message: error instanceof Error ? error.message : String(error),
        componentStack: info.componentStack,
      });
    },
  });
  root.render(node);
  return root;
}
