import * as DateTime from "effect/DateTime";
import type { ConversationSnapshot } from "./bridge";
import {
  deriveTimelineEntriesFromVisibleTurnItems,
  type TimelineEntry,
  type PendingApproval,
} from "@conversation-source/session-logic";
import type { TimelineLatestRun } from "@conversation-source/components/chat/MessagesTimeline.logic";
import type { TurnDiffSummary } from "@conversation-source/types";

// Native user-item IDs identify accepted turns. They are local bridge identities,
// never represented as provider run/attempt IDs. Provider metadata wins when present.
export const nativeRunId = (userItemID: string) => `native-turn:${userItemID}`;
const object = (value: unknown): Record<string, any> =>
  value !== null && typeof value === "object" ? (value as Record<string, any>) : {};
const date = (value: unknown): string | undefined =>
  typeof value === "string" && Number.isFinite(Date.parse(value)) ? value : undefined;
const parse = (value: unknown): unknown => {
  if (typeof value !== "string") return value;
  try {
    return JSON.parse(value);
  } catch {
    return value;
  }
};
const attachmentURL = (item: string, id: string) =>
  `tab-conversation://bundle/__attachment?item=${encodeURIComponent(item)}&attachment=${encodeURIComponent(id)}`;
const toolStatus = (status: unknown, complete: boolean) =>
  status === "denied"
    ? "cancelled"
    : status === "interrupted"
      ? "interrupted"
      : status === "failed"
        ? "failed"
        : status === "running" || !complete
          ? "running"
          : "completed";

