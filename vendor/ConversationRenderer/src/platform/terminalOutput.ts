export * from "@tab-native/terminal-output-source";
// CSS variables keep source spans current during same-appearance theme changes,
// including spans already cached by the source React/compiler renderer.
const ansi = Array.from({ length: 16 }, (_, index) => `var(--tab-ansi-${index})`);
export const TERMINAL_PALETTES = { light: ansi, dark: ansi };
