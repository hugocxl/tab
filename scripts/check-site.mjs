// Check the built site in _site/: links, anchors, assets and the design system's
// page contract (DS markup, recipe order, accent budget, one filled button,
// icons from @hugocxl/icons only, plain layout only).
import { existsSync, readFileSync } from "node:fs";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const site = "_site";
const pages = { "index.html": "home", "docs.html": "docs", "changelog.html": "changelog" };
const docs = new Map(
  Object.keys(pages).map((name) => [name, new JSDOM(readFileSync(`${site}/${name}`, "utf8")).window.document]),
);
const local = (href) => !/^(https?:|mailto:|data:)/.test(href);
let links = 0;

for (const [name, doc] of docs) {
  for (const a of doc.querySelectorAll("a[href]")) {
    const href = a.getAttribute("href");
    if (!local(href)) continue;
    links++;
    const [path, hash] = href.split("#");
    const target = !path || path === "./" ? (path ? "index.html" : name) : path;
    assert.ok(existsSync(`${site}/${target}`), `${name}: missing ${href}`);
    if (hash) assert.ok(docs.get(target)?.getElementById(hash), `${name}: missing anchor ${href}`);
  }
  for (const element of doc.querySelectorAll("[src], link[href]")) {
    const path = (element.getAttribute("src") || element.getAttribute("href")).split(/[?#]/)[0];
    if (local(path)) assert.ok(existsSync(`${site}/${path}`), `${name}: missing asset ${path}`);
  }
  const ids = [...doc.querySelectorAll("[id]")].map((el) => el.id);
  assert.equal(new Set(ids).size, ids.length, `${name}: duplicate id`);
}

// Every page is a plain-layout design system page with the shared masthead and footer.
const linkList = (root) => [...root.querySelectorAll("a")].map((a) => `${a.textContent.trim()} ${a.getAttribute("href")}`);
const glyphs = /[←-⇿⌀-⏿■-➿⤀-⥿⬀-⯿\u{1F300}-\u{1FAFF}]/u;
for (const name of Object.keys(pages)) {
  const doc = docs.get(name);
  const body = doc.body;
  assert.ok(body.classList.contains("p9"), `${name}: body.p9`);
  assert.equal(body.dataset.layout, "plain", `${name}: plain layout`);
  assert.ok(!doc.querySelector('[data-layout="field"], [src*="gray-folds"]'), `${name}: no field layout`);
  assert.ok(doc.querySelector('head link[rel=stylesheet][href="system/p9.css"]'), `${name}: p9.css`);
  assert.ok(doc.querySelector('head script[src="system/theme.js"]:not([type])'), `${name}: theme.js`);
  assert.ok(doc.querySelector('head script[type=module][src="system/p9.js"]'), `${name}: p9.js`);
  assert.equal(body.firstElementChild.className, "p9-masthead", `${name}: masthead first`);
  assert.equal(body.lastElementChild.className, "p9-footer", `${name}: footer last`);
  assert.deepEqual(linkList(doc.querySelector(".p9-masthead")), [
    "Tab ./",
    "Docs docs.html",
    "Changelog changelog.html",
    "GitHub https://github.com/hugocxl/tab",
  ]);
  const theme = doc.querySelector(".p9-masthead > button.p9-theme[data-p9-theme][aria-label]");
  assert.ok(theme?.querySelector('svg.p9-icon[data-icon="contrast"]'), `${name}: theme button`);
  assert.deepEqual(linkList(doc.querySelector(".p9-footer")), [
    "Tab https://hugocxl.github.io/tab/",
    "Quickshot https://hugocxl.github.io/quickshot/",
    "AgentKit https://hugocxl.github.io/agentkit/",
    "GitHub https://github.com/hugocxl/tab",
    "License https://github.com/hugocxl/tab/blob/main/LICENSE",
    "@hugocxl https://github.com/hugocxl",
  ]);
  assert.ok(doc.querySelectorAll(".p9-accent, .p9-dot").length <= 2, `${name}: accent budget`);
  assert.ok(doc.querySelectorAll(".p9-button").length <= 1, `${name}: one filled button`);
  assert.equal(doc.querySelectorAll("main > article.p9-column.p9-opening").length, 1, `${name}: one column`);
  assert.equal(doc.querySelectorAll("main").length, 1, `${name}: one main`);

  // Artwork: Stroke icons and vectors only, no glyphs standing in for icons.
  for (const svg of doc.querySelectorAll("svg")) {
    const icon = svg.matches('.p9-icon[data-icon][viewBox="0 0 16 16"][aria-hidden="true"]');
    const vector = svg.matches('.p9-vector[data-vector][role="img"]') && svg.querySelector(":scope > title") && svg.closest(".p9-media, .p9-grid");
    assert.ok(icon || vector, `${name}: svg that is neither an icon nor a vector`);
    assert.ok(!svg.closest(".p9-accent, h1, h2, h3"), `${name}: artwork in a heading or accent`);
    assert.ok(!svg.hasAttribute("color") && !svg.hasAttribute("xmlns"), `${name}: unprocessed svg`);
  }
  for (const element of doc.querySelectorAll("a, button, .p9-label, h1, h2, h3")) {
    assert.doesNotMatch(element.textContent, glyphs, `${name}: symbol character in "${element.textContent.trim()}"`);
  }
  for (const img of doc.querySelectorAll("img")) {
    assert.ok(img.getAttribute("alt"), `${name}: image without alt`);
    assert.ok(img.closest("figure.p9-wide > .p9-media"), `${name}: image outside figure-wide`);
  }
  for (const figure of doc.querySelectorAll("figure.p9-wide")) {
    assert.match(figure.querySelector("figcaption.p9-caption > .p9-label")?.textContent ?? "", /^Fig\. \d{2} \/ \S/, `${name}: caption`);
  }
  for (const table of doc.querySelectorAll("table")) {
    assert.ok(table.classList.contains("p9-table") && table.parentElement.matches(".p9-table-scroll[tabindex]"), `${name}: table`);
  }
  for (const pre of doc.querySelectorAll("pre")) {
    assert.ok(pre.matches(".p9-code > pre[tabindex]") && pre.nextElementSibling?.matches("button[type=button]"), `${name}: code`);
  }
}

// Recipe order per page (DESIGN.md › Page recipes).
const kind = (el) =>
  el.matches(".p9-statement") ? "statement"
  : el.matches(".p9-title") ? "title"
  : el.matches(".p9-meta") ? "meta"
  : el.matches(".p9-section") ? "section"
  : el.matches("figure.p9-wide") ? "figure-wide"
  : el.matches(".p9-grid") ? "figure-grid"
  : el.matches(".p9-index") ? "index"
  : el.matches(".p9-button") ? "button"
  : `?${el.tagName}`;
const recipes = {
  home: /^statement( meta)? section (figure-wide|figure-grid)( section)*( button)?$/,
  docs: /^title( meta)? section( section| figure-wide)*$/,
  changelog: /^title( section)? index$/,
};
for (const [name, recipe] of Object.entries(pages)) {
  const doc = docs.get(name);
  const sequence = [...doc.querySelector("main > article").children].map(kind).join(" ");
  assert.match(sequence, recipes[recipe], `${name} (${recipe}) order: ${sequence}`);
  const lead = doc.querySelector("main > article > .p9-section");
  assert.ok(!lead.querySelector(":scope > h2"), `${name}: lead section has no heading`);
  for (const section of [...doc.querySelectorAll("main > article > .p9-section")].slice(1)) {
    assert.ok(section.querySelector(":scope > h2"), `${name}: section without heading`);
  }
}

// Home: one accent phrase, one status dot, the download button.
const home = docs.get("index.html");
assert.equal(home.querySelectorAll(".p9-statement .p9-accent").length, 1);
assert.equal(home.querySelectorAll(".p9-meta > li:first-child > .p9-dot").length, 1);
assert.equal(home.querySelector(".p9-button").getAttribute("href"), "https://github.com/hugocxl/tab/releases/latest");

// Changelog: one row per version in CHANGELOG.md, newest first.
const changelog = readFileSync("CHANGELOG.md", "utf8");
const versions = [...changelog.matchAll(/^## (\d+\.\d+\.\d+) - /gm)].map((m) => m[1]);
const rows = [...docs.get("changelog.html").querySelectorAll(".p9-index > li h3")].map((h) => h.textContent);
assert.deepEqual(rows, versions, "changelog rows");
assert.match(home.querySelector(".p9-meta").textContent, new RegExp(`Version ${versions[0].replaceAll(".", "\\.")}`));

// Site CSS stays inside the design system's tokens.
const css = readFileSync("website/site.css", "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
assert.doesNotMatch(css, /#[0-9a-f]{3,8}\b|rgba?\(|hsla?\(|oklch\(/i, "site.css: literal color");
assert.doesNotMatch(css, /box-shadow|text-shadow|gradient|font-family|font-weight|font-size|border-radius:\s*\d|\d+px/i, "site.css: off-token style");
for (const [, property] of css.matchAll(/var\((--[\w-]+)/g)) assert.match(property, /^--p9-/, `site.css: ${property}`);

console.log(`Site verified: ${docs.size} pages, ${links} local links, ${versions.length} changelog versions.`);
