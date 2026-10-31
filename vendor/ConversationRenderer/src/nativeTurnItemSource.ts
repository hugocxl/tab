import { Atom, AsyncResult } from "effect/reactivity";
import { appendTerminalOutput, EMPTY_TERMINAL_OUTPUT } from "@conversation/shared/terminalOutput";
import type { TurnItemSource } from "@conversation-source/components/chat/timelineRowContext";
import { platformSnapshotAtom } from "./platform/snapshot";
import { projectNativeSnapshot } from "./projectNativeSnapshot";

// One derived projection per immutable native snapshot, shared by every open
// inspector. Closed tools subscribe to no output atoms, matching the source UI.
const projection = Atom.make((get) => {
  const snapshot = get(platformSnapshotAtom);
  return snapshot
    ? { sessionId: snapshot.sessionId, value: projectNativeSnapshot(snapshot) }
    : null;
});
const detail = Atom.family((key: string) =>
  Atom.make((get) => {
    const { threadId, itemId } = JSON.parse(key);
    const current = get(projection);
    const item =
      current?.sessionId === threadId ? (current.value.toolItems.get(itemId) ?? null) : null;
    return AsyncResult.success({ item });
  }),
);
const command = Atom.family((key: string) =>
  Atom.make((get) => {
    const { threadId, itemId } = JSON.parse(key);
    const current = get(projection);
    const item = current?.sessionId === threadId ? current.value.toolItems.get(itemId) : undefined;
    const text =
      item?.type === "command_execution" && typeof item.output === "string" ? item.output : "";
    return AsyncResult.success({
      output: appendTerminalOutput(EMPTY_TERMINAL_OUTPUT, text),
      running:
        item?.status === "running" || item?.status === "waiting" || item?.status === "pending",
    });
  }),
);
export const nativeTurnItemSource: TurnItemSource = {
  detail: (input) => detail(JSON.stringify(input)),
  commandOutput: (input) => command(JSON.stringify(input)),
};
