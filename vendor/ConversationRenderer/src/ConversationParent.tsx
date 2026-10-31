import { useLayoutEffect, useRef, useState, type ReactNode, type RefObject } from "react";
import type { LegendListRef } from "@legendapp/list/react";
import type { ScopedThreadRef } from "@conversation/contracts";
import { ChatCanvas } from "@conversation-source/components/chat/ChatCanvas";
import { createChatCanvasStore } from "@conversation-source/components/chat/canvasStore";
import { ScrollToEndButton } from "@conversation-source/components/chat/TimelineOverlays";
import { useTimelineFollow } from "@conversation-source/components/chat/useTimelineFollow";
import type { ConversationSnapshot } from "./bridge";
import { post, nativeAction } from "./bridge";
import { reportNativeFailure } from "./platform/bridgeActions";
import { useThreadFind } from "@conversation-source/components/chat/useThreadFind";
import {
  ThreadFindBar,
  THREAD_FIND_BAR_RESERVED_HEIGHT,
} from "@conversation-source/components/chat/ThreadFindBar";
import { ThreadFindTimelineContext } from "@conversation-source/components/chat/ThreadFindProvider";
import {
  openThreadFind,
  closeThreadFind,
} from "@conversation-source/components/chat/threadFindStore";
import { observeNativeOverlays, resolveNativeViewport } from "./nativeViewport";
import { installNativeFind, type NativeFindAction } from "./nativeFind";

type SourceFollowInput = Parameters<typeof useTimelineFollow>[0];
type SourceProjection = NonNullable<SourceFollowInput["serverProjection"]>;
export interface NativeFollowModel {
  projection: Pick<SourceProjection, "visibleTurnItems"> | null;
  threadStatus: SourceFollowInput["threadStatus"];
  activityRun: Pick<NonNullable<SourceFollowInput["activeActivityRun"]>, "runId" | "status"> | null;
  runningRunId: SourceFollowInput["activeRunningTurnId"];
  entries: SourceFollowInput["timelineEntries"];
}
export interface ConversationSurfaceControls {
  listRef: RefObject<LegendListRef | null>;
  follow: ReturnType<typeof useTimelineFollow>;
  anchorMessageId: SourceFollowInput["timelineAnchorMessageId"];
  onIsAtEndChange: (isAtEnd: boolean) => void;
  onViewportAttach: NonNullable<
    Parameters<
      typeof import("@conversation-source/components/chat/MessagesTimeline").MessagesTimeline
    >[0]["onViewportAttach"]
  >;
  composerInset: number;
}

