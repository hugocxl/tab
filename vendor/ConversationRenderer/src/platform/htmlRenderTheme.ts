import { useMemo } from "react";
import { HTML_RENDER_DEFAULT_FONTS } from "@conversation/shared/htmlRender";
import { usePlatformSnapshot } from "./snapshot";

// Actual source document/iframe theme messaging consumes the native semantic
// variables. Authored document styles continue to override those defaults.
export function useHtmlRenderTheme() {
  const snapshot = usePlatformSnapshot();
  return useMemo(() => {
    const style = getComputedStyle(document.documentElement);
    const names = [
      "background",
      "foreground",
      "muted",
      "muted-foreground",
      "card",
      "card-foreground",
      "popover",
      "popover-foreground",
      "secondary",
      "secondary-foreground",
      "border",
      "input",
      "ring",
      "primary",
      "primary-foreground",
      "accent",
      "accent-foreground",
      "accent-surface",
      "accent-surface-foreground",
      "destructive",
      "destructive-foreground",
      "destructive-surface",
      "warning",
      "warning-foreground",
      "warning-surface",
      "success",
      "success-foreground",
      "info",
      "info-foreground",
      "code-background",
      "code-foreground",
      "chart-1",
      "chart-2",
      "chart-3",
      "chart-4",
      "chart-5",
      "chart-6",
      "radius",
    ];
    const variables = Object.fromEntries(
      names.map((name) => [`--${name}`, style.getPropertyValue(`--${name}`).trim()]),
    );
    variables["--font-sans"] =
      style.getPropertyValue("--font-sans").trim() || HTML_RENDER_DEFAULT_FONTS.sans;
    variables["--font-mono"] =
      style.getPropertyValue("--font-mono").trim() || HTML_RENDER_DEFAULT_FONTS.mono;
    return { appearance: snapshot?.theme ?? "light", variables };
  }, [snapshot?.theme, snapshot?.palette]);
}
