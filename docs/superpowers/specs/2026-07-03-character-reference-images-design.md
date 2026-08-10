# Character Reference Images — Design

**Date:** 2026-07-03
**Status:** Approved — implemented (see
`docs/superpowers/plans/2026-07-03-character-reference-images.md`)

## Goal

Reliably and consistently render the same characters across a book. For each
character we optionally accept a user-uploaded source photo, then generate an
**AI character reference portrait** in the book's master style. That reference
is reused two ways:

1. As a conditioning image (alongside the character's text prompt) when
   generating any spread that features the character.
2. Circle-cropped into the **back cover** (the back-cover character) and,
   separately, a
   user-uploaded photo circle-cropped into the **dedication** page.

There is no DB or upload UI yet. Everything is driven from IEx via `Generator`
and the `NanisMagicThread` template, using local files and in-memory structs.

## Decisions (from brainstorming)

- **Reference trigger:** Generate an AI reference for **every** character.
  Condition on `source_image + prompt` when a source photo exists; otherwise
  generate from the prompt alone. Maximizes cross-spread consistency.
- **Character selection for spreads:** Gemini 3.1 Flash-Lite selects configured
  names from the spread's `text` and `image_prompt` before an actual render. The
  result is cached; previews only read that cache and never initiate a paid call.
  A selection failure warns and includes all configured characters.
- **Back cover character:** `List.first(book.characters)` for now, behind a
  `back_cover_character/1` helper so the rule can change later.
- **Reference image style:** Single clean portrait/figure on a soft plain
  background, square (`1:1`) for clean circle-cropping. Reused for both spread
  conditioning and the back-cover circle.

## File conventions

| Kind | Folder | Path stored where |
|------|--------|-------------------|
| Character source photo (input) | `priv/source_images/` | `Character.source_image_path` (set in template) |
| Dedication photo (input) | `priv/source_images/` | `DedicationSpread.user_image_path` (set in template) |
| AI character reference (output) | `priv/generated_images/` | `Character.reference_image_path` (set by generator, in-memory) |

- `priv/source_images/` is a new folder for hand-provided inputs. Only its
  `.gitkeep` is tracked — the photos themselves are real people (including
  children) and are gitignored. The template references files with the existing
  idiom: `Path.join(:code.priv_dir(:circle_story), "source_images/ornella.jpg")`.
- AI references are saved as
  `priv/generated_images/character_<slug>_<digest>_<ts>.png`, alongside existing
  `inner_*`/`cover_front_*` art. `<slug>` is the downcased, non-alphanumeric →
  `_` character name (lossy, so filenames stay ASCII) and `<digest>` is the
  first 8 hex chars of the SHA-256 of the exact name, which is what actually
  keeps two characters apart — see `GenerateCharacterReference.reference_prefix/1`
  for why the slug alone is not enough.
- The digest was added after the first portraits were generated, so any
  `character_<slug>_<ts>.png` written before it is no longer found by
  `attach_character_reference/2`; regenerate or rename those. Acceptable for a
  pre-release, IEx-driven feature with no persistence.
- Reference paths live only in memory on the returned `Book` struct (no DB),
  the same as `generated_image_path` today.

## Struct changes

### `Character` (`lib/circle_story/books/character.ex`)
- Keep `name`, `image_prompt`.
- **Add** `source_image_path` — optional user-uploaded source photo (input).
- **Repurpose** `reference_image_path` — now specifically the AI-generated
  style reference portrait (output). Spreads already load this field, so
  downstream wiring is unchanged.

```elixir
defstruct [:name, :image_prompt, :source_image_path, :reference_image_path]
```

### `DedicationSpread`
No struct change — `user_image_path` already exists; we start rendering it.

### `Book`
No new field. The back-cover character is resolved via a helper (see below).

## New action: `GenerateCharacterReference`

`lib/circle_story/books/actions/generate_character_reference.ex` (`use
Jido.Action`).

- **Schema:** `character` (Character struct, required).
- **Behavior:**
  - System prompt: `PromptBuilder.system_prompt(:character)` — master style +
    portrait composition rules (single centered subject, soft plain background,
    upper/full figure, **no text**).
  - User message: the character's `image_prompt`.
  - If `source_image_path` is set, load it and attach as a reference image with
    an instruction to match that person's likeness. An unreadable path degrades
    to a text-only portrait rather than failing, but logs a warning — the call
    is paid, so a silently ignored photo must not look like success.
  - Aspect ratio `1:1`; `google_thinking_level: :high` (consistent with
    `GenerateSpreadImage`).
  - Save under `priv/generated_images/` with the filename from
    `reference_prefix/1` (see "File conventions" above).
- **Returns:** `{:ok, %{image_path: path}}`.

Reuses `GenerateSpreadImage`'s existing helpers where practical (image loading,
mime detection, save). Any shared helper extraction is left to the implementer's
judgment; do not over-refactor.

