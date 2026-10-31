import { useSyncExternalStore } from "react";
import type { ConversationSnapshot } from "../bridge";
import { Atom } from "effect/reactivity";
import { appAtomRegistry } from "@conversation-source/rpc/atomRegistry";
export type PlatformSnapshot = ConversationSnapshot & {
  environmentId?: string;
  projectId?: string;
  title?: string;
  subagents?: unknown[];
  providers?: unknown[];
  keybindings?: unknown[];
  settings?: Record<string, unknown>;
  projects?: Array<Record<string, unknown>>;
  serverConfig?: Record<string, unknown>;
  remote?: boolean;
};
let snapshot: PlatformSnapshot | undefined;
const listeners = new Set<() => void>();
export const platformSnapshotAtom = Atom.make<PlatformSnapshot | undefined>(undefined).pipe(
  Atom.keepAlive,
);
export function setPlatformSnapshot(value: PlatformSnapshot) {
  snapshot = value;
  appAtomRegistry.set(platformSnapshotAtom, value);
  for (const listener of listeners) listener();
}
export function getPlatformSnapshot() {
  return snapshot;
}
export function subscribePlatform(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}
export function usePlatformSnapshot() {
  return useSyncExternalStore(subscribePlatform, getPlatformSnapshot, getPlatformSnapshot);
}
export function capability(name: string) {
  return snapshot?.capabilities?.[name] === true;
}
