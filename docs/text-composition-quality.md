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
- a line fails the configured contrast percentile gate, or any overlapping
  local tile fails the configured contrast percentile or low-contrast-fraction
  gate. The two tile gates are applied to every tile independently: the tile
  with the weakest percentile and the tile with the largest low-contrast
  fraction are usually different tiles, and either one rejects the candidate.

Passing candidates retain named metrics and weighted contributions for
readability margin, font size, compactness, seed proximity, whitespace balance,
and edge quietness. The selected candidate therefore has an inspectable vector
rather than an opaque score.

Treatment strength is deliberately not a soft weight. The weakest passing
treatment is enforced before ranking, so any weight over it could never change
the ordering; the chosen treatment type and opacity remain in provenance.

## Long text and fallback

Chrome binary-searches from the role minimum to each candidate font cap and
surfaces its final font, lines, available/scroll dimensions, and overflow. The
search can grow, shrink, translate, or rewrap around the semantic seed, but it
never changes story wording.

If no untreated finalist passes local contrast, the compositor tries opposite
black/white rectangular backings at the finite policy opacities 44%, 60%, and
78%. Each finalist/ink pair walks that list weakest-to-strongest and stops at
its own first passing opacity, so pairs that need a stronger backing are still
scored while resolved pairs stop costing scans. Selection then ranks only the
passing candidates that share the weakest passing treatment, so a stronger
backing never outranks a weaker one that already passed. If content still
cannot fit at the role minimum, the caller receives
`{:composition_overflow, details}`. Those details carry `closest_fit`: the id,
fitted font, line count, available and scroll dimensions, and the derived
`overflow_width`/`overflow_height` of the candidate that came nearest to
fitting, so an operator can see by how much the page overran. Every field is a
number or a candidate id — no story text ever travels in a failure. `nil` there
means the measurement source reported no fit geometry. The existing print-ready
artifact is not silently clipped or overwritten by that failed composition.

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

Untreated ink attempts and backing attempts are recorded separately, never
merged: `attempts.untreated` and `attempts.treated` each carry their own
`scanned`, `passed`, `rejected`, and `rejection_reasons` frequencies, and
`scored_count` is the total scan count across both. A page that shipped with a
backing therefore still records that plain ink was scanned first and exactly
which gate refused every one of those scans. The same split appears in
`{:composition_quality_failed, details}` and in the development evaluation UI.
Renderer faults that prevented a finalist mask are listed as
`mask_render_errors` (candidate id and a bounded fault class only).

Renderer and image-library terms are never persisted or displayed verbatim. A
ChromicPDF exit reason carries the whole `GenServer.call/3` argument list, which
includes the page document, and an exception message can quote whatever it was
raised over. `Quality.Diagnostics.reason_class/1` reduces every such reason to a
class built only from the atom tags naming the fault — `renderer_exit:timeout`,
`renderer_exception:ArgumentError`, `image_binary_failed` — with any other
payload contributing its type and nothing else, capped at four segments and 96
characters. Attempt `rejection_reasons` keys pass through the same reduction, so
sidecar size and privacy do not depend on what a third-party library chose to
put in an error term. That reduction is many-to-one — two libvips faults with
different payloads share one class — so colliding counts are summed, and the
persisted frequencies still total the `rejected` count they explain. Live
`Attempts` structs still hold the raw reasons they collected, so the development
UI reduces them through the same classing before display.

The same rule holds for reasons that leave a step directly rather than through
attempt evidence. `Quality.ImageRead.write_to_binary/1` is the single libvips
byte-read boundary and already classes the fault term it returns, and the
development UI's catch-all `format_error/1` names a bounded class instead of
inspecting an unrecognized reason, so no raw third-party payload can reach an
operator by escaping a step early.

When every finalist mask fails, the composition returns
`{:composition_mask_render_failed, errors}`, reported to the operator as a local
Chrome fault rather than as page content to rewrite. That operator message is
fixed copy: "Text readability verification could not run because the local
renderer failed. No composed page was published. Retry composition; if the
problem continues, inspect the local Chrome renderer." The bounded fault classes
behind it are surfaced separately as structured evidence
(`NaniEvaluationLive.error_evidence/1`) rather than spliced into that sentence.

A browser that returns no usable measurement at all is reported as
`{:composition_measurement_failed, details}` with `reason:
:no_usable_measurement`, distinct from genuine
`{:composition_overflow, details}` content that cannot fit — an operator is
never asked to rewrite a page because Chrome misbehaved. Both details carry
`rejection_reasons` frequencies.

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

Full-resolution glyph scanning is the dominant cost and is explicitly bounded.
Each finalist is scanned once per ink untreated. The backing fallback runs only
when no untreated variant passes, and each finalist/ink pair then walks
`backing_opacities` weakest-to-strongest and stops at its own first passing
opacity — so a pair that the lightest backing fixes never pays for the stronger
ones. Worst case is `2 x finalists x (1 + length(backing_opacities))` scans, and
the actual number is reported as `scored_count` on the optimizer result — the
sum of the untreated and treated attempt counts, including the weaker opacities
rejected on the way. Finalist preselection first collapses candidates that
differ only in an unreached font cap, so no finalist slot and no mask render is
spent twice on one rendered layout.

Within one scan, only pixels at or above the core mask threshold touch the
sample accumulator; the pixel index is threaded as a plain argument so the
majority of pixels that contribute nothing cost no map update. A contributing
pixel accumulates exactly one value — its contrast — into the overall, line, and
overlapping-tile groups, so summarizing a group is a single sort and count with
no second per-pixel arithmetic pass. The sRGB gamma
expansion behind every relative-luminance read is a compile-time 256-entry
table rather than a `:math.pow/2` call per channel per pixel.

Per-scan cost still scales with glyph area, and the cover role's much larger
fonts produce far more glyph pixels per scan than the measured inner role. No
full-size cover measurement is claimed here: busy cover artwork that needs the
strongest backing is the heaviest production path and is deliberately left
unmeasured in this change. Benchmarking and calibrating it is tracked as GitHub
issue #13.
