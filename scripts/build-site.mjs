// Build the GitHub Pages site from website/ into _site/.
// Pages follow the @hugocxl design system, copied from the @hugocxl/design-system
// package, with Stroke icons from @hugocxl/icons and vectors from
// @hugocxl/vectors inlined at build time. The changelog page and the version
// come from CHANGELOG.md.
import { cpSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";

const out = "_site";
const read = (path) => readFileSync(path, "utf8");
const escape = (text) =>
  String(text).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

const designSystem = dirname(createRequire(import.meta.url).resolve("@hugocxl/design-system/package.json"));

// ─── Artwork: Stroke icons and vectors, inlined per DESIGN.md ──────────
// The names come from {{icon NAME}} and {{vector NAME}} in the templates.
const templates = [
  ...readdirSync("website").filter((name) => name.endsWith(".html")).map((name) => `website/${name}`),
  ...readdirSync("website/partials").map((name) => `website/partials/${name}`),
];
const artwork = { icon: new Map(), vector: new Map() };
for (const path of templates) {
  for (const [, kind, name] of read(path).matchAll(/\{\{(icon|vector) ([\w-]+)\}\}/g)) {
    if (artwork[kind].has(name)) continue;
    const module = kind === "icon" ? `@hugocxl/icons/js/stroke/${name}` : `@hugocxl/vectors/js/${name}`;
    artwork[kind].set(name, Object.values(await import(module))[0]);
  }
}
const inner = (svg) => svg.replace(/^[\s\S]*?<svg[^>]*>/, "").replace(/<\/svg>\s*$/, "").trim();
const icon = (name) =>
  `<svg class="ds-icon" data-icon="${name}" viewBox="0 0 16 16" fill="none" aria-hidden="true">${inner(artwork.icon.get(name)).replace(/\n\s*/g, "")}</svg>`;
const vector = (name) =>
  artwork.vector.get(name)
    .trim()
    .replace(/ xmlns="[^"]*"/, ` class="ds-vector" data-vector="${name}"`)
    .replace(/ color="[^"]*"/, "")
    .replace(/\n\s*/g, "");

// ─── Changelog ──────────────────────────────────────────────────────────
const inline = (text) =>
  escape(text)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2">$1</a>');

const versions = [];
for (const line of read("CHANGELOG.md").split("\n")) {
  const version = line.match(/^## (\d+\.\d+\.\d+) - (\d{4}-\d{2}-\d{2})$/);
  if (version) versions.push({ number: version[1], date: version[2], groups: [] });
  else if (!versions.length) continue;
  else if (line.startsWith("### ")) versions.at(-1).groups.push({ name: line.slice(4).trim(), entries: [] });
  else if (line.startsWith("- ")) versions.at(-1).groups.at(-1).entries.push(line.slice(2).trim());
  else if (/^\s+\S/.test(line)) {
    const entries = versions.at(-1).groups.at(-1).entries;
    entries[entries.length - 1] += ` ${line.trim()}`;
  }
}
if (!versions.length) throw new Error("No versions in CHANGELOG.md");

const longDate = (iso, month = "long") =>
  new Date(`${iso}T00:00:00Z`).toLocaleDateString("en-GB", { day: "numeric", month, year: "numeric", timeZone: "UTC" });
const changelog = [
  '      <ol class="ds-index">',
  ...versions.map(({ number, date, groups }) => {
    const text = groups
      .filter((group) => group.entries.length)
      .map((group) => `<p><strong>${escape(group.name)}.</strong> ${group.entries.map(inline).join(" ")}</p>`)
      .join("");
    return `        <li id="v${number}"><span class="ds-label"><time datetime="${date}">${longDate(date, "short")}</time></span><div><h3>${number}</h3>${text}</div></li>`;
  }),
  "      </ol>",
].join("\n");

const latest = versions[0];
const values = {
  version: latest.number,
  date: latest.date,
  "date-long": longDate(latest.date),
  changelog,
};

// ─── Templates ──────────────────────────────────────────────────────────
const partial = (name) => read(`website/partials/${name}.html`).replace(/\n$/, "");
function render(template) {
  const html = template
    .replace(/\{\{head ([^}]*)\}\}/, (_, args) => {
      const attributes = Object.fromEntries([...args.matchAll(/(\w+)="([^"]*)"/g)].map((m) => [m[1], m[2]]));
      return partial("head").replace(/\{\{(\w+)\}\}/g, (__, key) => attributes[key] ?? "");
    })
    .replace("{{masthead}}", partial("masthead"))
    .replace("{{footer}}", partial("footer"))
    .replace(/\{\{icon ([\w-]+)\}\}/g, (_, name) => icon(name))
    .replace(/\{\{vector ([\w-]+)\}\}/g, (_, name) => vector(name))
    .replace(/\{\{([\w-]+)\}\}/g, (match, key) => (key in values ? values[key] : match));
  const unknown = html.match(/\{\{[^}]*\}\}/);
  if (unknown) throw new Error(`Unknown template value ${unknown[0]}`);
  return html;
}

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
cpSync(join(designSystem, "system"), `${out}/system`, { recursive: true, filter: (path) => !path.endsWith(".DS_Store") });
cpSync("website/assets", `${out}/assets`, { recursive: true, filter: (path) => !path.endsWith(".DS_Store") });
cpSync("website/site.css", `${out}/site.css`);
for (const page of ["index.html", "docs.html", "changelog.html"]) {
  writeFileSync(`${out}/${page}`, render(read(`website/${page}`)));
}
writeFileSync(`${out}/.nojekyll`, "");
console.log(`Built site for Tab ${latest.number} with ${versions.length} changelog versions.`);
