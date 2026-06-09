# Text Composition Pipeline — Design

**Date:** 2026-06-09
**Status:** Approved (pending implementation plan)

## Overview

After AI art is generated for a book page, this pipeline composes the artwork
with text to produce **print-ready PNGs** for the cover, dedication, and inner
spreads. Text placement on artwork-bearing pages is driven by an AI
bounding-box call (Gemini); fixed-layout pages (dedication, back cover) are
composited deterministically.

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
- **Fonts:** Fredoka (title/spine) + Nunito (body), vendored as TTFs.
- **Safe inset:** uniform 112px (6% of 1875) on every panel/page edge.
- **Compositing engine:** the `image` library (Vix / precompiled libvips) — no
  system install required.
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

`<base>` examples: `cover_front_<ts>`, `inner_3_<ts>`. Composers derive the
bbox and output paths from the raw art path stored on the struct
(`generated_image_path`).

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

## 4. Text rendering

- Fonts vendored as TTFs in `priv/fonts/` (Fredoka, Nunito). libvips is pointed
  at them via a generated `fonts.conf` + `FONTCONFIG_PATH` set at application
  boot (`CircleStory.Books.Fonts`) — no OS font installation.
- `TextRenderer` renders a text run via `Image.Text` with Pango wrapping to the
  box width, alignment from the model, and **auto-fit** font sizing (shrink from
  a max until the rendered run fits the box height and width, bounded by a
  min/max size).
- **Color** is black or white, chosen by `Luminance` sampling the mean weighted
  luminance of the placement region on the final image (threshold ~0.6).

## 5. Per-page composition

### Inner spread
1. Fill-crop the 16:9 art to 3675×1875 (centre gravity).
2. `PlaceText` on the resized image with the story text.
3. Render story text (Nunito, auto-fit) into the box, aligned per model, color
   by luminance. Composite onto the page.

### Cover wrap (single 3863×1875 PNG)
- **Front** `[1988–3863]`: square art resized to 1875×1875. `PlaceText` on
  title+author → render Title (Fredoka, large) above Author (Nunito, smaller),
  stacked within the returned box; color by luminance.
- **Spine** `[1875–1988]`: solid fill = desaturated **average color of the front
  art**; vertical "Title · Author" (Fredoka), centered, color by fill luminance.
- **Back** `[0–1875]`: same sampled fill color. Tagline top-center (Nunito
  italic); empty **pink placeholder circle** centered (~38% of panel width,
  later holds the character reference image); blurb bottom-left within the safe
  inset:

  ```
  Circle Storybooks
  A one of a kind story.
  Make your own at:
  www.circlestorybooks.com
  ```

### Dedication spread (fixed, no AI call)
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
    text_renderer.ex                # Image.Text run → RGBA layer (autofit, wrap, align)
    luminance.ex                    # sample region → :black | :white
    cover_composer.ex
    spread_composer.ex
    dedication_composer.ex
  actions/
    place_text.ex                   # Jido action: bbox AI call (generate_object)
  fonts.ex                          # fontconfig setup at boot
priv/fonts/{Fredoka,Nunito}*.ttf    # vendored TTFs
```

- `generator.ex` wires `generate_*` → existing `GenerateSpreadImage` +
  `PlaceText` + the relevant composer; adds `compose_*` for cheap re-runs.
- New dependency: `{:image, "~> 0.x"}` (pulls in `:vix` + precompiled libvips).
- `CircleStory.Books.Fonts` (fontconfig setup) runs at application boot.

## 7. Testing & error handling

### Tests
- **Pure unit (no network/images):** `Layout` geometry (panels tile the canvas,
  bbox→px mapping, safe-inset clamping); `PlaceText` JSON parse / validate /
  clamp / fallback against stubbed responses.
- **Image tests with local fixtures (no network):** `Luminance` against
  synthetic black/white swatches; `TextRenderer` output dimensions ≤ box and ≥
  min size; composers fed a fixture raw-art PNG + injected bbox → assert output
  PNG exists at the correct dimensions.
- Live AI calls are **not** part of the test suite.

### Errors
- Missing raw art / font / unreadable image → `{:error, reason}`.
- Malformed or out-of-range bbox → clamp to safe area; total parse failure →
  documented fallback box + warning log.

## Out of scope (future)

- Inserting real character reference images into the placeholder circles.
- Real user photo into the dedication circle.
- Full-book assembly / PDF export across all pages.
