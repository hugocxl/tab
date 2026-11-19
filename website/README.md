# Tab website

The site at **https://hugocxl.github.io/tab/**, built strictly from the
[@hugocxl design system](https://hugocxl.github.io/stack/design-system/) with icons from
[@hugocxl/icons](https://hugocxl.github.io/stack/icons/) and figures from
[@hugocxl/vectors](https://hugocxl.github.io/stack/vectors/). Every page uses the
`plain` layout.

| Page | Recipe | Source |
| --- | --- | --- |
| `index.html` | `home` | Product copy, the screenshot and the download button |
| `docs.html` | `docs` | Install, requirements, the server, remote Macs, the `tab` command, building |
| `changelog.html` | `changelog` | Generated from `CHANGELOG.md` |

## Build and check

From the repository root, with Node 22:

```sh
npm ci
npm run build:site   # website/ → _site/
npm run check:site   # links, anchors, assets, design system markup and recipe order
python3 -m http.server 8765 --bind 127.0.0.1 --directory _site
```

## Files

- `index.html`, `docs.html`, `changelog.html`: page templates. `{{head …}}`,
  `{{masthead}}` and `{{footer}}` come from `partials/`, `{{icon NAME}}` and
  `{{vector NAME}}` inline Stroke icons from the `@hugocxl/icons` package and
  vectors from `@hugocxl/vectors` at build time, and `{{version}}` and
  `{{changelog}}` come from `CHANGELOG.md`.
- `site.css`: the few site additions, using only `--ds-*` tokens.
- The design system isn't committed here: the build copies `system/` from the
  `@hugocxl/design-system` package (a dev dependency) into `_site/system/`, and
  the check compares it and every inlined icon and vector with the packages.
- `assets/tab-window.png`: the product screenshot. `assets/favicon.svg`: the
  small app icon.
- `MESSAGING.md`: positioning, reusable descriptions and claim boundaries.

Download links go to the latest GitHub release rather than a versioned disk image
that would become stale.

## Publish

The **Pages** workflow (`.github/workflows/pages.yml`) builds and checks the site
and deploys `_site/` to GitHub Pages for pushes to `main` that touch the site or
`CHANGELOG.md`, and can be dispatched manually. A design system release
dispatches it too. Each run installs the newest `@hugocxl/design-system`,
`@hugocxl/icons` and `@hugocxl/vectors` over the locked versions before
building. The repository's Pages source is **GitHub Actions**.
