import { useEffect, useSyncExternalStore, type ComponentType } from "react";
import {
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import type { AssistantCitation } from "@conversation/contracts";
import { assistantCitationFromLocation } from "@conversation-source/lib/assistantCitationNavigation";
import { nativeAction, post } from "../bridge";
import { getPlatformSnapshot } from "./snapshot";
import { reportNativeFailure } from "./bridgeActions";
let citationRequest: { citation: AssistantCitation; key: string } | null = null;
let activation = 0;
const listeners = new Set<() => void>();
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};
export function useNativeCitationRequest() {
  return useSyncExternalStore(
    subscribe,
    () => citationRequest,
    () => null,
  );
}
export function clearNativeCitationRequest() {
  citationRequest = null;
  for (const listener of listeners) listener();
}
export function activateNativeCitation(citation: AssistantCitation) {
  const snapshot = getPlatformSnapshot();
  if (!snapshot) return false;
  if (
    citation.threadId !== snapshot.sessionId ||
    citation.environmentId !== (snapshot.environmentId ?? snapshot.projectId)
  ) {
    void nativeAction({ kind: "navigateCitation", citation }).catch(reportNativeFailure);
    return false;
  }
  citationRequest = { citation, key: `native-citation-${++activation}` };
  for (const listener of listeners) listener();
  return true;
}
function ConversationRenderFailure({ error }: { error: unknown }) {
  useEffect(() => {
    post({ type: "error", message: error instanceof Error ? error.message : String(error) });
  }, [error]);
  return null;
}
/** Retain TanStack's source Link/navigation behavior while native Tab owns tabs. */
export function createNativeConversationRouter(component: ComponentType) {
  const root = createRootRoute({ component, errorComponent: ConversationRenderFailure });
  const thread = createRoute({
    getParentRoute: () => root,
    path: "/$environmentId/$threadId",
    beforeLoad: ({ params, location }) => {
      const citation = assistantCitationFromLocation(location.href);
      if (citation) {
        activateNativeCitation(citation);
        return;
      }
      const snapshot = getPlatformSnapshot();
      if (
        params.threadId !== snapshot?.sessionId ||
        params.environmentId !== (snapshot?.environmentId ?? snapshot?.projectId)
      )
        void nativeAction({
          kind: "openThread",
          threadId: params.threadId,
          environmentId: params.environmentId,
        }).catch(reportNativeFailure);
    },
  });
  return createRouter({
    routeTree: root.addChildren([thread]),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });
}
