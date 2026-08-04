# App icon

The mark is a terminal prompt drawn twice: a recessed chevron behind a solid
one, over a cursor block. One `>_` says terminal; two stacked says *concurrent*
terminals, which is what the app is for.

`agents-light.svg` and `agents-dark.svg` are the composed reference artwork.
`mark.svg` is the foreground on its own — flat, single colour, transparent
ground — which is the layer Icon Composer wants.

## Colour

|          | Ground                | Mark      |
| -------- | --------------------- | --------- |
| Light    | `#008EA6` → `#00606F` | `#EDF3F4` |
| Dark     | `#0A2B33` → `#04161B` | `#64D1DD` |

The light ground's gradient passes through `#00778C`, which is the signature
colour this is built around. `#64D1DD` is the same hue (186° against 189°)
lifted and desaturated so it can carry on a dark ground — a dark-on-dark mark
measures about 2:1 and dissolves, so the dark appearance inverts instead.

`#64D1DD` is also the app's UI tint: selected sidebar rows, focus rings, the
shell prompt. It's the one value in the palette bright enough to read against
the terminal's own near-black.

## Geometry

A 1024 × 1024 canvas, y increasing downward.

- **Squircle** — superellipse `|x|^4.6 + |y|^4.6 = 1` mapped onto the canvas.
  The corner lands at roughly 23.9% of the width, close to Apple's continuous
  corner. macOS does not mask app icons, so this shape is baked into the art.
- **Ground** — linear gradient along `(262.3, -105.9)` → `(761.7, 1129.9)`,
  which is CSS `linear-gradient(158deg, …)` resolved for this canvas.
- **Key light** — white, α 0.26 → 0 at 56%, ellipse centred `(266.2, 41.0)`,
  radii 1280 × 901.1.
- **Bounce** — white, α 0.10 → 0 at 60%, ellipse centred `(512, 1105.9)`,
  radii 1024 × 614.4.
- **Mark** — stroke width 86, round caps and joins.
  Recessed chevron at α 0.38: `(252,288) → (444,448) → (252,608)`.
  Front chevron: `(440,268) → (664,448) → (440,628)`.
  Cursor block: rounded rect at `(386, 716)`, 300 × 86, corner radius 43.

The mark is optically weighted rather than centred on its bounding box — the
chevrons sit left and high, the cursor right and low, so the composition reads
as a prompt line. Don't "fix" it by centring the bounds.

## Regenerating the PNGs

    bb icon

Renders the ten PNGs and `Contents.json` into
`macapp/Agents/Assets.xcassets/AppIcon.appiconset/`. The output is committed,
so this only needs running when the artwork changes — it is deliberately not a
dependency of `bb gen` or `bb build`.

To preview the dark appearance without touching the catalog:

    swift design/icon/RenderAppIcon.swift --appearance dark --out /tmp/dark

## Upgrading to a layered `.icon`

The committed asset catalog is a classic `.appiconset`: one flat image set, so
it carries the **light appearance only**. That is why `--appearance dark`
writes somewhere else — there is nowhere in this format to put it.

macOS 26's Liquid Glass treatment and the dark / clear / tinted appearances
need Icon Composer, which ships inside Xcode at
`/Applications/Xcode.app/Contents/Applications/Icon Composer.app`. To build it:

1. New macOS icon, 1024 pt canvas.
2. Drag in `mark.svg` as the foreground layer; tint it `#EDF3F4`.
3. Set the background to a linear gradient, `#008EA6` → `#00606F`, angled down
   and slightly right. Leave Icon Composer's own specular and shadow on — the
   two highlights described above are approximations of what it does properly,
   so don't stack ours on top of its.
4. Switch to the Dark appearance and set the ground to `#0A2B33` → `#04161B`
   and the mark to `#64D1DD`.
5. Save as `macapp/Agents/AppIcon.icon`.

Once that exists it supersedes the asset catalog, and
`ASSETCATALOG_COMPILER_APPICON_NAME` in `macapp/project.yml` keeps pointing at
`AppIcon` either way.
