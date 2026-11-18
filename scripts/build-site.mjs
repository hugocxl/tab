// Build the GitHub Pages site from website/ into _site/.
// Pages follow the @hugocxl design system vendored in website/system
// (scripts/sync-design-system.mjs), with icons and vectors vendored in
// website/art (scripts/sync-artwork.mjs). The changelog page and the version
// come from CHANGELOG.md.
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";

const out = "_site";
const read = (path) => readFileSync(path, "utf8");
const escape = (text) =>
  String(text).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

// ─── Artwork: Stroke icons and vectors, inlined per DESIGN.md ──────────
const inner = (svg) => svg.replace(/^[\s\S]*?<svg[^>]*>/, "").replace(/<\/svg>\s*$/, "").trim();
const icon = (name) =>
  `<svg class="ds-icon" data-icon="${name}" viewBox="0 0 16 16" fill="none" aria-hidden="true">${inner(read(`website/art/icons/${name}.svg`)).replace(/\n\s*/g, "")}</svg>`;
const vector = (name) =>
  read(`website/art/vectors/${name}.svg`)
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
cpSync("website/system", `${out}/system`, { recursive: true, filter: (path) => !path.endsWith(".DS_Store") });
cpSync("website/assets", `${out}/assets`, { recursive: true, filter: (path) => !path.endsWith(".DS_Store") });
cpSync("website/site.css", `${out}/site.css`);
for (const page of ["index.html", "docs.html", "changelog.html"]) {
  writeFileSync(`${out}/${page}`, render(read(`website/${page}`)));
}
writeFileSync(`${out}/.nojekyll`, "");
console.log(`Built site for Tab ${latest.number} with ${versions.length} changelog versions.`);
