import {
  readFileSync,
  realpathSync,
  mkdirSync,
  readdirSync,
  statSync,
  writeFileSync,
  copyFileSync,
  existsSync,
  renameSync,
  rmSync,
} from "node:fs";
import { resolve, dirname, relative } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createHash } from "node:crypto";
import "./prepare.mjs";
import { rejectInvalidImports } from "./buildWarnings.mjs";
import { provenance, transformSource } from "./transformSource.mjs";
const root = dirname(fileURLToPath(import.meta.url));
const {
  checkout,
  destination: source,
  revision,
  sourceTreeSHA256,
  installedDependencies,
  sourceExtractions,
} = JSON.parse(readFileSync(resolve(root, ".work/source.json"), "utf8"));
const load = async (path) =>
  import(pathToFileURL(resolve(checkout, "apps/web/node_modules", path)).href);
const { build } = await load("vite-plus/dist/index.js");
const { default: react } = await load("@vitejs/plugin-react/dist/index.js");
const { default: tailwind } = await load("@tailwindcss/vite/dist/index.mjs");
const { thirdPartyLicensesPlugin } = await import(
  pathToFileURL(resolve(source, "scripts/lib/third-party-licenses.ts")).href
);
const platformAliases = resolve(root, "src/platform/aliases.json");
const aliases = existsSync(platformAliases)
  ? JSON.parse(readFileSync(platformAliases, "utf8"))
  : {};
const pierreRoot = realpathSync(resolve(checkout, "apps/web/node_modules/@pierre/diffs"));
const highlightsRoot = realpathSync(resolve(pierreRoot, "../highlights"));
const themingRoot = realpathSync(resolve(pierreRoot, "../theming"));
const textmateRoot = realpathSync(resolve(themingRoot, "../theme"));
const smoke = process.env.CONVERSATION_SMOKE === "1";
const qaEntry = process.env.CONVERSATION_QA_ENTRY;
const finalOutput = qaEntry
  ? resolve(root, ".work", qaEntry)
  : process.env.CONVERSATION_OUTPUT
    ? resolve(root, process.env.CONVERSATION_OUTPUT)
    : smoke
      ? resolve(root, ".work/smoke")
      : resolve(root, "../../Sources/TabApp/Resources/ConversationRenderer");
