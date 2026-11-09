# Tab Icons drawing guide

Measured from the 373 SVGs in upstream package 0.9.0. Coordinates below are SVG
user units, not device pixels. This guide describes geometry, including the
exceptions; do not impose a uniform inset or rounded-rectangle recipe.

## Canvas and optical size

- Default `viewBox="0 0 16 16"`: 340/373 files. Preserve it verbatim on import.
- Other canvases: 18×16 (17), 16×17 (5), 10×16 (3), 12×16 (3), and one each of
  24×16, 8×16, 17×17, 19×16, 11×16. All start at 0,0.
- Use a 16-unit height for new standard glyphs. A wide glyph may extend the
  viewBox width (folder is 18×16, brand mark reaches 24×16); narrow marks can
  have narrow viewBoxes. Never squeeze path coordinates into a square.
- Preserve aspect ratio at display time. The sheet fits the entire viewBox into
  the requested square point-size slot and centers it, including wide glyphs.
- Margins are optical, not globally 1pt: folder bounds are x=1…17, y=1…15;
  app container x=0…16, y=1…15; full circle and terminal squircle x/y=0…16.
  Plus bounds are 3…13 on both axes, small filled squircle also 3…13.
- Chevron centerline is (2,5) → (8,11) → (14,5), with radius .75 caps/joins:
  true outline bounds x=1.25…14.75, y=4.25…11.75 (rounded decimal exports).
  Do not mistake cubic control points for curve extrema or add extra padding.

## Weight, ends and corners

- Standard monoline width is **1.5**. Draw centerlines, expand to filled
  outlines, then union overlaps. No SVG `stroke` attributes in delivered icons.
- Round caps have radius **.75**; a straight horizontal shaft centered at y=8
  has edges y=7.25 and 8.75. Cap centers terminate .75 before the visible end.
- Use round joins with the same .75 radius. At 45°, offsets are
  .75/√2 = .530330086; this explains recurring .46967/.53033 coordinates.
- Cubic quarter-circle control offset is approximately .55228475 × radius:
  .41421356 for radius .75. Keep upstream decimals; do not snap curved outlines
  to integer pixels. Axis-aligned edges commonly fall on quarter/half units.
- Rounded rect containers commonly use outer radius **2.25**, inner radius
  **.75** (difference 1.5). In the app container, outer x=0…16/y=1…15;
  corner centers x=2.25/13.75, y=3.25/12.75. Inner edges inset by 1.5.
  This is not the rule for every shape: document corners can be radius 2.75,
  and small toolbar bars use radius .5.

## Construction recipes

- Chevron: two 45° segments, expanded as one joined contour, round tips and
  outer elbow. Rotate the geometry for directional variants without changing
  weight. Smaller chevrons use shorter centerlines, not thinner strokes.
- Plus: union perpendicular 1.5-wide bars, .75-radius round ends. The reference
  has center (8,8), shaft centerlines 3.75…12.25, visible extent 3…13.
- Arrow: union a 1.5-wide shaft and two 45° head segments. Right arrow shaft
  centerline runs from (1.75,8) to the head at (14.25,8); head end centers are
  (9,2.75)/(9,13.25). Visible bounds x=1…15, y=2…14. Use the merged outline
  rather than overlapping translucent strokes. The inner shaft/head junction
  at x=12.4393 is a geometric intersection, not a new cap.
- Circle ring: center (8,8), outer radius **8**, inner radius **6.5**; subtraction
  leaves 1.5 thickness. Use opposite winding or `fill-rule="evenodd"` (retain
  `clip-rule="evenodd"` when supplied). A solid circle is a separate fill mark.
- Squircle: reuse the exact cubic silhouette below. It is a designed Bézier
  superellipse approximation, not a rounded rect or a measured exponent formula.
  Full outer silhouette: `M8 0C1.412 0 0 1.412 0 8C0 14.588 1.412 16 8 16C14.588 16 16 14.588 16 8C16 1.412 14.588 0 8 0Z`.
  The ring's inner contour has extrema 1.5…14.5 and multiple cubics per corner;
  copy that contour, do not simply scale the outer shape (that changes weight).
  Small filled squircle is the outer silhouette scaled by 5/8 around (8,8),
  giving bounds 3…13 and control offset 4.1175.
- Badges: compose a separate solid mark and cut the underlying silhouette away
  to leave clear space. File-status square badge is a 6×6 filled squircle at
  x/y=10…16, center (13,13), control offset 2.4705. The base document is cut back
  around approximately (13.5,13.5); do not merely overpaint it in background color.
  Other badges use circles at (13.5,2.5) or (13.5,13.5), radius 2.5. Inspect the
  matching base cutout so the badge survives both dark and light backgrounds.
- Duotone means the same tint with reduced alpha. **.4 is most common** (26
  occurrences), then .2 (9). Other measured values: .6 (4), .3 (2), and one each
  .5, .75, .65, .1, .15, .45. Use .2 or .4 for new secondary shapes unless a
  matching family calls for another value. Preserve layer order and opacities;
  overlapping translucent shapes compound their opacity.

## File contract and review

