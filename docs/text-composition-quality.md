# Deterministic text-composition quality

CircleStory treats the placement model's box as a semantic seed, not the final
glyph rectangle. `CircleStory.Books.Composition.Quality` runs after fitted art
and a cached/model placement are available and before the final page component
is rendered. It makes no provider calls.

## Captain's print policy

Print output must use transparent **black or white text only**. The compositor
must not add a white, black, colored, opaque, or semi-transparent rectangle
behind text. This is a deliberate print tradeoff: readability thresholds guide
the preferred result, but preserving transparent artwork is mandatory.

When at least one geometry-safe transparent candidate meets every established
readability threshold, the compositor publishes the best such candidate. When
none does, it deterministically publishes the best measured, geometry-safe
transparent black-or-white candidate. A contrast miss alone therefore does not
withhold an otherwise valid page. The fallback is explicit in provenance and in
the development evaluation UI.

Geometry and renderer success never become optional. The compositor refuses to
publish text that is clipped, overflowing, outside page/fold bounds, below the
minimum font, outside its glyph inset, unmeasured, or missing a valid glyph
mask.

## Architecture and pipeline

The orchestrator passes an explicit immutable `Quality.Context` through a fixed,
configurable list of one-argument steps:

1. `SafetyMap.build/2` downsamples fitted art into separate black- and white-ink
   contrast maps plus a local edge proxy.
2. `Regions.expand/1` grows from the seed in all four directions. Sustained
   unsafe contrast or edge strips stop growth; isolated cells are tolerated.
3. `Candidates.generate/1` searches bounded transform chains of depth at most
   two. The first operation is identity, one safety-approved growth, or one
   safety-approved translation. The optional second operation places an 80%
   width wrap, 90% width wrap, or 90% × 90% compact rectangle wholly inside
   that base. Width wraps use left/center/right positions; compact rectangles
   also use top/middle/bottom positions. Geometry is deduplicated before the
   policy's fixed rectangle budget is applied. Model `text_align` and
   `vertical_align` values are used only later to align glyphs inside each
   generated rectangle; they never position rectangles.
4. `BrowserRenderer.measure/3` fits all candidates in one Chrome document and
   returns actual font size, line boxes/count, scroll geometry, and overflow.
5. The best line-map candidates become finalists. Chrome renders one exact glyph
   mask per finalist. `Scorer` scans the fitted source art under that mask once
   for black ink and once for white ink. No treatment layer participates in
   rendering or scoring.
6. `Selection` first ranks geometry-safe candidates that meet all readability
   thresholds. If that set is empty, it ranks geometry-safe below-threshold
   candidates from the same glyph-mask measurements.

The steps are ordinary module/function tuples, not a workflow engine or plugin
system. Candidate transforms and soft weights are explicit policy fields, so a
step, transform, or weight can be changed without rewriting orchestration.
Identical art, content, placement, policy, renderer/font versions, and contract
version produce deterministic ordering and tie-breaking.

## Non-negotiable constraints and preferred thresholds

These failures are non-negotiable and can never be offset by ranking evidence:

- the browser returned no usable measurement;
- text does not fit at the role minimum;
- browser scroll geometry reports overflow or clipping;
- the final rect leaves established page/fold bounds;
- actual core glyphs leave the conservative internal inset;
- the glyph mask is empty, has the wrong geometry, or cannot be read/rendered.

The preferred phase additionally rejects a candidate when:

- a line fails the configured contrast percentile threshold;
- any overlapping local tile fails the contrast percentile threshold; or
- any overlapping local tile exceeds the configured low-contrast fraction.

The two tile checks are independent. The tile with the weakest percentile and
the tile with the largest low-contrast fraction are often different, and either
one removes a candidate from the preferred set.

Passing candidates retain named soft contributions for readability margin, font
size, compactness, seed fidelity, whitespace balance, and edge quietness. Seed
fidelity is rectangle intersection-over-union with the original placement seed. It
compares growths, translations, and contained wraps without consulting text
alignment, and gives equal fidelity to equal-size left/center/right wraps. A
passing transparent candidate always wins over a below-threshold candidate;
soft weights cannot reverse that phase boundary.

