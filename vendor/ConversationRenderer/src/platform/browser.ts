import { AsyncResult } from "effect/reactivity";
import * as Cause from "effect/Cause";
import { nativeAction } from "../bridge";
import { reportNativeFailure } from "./bridgeActions";
import { capability, getPlatformSnapshot, usePlatformSnapshot } from "./snapshot";
import { resolvePullRequestPreviewTarget } from "@conversation/client-runtime/change-request-links";
export class BrowserPreviewUnavailableError extends Error {
  constructor(input: { message: string }) {
    super(input.message);
  }
}
export class BrowserSettingsReadError extends Error {
  constructor(input: { cause?: unknown }) {
    super("Saved browser settings could not be loaded.");
    this.cause = input.cause;
  }
}
export function isPreviewAvailableFor(_environmentId: unknown) {
  return capability("preview");
}
export function isBrowserPreviewFile(path: string) {
  return /\.(?:html?|pdf)$/i.test(path.split(/[?#]/, 1)[0] ?? "");
}
export async function openUrlInPreview(input: { threadRef: unknown; url: string }) {
  try {
    await nativeAction({
      kind: "openLink",
      url: input.url,
      threadRef: input.threadRef,
      mode: "preview",
    });
    return AsyncResult.success(undefined);
  } catch (error) {
    return AsyncResult.failure(Cause.fail(error));
  }
}
export async function openFileInPreview(input: { threadRef: unknown; filePath: string }) {
  try {
    await nativeAction({
      kind: "openFile",
      path: input.filePath,
      threadRef: input.threadRef,
      mode: "preview",
    });
    return AsyncResult.success(undefined);
  } catch (error) {
    return AsyncResult.failure(Cause.fail(error));
  }
}
export function useOpenLink(threadRef: unknown) {
  return async (
    url: string,
    options?: {
      event?: { metaKey?: boolean; ctrlKey?: boolean; button?: number };
      threadRef?: unknown;
    },
  ) => {
    try {
      await nativeAction({
        kind: "openLink",
        url,
        threadRef: options?.threadRef ?? threadRef,
        modifiers: options?.event
          ? {
              metaKey: !!options.event.metaKey,
              ctrlKey: !!options.event.ctrlKey,
              button: options.event.button,
            }
          : undefined,
      });
    } catch (error) {
      reportNativeFailure(error);
      throw error;
    }
  };
}
export function useOpenChangeRequestLink(threadRef: unknown) {
  return (
    event: {
      preventDefault(): void;
      stopPropagation(): void;
      metaKey?: boolean;
      ctrlKey?: boolean;
    },
    url: string,
    targetThreadRef?: unknown,
  ) => {
    if (!capability("preview") || event.metaKey || event.ctrlKey) return false;
    event.preventDefault();
    event.stopPropagation();
    void nativeAction({
      kind: "openLink",
      url,
      threadRef: targetThreadRef ?? threadRef,
      mode: "preview",
    }).catch(reportNativeFailure);
    return true;
  };
}
export function usePullRequestPreviewTarget(environmentId: unknown, url: string) {
  const snapshot = usePlatformSnapshot();
  return resolvePullRequestPreviewTarget({
    environmentId: environmentId as any,
    projects: (snapshot?.projects ?? []) as any,
    pullRequestsEnabled: snapshot?.capabilities?.pullRequestPreview === true,
    url,
  });
}
export function recordVisitForThread(_threadRef: unknown, _url: string) {
  /* Native browser owns its own navigation history. */
}
export function resolveDiffThemeName(theme: string) {
  return theme === "dark" ? "pierre-dark" : "pierre-light";
}
export function useOpenPrLink(threadRef: unknown) {
  const openChangeRequest = useOpenChangeRequestLink(threadRef),
    openLink = useOpenLink(threadRef);
  return (event: any, url: string, targetThreadRef?: unknown) => {
    if (event.button > 1) return false;
    event.stopPropagation();
    const modified = event.metaKey || event.ctrlKey || event.button === 1;
    if (modified && event.currentTarget instanceof HTMLAnchorElement && event.currentTarget.href)
      return false;
    event.preventDefault();
    if (!modified && openChangeRequest(event, url, targetThreadRef)) return true;
    void openLink(url, { event, threadRef: targetThreadRef }).catch(reportNativeFailure);
    return false;
  };
}
