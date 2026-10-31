import { getPlatformSnapshot, usePlatformSnapshot, subscribePlatform } from "./snapshot";
export function useRenderedAppearance() {
  return usePlatformSnapshot()?.theme ?? "light";
}
export function useTheme() {
  const resolvedTheme = useRenderedAppearance();
  return { theme: resolvedTheme, resolvedTheme };
}
export function getRenderedAppearance() {
  return getPlatformSnapshot()?.theme ?? "light";
}

export const subscribeRenderedAppearance = subscribePlatform;
