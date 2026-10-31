import {
  appendCodexArtifactTemplateUsePrompt,
  type CodexArtifactTemplate,
} from "@conversation/shared/codexArtifactTemplates";
import { nativeAction } from "../bridge";
import { getPlatformSnapshot } from "./snapshot";

/** Exact source prompt/dedup semantics, with an atomic native draft check across the bridge. */
export async function insertArtifactTemplate(template: CodexArtifactTemplate): Promise<void> {
  if (getPlatformSnapshot()?.capabilities?.useArtifactTemplate !== true)
    throw new Error("Template insertion is unavailable in this conversation.");
  const current = (await nativeAction({ kind: "useArtifactTemplate", phase: "read" })) as {
    prompt: string;
  };
  if (typeof current?.prompt !== "string")
    throw new Error("The native composer did not provide its current draft.");
  const next = appendCodexArtifactTemplateUsePrompt(current.prompt, template);
  await nativeAction({
    kind: "useArtifactTemplate",
    phase: "append",
    expectedPrompt: current.prompt,
    append: next.slice(current.prompt.length),
  });
}
