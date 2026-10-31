import type {
  OrchestrationV2SearchThreadInput,
  OrchestrationV2ProjectedTurnItem,
} from "@conversation/contracts";
import {
  searchableMessageSegments,
  searchablePlanSegments,
} from "@conversation/shared/threadFindText";
import { countThreadSearchOccurrences } from "@conversation/shared/threadSearch";
import * as Cause from "effect/Cause";
import { Atom, AsyncResult } from "effect/reactivity";
import { selectMatch, resultForSelection } from "../../.work/threadFindSelection";
import { platformSnapshotAtom } from "./snapshot";
import { projectNativeSnapshot } from "../projectNativeSnapshot";

type Target = { environmentId: string; input: OrchestrationV2SearchThreadInput };
type ParsedText = { signature: string; segments: readonly string[]; bytes: number };
const parsedText = new Map<string, ParsedText>();
const CACHE_BYTES = 8 * 1024 * 1024;
let cacheBytes = 0;
function evict(key: string) {
  const entry = parsedText.get(key);
  if (entry) {
    cacheBytes -= entry.bytes;
    parsedText.delete(key);
  }
}
function segmentsFor(
  row: OrchestrationV2ProjectedTurnItem,
  cwd: string | undefined,
  skills: OrchestrationV2SearchThreadInput["skills"],
) {
  const item = row.item;
  if (
    item.type !== "user_message" &&
    item.type !== "assistant_message" &&
    item.type !== "proposed_plan"
  )
    return [];
  const text = item.type === "proposed_plan" ? item.markdown : item.text;
  const role =
    item.type === "proposed_plan" ? "plan" : item.type === "user_message" ? "user" : "assistant";
  const streaming = item.type === "assistant_message" && item.streaming;
  const hasContext = item.type === "user_message" && item.context !== undefined;
  const key = JSON.stringify([row.sourceThreadId, row.sourceItemId]);
  const signature = JSON.stringify([text, role, streaming, hasContext, cwd, skills]);
  const cached = parsedText.get(key);
  if (cached?.signature === signature) {
    parsedText.delete(key);
    parsedText.set(key, cached);
    return cached.segments;
  }
  evict(key);
  const segments =
    role === "plan"
      ? searchablePlanSegments(text, cwd)
      : (searchableMessageSegments(
          { role, text, streaming, context: hasContext ? { version: 1, records: [] } : undefined },
          cwd,
          skills as any,
        ) ?? []);
  // This is a parse cache, never a content/search limit. Eviction recomputes.
  const bytes =
    key.length * 2 +
    signature.length * 2 +
    segments.reduce((sum, value) => sum + value.length * 2, 0);
  if (bytes <= CACHE_BYTES) {
    while (parsedText.size && (parsedText.size >= 2048 || cacheBytes + bytes > CACHE_BYTES))
      evict(parsedText.keys().next().value!);
    parsedText.set(key, { signature, segments, bytes });
    cacheBytes += bytes;
  }
  return segments;
}
const queries = Atom.family((key: string) =>
  Atom.make((get) => {
    const target: Target = JSON.parse(key),
      snapshot = get(platformSnapshotAtom);
    if (
      !snapshot ||
      target.environmentId !== (snapshot.environmentId ?? snapshot.projectId) ||
      target.input.threadId !== snapshot.sessionId
    )
      return AsyncResult.failure(
        Cause.fail(new Error("The retained conversation is unavailable.")),
      );
    const projection = projectNativeSnapshot(snapshot);
    const documents = projection.visibleTurnItems.flatMap((row) => {
      const count = segmentsFor(row, snapshot.cwd, target.input.skills).reduce(
        (sum, text) => sum + countThreadSearchOccurrences(text, target.input.query),
        0,
      );
      if (!count) return [];
      const item = row.item;
      return [
        {
          position: row.position,
          visibility: row.visibility,
          sourceThreadId: row.sourceThreadId,
          sourceItemId: row.sourceItemId,
          entryId:
            item.type === "user_message" || item.type === "assistant_message"
              ? item.messageId
              : item.id,
          runId: item.runId,
          count,
        },
      ];
    });
    return AsyncResult.success(
      resultForSelection(
        selectMatch(documents, target.input),
        documents,
        snapshot.sequence ?? snapshot.revision,
      ),
    );
  }),
);
/** Source find operates on retained projected messages/plans, never a fabricated remote index. */
const threadFind = (target: Target) => queries(JSON.stringify(target));
export const orchestrationEnvironment = { threadFind, threadFindProgressive: threadFind };
