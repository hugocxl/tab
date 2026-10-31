import { createCSSVariablesTheme, registerCustomTheme } from "@pierre/diffs";
import { TERMINAL_PALETTES } from "@tab-native/terminal-output-source";
import type { ConversationSnapshot, NativeConversationPalette } from "../bridge";

let registered = false;
let signature = "";
const applied = new Set<string>();

// The source parser/highlighter remains unchanged. Its two requested theme names
// resolve to CSS-variable token colors supplied by the existing native AppTheme.
function registerNativeSyntax() {
  if (registered) return;
  registered = true;
  for (const appearance of ["light", "dark"] as const) {
    const name = `pierre-${appearance}`;
    const theme = createCSSVariablesTheme({ name, fontStyle: false });
    theme.type = appearance;
    theme.zed.appearance = appearance;
    theme.zed.style.syntax.type = "token-type";
    theme.zed.style.syntax.attribute = "token-attribute";
    registerCustomTheme(name, async () => theme, "diffs");
  }
}

export function nativeSemanticVariables(p: NativeConversationPalette): Record<string, string> {
  return {
    "--background": p.background,
    "--foreground": p.foreground,
    "--card": p.card,
    "--card-foreground": p.foreground,
    "--popover": p.floating,
    "--popover-foreground": p.foreground,
    "--primary": p.accent,
    "--primary-foreground": p.accentForeground,
    "--secondary": p.surface,
    "--secondary-foreground": p.foreground,
    "--muted": p.surface,
    "--muted-foreground": p.mutedForeground,
    "--placeholder": p.dimForeground,
    "--secondary-label": p.mutedForeground,
    "--icon-muted": p.mutedForeground,
    "--accent": p.hover,
    "--accent-foreground": p.foreground,
    "--accent-surface": p.accentSoft,
    "--accent-surface-foreground": p.accent,
    "--message-surface": p.surface,
    "--message-foreground": p.foreground,
    "--message-action": p.accent,
    "--message-action-foreground": p.accentForeground,
    "--message-action-hover": p.accentSoft,
    "--error": p.danger,
    "--error-foreground": p.danger,
    "--error-surface": p.surface,
    "--destructive": p.danger,
    "--destructive-foreground": p.danger,
    "--destructive-surface": p.surface,
    "--info": p.accent,
    "--info-foreground": p.accent,
    "--success": p.diffAdd,
    "--success-foreground": p.diffAdd,
    "--warning": p.warning,
    "--warning-foreground": p.warning,
    "--warning-surface": p.surface,
    "--update": p.accent,
    "--update-foreground": p.accent,
    "--border": p.border,
    "--input": p.border,
    "--ring": p.accent,
    "--surface-raised": p.raised,
    "--code-background": p.card,
    "--code-foreground": p.syntax.foreground,
    "--terminal-background": p.background,
    "--terminal-foreground": p.syntax.foreground,
    "--terminal-cursor": p.accent,
    "--terminal-selection-background": p.selection,
    "--selection": p.selection,
    "--diff-addition": p.diffAdd,
    "--diff-addition-foreground": p.diffAdd,
    "--diff-deletion": p.diffRemove,
    "--diff-deletion-foreground": p.diffRemove,
    "--diffs-addition-color-override": p.diffAdd,
    "--diffs-deletion-color-override": p.diffRemove,
    "--diffs-modified-color-override": p.accent,
    "--diffs-bg-separator-override": p.diffHunk,
    "--diffs-bg-hover-override": p.hover,
    "--diffs-bg-selection-override": p.selection,
    "--diffs-fg-number-override": p.dimForeground,
    "--diffs-foreground": p.syntax.foreground,
    "--diffs-background": p.card,
    "--diffs-token-comment": p.syntax.comment,
    "--diffs-token-string-expression": p.syntax.string,
    "--diffs-token-string": p.syntax.string,
    "--diffs-token-constant": p.syntax.number,
    "--diffs-token-keyword": p.syntax.keyword,
    "--diffs-token-parameter": p.syntax.foreground,
    "--diffs-token-function": p.syntax.function,
    "--diffs-token-type": p.syntax.type,
    "--diffs-token-attribute": p.syntax.attribute,
    "--diffs-token-punctuation": p.syntax.punctuation,
    "--diffs-token-link": p.accent,
    "--diffs-token-inserted": p.diffAdd,
    "--diffs-token-deleted": p.diffRemove,
  };
}

export function applyNativeTheme(snapshot: ConversationSnapshot) {
  const next = JSON.stringify([snapshot.theme, snapshot.palette]);
  if (next === signature) return;
  signature = next;
  const root = document.documentElement;
  for (const key of applied) root.style.removeProperty(key);
  applied.clear();
  const palette = snapshot.palette;
  if (palette) registerNativeSyntax();
  const variables = palette ? nativeSemanticVariables(palette) : {};
  const ansi = palette?.ansi16 ?? TERMINAL_PALETTES[snapshot.theme];
  const names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"];
  ansi.forEach((color, index) => {
    variables[`--tab-ansi-${index}`] = color;
    variables[`--diffs-ansi-${index < 8 ? "" : "bright-"}${names[index % 8]}`] = color;
  });
  for (const [key, value] of Object.entries(variables)) {
    root.style.setProperty(key, value);
    applied.add(key);
  }
}
