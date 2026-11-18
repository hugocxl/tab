// Vendor the icons and vectors the site uses from the sibling @hugocxl/icons and
// @hugocxl/vectors checkouts into website/art/. The copies are committed because
// CI has no sibling checkouts. The names come from {{icon NAME}} and
// {{vector NAME}} in the page templates.
//   node scripts/sync-artwork.mjs          copy what the templates use, verbatim
//   node scripts/sync-artwork.mjs --check  fail if a copy is missing, stale or unused
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";

const root = new URL("../", import.meta.url).pathname;
const sources = {
  icons: join(root, "../icons/icons/styles/stroke"),
  vectors: join(root, "../vectors/figures"),
};
const target = join(root, "website/art");

const templates = [
  ...readdirSync(join(root, "website")).filter((name) => name.endsWith(".html")).map((name) => join(root, "website", name)),
  ...readdirSync(join(root, "website/partials")).map((name) => join(root, "website/partials", name)),
];
const used = { icons: new Set(), vectors: new Set() };
for (const path of templates) {
  for (const [, kind, name] of readFileSync(path, "utf8").matchAll(/\{\{(icon|vector) ([\w-]+)\}\}/g)) {
    used[kind === "icon" ? "icons" : "vectors"].add(name);
  }
}

const check = process.argv.includes("--check");
const problems = [];
for (const [kind, names] of Object.entries(used)) {
  const dir = join(target, kind);
  if (!check) {
    rmSync(dir, { recursive: true, force: true });
    mkdirSync(dir, { recursive: true });
  }
  for (const name of [...names].sort()) {
    const from = join(sources[kind], `${name}.svg`);
    const to = join(dir, `${name}.svg`);
    if (!check) {
      if (!existsSync(from)) {
        console.error(`No ${kind} artwork named ${name} at ${from}.`);
        process.exit(1);
      }
      copyFileSync(from, to);
    } else if (!existsSync(to)) problems.push(`missing ${kind}/${name}.svg`);
    else if (existsSync(from) && !readFileSync(from).equals(readFileSync(to))) problems.push(`stale ${kind}/${name}.svg`);
  }
  if (check && existsSync(dir)) {
    for (const file of readdirSync(dir)) if (!names.has(file.replace(/\.svg$/, ""))) problems.push(`unused ${kind}/${file}`);
  }
}

if (problems.length) {
  console.error(`website/art differs from the templates: ${problems.join(", ")}. Run npm run sync:artwork.`);
  process.exit(1);
}
console.log(`${check ? "website/art matches" : "Copied"} ${used.icons.size} icons and ${used.vectors.size} vectors${check ? "." : " to website/art."}`);