const output = resolve(root, ".work", `building-${qaEntry ?? (smoke ? "smoke" : "full")}`);
const sourceRoot = resolve(source, "apps/web/src");
function appPath(path) {
  for (const base of [source, checkout, realpathSync(checkout)])
    if (path.startsWith(base + "/")) return path.slice(base.length + 1);
  return undefined;
}
function inputManifest() {
  const files = [];
  function scan(directory) {
    for (const name of readdirSync(directory).sort()) {
      const path = resolve(directory, name);
      if (statSync(path).isDirectory()) scan(path);
      else
        files.push({
          path: relative(root, path),
          sha256: createHash("sha256").update(readFileSync(path)).digest("hex"),
        });
    }
  }
  scan(resolve(root, "src"));
  for (const name of [
    "index.html",
    "build.mjs",
    "buildWarnings.mjs",
    "transformSource.mjs",
    "provenance.json",
    "prepare.mjs",
    "verifyDependencies.mjs",
    "extractThreadFind.mjs",
    "extractSourcePreview.mjs",
    ".work/readOnlySourcePreview.tsx",
    ".work/htmlRenderDocument.tsx",
    ".work/threadFindSelection.ts",
    "PINNED_REVISION",
  ])
    files.push({
      path: name,
      sha256: createHash("sha256")
        .update(readFileSync(resolve(root, name)))
        .digest("hex"),
    });
  return files;
}
const adapterInputs = inputManifest();
const fontPolicy = {
  interface: "upstream native system stack",
  code: "upstream ui-monospace/SF Mono/Menlo stack",
  math: null,
};
const adapters = {
  name: "tab-native-application-adapters",
  enforce: "pre",
  load(id) {
    const path = id.split("?")[0];
    if (
      (["apps/web/src/", "packages/"].some(prefix => appPath(path)?.startsWith(prefix)) ||
        [
          resolve(root, ".work/htmlRenderDocument.tsx"),
          resolve(root, ".work/readOnlySourcePreview.tsx"),
        ].includes(path)) &&
      /\.(?:[cm]?[jt]sx?|css)$/.test(path)
    )
      return transformSource(readFileSync(path, "utf8"), path);
    if (!/[\\/]katex[\\/]dist[\\/]katex\.min\.css$/.test(path)) return;
    const original = readFileSync(path, "utf8");
    let faces = 0;
    const css = original.replace(/src:([^;}]+)(?=[;}])/g, (full, sources) => {
      if (!sources.includes(".woff2")) return full;
      faces++;
      return (
        "src:" +
        sources
          .split(",")
          .filter((value) => value.includes(".woff2"))
          .join(",")
      );
    });
    if (faces !== 20 || /url\([^)]*\.(?:ttf|woff)["')]/.test(css))
      throw new Error("Pinned KaTeX modern-font extraction changed.");
    fontPolicy.math = {
      source: "katex/dist/katex.min.css",
      version: JSON.parse(readFileSync(resolve(dirname(path), "../package.json"), "utf8")).version,
      sourceSHA256: createHash("sha256").update(original).digest("hex"),
      cssSHA256: createHash("sha256").update(css).digest("hex"),
      faces,
      formats: ["woff2"],
      reason: "User-requested native fonts; specialized equation metrics retained",
    };
    return css;
  },
  generateBundle() {
    if (process.env.CONVERSATION_AUDIT_MODULES !== "1") return;
    const modules = [...this.getModuleIds()]
      .filter((id) => appPath(id)?.startsWith("apps/web/src/"))
      .map((id) => {
        const info = this.getModuleInfo(id);
        return {
          path: appPath(id),
          id,
          imports: info?.importedIds ?? [],
          dynamicImports: info?.dynamicallyImportedIds ?? [],
        };
      });
    mkdirSync(resolve(root, ".work/qa"), { recursive: true });
    writeFileSync(resolve(root, ".work/qa/body-modules.json"), JSON.stringify(modules, null, 2));
  },
  async resolveId(id, importer, options) {
    if (id.startsWith("\0")) return;
    if (id.startsWith("@conversation/"))
      return this.resolve(
        provenance.packageNamespace + id.slice("@conversation/".length),
        resolve(sourceRoot, "__tab_entry.tsx"),
        { ...options, skipSelf: true },
      );
    if (id === "@pierre/highlights/themes/loader")
      return resolve(root, "src/platform/highlightThemes.ts");
    if (id === "@pierre/theming/themes") return resolve(root, "src/platform/textmateThemes.ts");
    if (id.startsWith("@tab-native/highlights/"))
      return resolve(
        highlightsRoot,
        "dist/themes",
        id.slice("@tab-native/highlights/".length) + ".js",
      );
    if (id.startsWith("@tab-native/textmate/"))
      return resolve(textmateRoot, "dist", id.slice("@tab-native/textmate/".length) + ".mjs");
    if (id === "@tab-native/terminal-output-source")
      return resolve(source, "packages/shared/src/terminalOutput.ts");
    if (id === provenance.packageNamespace + "shared/terminalOutput")
      return resolve(root, "src/platform/terminalOutput.ts");

    if ((smoke || qaEntry) && (id === resolve(root, "src/main.tsx") || id === "/src/main.tsx"))
      return resolve(
        root,
        qaEntry === "error-boundaries"
          ? "tests/errorBoundaryEntry.tsx"
          : qaEntry === "mcp-services"
            ? "tests/mcpServiceEntry.tsx"
            : "src/markdownSmoke.tsx",
      );
    const candidate =
      id.startsWith(".") && importer
        ? resolve(dirname(importer), id)
        : id.startsWith("~/")
          ? resolve(sourceRoot, id.slice(2))
          : id.startsWith("@conversation-source/")
            ? resolve(sourceRoot, id.slice(11))
            : id;
    const key = appPath(candidate);
    if (key) {
      const stripped = key.replace(/\.(?:tsx?|jsx?)$/, "");
      for (const [name, target] of Object.entries(aliases)) {
        if (name.replace(/\.(?:tsx?|jsx?)$/, "") === stripped)
          return resolve(root, "src/platform", target);
      }
    }
    if (
      !id.startsWith(".") &&
      !id.startsWith("/") &&
      !id.startsWith("~") &&
      !id.startsWith("@conversation-source") &&
      (importer?.startsWith(root + "/src") ||
        importer?.startsWith(root + "/tests") ||
        importer === resolve(root, ".work/readOnlySourcePreview.tsx") ||
        importer === resolve(root, ".work/htmlRenderDocument.tsx"))
    )
      return this.resolve(id, resolve(sourceRoot, "__tab_entry.tsx"), {
        ...options,
        skipSelf: true,
      });
  },
};
await build({
  configFile: false,
  root,
  base: "./",
  publicDir: false,
  plugins: [
    adapters,
    react({ compiler: true }),
    tailwind(),
    thirdPartyLicensesPlugin({
      bundleName: "web",
      configFile: resolve(source, "third-party-licenses.config.json"),
      packageManifests: [{ bundle: "web", path: resolve(source, "apps/web/package.json") }],
    }),
  ],
  resolve: {
    alias: { "@conversation-source": sourceRoot, "~": sourceRoot },
    dedupe: ["react", "react-dom"],
  },
  assetsInclude: ["**/*.wasm"],
  define: {
    "import.meta.env.DEV": "false",
    "import.meta.env.PROD": "true",
    "import.meta.env.MODE": '"production"',
    "import.meta.env.TAB_FEATURE_SECRETS": '""',
    "import.meta.env.VITE_TAB_RELAY_URL": '""',
    "import.meta.env.VITE_CLERK_PUBLISHABLE_KEY": '""',
  },
  build: {
    outDir: output,
    emptyOutDir: true,
    sourcemap: process.env.CONVERSATION_SOURCEMAPS === "1",
    target: "safari17",
    assetsInlineLimit: 0,
    rollupOptions: {
      onwarn: rejectInvalidImports,
      output: { assetFileNames: "assets/[name]-[hash][extname]" },
    },
  },
});
if (JSON.stringify(adapterInputs) !== JSON.stringify(inputManifest()))
  throw new Error("Renderer inputs changed during the build; rebuild the coherent batch.");
