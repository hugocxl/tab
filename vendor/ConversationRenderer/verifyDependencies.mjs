import { readFileSync, realpathSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { createRequire } from "node:module";

const canonical = (value) =>
  JSON.stringify(value, (_key, current) =>
    current && typeof current === "object" && !Array.isArray(current)
      ? Object.fromEntries(Object.entries(current).sort(([a], [b]) => a.localeCompare(b)))
      : current,
  );
/** Accept a frozen filtered install only when every installed record belongs to the pinned lock. */
export function verifyInstalledDependencies(checkout) {
  const require = createRequire(
    realpathSync(resolve(checkout, "apps/web/node_modules/vite-plus/package.json")),
  );
  const yaml = require("yaml");
  const documents = yaml.parseAllDocuments(
    readFileSync(resolve(checkout, "pnpm-lock.yaml"), "utf8"),
  );
  for (const document of documents)
    if (document.errors.length) throw new Error("The pinned dependency lock is invalid.");
  const wanted = documents
    .map((document) => document.toJSON())
    .find((document) => document.importers?.["apps/web"]);
  if (!wanted) throw new Error("The pinned lock has no web application importer.");
  const installedPath = resolve(checkout, "node_modules/.pnpm/lock.yaml");
  if (!existsSync(installedPath))
    throw new Error(
      "The dependency installation has no pnpm lock state; run the pinned frozen install.",
    );
  const installed = yaml.parse(readFileSync(installedPath, "utf8"));
  for (const name of [
    "lockfileVersion",
    "settings",
    "catalogs",
    "overrides",
    "packageExtensionsChecksum",
    "pnpmfileChecksum",
    "patchedDependencies",
  ])
    if (canonical(wanted[name]) !== canonical(installed[name]))
      throw new Error(`Installed dependency ${name} differs from the pinned lock.`);
  for (const section of ["importers", "packages", "snapshots"])
    for (const [key, value] of Object.entries(installed[section] ?? {}))
      if (canonical(wanted[section]?.[key]) !== canonical(value))
        throw new Error(
          `Installed dependency record differs from the pinned lock: ${section}/${key}`,
        );
  if (canonical(installed.importers?.["apps/web"]) !== canonical(wanted.importers["apps/web"]))
    throw new Error("The installed web dependency graph differs from the pinned graph.");
  const metadata = yaml.parse(
    readFileSync(resolve(checkout, "node_modules/.modules.yaml"), "utf8"),
  );
  const expectedManager = JSON.parse(
    readFileSync(resolve(checkout, "package.json"), "utf8"),
  ).packageManager;
  if (metadata.packageManager !== expectedManager)
    throw new Error(`The dependency installation requires ${expectedManager}.`);
  return {
    packageManager: metadata.packageManager,
    installedPackages: Object.keys(installed.packages ?? {}).length,
  };
}