## Transparent fallback ranking

If the preferred set is empty, only candidates with no non-negotiable failure
remain eligible. `Selection` compares them lexicographically using existing,
auditable glyph-mask metrics:

1. maximize the weaker of `worst_tile_p10` and `worst_line_p05`;
2. minimize `worst_tile_low_contrast_fraction`;
3. maximize `worst_tile_p10`;
4. maximize `worst_line_p05`;
5. minimize `edge_density`;
6. break remaining ties by candidate generation index and then black before
   white.

This fallback adds no model call and no opaque score. Contrast and texture are
selection evidence, while measured fit and geometry remain hard publication
constraints. The selected candidate retains its readability rejection classes
so an operator can see which preferred thresholds it missed.

## Long text and structured refusal

Chrome binary-searches from the role minimum to each candidate font cap and
surfaces its final font, lines, available/scroll dimensions, and overflow. The
search can grow, shrink, translate, or rewrap around the semantic seed, but it
never changes story wording.

If content cannot fit at the role minimum, the caller receives
`{:composition_overflow, details}`. `closest_fit` contains only the candidate id,
fitted font, line count, available and scroll dimensions, and derived overflow
width/height of the candidate that came nearest to fitting. It contains no story
text. `nil` means the measurement source reported no fit geometry. Existing
print-ready output is retained rather than clipped or overwritten.

A browser that returns no usable measurement receives
`{:composition_measurement_failed, details}` with `reason:
:no_usable_measurement`, distinct from content overflow. If masks cannot be
rendered, no unmeasured text is published: all-mask failure returns
`{:composition_mask_render_failed, errors}`; a mixed scan with no geometry-safe
measured variant returns `{:composition_quality_failed, details}`.

## Geometry status

The policy preserves the existing 112px outer safety behavior and current
3675×1875 inner / 1875×1875 front-panel dimensions. Inner text is constrained
to one side of the fold. The 48px internal glyph spacing is supported by
reported failure evidence and synthetic regressions.

These values are isolated in `Quality.Policy`. They are **not** claimed to be a
printer-certified bleed, trim, binding, or gutter specification. The rect-level
fold inset remains zero until an authoritative print specification is chosen;
the internal glyph inset still keeps rendered ink away from the fold boundary.

## Provenance, privacy, and cache behavior

The original placement box and `model | fallback | unknown` source remain in
the bbox sidecar. Successful composition writes the
`composition-quality-v3` object with:

- final geometry, glyph alignment, fit, ink, and the compatibility value
  `treatment: "none"`;
- a privacy-safe `adjustment` transform-chain label such as
  `grow_left>wrap_80_center`; labels contain only fixed operation names;
- `glyph_bounds`, plus the compatibility field `effect_bounds`, which is fixed
  to the same measured glyph rectangle because transparent text has no separate
  effect layer to bound; it is not displayed anywhere in the evaluation UI;
- `selection_outcome`, either `threshold_pass` or
  `below_threshold_transparent_fallback`;
- `readability_thresholds_met` and the selected candidate's bounded
  `readability_rejections`;
- measured tile, line, overall contrast, low-contrast, and edge evidence;
- one `attempts.transparent` summary for all black/white scans; and
- bounded mask-render error classes.

The sidecar contains no text, prompt, image bytes, renderer document, source
path, or photo data. The compatibility treatment field is fixed to `none`; it
cannot encode a visual layer. Version 3 represents only bounded transform
composition and seed-fidelity ranking; superseded contract versions and
obsolete anchor-overload labels are ignored for quality display.

