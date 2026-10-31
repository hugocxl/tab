import { AsyncResult } from "effect/reactivity";
import * as Cause from "effect/Cause";
import { nativeAction } from "../bridge";
export class PreferredEditorEnvironmentRequiredError extends Error {
  constructor(input: { targetPath: string }) {
    super(`Cannot open ${input.targetPath} because no environment is selected.`);
  }
}
export function usePreferredEditor(_available: unknown) {
  return ["tab-native", () => {}] as const;
}
export function useOpenInPreferredEditor(environmentId: unknown, _available: unknown) {
  return async (path: string) => {
    try {
      if (!environmentId) throw new PreferredEditorEnvironmentRequiredError({ targetPath: path });
      await nativeAction({
        kind: "openEditor",
        environmentId,
        input: { cwd: path, editor: "tab-native" },
      });
      return AsyncResult.success("tab-native");
    } catch (error) {
      return AsyncResult.failure(Cause.fail(error));
    }
  };
}
export function openInEditorMenuLabel() {
  return "Open in Tab";
}
