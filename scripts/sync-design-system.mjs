// Vendor the P9 design system from the sibling checkout into website/system/.
// The copy is committed because CI has no sibling checkout.
//   node scripts/sync-design-system.mjs          copy ../design-system/system verbatim
//   node scripts/sync-design-system.mjs --check  fail if the vendored copy has drifted
import { cpSync, existsSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const source = new URL("../../design-system/system/", import.meta.url).pathname;
const target = new URL("../website/system/", import.meta.url).pathname;

if (!existsSync(source)) {
  console.error(`No design system checkout at ${source}. Clone hugocxl/design-system next to this repository.`);
  process.exit(1);
}

const files = (root) =>
  readdirSync(root, { recursive: true })
    .map(String)
    .filter((path) => statSync(join(root, path)).isFile() && !path.endsWith(".DS_Store"))
    .sort();

if (process.argv.includes("--check")) {
  const want = files(source);
  const have = existsSync(target) ? files(target) : [];
  const drift = [
    ...want.filter((path) => !have.includes(path) || !readFileSync(join(source, path)).equals(readFileSync(join(target, path)))),
    ...have.filter((path) => !want.includes(path)),
  ];
  if (drift.length) {
    console.error(`website/system differs from the design system: ${drift.join(", ")}. Run npm run sync:design-system.`);
    process.exit(1);
  }
  console.log(`website/system matches the design system (${want.length} files).`);
} else {
  rmSync(target, { recursive: true, force: true });
  cpSync(source, target, { recursive: true, filter: (path) => !path.endsWith(".DS_Store") });
  console.log(`Copied ${files(target).length} files from ${relative(process.cwd(), source) || source} to website/system.`);
}
