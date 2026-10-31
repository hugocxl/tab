import { DEFAULT_CLIENT_SETTINGS } from "@conversation/contracts/settings";
import { getPlatformSnapshot, usePlatformSnapshot } from "./snapshot";
export function getClientSettings() {
  return { ...DEFAULT_CLIENT_SETTINGS, ...getPlatformSnapshot()?.settings };
}
export function useClientSettings<T>(
  selector: (settings: ReturnType<typeof getClientSettings>) => T,
): T {
  const snapshot = usePlatformSnapshot();
  return selector({ ...DEFAULT_CLIENT_SETTINGS, ...snapshot?.settings });
}
export function useSettings<T>(selector: (settings: ReturnType<typeof getClientSettings>) => T): T {
  return useClientSettings(selector);
}

// Native settings arrive in the same authoritative snapshot as the conversation.
export function isClientSettingsHydrated() {
  return getPlatformSnapshot() !== undefined;
}
export async function ensureClientSettingsHydrated() {
  if (!isClientSettingsHydrated())
    throw new Error("The native conversation snapshot has not arrived.");
}
