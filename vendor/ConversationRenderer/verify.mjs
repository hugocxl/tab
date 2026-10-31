import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
const root = dirname(fileURLToPath(import.meta.url));
const directory = resolve(
  root,
  process.env.CONVERSATION_BUNDLE ?? "../../Sources/TabApp/Resources/ConversationRenderer",
);
const manifest = JSON.parse(readFileSync(resolve(directory, "manifest.json"), "utf8"));
const revision = readFileSync(resolve(root, "PINNED_REVISION"), "utf8").trim();
if (process.argv.includes("--check-inputs") || process.env.CONVERSATION_VERIFY_SOURCE === "1") {
  if (!manifest.adapterInputs?.length)
    throw new Error("The renderer has no source input manifest; rebuild it.");
  const current = [];
  function scanInputs(directory) {
    for (const name of readdirSync(directory).sort()) {
      const path = resolve(directory, name);
      if (statSync(path).isDirectory()) scanInputs(path);
      else current.push(path.slice(root.length + 1));
    }
  }
  scanInputs(resolve(root, "src"));
  const recorded = new Set(manifest.adapterInputs.map((input) => input.path));
  for (const path of current)
    if (!recorded.has(path)) throw new Error(`Renderer source added after the build: ${path}`);
  for (const input of manifest.adapterInputs) {
    const path = resolve(root, input.path);
    if (
      !path.startsWith(root + "/") ||
      !existsSync(path) ||
      createHash("sha256").update(readFileSync(path)).digest("hex") !== input.sha256
    )
      throw new Error(`Renderer source changed after the build: ${input.path}`);
  }
}
if (manifest.revision !== revision)
  throw new Error("Renderer revision does not match the pinned source");
for (const file of manifest.files) {
  const path = resolve(directory, file.path);
  if (!path.startsWith(directory + "/") || !existsSync(path))
    throw new Error(`Missing or invalid asset ${file.path}`);
  const content = readFileSync(path);
  if (
    content.length !== file.bytes ||
    createHash("sha256").update(content).digest("hex") !== file.sha256
  )
    throw new Error(`Changed renderer asset ${file.path}`);
}
for (const required of ["index.html", "UPSTREAM-LICENSE.txt", "third-party-licenses.json"])
  if (!manifest.files.some((file) => file.path === required))
    throw new Error(`Missing renderer notice or entry ${required}`);
const expected = new Set(["manifest.json", ...manifest.files.map((file) => file.path)]);
function inspect(directoryPath, prefix = "") {
  for (const name of readdirSync(directoryPath)) {
    const path = resolve(directoryPath, name),
      relative = prefix + name;
    if (statSync(path).isDirectory()) inspect(path, relative + "/");
    else if (!expected.has(relative)) throw new Error(`Untracked renderer asset ${relative}`);
  }
}
inspect(directory);
console.log(`Verified ${manifest.files.length} offline renderer assets at ${revision}`);