## `PromptBuilder` changes

- Extract the duplicated MASTER STYLE prose into a single module attribute
  referenced by the inner, cover, **and** character system prompts. Targeted
  de-duplication only.
- Add `system_prompt(:character)` — master style + portrait composition rules.
- Add a single-character message builder (e.g. `character_message/1`) wrapping
  one character's prompt in the `<CHARACTERS>` structure.
- Change `user_message/2` to accept an already-selected list of characters — it
  builds `<CHARACTERS>` blocks only for the characters it is given.

## Character selection: `CharacterSelector`

`lib/circle_story/books/character_selector.ex` is the single seam for "which
characters belong in this spread." `for_spread/2` is used only by actual spread
rendering. On a cache miss it calls the configured provider — by default
`CharacterSelector.Gemini`, which uses `google:gemini-3.1-flash-lite` structured
output to return exact names from the configured candidate list. This handles
names embedded in space-free scripts without adding language-specific boundary
rules. The provider is overridable via the `:character_selector_provider`
application env or a `:provider` option, which is how tests pin deterministic
fakes.

Selections are stored as JSON under
`priv/generated_images/character_selections/` (gitignored), keyed by the spread
text, image prompt, and configured names. Cached names are validated against the
current candidates before use. A retry reuses a cached *model* selection, but
selects again when the cached entry is an include-all failure fallback or was
produced under a different `Provider.selection_version/0` — the provider module
plus everything that determines its answers, which for Gemini is the model,
thinking level, full prompt text, and response schema — so neither a transient
failure nor a superseded selection identity can pin a spread forever. A provider
that cannot report its version yields an unmatchable one, so no cached entry is
reused.

`for_preview/2` only reads this cache, and reuses an entry only when it is a
model selection recorded under the current `Provider.selection_version/0`
(reading that version is a pure call). A preview before the first render, or one
whose cached entry is a fallback, is superseded, or has an unreadable version,
warns and includes all configured characters; it never initiates a model call.
Provider errors, invalid responses, and cache errors are logged explicitly. A
provider failure uses and caches an include-all fallback so a paid image render
never silently loses character conditioning.

Wiring in `GenerateSpreadImage.run/2`:
1. Compute `selected = CharacterSelector.for_spread(spread, characters)`.
2. Pass `selected` to `PromptBuilder.user_message/2` (selected `<CHARACTERS>`
   blocks only). Every selected character contributes its text prompt.
3. Pass `selected` to `load_reference_images/1`, which attaches a reference
   image **only for characters that have a generated `reference_image_path`**.
   A selected character with no generated reference still contributes its text
   prompt but no image.

`Generator.inspect_prompt/2` uses `for_preview/2`, so it reuses a cached render
selection without creating a paid selection call.

## Generator orchestration

`lib/circle_story/books/generator.ex`. Generation is **per character, at your
discretion** — there is no batch "generate all". A book with no generated
references simply generates spreads without reference images (the characters'
text prompts still flow via the selector).

- `generate_character_reference(book, name)` → runs the action for the named
  character, returns `{:ok, updated_book}` with that character's
  `reference_image_path` filled (mirrors the `put_cover_raw` update pattern).