/** Source parent layout/follow; the native composer contributes measurements, never duplicate DOM. */
export function ConversationParent({
  snapshot,
  threadRef,
  model,
  children,
}: {
  snapshot: ConversationSnapshot;
  threadRef: ScopedThreadRef;
  model: NativeFollowModel;
  children: (controls: ConversationSurfaceControls) => ReactNode;
}) {
  const find = useThreadFind({ thread: threadRef, enabled: true, progressive: false });
  const viewport = resolveNativeViewport(snapshot, window.innerWidth, window.innerHeight);
  const viewportRef = useRef(viewport);
  viewportRef.current = viewport;
  const [canvas] = useState(() => {
    const store = createChatCanvasStore();
    const measure = store.getState().setMeasurements;
    store.setState({
      setMeasurements: (next) =>
        measure({ ...next, composerHeight: viewportRef.current.composerInset }),
    });
    return store;
  });
  const listRef = useRef<LegendListRef | null>(null);
  const threadKey = `${threadRef.environmentId}:${threadRef.threadId}`;
  const [anchor, setAnchor] = useState<{
    threadKey: string | null;
    messageId: SourceFollowInput["timelineAnchorMessageId"];
  }>({ threadKey: null, messageId: null });
  const anchorMessageId = anchor.threadKey === threadKey ? anchor.messageId : null;
  const follow = useTimelineFollow({
    legendListRef: listRef,
    composerTimelineInset: viewport.composerInset,
    routeThreadKey: threadKey,
    activeThreadKey: threadKey,
    isServerThread: true,
    // The pinned hook reads only visibleTurnItems. This native application boundary
    // deliberately supplies that exact observed footprint, not invented provider graphs.
    serverProjection: model.projection as SourceProjection | null,
    threadStatus: model.threadStatus,
    activeActivityRun: model.activityRun as SourceFollowInput["activeActivityRun"],
    activeRunningTurnId: model.runningRunId,
    timelineEntries: model.entries,
    timelineAnchorMessageId: anchorMessageId,
    setTimelineAnchor: setAnchor,
  });
  useLayoutEffect(() => {
    document.documentElement.dataset.nativeViewport = viewport.mode;
    canvas.getState().setMeasurements(canvas.getState().measurements);
    // The pinned follow store reads only getBoundingClientRect().height from this
    // interface. A native geometry facade supplies real measurements without fake UI.
    const measurement: Pick<HTMLElement, "getBoundingClientRect"> = {
      getBoundingClientRect: () => {
        const current = viewportRef.current;
        const rect = current.composer;
        return new DOMRect(
          rect?.x ?? 0,
          rect?.y ?? current.height,
          rect?.width ?? current.width,
          current.composerInset,
        );
      },
    };
    follow.attachComposerOverlay(measurement as HTMLElement);
    return () => follow.attachComposerOverlay(null);
  }, [canvas, viewport.mode, viewport.composerInset, follow.attachComposerOverlay]);
  useLayoutEffect(() => observeNativeOverlays(), []);
  const closeFind = () => {
    find.barProps.onClose();
    void nativeAction({ kind: "focusComposer" }).catch((error) =>
      reportNativeFailure(error, "Unable to focus composer"),
    );
  };
  const findHandler = useRef<(action: NativeFindAction) => boolean>(() => false);
  findHandler.current = (action) => {
    if (action === "close") {
      if (!find.barProps.open) return false;
      closeFind();
      return true;
    }
    if (action === "open" || !find.barProps.open) {
      openThreadFind(threadKey);
      return true;
    }
    if (action === "next") {
      find.barProps.onNext();
      return true;
    }
    if (action === "previous") {
      find.barProps.onPrevious();
      return true;
    }
    return false;
  };
  useLayoutEffect(() => installNativeFind((action) => findHandler.current(action)), [threadKey]);
  useLayoutEffect(() => {
    const handle = (event: KeyboardEvent) => {
      if (event.key === "Escape" && find.barProps.open && !event.defaultPrevented) {
        event.preventDefault();
        event.stopPropagation();
        closeFind();
      }
    };
    window.addEventListener("keydown", handle);
    return () => window.removeEventListener("keydown", handle);
  }, [find.barProps.open]);
  useLayoutEffect(() => () => closeThreadFind(), [threadKey]);
  window.TabConversation.scrollToEnd = () => follow.scrollToEnd(true);
  const onIsAtEndChange = (isAtEnd: boolean) => {
    follow.onIsAtEndChangeStable(isAtEnd);
    post({ type: "scroll", isAtBottom: isAtEnd });
  };
  const onViewportAttach: ConversationSurfaceControls["onViewportAttach"] = (sourceViewport) => {
    const detach = follow.attachTimelineViewport(sourceViewport);
    let last = "";
    const capture = () => {
      const state = listRef.current?.getState();
      if (!state || state.data.length === 0) return;
      const row = state.data[state.start];
      if (!row) return;
      const messageId = row.kind === "message" ? row.message?.id : undefined;
      const itemId = row.groupedEntries?.[0]?.id ?? row.entry?.id;
      const runId = row.runId;
      if (!messageId && !itemId && !runId) return;
      const payload = {
        type: "anchor",
        ...(messageId ? { messageId } : {}),
        ...(itemId ? { itemId } : {}),
        ...(runId ? { runId } : {}),
        offset: Math.max(0, state.scroll - state.positionAtIndex(state.start)),
      };
      const signature = JSON.stringify(payload);
      if (signature !== last) {
        last = signature;
        post(payload);
      }
    };
    sourceViewport.scrollNode.addEventListener("scroll", capture, { passive: true });
    capture();
    return () => {
      detach?.();
      sourceViewport.scrollNode.removeEventListener("scroll", capture);
    };
  };
  return (
    <main
      data-tab-conversation
      data-native-viewport={viewport.mode}
      className="relative flex h-full min-h-0 flex-col text-foreground"
      style={{
        height: "100vh",
        background: viewport.mode === "full-pane" ? "transparent" : "var(--background)",
      }}
    >
      <div
        data-native-canvas-clip
        className="relative flex h-full min-h-0 flex-col"
        style={{
          clipPath:
            viewport.mode === "full-pane" ? `inset(0 0 ${viewport.composerInset}px 0)` : undefined,
        }}
      >
        <ThreadFindTimelineContext value={find.timelineProps}>
          <ChatCanvas
            store={canvas}
            threadRef={threadRef}
            preview={null}
            composerOverlayElement={null}
            detailsCardTopInset={find.barProps.open ? THREAD_FIND_BAR_RESERVED_HEIGHT : 0}
          >
            <ThreadFindBar {...find.barProps} onClose={closeFind} />
            <div className="relative flex min-h-0 flex-1 flex-col bg-background">
              {children({
                listRef,
                follow,
                anchorMessageId,
                onIsAtEndChange,
                onViewportAttach,
                composerInset: viewport.composerInset,
              })}
              {follow.showScrollToBottom && !find.barProps.open ? (
                <ScrollToEndButton
                  bottom={viewport.composerInset + 4}
                  summary={null}
                  onScrollToEnd={() => follow.scrollToEnd(true)}
                />
              ) : null}
            </div>
          </ChatCanvas>
        </ThreadFindTimelineContext>
      </div>
    </main>
  );
}