- Name resources in lower kebab-case: `folder.svg`, `chevron-down.svg`,
  `terminal-bash.svg`; use semantic names, with consistent directional suffixes.
  Import mappings explicitly translate source basenames into these names.
- Root: SVG namespace, original viewBox, `fill="none"`; omit width and height.
  Each path explicitly has `fill="currentColor"`. Preserve path data, transforms,
  fill rules, clip rules and opacity. Paths are the default; g/circle/rect allowed.
- Canonical form: alphabetically sorted attributes, double-quoted ordinary
  values, two-space indentation, one path per line, final newline; no XML
  declaration, comments, text, IDs, style, gradients or strokes.
- Upstream is not entirely compliant: `IconReplaceAll.svg` contains **two stroked
  paths in one file**, alongside expanded duplicate geometry. The validator
  rejects it; resolve its geometry explicitly before importing. Do not silently
  remove or expand these paths in the normalizer.
- Inventory: 754 paths, 13 groups, 4 circles. Do not assume paths are the only
  primitives, a 1pt margin is universal, or all secondary opacity is .2.
- Use `python3 -I scripts/icons/normalize.py FOLDER` before review. It validates
  and rewrites valid SVGs in place; reports file/reason and exits 1 on errors.
- Use the contact-sheet tool at 16pt and scale 4, then inspect both tints at
  native size. It uses AppKit NSImage SVG loading, template mode and sourceAtop
  tinting like the app; no browser/raster conversion stands in for AppKit.
  `--compare OTHER_FOLDER` requires every same-named SVG there and shows input
  light/dark followed by comparison light/dark. Missing/unloadable files fail.
- Retain required upstream license attribution when distributing derived art.

## Verbatim geometry references

These eight full path elements are copied verbatim from upstream 0.9.0 for
geometry reference only. Their original black fill is intentional here; imported
SVG resources use currentColor. Do not simplify or round their coordinate strings.

Chevron: IconChevron.svg; 1.5-wide joined diagonals, round caps.

```svg
<path d="M1.46967 4.46967C1.76256 4.17678 2.23744 4.17678 2.53033 4.46967L8 9.93934L13.4697 4.46967C13.7626 4.17678 14.2374 4.17678 14.5303 4.46967C14.8232 4.76256 14.8232 5.23744 14.5303 5.53033L8.53033 11.5303C8.23744 11.8232 7.76256 11.8232 7.46967 11.5303L1.46967 5.53033C1.17678 5.23744 1.17678 4.76256 1.46967 4.46967Z" fill="black"/>
```

Circle ring: IconCircle.svg; radius 8 outside, 6.5 inside.

```svg
<path d="M14.5 8C14.5 4.41015 11.5899 1.5 8 1.5C4.41015 1.5 1.5 4.41015 1.5 8C1.5 11.5899 4.41015 14.5 8 14.5V16C3.58172 16 0 12.4183 0 8C0 3.58172 3.58172 0 8 0C12.4183 0 16 3.58172 16 8C16 12.4183 12.4183 16 8 16V14.5C11.5899 14.5 14.5 11.5899 14.5 8Z" fill="black"/>
```

Rounded rect: IconAppToolbar.svg; radius 2.25 outside, .75 inside.

```svg
<path fill-rule="evenodd" clip-rule="evenodd" d="M2.25 1C1.00736 1 0 2.00736 0 3.25V12.75C0 13.9926 1.00736 15 2.25 15H13.75C14.9926 15 16 13.9926 16 12.75V3.25C16 2.00736 14.9926 1 13.75 1H2.25ZM1.5 3.25C1.5 2.83579 1.83579 2.5 2.25 2.5H13.75C14.1642 2.5 14.5 2.83579 14.5 3.25V12.75C14.5 13.1642 14.1642 13.5 13.75 13.5H2.25C1.83579 13.5 1.5 13.1642 1.5 12.75V3.25Z" fill="black"/>
```

Plus: IconPlus.svg; unioned bars and .75-radius ends.

```svg
<path d="M8 3C8.41421 3 8.75 3.33579 8.75 3.75V7.25H12.25C12.6642 7.25 13 7.58579 13 8C13 8.41421 12.6642 8.75 12.25 8.75H8.75V12.25C8.75 12.6642 8.41421 13 8 13C7.58579 13 7.25 12.6642 7.25 12.25V8.75H3.75C3.33579 8.75 3 8.41421 3 8C3 7.58579 3.33579 7.25 3.75 7.25H7.25V3.75C7.25 3.33579 7.58579 3 8 3Z" fill="black"/>
```

Arrow: IconArrowRight.svg; merged shaft/head, no interior cap.

```svg
<path d="M8.46967 2.21967C8.17678 2.51256 8.17678 2.98744 8.46967 3.28033L12.4393 7.25H1.75C1.33579 7.25 1 7.58579 1 8C1 8.41421 1.33579 8.75 1.75 8.75H12.4393L8.46967 12.7197C8.17678 13.0126 8.17678 13.4874 8.46967 13.7803C8.76256 14.0732 9.23744 14.0732 9.53033 13.7803L14.7803 8.53033C15.0732 8.23744 15.0732 7.76256 14.7803 7.46967L9.53033 2.21967C9.23744 1.92678 8.76256 1.92678 8.46967 2.21967Z" fill="black"/>
```