Reading a sidecar is fail-closed against its single producer,
`Quality.Result.provenance/1`. `readability_rejections` keeps only the reasons
`Quality.Scorer.readability_reasons/0` can produce, `ink` keeps only the labels
`Result.ink_labels/0` emits, and `selection_outcome` keeps only the outcomes
`Result.selection_outcomes/0` emits. A missing or unknown value decodes as
unrecorded rather than as a default, and a persisted `threshold_pass` whose own
`readability_thresholds_met`/`readability_rejections` evidence contradicts it is
also treated as unrecorded. A below-threshold publish therefore cannot be read
back — or displayed — as a clean pass.

Renderer and image-library terms reaching the composition-quality diagnostic
paths — persisted attempt evidence, mask-render errors, quality/measurement
failure reasons, and the unrecognized-reason catch-all in the evaluation UI —
are never persisted or displayed verbatim. A ChromicPDF exit can contain the
whole page document, and an exception can quote private content.
`Quality.Diagnostics.reason_class/1` reduces each reason to a bounded class
built only from atom tags, capped at four segments and 96 characters. Frequency
collisions are summed so persisted counts still reconcile with rejected
variants.

Two pre-existing development-only error paths are outside that guarantee and
unchanged by this work: `{:chromic_pdf_failure, message}` and the generic
`{:exception, message}` card still show the raised message text. They are never
persisted to the sidecar.

Deterministic selection is recomputed on every composition, including cached
bbox recomposition; it is not reused as a stale output cache. The cached-only
path never invokes `PlaceText` or another provider. The development Nani
evaluation page shows the model seed beside the deterministic result.

## Operator interpretation

The development evaluation panel uses two explicit success outcomes:

- **Preferred readability thresholds met**: a transparent candidate cleared all
  preferred contrast gates.
- **Below preferred readability thresholds · best geometry-safe transparent
  result published**: every geometry-safe transparent candidate missed at least
  one readability threshold, so the deterministic fallback was published.

Only the first reads as a pass, in green. Anything else — including a sidecar
whose outcome decoded as unrecorded — is shown in amber as **Selection outcome
not recorded · treat as below preferred readability thresholds**, with the
threshold-miss line, so an unreadable record is reviewed rather than trusted.

For both outcomes the panel shows black/white ink, selected geometry, fit,
contrast/edge metrics, scan counts, and bounded rejection classes. It never
shows story text, source images, private paths, or raw renderer payloads.

Overflow means upstream content must be shortened or split. Measurement and mask
failures mean the local Chrome renderer should be checked and retried. A
`composition_quality_failed` result means no renderer-successful,
geometry-safe candidate existed; it is not a contrast-only refusal.

## Call count and bounded work

Stage A adds **zero** placement, review, image, or other provider calls and adds
no retry path. It uses the already supervised ChromicPDF and installed
Image/libvips stack.

The default rectangle budget is 34: up to 17 retained seed/growth/translation
baselines, all 15 reposition operations inside the seed, and one bounded
composition from each growth and translation family. With the default three
horizontal alignments, three vertical alignments, and three font caps, browser
measurement is bounded at `34 × 3 × 3 × 3 = 918` candidates. This preserves
all baseline and seed-wrap operations plus deterministic representation of both
depth-two families without evaluating their Cartesian product.

Finalist work remains bounded at exactly two transparent scans per successfully
rendered finalist mask: one black and one white. Worst case is therefore
`2 x finalist_limit` full-resolution scans, reported as `scored_count` and
`attempts.transparent.scanned`. Finalist preselection collapses candidates that
differ only in an unreached font cap, so no finalist slot or mask render is
spent twice on one rendered layout.

Within one scan, only pixels at or above the core mask threshold touch the
sample accumulator. A contributing pixel accumulates one contrast value into
the overall, line, and overlapping-tile groups. The sRGB gamma expansion behind
relative luminance uses a compile-time 256-entry table rather than a power call
per channel per pixel.

Per-scan cost therefore scales with the **candidate rect area**: every pixel of
the rect is walked once, and glyph area only sets how many of those pixels pay
the accumulator cost. An inner-spread rect can approach 1700x1650px, so worst
case is 20 such scans per page. Production calibration remains tracked as
GitHub issue #13.
