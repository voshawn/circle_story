# Deterministic text-composition quality

CircleStory treats the placement model's box as a semantic seed, not the final
glyph rectangle. `CircleStory.Books.Composition.Quality` runs after fitted art
and a cached/model placement are available and before the final page component
is rendered. It makes no provider calls.

## Pipeline

The orchestrator passes an explicit immutable `Quality.Context` through a fixed,
configurable list of one-argument steps:

1. `SafetyMap.build/2` downsamples fitted art into separate black- and white-ink
   contrast maps plus a local edge proxy.
2. `Regions.expand/1` grows from the seed in all four directions. Sustained
   unsafe contrast or edge strips stop growth; isolated cells are tolerated.
3. `Candidates.generate/1` searches a finite role-aware set of region sizes,
   wraps, translations, horizontal/vertical anchors, and font caps.
4. `BrowserRenderer.measure/3` fits all candidates in one Chrome document and
   returns actual font size, line boxes/count, scroll geometry, and overflow.
5. The best line-map candidates become finalists. Chrome renders an exact glyph
   mask for each finalist, and `Scorer` evaluates full-resolution art under the
   mask with overlapping role-relative tiles and per-line distributions.
6. `Selection` rejects every candidate that fails a hard gate, then ranks only
   passing candidates by named soft contributions.

The steps are ordinary module/function tuples, not a workflow engine or plugin
system. Candidate transforms and soft weights are explicit policy fields, so a
step, transform, or weight can be changed without rewriting orchestration.
Identical art, content, placement, policy, renderer/font versions, and contract
version produce deterministic ordering and tie-breaking.

## Hard gates versus soft ranking

Hard failures cannot be offset by weights:

- text does not fit at the role minimum;
- browser scroll geometry reports overflow or clipping;
- final rect leaves the established page/fold bounds;
- actual core glyphs leave the conservative internal inset;
- a line or overlapping local tile fails the configured contrast percentile or
  low-contrast-fraction gate.

Passing candidates retain named metrics and weighted contributions for
readability margin, font size, compactness, seed proximity, whitespace balance,
edge quietness, and treatment restraint. The selected candidate therefore has
an inspectable vector rather than an opaque score.

## Long text and fallback

Chrome binary-searches from the role minimum to each candidate font cap and
surfaces its final font, lines, available/scroll dimensions, and overflow. The
search can grow, shrink, translate, or rewrap around the semantic seed, but it
never changes story wording.

If no untreated finalist passes local contrast, the compositor tries opposite
black/white rectangular backings at the finite policy opacities 44%, 60%, and
78%, stopping at the first opacity with a passing candidate. If content still
cannot fit at the role minimum, the caller receives
`{:composition_overflow, details}`. The existing print-ready artifact is not
silently clipped or overwritten by that failed composition.

## Geometry status

The policy preserves the existing 112px outer safety behavior and current
3675×1875 inner / 1875×1875 front-panel dimensions. Inner text is constrained
to one side of the fold. The 48px internal glyph spacing is supported by the
reported failure and synthetic regressions.

These values are isolated in `Quality.Policy`. They are **not** claimed to be a
printer-certified bleed, trim, binding, or gutter specification. The rect-level
fold inset remains zero until an authoritative print specification is chosen;
the internal glyph inset still keeps rendered ink away from the fold boundary.

## Provenance and cache behavior

The original placement box and `model | fallback | unknown` source remain in
the bbox sidecar. Successful composition adds a compact
`composition_quality` object containing the final rect, adjustment, anchors,
font/line fit, treatment, candidate/rejection counts, and selected named metrics.
It contains no text, prompt, image bytes, source path, or photo data.

Deterministic selection is recomputed on every composition, including free
cached-bbox recomposition; it is never reused as a stale output cache. Persisted
provenance is accepted for display only when its contract version matches the
current policy contract. The development Nani evaluation page displays the
model seed beside this deterministic result.

## Call count and performance

Stage A adds **zero** placement, review, image, or other provider calls and adds
no retry path. It uses the already supervised ChromicPDF and installed
Image/libvips stack.

A local full-size synthetic regression at 3675×1875 generated and measured 540
bounded candidates, rendered 10 finalist masks, and selected a no-backing
candidate in **8.4 seconds** on the development Mac used for implementation.
The small 800×400 browser regression suite (dark edge, inverse light edge,
busy backing, and minimum-font overflow) completes in about 8 seconds total.
These are development measurements, not a production SLO; candidate count,
finalist count, Chrome/font version, and quality duration should be calibrated
before high-volume use.
