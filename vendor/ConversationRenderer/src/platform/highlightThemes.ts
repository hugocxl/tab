// Compatibility fallback for snapshots without an application palette. Actual
// native themes register CSS-variable palettes before rendering any code.
export const themes = {
  "pierre-light": () => import("@tab-native/highlights/pierre-light"),
  "pierre-dark": () => import("@tab-native/highlights/pierre-dark"),
};
