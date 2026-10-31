import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { createHash } from "node:crypto";

/** Extract unchanged pure selection functions without the server's SQLite runtime. */
export function extractThreadFind(root, checkout, revision) {
  const path = "apps/server/src/orchestration-v2/ThreadFind.ts";
  const original = execFileSync("git", ["-C", checkout, "show", `${revision}:${path}`], {
    encoding: "utf8",
  });
  const interfaces = original.slice(
    original.indexOf("interface FindRow {"),
    original.indexOf("class TextKey"),
  );
  const functions = original.match(
    /^function selectMatch\([\s\S]*?^}\n\nfunction resultForSelection\([\s\S]*?^}\n/m,
  )?.[0];
  if (!interfaces.startsWith("interface FindRow {") || !functions)
    throw new Error("Pinned thread-find extraction boundaries changed.");
  const generated = `// Unchanged pure functions from ${path} at ${revision}. upstream MIT license.\nimport type {OrchestrationV2ProjectedTurnItem,OrchestrationV2TurnItem,OrchestrationV2SearchThreadInput,OrchestrationV2SearchThreadResult,ThreadId,TurnItemId} from '@conversation/contracts';\n${interfaces}\n${functions}\nexport {selectMatch,resultForSelection};\n`;
  const generatedPath = ".work/threadFindSelection.ts";
  writeFileSync(resolve(root, generatedPath), generated);
  return {
    path,
    revision,
    sha256: createHash("sha256").update(original).digest("hex"),
    functions: ["selectMatch", "resultForSelection"],
    generatedPath,
    generatedSHA256: createHash("sha256").update(generated).digest("hex"),
  };
}