Squircle ring: IconTerminal.svg; copy the inset contour, not a scale.

```svg
<path fill-rule="evenodd" clip-rule="evenodd" d="M8 0C1.412 0 0 1.412 0 8C0 14.588 1.412 16 8 16C14.588 16 16 14.588 16 8C16 1.412 14.588 0 8 0ZM1.5 8C1.5 6.38724 1.58837 5.19362 1.78784 4.29611C1.98352 3.41564 2.26561 2.91472 2.59016 2.59016C2.91472 2.26561 3.41564 1.98352 4.29611 1.78784C5.19362 1.58837 6.38724 1.5 8 1.5C9.61276 1.5 10.8064 1.58837 11.7039 1.78784C12.5844 1.98352 13.0853 2.26561 13.4098 2.59016C13.7344 2.91472 14.0165 3.41564 14.2122 4.29611C14.4116 5.19362 14.5 6.38724 14.5 8C14.5 9.61276 14.4116 10.8064 14.2122 11.7039C14.0165 12.5844 13.7344 13.0853 13.4098 13.4098C13.0853 13.7344 12.5844 14.0165 11.7039 14.2122C10.8064 14.4116 9.61276 14.5 8 14.5C6.38724 14.5 5.19362 14.4116 4.29611 14.2122C3.41564 14.0165 2.91472 13.7344 2.59016 13.4098C2.26561 13.0853 1.98352 12.5844 1.78784 11.7039C1.58837 10.8064 1.5 9.61276 1.5 8Z" fill="black"/>
```

Small squircle: IconSquircle.svg; 10×10 solid silhouette.

```svg
<path d="M8 3C3.8825 3 3 3.8825 3 8C3 12.1175 3.8825 13 8 13C12.1175 13 13 12.1175 13 8C13 3.8825 12.1175 3 8 3Z" fill="black"/>
```

Badge: IconFileStatusSquare.svg; 6×6 solid squircle at bottom right.

```svg
<path d="M13 10C10.5295 10 10 10.5295 10 13C10 15.4705 10.5295 16 13 16C15.4705 16 16 15.4705 16 13C16 10.5295 15.4705 10 13 10Z" fill="black"/>
```

## Two-tone (Duo) icons and marks

The upstream file and brand library (see THIRD_PARTY_NOTICES.md) adds a second layer
to the same language, and the set follows its rules exactly:

- A **Duo** icon is one color in two opacities: a background shape at reduced
  opacity and a full-opacity foreground. Letter and monogram marks (TS, JS,
  CSS, Bash `$_`, npm, WASM, TOML…) sit on the 14pt squircle
  `M8 1C2.24 1 1 2.24 1 8s1.24 7 7 7 7-1.24 7-7-1.24-7-7-7` at `opacity=".2"`
  with the glyph on top. File and folder bodies use `.4`/`.5` for the body
  and full opacity for the fold or tab.
- Every signature mark, including pictorial brands (go, docker, python, rust,
  swift, git, claude, yarn, node…), uses the full-canvas squircle
  `M8 0C1.42 0 0 1.42 0 8s1.42 8 8 8 8-1.42 8-8-1.42-8-8-8` as its first
  path at `.2` opacity, on a `0 0 16 16` viewBox. Fit the opaque glyph's larger
  side to 10.25 units (64% of the squircle), centered at (8,8), so the mark
  keeps its padding and reads as large as a file or folder body. Preserve proportions and generous counters. Simplify tiny
  details instead of enlarging the glyph. The document/folder family (file,
  file-symlink, file-table, file-text, folder, folder-open, slides, spreadsheet,
  video, zip and dot) keeps its construction, fitted to 14 units.
- UI icons (chevrons, close, copy, search, status discs…) stay plain.
- Brand marks are simplified, recognizable monochrome drawings, never copies of
  official logos.
- Color is applied by code, one hue per icon from the theme palette
  (`AppTheme.IconHue`): the SVG only uses `currentColor` and `opacity`.

## Adapting a brand mark

Start from an official reference SVG, not memory: run
`python3 -I scripts/icons/adapt-brand.py SOURCE.svg OUT.svg` to fit its geometry
in a centered 14pt box on the 16×16 canvas. Use `--keep-subpaths` to keep source
elements as separate editable paths (compound holes stay with their contour).
For signature marks use `--duo`, which defaults to a centered 10.25-unit glyph box
and emits the standard squircle first. Source geometry must be opaque: remove
an existing container first, or turn its identifying silhouette into the glyph
with inner details cut out. `--box` can override the glyph fit.
Then simplify by hand so the mark reads at 16pt: drop tiny details, merge tiny
gaps, and keep the silhouette solid. Run `python3 -I scripts/icons/normalize.py FOLDER`, then render
and inspect a sheet at 16pt (`--size 16 --scale 4`) and 32pt (`--size 32 --scale 2`)
next to `go.svg`, `docker.svg` and `python.svg` from the set. The adapter preserves
geometry, not optical weight; its output is a starting point for drawing agents.
