import { useEffect, useState } from "react";
import { Atom } from "effect/reactivity";
import * as Effect from "effect/Effect";
import { useEnvironmentQuery } from "@conversation-source/state/query";
import { nativeAction } from "../bridge";
export function useDebouncedValue<A>(value: A, delayMs: number): A {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const timer = window.setTimeout(() => setDebounced(value), delayMs);
    return () => window.clearTimeout(timer);
  }, [delayMs, value]);
  return debounced;
}
const turnItem = Atom.family((key: string) =>
  Atom.make(
    Effect.tryPromise({
      try: () => nativeAction({ kind: "loadTurnItem", ...JSON.parse(key) }),
      catch: (error) => error,
    }),
  ),
);
export function useTurnItemDetail(
  target: { environmentId: string; threadId: string; itemId: string; revision: string } | null,
  source?: (input: { threadId: string; itemId: string; revision: string }) => any,
) {
  const input = target
    ? { threadId: target.threadId, itemId: target.itemId, revision: target.revision }
    : null;
  return useEnvironmentQuery(
    target && input ? ((source ? source(input) : turnItem(JSON.stringify(target))) as any) : null,
  );
}
