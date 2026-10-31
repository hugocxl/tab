import React, { useState, useLayoutEffect } from "react";
import { mountConversation } from "./reactRoot";
import { classifyBrowserError } from "./browserErrors";
import { EnvironmentId, ThreadId } from "@conversation/contracts";
import { RouterProvider } from "@tanstack/react-router";
import {
  createNativeConversationRouter,
  useNativeCitationRequest,
  activateNativeCitation,
} from "./platform/router";
import { MessagesTimeline } from "@conversation-source/components/chat/MessagesTimeline";
import { ExpandedImageDialog } from "@conversation-source/components/chat/ExpandedImageDialog";
import type { ExpandedImagePreview } from "@conversation-source/components/chat/ExpandedImagePreview";
import { AppAtomRegistryProvider } from "@conversation-source/rpc/atomRegistry";
import { applyAppearanceFontVariables } from "@conversation-source/appearanceFonts";
import "./renderer.css";
import { post, resolveNative, nativeAction, type ConversationSnapshot } from "./bridge";
import {
  installNativePlatform,
  reportNativeFailure,
  citeAssistantText,
} from "./platform/bridgeActions";
import { setPlatformSnapshot } from "./platform/snapshot";
import { projectNativeSnapshot } from "./projectNativeSnapshot";
import { ConversationParent } from "./ConversationParent";
import { ConversationProviders } from "./ConversationProviders";
import { useClientSettings } from "./platform/settings";
import { nativeTurnItemSource } from "./nativeTurnItemSource";
import { insertArtifactTemplate } from "./platform/artifactTemplates";
import { prepareMcpDocument, htmlRenderReference } from "./prepareMcpDocument";
import { requestNativeFind } from "./nativeFind";
import { applyNativeTheme } from "./platform/nativeTheme";
installNativePlatform();
let receive: ((snapshot: ConversationSnapshot) => void) | undefined;
let latest: ConversationSnapshot | undefined;
window.TabConversation = {
  scrollToEnd() {},
  find: requestNativeFind,
  update(snapshot) {
    const previousScope = latest
      ? `${latest.environmentId ?? latest.projectId}:${latest.sessionId}`
      : null;
    const nextScope = `${snapshot.environmentId ?? snapshot.projectId}:${snapshot.sessionId}`;
    applyNativeTheme(snapshot);
    setPlatformSnapshot(snapshot);
    latest = snapshot;
    window.TabConversation.snapshot = snapshot;
    receive?.(snapshot);
    if (previousScope !== nextScope)
      void router
        .navigate({
          to: "/$environmentId/$threadId",
          params: {
            environmentId: snapshot.environmentId ?? snapshot.projectId ?? "tab-local",
            threadId: snapshot.sessionId,
          },
          replace: true,
        })
        .catch(reportNativeFailure);
  },
  resolve: resolveNative,
  prepareMcpDocument,
  htmlRenderReference,
};
function action(kind: string, payload: Record<string, unknown> = {}) {
  const titles: Record<string, string> = {
    openThread: "Unable to open conversation",
    openToolDiff: "Unable to open changes",
    openTurnDiff: "Unable to open changes",
    openAttachment: "Unable to open attachment",
    downloadAttachment: "Unable to download attachment",
    runShellCommand: "Unable to run command",
    useArtifactTemplate: "Unable to use artifact",
  };
  void nativeAction({ kind, ...payload }).catch((error) =>
    reportNativeFailure(error, titles[kind]),
  );
}
function Conversation() {
  const [snapshot, setSnapshot] = useState(latest);
  const timestampFormat = useClientSettings((settings) => settings.timestampFormat);
  const [respondingRequestIds, setRespondingRequestIds] = useState<string[]>([]);
  const [isRevertingCheckpoint, setRevertingCheckpoint] = useState(false);
  const [expandedImage, setExpandedImage] = useState<ExpandedImagePreview | null>(null);
  const citationRequest = useNativeCitationRequest();
  receive = setSnapshot;
  useLayoutEffect(() => {
    if (!snapshot) return;
    // Transport readiness precedes data; reveal only the committed, themed body.
    post({
      type: "rendered",
      sessionId: snapshot.sessionId,
      sequence: snapshot.sequence,
      revision: snapshot.revision,
    });
  }, [snapshot]);
  if (!snapshot) return null;
  document.documentElement.classList.toggle("dark", snapshot.theme === "dark");
  applyAppearanceFontVariables(document.documentElement, {
    sans: "",
    code: "",
    composer: "",
    sizeInterface: snapshot.font.interfaceSize,
    sizePrompt: snapshot.font.promptSize,
    sizeCode: snapshot.font.codeSize,
    smoothing: true,
    separate: false,
  });
  const projection = projectNativeSnapshot(snapshot);
  const environmentId = EnvironmentId.make(
    snapshot.environmentId ?? snapshot.projectId ?? "tab-local",
  );
  const threadRef = { environmentId, threadId: ThreadId.make(snapshot.sessionId) };
  return (
    <>
      <ConversationParent snapshot={snapshot} threadRef={threadRef} model={projection.followModel}>
        {({
          listRef,
          follow,
          anchorMessageId,
          onIsAtEndChange,
          onViewportAttach,
          composerInset,
        }) => (
          <MessagesTimeline
            {...projection}
            listRef={listRef}
            turnItemSource={nativeTurnItemSource}
            citationRequest={citationRequest}
            citationHistory={{
              _tag:
                !citationRequest ||
                snapshot.items.some(
                  (item) =>
                    item.id === citationRequest.citation.messageId && item.kind === "assistant",
                )
                  ? "found"
                  : "failed",
            }}
            routeThreadKey={`${environmentId}:${snapshot.sessionId}`}
            activeThreadEnvironmentId={environmentId}
            markdownCwd={snapshot.cwd}
            workspaceRoot={snapshot.cwd}
            resolvedTheme={snapshot.theme}
            timestampFormat={timestampFormat}
            isWorking={projection.isWorking}
            activeTurnStartedAt={projection.activeTurnStartedAt}
            supportsConversationRollback={snapshot.capabilities?.rollback === true}
            isRevertingCheckpoint={isRevertingCheckpoint}
            canOperateThread={
              snapshot.connectionState === "live" && snapshot.capabilities?.nativeActions === true
            }
            respondingRequestIds={respondingRequestIds}
            onRespondToApproval={
              snapshot.capabilities?.approvals
                ? async (requestId, decision) => {
                    setRespondingRequestIds((ids) => [...ids, requestId]);
                    try {
                      await nativeAction({
                        kind: "approve",
                        requestId,
                        allow: decision === "accept",
                        decision,
                      });
                    } catch (error) {
                      reportNativeFailure(error, "Unable to respond to approval");
                    } finally {
                      setRespondingRequestIds((ids) => ids.filter((id) => id !== requestId));
                    }
                  }
                : undefined
            }
            onOpenToolDiff={
              snapshot.capabilities?.openToolDiff
                ? (target) => action("openToolDiff", { target })
                : undefined
            }
            onOpenTurnDiff={
              snapshot.capabilities?.openTurnDiff
                ? (runId, filePath) => action("openTurnDiff", { runId, filePath })
                : undefined
            }
            onOpenThread={(threadId) => action("openThread", { threadId })}
            onForkFromRun={
              snapshot.capabilities?.fork
                ? async (input) => {
                    try {
                      await nativeAction({ kind: "forkFromRun", ...input });
                    } catch (error) {
                      reportNativeFailure(error, "Unable to fork conversation");
                    }
                  }
                : undefined
            }
            onRevertToTurnCount={(targetTurnCount, messageId) => {
              if (!snapshot.capabilities?.rollback) return;
              setRevertingCheckpoint(true);
              void nativeAction({ kind: "revertToTurnCount", targetTurnCount, messageId })
                .catch(reportNativeFailure)
                .finally(() => setRevertingCheckpoint(false));
            }}
            onUseArtifactTemplate={(template) => {
              void insertArtifactTemplate(template).catch((error) =>
                reportNativeFailure(error, "Unable to add to chat"),
              );
            }}
            onSendAppMessage={
              snapshot.capabilities?.sendAppMessage
                ? async (text) => {
                    await nativeAction({ kind: "sendAppMessage", text });
                  }
                : undefined
            }
            onRunShellCommand={
              snapshot.capabilities?.runShellCommand
                ? (command) => action("runShellCommand", { command })
                : undefined
            }
            onImageExpand={setExpandedImage}
            onFileOpen={
              snapshot.capabilities?.openAttachment
                ? (attachment) => action("openAttachment", { attachment })
                : undefined
            }
            onFileDownload={
              snapshot.capabilities?.downloadAttachment
                ? (attachment) => action("downloadAttachment", { attachment })
                : undefined
            }
            onCiteAssistantText={
              snapshot.capabilities?.cite ? (citation) => citeAssistantText(citation) : undefined
            }
            anchorMessageId={anchorMessageId}
            onAnchorReady={follow.onTimelineAnchorReadyStable}
            onAnchorSizeChanged={follow.onTimelineAnchorSizeChangedStable}
            contentInsetEndAdjustment={composerInset}
            emptyPlaceholderInset={composerInset}
            liveFollowEnabled={follow.timelineLiveFollowEnabled}
            onIsAtEndChange={onIsAtEndChange}
            onViewportAttach={onViewportAttach}
            onFooterGrow={follow.onTimelineFooterGrowStable}
          />
        )}
      </ConversationParent>
      {expandedImage ? (
        <ExpandedImageDialog preview={expandedImage} onClose={() => setExpandedImage(null)} />
      ) : null}
    </>
  );
}
const router = createNativeConversationRouter(() => (
  <ConversationProviders>
    <Conversation />
  </ConversationProviders>
));
window.TabConversation.navigateCitation = (citation) =>
  activateNativeCitation(citation as Parameters<typeof activateNativeCitation>[0]);
mountConversation(
  document.getElementById("root")!,
  <AppAtomRegistryProvider>
    <RouterProvider router={router} />
  </AppAtomRegistryProvider>,
);
window.addEventListener("error", (event) => post(classifyBrowserError(event)));
window.addEventListener("unhandledrejection", (event) =>
  post({ type: "error", message: String(event.reason) }),
);
post({
  type: "ready",
  features: {
    fullTimeline: true,
    nativeViewport: true,
    nativeViewportVersion: 1,
    renderedHandshake: true,
  },
});
