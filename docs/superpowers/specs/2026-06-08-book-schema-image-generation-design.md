# Book Schema & Image Generation Design

**Date:** 2026-06-08  
**Status:** Approved  

## Overview

Minimal infrastructure to represent a children's board book as in-memory Elixir structs and test an end-to-end AI image generation call via the Google Gemini model using `ReqLLM` wrapped in a `Jido.Action`.

No Ecto schemas or database migrations in this phase. All structs are plain Elixir `defstruct` with `@type` specs and can be converted to Ecto schemas in a later iteration.

---

## Data Structs

All modules live under `CircleStory.Books`.

### `Book`

```elixir
%Book{
  title: string,
  cover: %CoverSpread{},
  dedication: %DedicationSpread{},
  spreads: [%InnerSpread{}, ...],   # exactly 9
  characters: [%Character{}, ...]
}
```

### `CoverSpread`

Full wraparound: back cover + spine + front cover.

```elixir
%CoverSpread{
  text: string,
  image_prompt: string,
  generated_image_path: string | nil
}
```

Target dimensions: **3863 × 1875 px**

### `DedicationSpread`

User-uploaded photo with a text dedication. Not AI-generated — no image prompt.

```elixir
%DedicationSpread{
  text: string,
  user_image_path: string | nil
}
```

### `InnerSpread`

One of nine story spreads.

```elixir
%InnerSpread{
  position: 1..9,
  text: string,
  image_prompt: string,
  generated_image_path: string | nil
}
```

Target dimensions: **3675 × 1875 px**

### `Character`

```elixir
%Character{
  name: string,
  image_prompt: string,
  reference_image_path: string | nil   # local path for now, storage URL later
}
```

---

## Prompt Assembly — `CircleStory.Books.PromptBuilder`

A pure module with no side effects. Produces two strings for every generation call.

### System prompt

Hardcoded per spread type (`:inner` or `:cover`). Contains:
- The master illustration style block (children's book style, color palette, mood, avoid list)
- Composition instructions specific to the spread type
  - `:inner` — leave empty space for text overlay, avoid placing content at the center fold
  - `:cover` — compose for a wraparound (back + spine + front), leave space for title treatment

### User message

Assembled from the `Book` struct at call time:

```
<SCENE>
{spread.image_prompt}
</SCENE>

<CHARACTERS>
<CHARACTER_NAME>
{character.image_prompt}
</CHARACTER_NAME>
...
</CHARACTERS>
```

- Character tag names use the character's name uppercased (e.g. `<CHLOE>`, `<CHRISTINE>`)
- Characters with a `reference_image_path` receive a note in the system prompt that reference images are attached

### Public API

```elixir
PromptBuilder.system_prompt(:inner | :cover) :: String.t()
PromptBuilder.user_message(spread, characters) :: String.t()
```

---

## Image Generation — `CircleStory.Books.Actions.GenerateSpreadImage`

A `Jido.Action` that handles one image generation call and returns the local path of the saved image.

### Schema inputs

| Field | Type | Description |
|-------|------|-------------|
| `spread` | `InnerSpread \| CoverSpread` | The spread to generate an image for |
| `characters` | `[Character]` | All characters in the book |
| `spread_type` | `:inner \| :cover` | Controls system prompt and output dimensions |

### Execution steps

1. Call `PromptBuilder.system_prompt(spread_type)` and `PromptBuilder.user_message(spread, characters)`
2. Load any character `reference_image_path` binaries from disk (skip if `nil`)
3. Call `ReqLLM.generate_image/3`:
   - Model: `"google:gemini-3.1-flash-image"`
   - Prompt: user message string
   - Options: `system:` prompt, reference image binaries as multimodal content, aspect ratio hint (`"2:1"`)
4. Decode the returned image bytes
5. Write to `priv/generated_images/{spread_type}_{position_or_cover}_{timestamp}.png` (e.g. `inner_3_1234567890.png`, `cover_1234567890.png`)
6. Return `{:ok, %{image_path: path}}`

### Error handling

Returns `{:error, reason}` on API failure or file write failure — Jido's action lifecycle emits telemetry events for both outcomes.

### Telemetry

Jido emits standard action lifecycle events (`start`, `complete`, `error`) which carry the action name and timing. ReqLLM additionally emits OpenTelemetry spans for the HTTP call itself, including token/cost metadata.

---

## File Layout

```
lib/circle_story/books/
  book.ex                          # Book struct
  cover_spread.ex                  # CoverSpread struct
  dedication_spread.ex             # DedicationSpread struct
  inner_spread.ex                  # InnerSpread struct
  character.ex                     # Character struct
  prompt_builder.ex                # Pure prompt assembly
  actions/
    generate_spread_image.ex       # Jido.Action
priv/generated_images/             # Output directory (gitignored)
```

---

## Out of Scope (This Phase)

- Ecto schemas and database migrations
- UI / LiveView
- Cover prompt authoring (system prompt stub only — content TBD)
- Dedication spread image handling
- Batch generation across all spreads
- Storage bucket integration for reference images or outputs
