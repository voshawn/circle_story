# Character Reference Images — Design

**Date:** 2026-07-03
**Status:** Approved, pending implementation plan

## Goal

Reliably and consistently render the same characters across a book. For each
character we optionally accept a user-uploaded source photo, then generate an
**AI character reference portrait** in the book's master style. That reference
is reused two ways:

1. As a conditioning image (alongside the character's text prompt) when
   generating any spread that features the character.
2. Circle-cropped into the **back cover** (protagonist) and, separately, a
   user-uploaded photo circle-cropped into the **dedication** page.

There is no DB or upload UI yet. Everything is driven from IEx via `Generator`
and the `NanisMagicThread` template, using local files and in-memory structs.

## Decisions (from brainstorming)

- **Reference trigger:** Generate an AI reference for **every** character.
  Condition on `source_image + prompt` when a source photo exists; otherwise
  generate from the prompt alone. Maximizes cross-spread consistency.
- **Character selection for spreads:** **Name matching** — inject only the
  characters whose name appears in the spread's `text` or `image_prompt`. No LLM
  call.
- **Protagonist:** `List.first(book.characters)` for now, behind a
  `protagonist/1` helper so the rule can change later.
- **Reference image style:** Single clean portrait/figure on a soft plain
  background, square (`1:1`) for clean circle-cropping. Reused for both spread
  conditioning and the back-cover circle.

## File conventions

| Kind | Folder | Path stored where |
|------|--------|-------------------|
| Character source photo (input) | `priv/source_images/` | `Character.source_image_path` (set in template) |
| Dedication photo (input) | `priv/source_images/` | `DedicationSpread.user_image_path` (set in template) |
| AI character reference (output) | `priv/generated_images/` | `Character.reference_image_path` (set by generator, in-memory) |

- `priv/source_images/` is a new folder for hand-provided inputs, committed to
  the repo. The template references files with the existing idiom:
  `Path.join(:code.priv_dir(:circle_story), "source_images/ornella.jpg")`.
- AI references are saved as
  `priv/generated_images/character_<slug>_<ts>.png`, alongside existing
  `inner_*`/`cover_front_*` art. `<slug>` is the downcased, non-alphanumeric →
  `_` character name.
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
No new field. Protagonist resolved via a helper (see below).

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
    an instruction to match that person's likeness.
  - Aspect ratio `1:1`; `google_thinking_level: :high` (consistent with
    `GenerateSpreadImage`).
  - Save to `priv/generated_images/character_<slug>_<ts>.png`.
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
- Change `user_message/2` to accept an already-filtered list of characters (the
  caller does the name matching) — it builds `<CHARACTERS>` blocks only for the
  characters it is given.

## Character selection: `CharacterMatch`

New module `lib/circle_story/books/character_match.ex`:

- `for_spread(spread, characters)` → the subset of `characters` whose `name`
  appears in `spread.text` **or** `spread.image_prompt`, case-insensitive,
  matched on word boundaries (so "Asha" does not match inside another word).
- For the cover (no `text`), match against `cover.image_prompt` only.
- If nothing matches, returns `[]` — the scene prompt stands alone; no
  characters are injected.

Wiring in `GenerateSpreadImage.run/2`:
1. Compute `matched = CharacterMatch.for_spread(spread, characters)`.
2. Pass `matched` to `PromptBuilder.user_message/2` (matched `<CHARACTERS>`
   blocks only).
3. Pass `matched` to `load_reference_images/1` (matched reference images only).

`Generator.inspect_prompt/2` uses the same matching so previews stay accurate.

## Generator orchestration

`lib/circle_story/books/generator.ex`:

- `generate_character_reference(book, name)` → runs the action for the named
  character, returns `{:ok, updated_book}` with that character's
  `reference_image_path` filled (mirrors the `put_cover_raw` update pattern).
- `generate_character_references(book)` → generates for all characters, returns
  the updated book. Convenience for IEx.
- `attach_character_references(book)` → for each character, re-attach the newest
  `character_<slug>_*` via `ImageOps.latest_raw/1` without regenerating (mirrors
  `compose_cover`'s `latest_raw` re-attach). Missing references are left `nil`.

`ImageOps.latest_raw/1` already supports arbitrary prefixes, so no change there.

Typical IEx workflow:

```elixir
book = CircleStory.Books.Templates.NanisMagicThread.book()
{:ok, book} = CircleStory.Books.Generator.generate_character_references(book)
{:ok, %{image_path: p}} = CircleStory.Books.Generator.generate_cover(book)
{:ok, %{image_path: p}} = CircleStory.Books.Generator.generate_spread(book, 1)
```

## Rendering the circles

### Back cover (`PageComponents.cover/1`)
- Add an optional `protagonist_uri` assign (default `nil`).
- When present: render a circle-cropped `<img>` (`border-radius:50%;
  object-fit:cover;`) in the existing circle geometry.
- When `nil`: keep the current pink placeholder (graceful fallback).
- `Composition.cover_html/2` resolves `protagonist(book)` → its
  `reference_image_path`; when set, `ImageOps.fit(path, d, d)` (square, `d = 2 *
  circle_r`) then `to_data_uri/1`, passed as `protagonist_uri`.

### Dedication (`PageComponents.dedication/1`)
- Add an optional `dedication_uri` assign (default `nil`); same circle-crop
  treatment and placeholder fallback.
- `Composition.dedication_html/1` resolves `dedication.user_image_path`; when
  set, fit-to-square + `to_data_uri`.

### `protagonist/1` helper
Lives where the back cover composition can reach it (e.g. `Book` or
`Composition`). Returns `List.first(book.characters)`; single source of truth for
the protagonist rule.

## Testing

Unit tests only (no model calls, consistent with the existing untested
Gemini-calling actions):

- `CharacterMatch.for_spread/2`: matched subset, case-insensitivity, no-match →
  `[]`, word-boundary/substring safety.
- `PromptBuilder.user_message/2` builds `<CHARACTERS>` blocks for only the
  characters it is given; `system_prompt(:character)` includes the master style.
- `protagonist/1` returns the first character.
- `PageComponents.cover/1` and `dedication/1` render an `<img>` when the URI is
  present and the pink placeholder when it is `nil`.

`GenerateCharacterReference` and the `Generator.generate_*` functions that call
Gemini stay IEx-exercised, consistent with `GenerateSpreadImage`.

## Out of scope

- Upload UI / LiveView.
- Persistence / storage buckets (paths are in-memory only for now).
- Changing the protagonist rule beyond "first character".
- Reference character sheets / multi-pose references.
