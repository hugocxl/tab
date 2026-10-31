import { provenance } from "./transformSource.mjs";
import { readFileSync, writeFileSync, unlinkSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
const root = dirname(fileURLToPath(import.meta.url));
const { checkout } = JSON.parse(readFileSync(resolve(root, ".work/source.json"), "utf8"));
const target = resolve(
  checkout,
  "apps/web/src/components/chat/TabNativeSnapshot.generated.browser.test.tsx",
);
const projectionTarget = resolve(
  checkout,
  "apps/web/src/components/chat/TabNativeProjection.generated.ts",
);
writeFileSync(
  projectionTarget,
  readFileSync(resolve(root, "src/projectNativeSnapshot.ts"), "utf8")
    .replaceAll("@conversation-source/", "~/")
    .replaceAll("@conversation/", provenance.packageNamespace),
);
const fixture = readFileSync(
  resolve(root, "tests/projectNativeSnapshot.browser.tsx"),
  "utf8",
).replace("__TAB_NATIVE_PROJECTION_MODULE__", "./TabNativeProjection.generated");
writeFileSync(
  target,
  fixture
    .replaceAll("@conversation/", provenance.packageNamespace)
    .replaceAll("tabMcpApp", provenance.legacyMcpOutputKey),
);
try {
  const result = spawnSync(
    "pnpm",
    [
      "--dir",
      resolve(checkout, "apps/web"),
      "exec",
      "vp",
      "test",
      "run",
      "--project",
      "browser",
      "src/components/chat/TabNativeSnapshot.generated.browser.test.tsx",
    ],
    { stdio: "inherit" },
  );
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 1;
} finally {
  unlinkSync(target);
  unlinkSync(projectionTarget);
}