export function projectNativeSnapshot(snapshot: ConversationSnapshot) {
  const turns = snapshot.turns.map(object);
  const byUser = new Map(turns.map((turn) => [String(turn.userItemID), turn]));
  const timelineEntries: TimelineEntry[] = [];
  const visibleTurnItems: any[] = [];
  const pendingApprovals: PendingApproval[] = [];
  const turnDiffSummaries: TurnDiffSummary[] = [];
  const toolItems = new Map<string, any>();
  const attachmentOwners = new Map<string, { itemId: string; attachmentId: string; url: string }>();
  let turn: Record<string, any> | undefined;
  const finalAssistantDates = new Map<string, string>();
  turns.forEach((turn, index) => {
    if (!date(turn.completedAt)) return;
    const start = snapshot.items.findIndex((item) => item.id === turn.userItemID);
    if (start < 0) return;
    const next = snapshot.items.findIndex(
      (item, itemIndex) => itemIndex > start && item.kind === "user",
    );
    const range = snapshot.items.slice(start + 1, next < 0 ? undefined : next);
    const final = range.findLast((item) => item.kind === "assistant");
    if (final) finalAssistantDates.set(String(final.id), turn.completedAt);
  });
  snapshot.items.forEach((raw, index) => {
    const native = object(raw),
      context = object(native.workContext),
      activity = object(native.tool);
    const id = String(native.id),
      complete = native.isComplete !== false;
    if (native.kind === "user") turn = byUser.get(id);
    const runId = context.runID ?? (turn ? nativeRunId(String(turn.userItemID)) : null);
    const knownDate =
      date(context.createdAt) ??
      date(activity.startedAt) ??
      date(native.createdAt) ??
      (native.kind === "user" ? date(turn?.startedAt) : finalAssistantDates.get(id));
    // Source timestamp formatters reject an empty legacy date and render no label.
    // A private revision sentinel below satisfies the source DateTime detail key only.
    const createdAt = knownDate ?? "";
    const attachments = (Array.isArray(native.attachments) ? native.attachments : [])
      .map(object)
      .map((file) => {
        const sourceID =
          typeof file.bridgeId === "string"
            ? file.bridgeId
            : `native-attachment:${encodeURIComponent(id)}:${encodeURIComponent(String(file.id))}`;
        attachmentOwners.set(sourceID, {
          itemId: id,
          attachmentId: String(file.id),
          url: attachmentURL(id, String(file.id)),
        });
        return {
          type: String(file.mimeType).startsWith("image/") ? "image" : "file",
          id: sourceID,
          name: file.name,
          mimeType: file.mimeType,
          sizeBytes: file.byteCount,
        };
      });
    const base: any = {
      id,
      threadId: snapshot.sessionId,
      runId,
      nodeId: null,
      providerThreadId: null,
      providerTurnId: context.providerTurnID ?? null,
      nativeItemRef: null,
      parentItemId: null,
      ordinal: index,
      status: [
        "pending",
        "running",
        "waiting",
        "completed",
        "idle",
        "failed",
        "cancelled",
        "interrupted",
      ].includes(context.sourceStatus)
        ? context.sourceStatus
        : toolStatus(activity.status, complete),
      title: null,
      startedAt: knownDate ? DateTime.makeUnsafe(knownDate) : null,
      completedAt: date(activity.completedAt)
        ? DateTime.makeUnsafe(activity.completedAt)
        : complete &&
            context.sourceStatus !== "running" &&
            ["reasoning", "compaction", "proposed_plan", "todo_list"].includes(context.itemType) &&
            date(native.updatedAt)
          ? DateTime.makeUnsafe(native.updatedAt)
          : null,
      updatedAt: DateTime.makeUnsafe(
        date(native.updatedAt) ??
          date(activity.completedAt) ??
          knownDate ??
          "1970-01-01T00:00:00.000Z",
      ),
    };
    if (native.kind === "user" || native.kind === "assistant") {
      const message = {
        id,
        role: native.kind,
        text: String(native.text ?? ""),
        attachments,
        runId,
        streaming: !complete,
        createdAt,
        updatedAt:
          date(native.updatedAt) ??
          finalAssistantDates.get(id) ??
          date(activity.completedAt) ??
          createdAt,
      };
      const payload = {
        ...base,
        type: native.kind === "user" ? "user_message" : "assistant_message",
        messageId: id,
        text: message.text,
        attachments,
        streaming: !complete,
        ...(native.kind === "user"
          ? { createdBy: "user", creationSource: "server", inputIntent: "turn_start" }
          : {}),
      };
      visibleTurnItems.push({
        position: index,
        visibility: "local",
        sourceThreadId: snapshot.sessionId,
        sourceItemId: id,
        item: payload,
      });
      timelineEntries.push({ id, kind: "message", createdAt, message } as TimelineEntry);
      return;
    }
    if (native.kind === "approval" && complete) return;
    let payload: any;
    const planData = object(parse(native.detail));
    const validSteps =
      Array.isArray(planData.steps) &&
      planData.steps.every(
        (step: any) =>
          typeof step?.id === "string" &&
          step.id.trim() !== "" &&
          typeof step?.text === "string" &&
          step.text.trim() !== "" &&
          ["pending", "running", "completed"].includes(step.status),
      );
    // Local UI identity for observed content, not an orchestration graph ID.
    const planId = `native-plan:${encodeURIComponent(id)}`;
    if (context.itemType === "error") {
      payload = {
        ...base,
        type: "error",
        status: "failed",
        failure: {
          class: "unknown",
          message:
            String(native.text ?? "")
              .trim()
              .slice(0, 4096) || "Agent failed",
          code: null,
          retryable: null,
        },
      };
    } else if (context.itemType === "proposed_plan") {
      payload = {
        ...base,
        type: "proposed_plan",
        planId,
        markdown: String(native.detail ?? ""),
        streaming: context.sourceStatus === "running" || !complete,
      };
    } else if (context.itemType === "todo_list" && validSteps) {
      payload = {
        ...base,
        type: "todo_list",
        planId,
        steps: planData.steps,
        ...(typeof planData.explanation === "string" ? { explanation: planData.explanation } : {}),
      };
    } else if (native.kind === "approval") {
      const requestId = id;
      payload = {
        ...base,
        type: "approval_request",
        requestId,
        requestKind: context.requestKind ?? "command",
        prompt: native.detail ?? native.text,
        options: [
          { decision: "decline", label: "Decline" },
          { decision: "accept", label: "Approve" },
        ],
      };
      pendingApprovals.push({
        requestId,
        requestKind: payload.requestKind,
        createdAt,
        detail: payload.prompt,
        options: payload.options,
        responseCapability: "live",
      } as PendingApproval);
    } else if (native.kind === "notice") {
      payload = {
        ...base,
        type: "system_notice",
        message: String(native.text ?? ""),
        severity: "info",
      };
    } else if (context.itemType === "compaction") {
      payload = {
        ...base,
        type: "compaction",
        title: native.text,
        driver:
          snapshot.provider === "claude"
            ? "claudeAgent"
            : snapshot.provider === "codex"
              ? "codex"
              : null,
        ...(native.detail ? { summary: String(native.detail) } : {}),
        ...(context.beforeTokenCount !== undefined
          ? { beforeTokenCount: context.beforeTokenCount }
          : {}),
        ...(context.afterTokenCount !== undefined
          ? { afterTokenCount: context.afterTokenCount }
          : {}),
      };
    } else if (context.itemType === "reasoning") {
      payload = {
        ...base,
        type: "reasoning",
        text: String(native.detail ?? native.text ?? ""),
        streaming: !complete,
      };
    } else if (
      activity.presentation === "command" ||
      (activity.presentation == null &&
        (activity.category === "command" || activity.name === "commandExecution"))
    ) {
      const input = parse(activity.input);
      const command =
        typeof input === "string"
          ? input
          : String(object(input).command ?? object(input).cmd ?? activity.input ?? "");
      payload = {
        ...base,
        type: "command_execution",
        input: command,
        output: activity.output,
        exitCode: activity.exitCode,
      };
    } else if (activity.presentation === "fileChange") {
      const details = object(activity.fileChangeDetails),
        changes = Array.isArray(activity.fileChanges) ? activity.fileChanges.map(object) : [];
      payload = {
        ...base,
        type: "file_change",
        fileName: details.fileName ?? changes[0]?.path ?? activity.filePaths?.[0] ?? "File changes",
        diffStr: details.diff ?? changes.map((change: any) => change.diff ?? "").join("\n"),
        additions: details.additions,
        deletions: details.deletions,
        changes: details.operations,
      };
    } else if (activity.presentation === "fileSearch") {
      const details = object(activity.fileSearchDetails);
      payload = {
        ...base,
        type: "file_search",
        pattern: details.pattern,
        results: details.results,
      };
    } else if (activity.presentation === "webSearch") {
      payload = {
        ...base,
        type: "web_search",
        patterns: activity.searchPatterns ?? [],
        results: activity.webResults ?? [],
      };
    } else {
      const output =
        context.itemType === "todo_list" && !validSteps
          ? native.detail
          : activity.outputIsJSON === true
            ? parse(activity.output)
            : activity.output;
      payload = {
        ...base,
        type: "dynamic_tool",
        toolName: activity.name ?? native.text ?? null,
        input: parse(activity.input) ?? null,
        ...(output === undefined ? {} : { output }),
      };
      // Persisted image descriptors are resolved through the message-owned bridge.
      // The source recognizes these metadata-only blocks without embedding provider bytes.
      const images = attachments
        .filter((attachment: any) => attachment.type === "image")
        .map((attachment: any) => ({ type: "image", mimeType: attachment.mimeType }));
      if (images.length > 0) {
        if (Array.isArray(output))
          payload.output = [...output.filter((block) => object(block).type !== "image"), ...images];
        else if (Array.isArray(object(output).content))
          payload.output = {
            ...object(output),
            content: [
              ...object(output).content.filter((block: any) => object(block).type !== "image"),
              ...images,
            ],
          };
        else
          payload.output = {
            content: [
              ...(output == null || output === ""
                ? []
                : [
                    {
                      type: "text",
                      text: typeof output === "string" ? output : JSON.stringify(output, null, 2),
                    },
                  ]),
              ...images,
            ],
          };
      }
    }
    if (context.toolNonExecutionKind) payload.toolNonExecutionKind = context.toolNonExecutionKind;
    toolItems.set(id, payload);
    const projectedItem = {
      position: index,
      visibility: "local",
      sourceThreadId: snapshot.sessionId,
      sourceItemId: id,
      item: payload,
    };
    visibleTurnItems.push(projectedItem);
    // Run the pinned source classifier, including native typed inspectors and
    // completed HTML/MCP resource cards. Only unknown display dates are restored
    // afterwards; their valid detail-revision sentinel must never become a label.
    const derived = deriveTimelineEntriesFromVisibleTurnItems({
      visibleTurnItems: [projectedItem],
      optimisticMessages: [],
    });
    for (const source of derived) {
      const entry: any = knownDate ? source : { ...source, createdAt };
      if (!knownDate && entry.kind === "work") entry.entry = { ...entry.entry, createdAt };
      if (
        entry.kind === "proposed-plan" &&
        ["active", "completed", "superseded"].includes(context.planStatus)
      ) {
        entry.proposedPlan = { ...entry.proposedPlan, status: context.planStatus };
      }
      const key =
        entry.kind === "html-render" ? "htmlRender" : entry.kind === "mcp-app" ? "mcpApp" : null;
      if (key) {
        const rawID = entry[key].attachmentId;
        const file = (Array.isArray(native.attachments) ? native.attachments : [])
          .map(object)
          .find((file) => file.id === rawID);
        if (file)
          entry[key] = {
            ...entry[key],
            attachmentId:
              file.bridgeId ??
              `native-attachment:${encodeURIComponent(id)}:${encodeURIComponent(String(rawID))}`,
          };
      }
      timelineEntries.push(entry);
    }
  });
  turns.forEach((entry, turnIndex) => {
    const checkpoint = object(entry.checkpoint);
    if (!checkpoint.id || !entry.completedAt) return;
    const runId = nativeRunId(String(entry.userItemID));
    const messages = timelineEntries.filter(
      (value: any) =>
        value.kind === "message" &&
        value.message.runId === runId &&
        value.message.role === "assistant",
    ) as any[];
    const files = (checkpoint.files ?? []).map((file: any) => ({ ...file, kind: "modified" }));
    turnDiffSummaries.push({
      checkpointId: checkpoint.id,
      runId,
      checkpointTurnCount: turnIndex + 1,
      checkpointRef: checkpoint.id,
      status: "ready",
      files,
      filesTotal: {
        count: checkpoint.totalFiles,
        additions: checkpoint.additions,
        deletions: checkpoint.deletions,
      },
      assistantMessageId: messages.at(-1)?.message.id ?? null,
      completedAt: entry.completedAt,
    } as TurnDiffSummary);
  });
  const latest = turns.at(-1);
  const observedOutcome = latest?.outcome;
  const terminalStatus = ["completed", "interrupted", "failed", "cancelled"].includes(
    observedOutcome,
  )
    ? observedOutcome
    : latest?.status === "failed"
      ? "failed"
      : null;
  // Legacy idle is ambiguous: both normal completion and interruption returned idle.
  const latestRun: TimelineLatestRun | null =
    latest && (!latest.completedAt || terminalStatus)
      ? ({
          runId: nativeRunId(String(latest.userItemID)),
          status: latest.completedAt
            ? terminalStatus
            : snapshot.status === "waiting"
              ? "waiting"
              : "running",
          startedAt: latest.startedAt ?? null,
          completedAt: latest.completedAt ?? null,
          turnEnded: !!latest.completedAt,
        } as TimelineLatestRun)
      : null;
  const followModel = {
    projection: { visibleTurnItems },
    threadStatus: snapshot.connectionState === "live" ? ("live" as const) : ("cached" as const),
    activityRun: latestRun ? { runId: latestRun.runId, status: latestRun.status } : null,
    runningRunId: latestRun?.status === "running" ? latestRun.runId : null,
    entries: timelineEntries,
  };
  return {
    followModel,
    visibleTurnItems,
    timelineEntries,
    latestRun,
    turnDiffSummaries,
    runs: [],
    pendingApprovals,
    toolItems,
    attachmentOwners,
    activeTurnStartedAt: latest && !latest.completedAt ? latest.startedAt : null,
    isWorking: snapshot.status === "working" || snapshot.status === "waiting",
  };
}
