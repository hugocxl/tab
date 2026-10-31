import { execFileSync } from "node:child_process";
import { readFileSync, mkdirSync, existsSync, symlinkSync, writeFileSync, rmSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { extractSourcePreview } from "./extractSourcePreview.mjs";
import { extractThreadFind } from "./extractThreadFind.mjs";
import { verifyInstalledDependencies } from "./verifyDependencies.mjs";
import { provenance } from "./transformSource.mjs";
const root = dirname(fileURLToPath(import.meta.url));
const revision = readFileSync(resolve(root, "PINNED_REVISION"), "utf8").trim();
const checkout = resolve(process.env.CONVERSATION_SOURCE ?? resolve(root, ".work/checkout"));
if (!existsSync(resolve(checkout, ".git"))) {
  mkdirSync(dirname(checkout), { recursive: true });
  execFileSync(
    "git",
    ["clone", "--filter=blob:none", "--no-checkout", provenance.repository + ".git", checkout],
    { stdio: "inherit" },
  );
  execFileSync("git", ["-C", checkout, "checkout", "--detach", revision], { stdio: "inherit" });
}
// Application dependencies must resolve the same tracked source used by git archive.
const dependencyManifests = execFileSync(
  "git",
  [
    "-C",
    checkout,
    "ls-tree",
    "-r",
    "--name-only",
    revision,
    "--",
    "package.json",
    "pnpm-lock.yaml",
    "pnpm-workspace.yaml",
    ".pnpmfile.cjs",
    "pnpmfile.cjs",
    ".npmrc",
    "apps",
    "packages",
    "scripts",
    "infra",
    "evals",
    "oxlint-plugin-" + provenance.repository.split("/").at(-1),
  ],
  { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 },
)
  .trim()
  .split("\n")
  .filter(
    (path) =>
      path === "package.json" ||
      path.endsWith("/package.json") ||
      ["pnpm-lock.yaml", "pnpm-workspace.yaml", ".pnpmfile.cjs", "pnpmfile.cjs", ".npmrc"].includes(
        path,
      ),
  );
execFileSync("git", [
  "-C",
  checkout,
  "diff",
  "--quiet",
  revision,
  "--",
  "packages",
  "patches",
  ...dependencyManifests,
]);
if (!existsSync(resolve(checkout, "apps/web/node_modules/vite-plus/package.json"))) {
  execFileSync("pnpm", ["install", "--frozen-lockfile", "--ignore-scripts"], {
    cwd: checkout,
    stdio: "inherit",
  });
}
const installedDependencies = verifyInstalledDependencies(checkout);
const actual = execFileSync("git", ["-C", checkout, "rev-parse", revision], {
  encoding: "utf8",
}).trim();
if (actual !== revision) throw new Error("Pinned source revision is unavailable");
const licenseFiles = [];
function collectLicenseFiles(value) {
  if (!value || typeof value !== "object") return;
  for (const [key, nested] of Object.entries(value)) {
    if (key === "noticeFile" && typeof nested === "string") licenseFiles.push(nested);
    else collectLicenseFiles(nested);
  }
}
collectLicenseFiles(
  JSON.parse(
    execFileSync("git", ["-C", checkout, "show", `${revision}:third-party-licenses.config.json`], {
      encoding: "utf8",
    }),
  ),
);
const destination = resolve(root, ".work/upstream");
mkdirSync(destination, { recursive: true });
// Always re-extract the pinned archive: cached source must never override provenance.
rmSync(destination, { recursive: true, force: true });
mkdirSync(destination, { recursive: true });
const archive = execFileSync(
  "git",
  [
    "-C",
    checkout,
    "archive",
    revision,
    "apps/web/src",
    "apps/web/public",
    "apps/web/package.json",
    "packages",
    "LICENSE",
    "third-party-licenses",
    "third-party-licenses.config.json",
    "pnpm-lock.yaml",
    "package.json",
    "pnpm-workspace.yaml",
    "tsconfig.base.json",
    "scripts/lib/third-party-licenses.ts",
    "apps/server/src/device/deviceToolVersions.json",
    ...licenseFiles,
  ],
  { maxBuffer: 256 * 1024 * 1024 },
);
execFileSync("tar", ["-xf", "-", "-C", destination], {
  input: archive,
  maxBuffer: 256 * 1024 * 1024,
});

for (const path of [
  "node_modules",
  "apps/web/node_modules",
  ...execFileSync("git", ["-C", checkout, "ls-tree", "--name-only", `${revision}:packages`], {
    encoding: "utf8",
  })
    .trim()
    .split("\n")
    .map((name) => `packages/${name}/node_modules`),
]) {
  const from = resolve(checkout, path),
    to = resolve(destination, path);
  if (existsSync(from) && !existsSync(to)) {
    mkdirSync(dirname(to), { recursive: true });
    symlinkSync(from, to, "dir");
  }
}
writeFileSync(
  resolve(root, ".work/source.json"),
  JSON.stringify(
    {
      revision,
      checkout,
      destination,
      installedDependencies,
      sourceExtractions: [
        extractThreadFind(root, checkout, revision),
        ...extractSourcePreview(root, checkout, revision),
      ],
      sourceTreeSHA256: createHash("sha256")
        .update(
          execFileSync("git", [
            "-C",
            checkout,
            "ls-tree",
            "-r",
            revision,
            "apps/web/src",
            "apps/server/src/orchestration-v2/ThreadFind.ts",
            "packages",
            "apps/web/package.json",
            "pnpm-lock.yaml",
            "scripts/lib/third-party-licenses.ts",
            "apps/server/src/device/deviceToolVersions.json",
            ...licenseFiles,
            "third-party-licenses.config.json",
            "tsconfig.base.json",
          ]),
        )
        .digest("hex"),
    },
    null,
    2,
  ) + "\n",
);
console.log(`Prepared conversation renderer source ${revision}`);