const manifest = [];
function collect(directory) {
  for (const name of readdirSync(directory).sort()) {
    const path = resolve(directory, name);
    if (statSync(path).isDirectory()) collect(path);
    else
      manifest.push({
        path: relative(output, path),
        bytes: statSync(path).size,
        sha256: createHash("sha256").update(readFileSync(path)).digest("hex"),
      });
  }
}
copyFileSync(resolve(source, "LICENSE"), resolve(output, "UPSTREAM-LICENSE.txt"));
collect(output);
writeFileSync(
  resolve(output, "manifest.json"),
  JSON.stringify(
    {
      provenance,
      revision,
      sourceTreeSHA256,
      installedDependencies,
      sourceExtractions,
      fontPolicy,
      themePolicy: {
        source: "existing native AppTheme, SyntaxColors and TerminalPalette",
        syntax: "source highlighter with CSS-variable theme; grammar and WASM unchanged",
        compatibilityFallbacks: ["pierre-light", "pierre-dark"],
        catalog: "two requested compatibility names only; no theme picker or catalog",
        userAuthorizedColorException: true,
      },
      entry: qaEntry ? `QA:${qaEntry}` : smoke ? "ChatMarkdown" : "MessagesTimeline",
      adapterInputs,
      lockSHA256: createHash("sha256")
        .update(readFileSync(resolve(source, "pnpm-lock.yaml")))
        .digest("hex"),
      files: manifest,
    },
    null,
    2,
  ) + "\n",
);
// Publish only a complete, licensed and input-coherent bundle. A failed build
// leaves the last known-good renderer available to the native fallback gate.
mkdirSync(dirname(finalOutput), { recursive: true });
const previous = finalOutput + ".previous";
rmSync(previous, { recursive: true, force: true });
if (existsSync(finalOutput)) renameSync(finalOutput, previous);
try {
  renameSync(output, finalOutput);
} catch (error) {
  if (existsSync(previous)) renameSync(previous, finalOutput);
  throw error;
}
rmSync(previous, { recursive: true, force: true });
console.log(
  `Bundled actual Tab conversation ${revision}: ${manifest.length} assets -> ${finalOutput}`,
);
