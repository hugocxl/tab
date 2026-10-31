import { useMemo } from "react";
import { Atom, AsyncResult } from "effect/reactivity";
import * as Effect from "effect/Effect";
import * as Cause from "effect/Cause";
import * as Option from "effect/Option";
import { nativeAction } from "../bridge";
import { reportNativeFailure } from "./bridgeActions";
import { getPlatformSnapshot, usePlatformSnapshot, platformSnapshotAtom } from "./snapshot";
import { projectNativeSnapshot } from "../projectNativeSnapshot";
import { create } from "zustand";
import { sourceControlClients } from "@conversation/client-runtime/source-control-clients";
import { parseGitRemoteRepository } from "@conversation/shared/git";
import { DEFAULT_RESOLVED_KEYBINDINGS } from "@conversation/shared/keybindings";

type Target = Record<string, unknown>;
type Operation = ((target: Target) => unknown) & {
  nativeKind: string;
  execute?: (target: Target) => Promise<unknown>;
};
function operation(kind: string): Operation {
  const family = Atom.family((key: string) =>
    Atom.make(
      Effect.tryPromise({
        try: () => nativeAction({ kind, ...JSON.parse(key) }),
        catch: (error) => (error instanceof Error ? error : new Error(String(error))),
      }),
    ),
  );
  const run = ((target: Target) => family(JSON.stringify(target))) as Operation;
  run.nativeKind = kind;
  return run;
}
export function useAtomCommand(command: Operation, _options?: unknown) {
  return async (target: Target) => {
    try {
      return AsyncResult.success(
        await (command.execute
          ? command.execute(target)
          : nativeAction({ kind: command.nativeKind, ...target })),
      );
    } catch (error) {
      return AsyncResult.failure(Cause.fail(error));
    }
  };
}
export const useAtomQueryRunner = useAtomCommand;
export const shellEnvironment = { openInEditor: operation("openEditor") };
const createAssetUrl = operation("createAssetUrl");
const createAssetUrls = Atom.family((key: string) =>
  Atom.make((get) => {
    const [environmentId, resources] = JSON.parse(key);
    return resources.map((resource: unknown) =>
      get(createAssetUrl({ environmentId, input: { resource } }) as any),
    );
  }),
);
export const assetEnvironment = {
  createUrl: createAssetUrl,
  createUrls: (target: { environmentId: unknown; resources: readonly unknown[] }) =>
    createAssetUrls(JSON.stringify([target.environmentId, target.resources])),
};
const fileMetadataRequests = Atom.family((key: string) =>
  Atom.make(
    Effect.tryPromise({
      try: async () => {
        const target = JSON.parse(key),
          snapshot = getPlatformSnapshot();
        if (
          !readEnvironmentScope(target.environmentId, "filesystem:read", snapshot) ||
          (target.input?.threadId !== undefined && target.input.threadId !== snapshot?.sessionId)
        )
          throw new Error("The file metadata belongs to an unavailable conversation scope.");
        const result = (await nativeAction({
          kind: "filesystemMetadata",
          environmentId: target.environmentId,
          input: { paths: [target.input.path] },
        })) as { entries: unknown[] };
        if (!Array.isArray(result?.entries) || result.entries.length !== 1)
          throw new Error("The native filesystem returned invalid file metadata.");
        return result.entries[0] ?? null;
      },
      catch: (error) => (error instanceof Error ? error : new Error(String(error))),
    }),
  ),
);
export const projectEnvironment = {
  searchEntries: operation("searchProjectEntries"),
  writeFile: operation("writeProjectFile"),
  fileMetadata: (target: Target) => fileMetadataRequests(JSON.stringify(target)),
};
export const filesystemEnvironment = { getMetadata: operation("filesystemMetadata") };
export const previewEnvironment = { open: operation("openPreview") };
export const threadEnvironment = {
  linkPullRequest: operation("linkPullRequest"),
  unlinkPullRequest: operation("unlinkPullRequest"),
};
function nativeServerConfig(snapshot = getPlatformSnapshot()) {
  if (snapshot?.serverConfig) return snapshot.serverConfig;
  return snapshot?.capabilities?.pullRequestPreview === true
    ? { availableEditors: [], shellRevealInFileManager: false }
    : null;
}
export const serverEnvironment = {
  configValueAtom: Atom.family((environmentId: unknown) =>
    Atom.make((get) => {
      const snapshot = get(platformSnapshotAtom);
      return environmentId === (snapshot?.environmentId ?? snapshot?.projectId)
        ? nativeServerConfig(snapshot)
        : null;
    }),
  ),
  providersValueAtom: Atom.family((_environmentId: unknown) =>
    Atom.make((get) => get(platformSnapshotAtom)?.providers ?? []),
  ),
};
export const environmentServerConfigsAtom = Atom.make(() => new Map());
export function readEnvironmentScope(
  environmentId: unknown,
  scope: unknown,
  snapshot = getPlatformSnapshot(),
) {
  if (
    !environmentId ||
    !snapshot ||
    snapshot.connectionState !== "live" ||
    environmentId !== (snapshot.environmentId ?? snapshot.projectId)
  )
    return false;
  const name = String(scope).toLowerCase();
  if (name.includes("preview")) return snapshot.capabilities?.preview === true;
  if (name.includes("filesystem") && name.includes("write"))
    return snapshot.capabilities?.filesystemWrite === true;
  if (name.includes("filesystem")) return snapshot.capabilities?.filesystem === true;
  return snapshot.capabilities?.nativeActions === true;
}
export function useEnvironmentScope(environmentId: unknown, scope: unknown) {
  const snapshot = usePlatformSnapshot();
  return readEnvironmentScope(environmentId, scope, snapshot);
}
export function readPreparedConnection(environmentId: unknown, snapshot = getPlatformSnapshot()) {
  if (
    !environmentId ||
    !snapshot ||
    snapshot.connectionState !== "live" ||
    environmentId !== (snapshot.environmentId ?? snapshot.projectId)
  )
    return null;
  return {
    httpBaseUrl: "tab-conversation://bundle",
    target: { _tag: "NativeTabConnectionTarget", label: "Tab" },
  };
}
export function usePreparedConnection(environmentId: unknown) {
  const snapshot = usePlatformSnapshot();
  const connection = readPreparedConnection(environmentId, snapshot);
  return connection ? Option.some(connection) : Option.none();
}
export function useFilesystemReadAccess(environmentId: unknown) {
  const snapshot = usePlatformSnapshot();
  return {
    canReadFiles: readEnvironmentScope(environmentId, "filesystem:read", snapshot),
    isPending: false,
    error: null,
  };
}
export function useProjects() {
  const snapshot = usePlatformSnapshot();
  return readProjects(snapshot);
}
export function readThreadShell(threadRef: any, snapshot = getPlatformSnapshot()) {
  return threadRef &&
    snapshot &&
    threadRef.threadId === snapshot.sessionId &&
    threadRef.environmentId === (snapshot.environmentId ?? snapshot.projectId)
    ? {
        id: snapshot.sessionId,
        environmentId: threadRef.environmentId,
        projectId: snapshot.projectId,
        workspaceRoot: snapshot.cwd,
        title:
          snapshot.title ??
          snapshot.messages.find((message) => message.role === "user")?.text ??
          "",
        pullRequests: [],
      }
    : null;
}
export function resolveRemoteOpenState(snapshot = getPlatformSnapshot()) {
  return { mode: snapshot?.remote ? "remote-unavailable" : "local-exec" };
}
export function useRemoteOpenResolution() {
  const snapshot = usePlatformSnapshot();
  return { state: resolveRemoteOpenState(snapshot), isResolved: true };
}
export const useRightPanelStore = create<any>((set) => ({
  byThreadKey: {},
  threadPanelVisibilityByThreadKey: {},
  openFile: (threadRef: unknown, path: string, line?: number) => {
    void nativeAction({ kind: "openFile", threadRef, path, line, mode: "panel" }).catch(
      reportNativeFailure,
    );
  },
  setThreadPanelOpen: (ref: any, presentation: string, open: boolean) =>
    set((state: any) => {
      const key = JSON.stringify([ref.environmentId, ref.threadId]);
      return {
        threadPanelVisibilityByThreadKey: {
          ...state.threadPanelVisibilityByThreadKey,
          [key]: {
            ...state.threadPanelVisibilityByThreadKey[key],
            [presentation === "inline" ? "inlineOpen" : "popoverOpen"]: open,
          },
        },
      };
    }),
}));
export function selectThreadPanelOpen(states: Record<string, any>, ref: any, presentation: string) {
  return ref
    ? states[JSON.stringify([ref.environmentId, ref.threadId])]?.[
        presentation === "inline" ? "inlineOpen" : "popoverOpen"
      ] === true
    : false;
}
export const EMPTY_SERVER_PROVIDERS: readonly unknown[] = [];
export const providersIgnoringCheckedAtAtom = serverEnvironment.providersValueAtom;
export const primaryServerKeybindingsAtom = Atom.make(
  (get) => get(platformSnapshotAtom)?.keybindings ?? DEFAULT_RESOLVED_KEYBINDINGS,
);
export function useEnvironmentsWithScope(
  environments: readonly { environmentId: string }[],
  scope: unknown,
) {
  const snapshot = usePlatformSnapshot();
  return new Set(
    environments
      .filter((value) => readEnvironmentScope(value.environmentId, scope, snapshot))
      .map((value) => value.environmentId),
  );
}

