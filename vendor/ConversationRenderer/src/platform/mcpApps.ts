import type { McpAppToolInfo } from "@conversation/contracts";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import { AsyncResult, Atom } from "effect/reactivity";
import { nativeAction } from "../bridge";
import { getPlatformSnapshot, platformSnapshotAtom, type PlatformSnapshot } from "./snapshot";

type Target = Record<string, unknown>;
type OperationName = "callTool" | "toolInfo" | "readResource" | "updateModelContext";
const capability = (operation: OperationName) => `mcpApps.${operation}`;
function requireOperation(
  operation: OperationName,
  target: Target,
  snapshot = getPlatformSnapshot(),
) {
  if (!snapshot || target.environmentId !== (snapshot.environmentId ?? snapshot.projectId))
    throw new Error("The MCP app belongs to an unavailable conversation environment.");
  if (snapshot.connectionState !== "live")
    throw new Error("MCP app operations are unavailable while the native connection is offline.");
  if (snapshot.capabilities?.[capability(operation)] !== true)
    throw new Error(
      `The native provider does not expose MCP app ${operation}. The supplied app can still be displayed.`,
    );
}
async function execute(operation: OperationName, target: Target, snapshot?: PlatformSnapshot) {
  requireOperation(operation, target, snapshot);
  return nativeAction({ kind: `mcpApps.${operation}`, ...target });
}
function command(operation: OperationName) {
  // The existing native command adapter preserves real failed AsyncResults; the
  // actual McpAppHost turns these failures into its source protocol refusals.
  return Object.assign(
    (_target: Target) => {
      throw new Error("MCP commands must be executed through useAtomCommand.");
    },
    {
      nativeKind: `mcpApps.${operation}`,
      execute: (target: Target) => execute(operation, target),
    },
  );
}
const toolInfoRequests = Atom.family((key: string) =>
  Atom.make(
    Effect.tryPromise({
      try: () => execute("toolInfo", JSON.parse(key)) as Promise<McpAppToolInfo>,
      catch: (error) => (error instanceof Error ? error : new Error(String(error))),
    }),
  ),
);
const toolInfoQueries = Atom.family((key: string) =>
  Atom.make((get) => {
    const snapshot = get(platformSnapshotAtom);
    try {
      requireOperation("toolInfo", JSON.parse(key), snapshot);
    } catch (error) {
      return AsyncResult.failure(
        Cause.fail(error instanceof Error ? error : new Error(String(error))),
      );
    }
    return get(toolInfoRequests(key));
  }),
);
/** Pure native seam: never constructs the upstream socket/auth runtime. */
export const mcpAppEnvironment = {
  callTool: command("callTool"),
  toolInfo: command("toolInfo"),
  readResource: command("readResource"),
  updateModelContext: command("updateModelContext"),
  toolInfoQuery: (target: Target) => toolInfoQueries(JSON.stringify(target)),
};
