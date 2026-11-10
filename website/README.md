# Tab website

A static website for **https://hugocxl.github.io/tab/**. Plain HTML and CSS, with
local assets, a bundled heading font, and no JavaScript, dependencies, analytics, or build
step. Relative asset paths support GitHub Pages' `/tab/` project path.

## Preview

From the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1
```

Open `http://127.0.0.1:8765/website/`. Inside Tab, keep the preview server in a
session or terminal pane with `tab session new -- python3 -m http.server 8765
--bind 127.0.0.1`.

## Publish with GitHub Pages

1. In the repository's **Settings → Pages**, select **GitHub Actions** as the
   source. This repository is configured to use GitHub Actions; repeat this
   one-time setup only for a new fork.
2. Commit and push the website and `.github/workflows/website.yml` to `main`
   following the repository's changelog and validation rules. Pushing to `main`
   also triggers the app's existing release workflow.
3. The **Website** workflow uploads only `index.html`, `styles.css`, and `assets/`
   and deploys them to the `github-pages` environment. It runs for website changes
   on `main` and can also be dispatched manually on `main`.
4. Verify the deployed URL before announcing it, then set the repository homepage
   to `https://hugocxl.github.io/tab/`.

No custom domain or `CNAME` file is needed. Deployment follows GitHub's
[custom Pages workflow documentation](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).

## Content and assets

- `index.html`: product copy, metadata, links, and native HTML FAQ disclosure.
- `styles.css`: responsive layouts, visible keyboard focus, reduced-motion support.
- `assets/mascot.svg`: the existing mascot from `packaging/AppIcon.svg`, with its
  app-icon tile removed and its view box fitted to the character. The root README
  uses this same asset.
- `assets/fonts/`: Junicode Regular Latin, downloaded from Peek for H1/H2 headings,
  with its SIL Open Font License. Body text and smaller headings use system fonts.
- `assets/favicon.svg`: the existing small app icon.
- Pane icons: copied from Tab’s own `Sources/TabApp/Resources/TabIcons` set.
- `assets/tab-window.png`: the supplied product screenshot, also stored in
  `media/tab-window.png`; replace both together when updating the screenshot.
- `MESSAGING.md`: positioning, reusable descriptions, and reference analysis.

Download links go to the latest GitHub release, rather than a versioned DMG that
would become stale. Native agent panes require the user's installed, authenticated
provider CLI. Avoid claims about bundled subscriptions or work continuing while
the host Mac sleeps.