- `attach_character_reference(book, name)` → re-attach the newest saved
  reference for one character via `ImageOps.latest_raw/1` without regenerating
  (mirrors `compose_cover`'s `latest_raw` re-attach). Returns
  `{:error, :no_reference_image}` when nothing is saved for that character —
  an unchanged `{:ok, book}` is indistinguishable from a real attach and would
  buy an unconditioned spread.

`ImageOps.latest_raw/1` takes arbitrary prefixes, but it anchors on the trailing
timestamp (`^prefix\d+\.png$`) rather than globbing `prefix*.png`, so one
character's prefix cannot pick up a longer sibling's portrait.

Typical IEx workflow (generate references one at a time, as desired):

```elixir
book = CircleStory.Books.Templates.NanisMagicThread.book()
{:ok, book} = CircleStory.Books.Generator.generate_character_reference(book, "Ornella")
{:ok, book} = CircleStory.Books.Generator.generate_character_reference(book, "Nani")
{:ok, %{image_path: p}} = CircleStory.Books.Generator.generate_cover(book)
{:ok, %{image_path: p}} = CircleStory.Books.Generator.generate_spread(book, 1)
```

## Rendering the circles

### Back cover (`PageComponents.cover/1`)
- Add an optional `character_uri` assign (default `nil`).
- When present: render a circle-cropped `<img>` (`border-radius:50%;
  object-fit:cover;`) in the existing circle geometry.
- When `nil`: keep the current pink placeholder (graceful fallback). A path that
  is set but missing or undecodable also falls back, with a warning logged.
- `Composition.cover_html/2` resolves `back_cover_character(book)` → its
  `reference_image_path`; when set, `ImageOps.fit(path, d, d)` (square, `d = 2 *
  circle_r`) then `to_data_uri/1`, passed as `character_uri`.

### Dedication (`PageComponents.dedication/1`)
- Add an optional `dedication_uri` assign (default `nil`); same circle-crop
  treatment and placeholder fallback.
- `Composition.dedication_html/1` resolves `dedication.user_image_path`; when
  set, fit-to-square + `to_data_uri`.

### `back_cover_character/1` helper
Lives where the back cover composition can reach it (e.g. `Book` or
`Composition`). Returns `List.first(book.characters)`; single source of truth for
which character appears in the back-cover circle.

## Testing

Selector behavior is unit tested through deterministic provider fakes, and the
real `CharacterSelector.Gemini` adapter through a stubbed local HTTP plug; no
live model calls are made anywhere:

- `CharacterSelector.for_spread/2`: ASCII, accented Latin, prefix safety, and a
  space-free CJK mention; cache reuse; preview behavior (including a superseded
  selection version); and explicit include-all failures.
- `CharacterSelector.Gemini.select/3` against a `Plug` stub: the emitted request
  contract (thinking level, candidate-constrained response schema, prompt
  fields), the decoded selection, and error paths. Model interpretation is never
  asserted.
- `GenerateSpreadImage.build_request/4`: selected prompt blocks and reference
  image bytes both survive to the normalized request boundary.
- `GenerateCharacterReference.reference_prefix/1`: stable per name, ASCII-safe,
  and never shared by two distinct names (accented and non-Latin included).
- `ImageOps.latest_raw/1`: the trailing-timestamp anchor excludes a longer
  sibling built on the same prefix.
- `PromptBuilder.user_message/2` builds `<CHARACTERS>` blocks for only the
  characters it is given; `system_prompt(:character)` includes the master style.
- `back_cover_character/1` returns the first character.
- `PageComponents.cover/1` and `dedication/1` render an `<img>` when the URI is
  present and the pink placeholder when it is `nil`.

The Gemini-calling paths — `GenerateCharacterReference.run/2` and the
`Generator.generate_*` functions — stay IEx-exercised and `@tag :integration`
(excluded from `mix test`), consistent with `GenerateSpreadImage`; only their
pure helpers are unit tested.

## Out of scope

- Upload UI / LiveView.
- Persistence / storage buckets (paths are in-memory only for now).
- Changing the `back_cover_character/1` rule beyond "first character".
- Reference character sheets / multi-pose references.