export function usePullRequestLinking() {
  const snapshot = usePlatformSnapshot();
  const supported = snapshot?.capabilities?.pullRequestLinking === true;
  return {
    mode: supported ? "supported" : "unsupported",
    canLink: (_url: string) => supported,
    isLinked: () => false,
    changeLink: async (threadRef: unknown, url: string, linked: boolean) => {
      await nativeAction({
        kind: linked ? "linkPullRequest" : "unlinkPullRequest",
        threadRef,
        url,
      });
    },
  };
}
export function useThreadRefs(enabled = true) {
  const snapshot = usePlatformSnapshot();
  return enabled && snapshot
    ? [
        {
          environmentId: snapshot.environmentId ?? snapshot.projectId,
          threadId: snapshot.sessionId,
        },
      ]
    : [];
}
export function useThreadShell(ref: { environmentId?: string; threadId?: string } | null) {
  const snapshot = usePlatformSnapshot();
  return readThreadShell(ref, snapshot);
}
export const useQuietThreadShell = useThreadShell;
export function readProjects(snapshot = getPlatformSnapshot()) {
  return (snapshot?.projects ?? []).map((project) => {
    if (project.repositoryIdentity || typeof project.originURL !== "string") return project;
    const provider = sourceControlClients.recognizeRemote(project.originURL);
    const remote = parseGitRemoteRepository(project.originURL);
    if (!provider || !remote) return project;
    return {
      ...project,
      repositoryIdentity: {
        canonicalKey: sourceControlClients.repositoryKeyFromRemote(project.originURL),
        displayName: remote.path,
        locator: { source: "git-remote", remoteName: "origin", remoteUrl: project.originURL },
        provider: provider.kind,
        ...(typeof project.workspaceRoot === "string" ? { rootPath: project.workspaceRoot } : {}),
      },
    };
  });
}
export function readProject(
  ref: { environmentId?: string; projectId?: string } | null,
  snapshot = getPlatformSnapshot(),
) {
  return ref
    ? (readProjects(snapshot).find(
        (project) => project.id === ref.projectId && project.environmentId === ref.environmentId,
      ) ?? null)
    : null;
}
export function useProject(ref: { environmentId?: string; projectId?: string } | null) {
  const snapshot = usePlatformSnapshot();
  return readProject(ref, snapshot);
}
export const environmentSession = {
  sessionStateAtom: Atom.family((environmentId: unknown) =>
    Atom.make((get) => {
      const snapshot = get(platformSnapshotAtom);
      return AsyncResult.success(
        readPreparedConnection(environmentId, snapshot)
          ? {
              authenticated: true,
              scopes: [
                ...(readEnvironmentScope(environmentId, "filesystem:read", snapshot)
                  ? ["filesystem:read"]
                  : []),
                ...(readEnvironmentScope(environmentId, "filesystem:write", snapshot)
                  ? ["filesystem:write"]
                  : []),
                ...(readEnvironmentScope(environmentId, "orchestration:operate", snapshot)
                  ? ["orchestration:operate"]
                  : []),
                ...(readEnvironmentScope(environmentId, "preview:operate", snapshot)
                  ? ["preview:operate"]
                  : []),
              ],
            }
          : null,
      );
    }),
  ),
};
export const environmentThreadShells = {
  threadShellsAtom: Atom.make((get) => {
    const snapshot = get(platformSnapshotAtom);
    if (!snapshot) return [];
    const shell = readThreadShell(
      { environmentId: snapshot.environmentId ?? snapshot.projectId, threadId: snapshot.sessionId },
      snapshot,
    );
    return shell ? [shell] : [];
  }),
};
export const projectFaviconUrlAtom = Atom.family(
  (target: { environmentId: string; cwd: string; faviconPath?: string | null }) =>
    Atom.make((get) => {
      const snapshot = get(platformSnapshotAtom);
      if (
        !target.faviconPath ||
        !readEnvironmentScope(target.environmentId, "filesystem:read", snapshot)
      )
        return null;
      const result = get(
        assetEnvironment.createUrl({
          environmentId: target.environmentId,
          input: { resource: { _tag: "media-file", path: target.faviconPath, cwd: target.cwd } },
        }) as any,
      );
      return AsyncResult.getOrElse(result as any, () => null)?.relativeUrl ?? null;
    }),
);
const pullRequestPreview = operation("pullRequestPreview");
export const pullRequestEnvironment = {
  previewCard: pullRequestPreview,
  preview: pullRequestPreview,
};
export function useAssistantMessageText(
  ref: { environmentId?: string; threadId?: string } | null,
  itemId: string | undefined,
) {
  const snapshot = usePlatformSnapshot();
  if (!snapshot || !readThreadShell(ref, snapshot) || !itemId) return null;
  const item = snapshot.items.find((item) => item.id === itemId && item.kind === "assistant");
  return typeof item?.text === "string" ? item.text : null;
}
function threadProjection(
  ref: { environmentId?: string; threadId?: string } | null,
  snapshot = getPlatformSnapshot(),
) {
  const shell = readThreadShell(ref, snapshot);
  if (!snapshot || !shell) return null;
  const projection = projectNativeSnapshot(snapshot);
  return {
    ...shell,
    projection: {
      thread: shell,
      messages: projection.timelineEntries.flatMap((entry: any) =>
        entry.kind === "message" ? [entry.message] : [],
      ),
      items: projection.timelineEntries.flatMap((entry: any) =>
        entry.kind === "work" && entry.entry.projectedItem ? [entry.entry.projectedItem] : [],
      ),
      runs: projection.runs,
      subagents: snapshot.subagents ?? [],
    },
  };
}
export function useThreadProjection(ref: { environmentId?: string; threadId?: string } | null) {
  const snapshot = usePlatformSnapshot();
  return useMemo(
    () => threadProjection(ref, snapshot),
    [snapshot, ref?.environmentId, ref?.threadId],
  );
}
export const environmentThreadDetails = {
  threadAtom: Atom.family((ref: { environmentId?: string; threadId?: string } | null) =>
    Atom.make((get) => {
      const snapshot = get(platformSnapshotAtom);
      return threadProjection(ref, snapshot);
    }),
  ),
};

const closedRightPanel = { isOpen: false, activeSurfaceId: null, surfaces: [] };
export function selectThreadRightPanelState(states: Record<string, any>, ref: any) {
  return ref
    ? (states[JSON.stringify([ref.environmentId, ref.threadId])] ?? closedRightPanel)
    : closedRightPanel;
}
export const primaryServerEnvironmentThemesAtom = Atom.make(
  (get) => get(platformSnapshotAtom)?.serverConfig?.environmentThemes ?? [],
);
export function useServerConfigs() {
  const snapshot = usePlatformSnapshot();
  const environment = snapshot?.environmentId ?? snapshot?.projectId;
  return environment && nativeServerConfig(snapshot)
    ? new Map([[environment, nativeServerConfig(snapshot)]])
    : new Map();
}
