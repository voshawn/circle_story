# Text Composition Pipeline — Design

**Date:** 2026-06-09
**Status:** Approved — revised 2026-06-09 to render via an HTML/CSS intermediate
(headless Chrome) instead of compositing directly with libvips.

## Overview

After AI art is generated for a book page, this pipeline composes the artwork
with text to produce **print-ready PNGs** for the cover, dedication, and inner
spreads. Text placement on artwork-bearing pages is driven by an AI
bounding-box call (Gemini); fixed-layout pages (dedication, back cover) are
composited deterministically.

Each page is rendered as an **HTML/CSS document** — a reusable Phoenix function
component — and rasterized to PNG with **headless Chrome (ChromicPDF)**. The
HTML representation is the single source of truth for layout, so the future
in-app editor (change text, placement, color, crop/resize art) can render the
exact same components live and re-export. The `image` library (Vix/libvips) is
used only for deterministic source preparation (fill-crop) and luminance
sampling — not for text or final compositing.

The pipeline lives under `lib/circle_story/books/` and is wired into the
existing `CircleStory.Books.Generator` so `generate_cover/1` and
`generate_spread/2` return finished print-ready pages.

## Decisions (settled during brainstorming)

- **Pipeline shape:** decoupled — generation and compositing are separable so
  text/layout can be re-rendered cheaply without re-calling the expensive image
  model.
- **Text treatment:** plain text, **no scrim/shadow**. Legibility handled via
  heavy fonts and (later) lighter artwork.
- **Text color:** black **or** white, chosen by sampling the mean luminance of
  the placement region (no extra AI field).
- **Fonts:** Fredoka (title/spine) + Nunito (body), vendored as TTFs and embedded
  in the render document via base64 `@font-face` (no fontconfig / OS install).
- **Safe inset:** uniform 112px (6% of 1875) on every panel/page edge.
- **Render engine:** each page is a reusable **Phoenix HEEx function component**;
  final rasterization is **headless Chrome via ChromicPDF** (`capture_screenshot`,
  `full_page: true`, `deviceScaleFactor: 1` → pixel-exact). Chrome/Chromium is a
  system dependency (present in dev; installed in the prod image).
- **Source prep & luminance:** the `image` library (Vix / bundled libvips, no
  system install) fill-crops the raw art to print dims and samples region
  luminance. Not used for text or final compositing.
- **Autofit:** handled in-browser by a small text-fit script (shrinks each text
  block to fit its box) — not a server-side font-size loop.
- **Bbox model:** `google:gemini-3.5-flash` (fallback `google:gemini-2.5-flash`
  if the unlisted id errors).

## 1. Pipeline shape & data flow

Two entry points per page type:

- **`generate_*`** — full path: AI art generation → resize/crop to print dims →
  AI bounding-box call → cache bbox → composite → write print-ready PNG. One
  call yields the finished page.
- **`compose_*`** — re-composites from cached raw art + cached bbox JSON, with
  **no model calls**. Used while tuning fonts/margins. If the bbox JSON is
  missing it performs the bbox call once and caches it.

**Sequencing:** the bounding-box call runs on the **already-resized print-size
image**, not the raw 16:9 art. Box coordinates are therefore directly in final
page space (no crop-transform math), and the "avoid the fold midpoint"
instruction is meaningful because the image *is* the spread.

### Files (no Ecto — sidecar files on disk)

```
priv/generated_images/<base>.png         # raw AI art (existing behavior)
priv/generated_images/<base>.bbox.json   # cached {bounding_box, text_align}
priv/print_ready/<base>.png              # composited print-ready output
```

`<base>` examples: `cover_front_<ts>`, `inner_3_<ts>`. The composition facade
derives the bbox and output paths from the raw art path stored on the struct
(`generated_image_path`); the cheap re-compose path discovers the newest raw
file for a page by filename prefix.

## 2. Canvas geometry (pixels)

| Surface              | Dimensions  | Notes |
|----------------------|-------------|-------|
| Inner spread         | 3675 × 1875 | Page midpoint x=1837; text avoids crossing it |
| Dedication spread    | 3675 × 1875 | Fixed layout |
| Cover wrap           | 3863 × 1875 | Back · spine · front |

Cover wrap panels (left→right):

| Panel | x-range     | Size        |
|-------|-------------|-------------|
| Back  | 0 – 1875    | 1875 × 1875 |
| Spine | 1875 – 1988 | 113 × 1875  |
| Front | 1988 – 3863 | 1875 × 1875 (square, matches 1:1 art) |

**Text-safe inset:** uniform 112px on every edge of each panel/page. The bbox
prompt is instructed to keep text inside this inset; fixed layouts respect it.

## 3. Bounding-box AI step — `PlaceText` action

A Jido action calling
`ReqLLM.generate_object("google:gemini-3.5-flash", messages, schema, opts)` with
the **print-size image** + the page text.

Structured output schema:

```json
{ "bounding_box": [ymin, xmin, ymax, xmax], "text_align": "left|right|center" }
```

`bounding_box` is normalized to a 1000×1000 grid. `Layout` maps it to pixel
coordinates within the target region.

Prompt (adapted from the original): instructs the model to place the text well
for a children's book page, to keep text inside the 6% safe-edge area, and:

- **inner** spreads: include the "avoid crossing the fold midpoint" clause.
- **cover**: drop the fold clause (front panel is not folded). The combined
  `Title\nAuthor` text is passed and a single box is returned.

Robustness:

- Out-of-range or inverted coordinates → clamped to the safe area.
- Parse failure → fall back to a default box (inner: lower third; cover: upper
  center) and log a warning.

## 4. HTML rendering & rasterization

- **Fonts:** vendored TTFs in `priv/fonts/` (Fredoka, Nunito, Nunito-Italic) are
  read once and emitted as base64 `@font-face` rules in the render document, so
  the screenshot is hermetic (no static-serving or network). No fontconfig.
- **Page components** (`PageComponents`): each page (`cover/1`, `inner_spread/1`,
  `dedication/1`) is a pure HEEx function component. Text blocks are
  absolutely-positioned `<div>`s at the denormalized pixel rect, with CSS
  `text-align`, the chosen color, and font. Spine text uses
  `transform: rotate(-90deg)`; placeholder circles use `border-radius: 50%`.
- **Autofit:** a small inline JS fit-script scales each `.fit-text` block down to
  fit its container after `document.fonts.ready`, then sets a `data-ready`
  attribute on `<body>`.
- **Rasterization** (`HtmlRenderer`): wraps a component's HTML in a full document
  (embedded fonts, exact-size body, fit-script), then
  `ChromicPDF.capture_screenshot({:html, html}, full_page: true, wait_for:
  %{selector: "body[data-ready]", attribute: "data-ready"}, capture_screenshot:
  %{format: "png"}, output: path)`. `full_page` sizes the viewport to the
  exactly-sized body at `deviceScaleFactor: 1`, producing a pixel-exact PNG.
- **Color** is black or white, chosen by `Luminance` sampling the mean weighted
  luminance of the placement region on the fitted image (threshold ~0.6), passed
  into the component as the text color.

## 5. Per-page rendering

### Inner spread (3675×1875)
1. `image` fill-crops the 16:9 art to 3675×1875 (centre) → background data URI.
2. `PlaceText` on the fitted image with the story text → bbox + align.
3. `Layout.denormalize` → pixel rect; `Luminance` → ink color.
4. Render `inner_spread/1`: full-bleed background + one absolutely-positioned
   `.fit-text` story-text block at the rect, aligned per model. Screenshot → PNG.

### Cover wrap (3863×1875)
- **Front** `[1988–3863]`: square art (fill-cropped to 1875×1875) full-bleed in
  the panel; title (Fredoka) over author (Nunito) in a `.fit-text` block at the
  `PlaceText` box; ink by luminance.
- **Spine** `[1875–1988]`: solid fill = softened **average color of the front
  art**; vertical "Title · Author" (Fredoka, `rotate(-90deg)`), centered, ink by
  fill luminance.
- **Back** `[0–1875]`: same fill. Tagline top-center (Nunito italic); empty
  **pink placeholder circle** centered (~38% of panel width, later holds the
  character reference image); blurb bottom-left within the safe inset:

  ```
  Circle Storybooks
  A one of a kind story.
  Make your own at:
  www.circlestorybooks.com
  ```

### Dedication spread (3675×1875, fixed, no AI call)
- Cream background.
- Dedication text centered in the left page `[0–1837]` (Nunito).
- Empty pink placeholder circle centered in the right page `[1837–3675]` (later
  holds the real user image).

## 6. Module breakdown

```
lib/circle_story/books/
  composition.ex                    # facade: compose_cover / compose_spread / compose_dedication
  composition/
    layout.ex                       # pure geometry: dims, panel rects, safe insets, bbox→px
    luminance.ex                    # sample region → :black | :white (image lib)
    image_ops.ex                    # fill-crop fit, data-URI encode, paths, latest-raw discovery
    fonts.ex                        # read TTFs → base64 @font-face CSS
    html_renderer.ex                # component HTML → wrapper doc → ChromicPDF screenshot → PNG
  page_components.ex                # HEEx function components: cover/1, inner_spread/1, dedication/1
  actions/
    place_text.ex                   # Jido action: bbox AI call (generate_object)
priv/fonts/{Fredoka,Nunito,Nunito-Italic}.ttf   # vendored TTFs
```

- `generator.ex` wires `generate_*` → existing `GenerateSpreadImage` +
  `PlaceText` + the facade; adds `compose_*` for cheap re-runs.
- New dependencies: `{:image, "~> 0.68"}` (Vix + bundled libvips) and
  `{:chromic_pdf, "~> 1.17"}`. `ChromicPDF` is started in the supervision tree.
- `page_components.ex` is plain presentation, reused by the future LiveView
  editor.

## 7. Testing & error handling

### Tests
- **Pure unit (no network/images):** `Layout` geometry (panels tile the canvas,
  bbox→px mapping, safe-inset clamping); `PlaceText` JSON parse / validate /
  clamp / fallback against stubbed responses; `Fonts` `@font-face` CSS contains
  the families; `ImageOps` path helpers + latest-raw discovery.
- **Image tests with local fixtures (no network):** `Luminance` against
  synthetic black/white swatches; `ImageOps.fit` produces exact dimensions.
- **Component tests (no browser):** render `cover/1` / `inner_spread/1` /
  `dedication/1` via `render_component` and assert the page-size container, the
  text content, the positioned rect, alignment, and color appear in the markup.
- **Screenshot/E2E (`:integration`, needs Chrome, excluded by default):**
  `HtmlRenderer` + the facade produce a PNG at the exact print dimensions. Live
  AI calls are likewise `:integration` and excluded.

### Errors
- Missing raw art / unreadable image → `{:error, reason}`.
- Malformed or out-of-range bbox → clamp to safe area; total parse failure →
  documented fallback box + warning log.
- Screenshot failure (Chrome missing/crash) → `{:error, reason}` surfaced from
  ChromicPDF.

## Out of scope (future)

- The in-app editor UI itself (live text/placement/color editing, interactive
  crop/resize). This pivot only builds the HTML-intermediate render + PNG export
  that the editor will later reuse via the same `PageComponents`.
- Inserting real character reference images into the placeholder circles.
- Real user photo into the dedication circle.
- Full-book assembly / PDF export across all pages.
