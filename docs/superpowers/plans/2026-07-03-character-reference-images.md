# Character Reference Images Implementation Plan

**Status:** Shipped — historical execution record. The `- [ ]` step boxes below
are the authoring syntax this plan was written in, not open work; like the other
plans in `docs/superpowers/plans/`, they are not flipped after execution. For
what actually ships today, read
`docs/superpowers/specs/2026-07-03-character-reference-images-design.md`, which
is the authoritative contract wherever it and a task step disagree.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Executed — historical record.** Pre-merge review changed several contracts this plan specifies: `reference_prefix/1` appends a name digest, `CharacterSelector` matches with the `/u` modifier, `ImageOps.latest_raw/1` anchors on the trailing timestamp, and `attach_character_reference/2` returns `{:error, :no_reference_image}` instead of the book unchanged. The shipped contracts live in the module `@doc`s and in `docs/superpowers/specs/2026-07-03-character-reference-images-design.md`; do not read the snippets below as current.

**Goal:** Generate an AI character reference portrait (in the book's master style) for each character, reuse it as a conditioning image for the spreads that feature that character, and render it (plus a user-uploaded dedication photo) into the back-cover and dedication circles.

**Architecture:** A new Jido action (`GenerateCharacterReference`) produces a square portrait saved under `priv/generated_images/`; its path lands in-memory on `Character.reference_image_path` via new `Generator` functions. `CharacterSelector` is the single seam for "which characters belong in this spread"; actual renders use a cached Gemini 3.1 Flash-Lite selection, while previews only consume the cache. `GenerateSpreadImage` routes character prompts/images through it. `PageComponents` gain optional image URIs for the two circles, resolved by `Composition` from the relevant paths.

**Tech Stack:** Elixir 1.20 / Phoenix 1.8 / LiveView, Jido + ReqLLM (Google Gemini image model), `image`/libvips (`ImageOps`), ExUnit + `Phoenix.LiveViewTest`.

## Global Constraints

- Image model is `google:gemini-3.1-flash-image`, called via `ReqLLM.generate_image/3` with `google_thinking_level: :high` (match existing `GenerateSpreadImage`).
- No DB and no upload UI: reference/source paths live only in-memory on structs for the session.
- Bundled assets live under `priv/`: inputs in `priv/source_images/`, generated art in `priv/generated_images/`.
- `mix test` excludes `:integration` (see `test/test_helper.exs`). Model-calling tests must be tagged `@tag :integration`.
- Run `mix precommit` before finishing (compile warnings-as-errors, unused-dep check, format, test). Any unused alias/variable fails the build.
- HEEx escapes text in `{...}` (e.g. `'` → `&#39;`); assert against escaped output in component tests.

> **2026-08 selector follow-up:** Task 2 below records the original deterministic
> implementation. It was superseded after Unicode word boundaries still dropped
> CJK names adjacent to other CJK text. The implemented contract is documented in
> the design's `CharacterSelector` section: render-only Gemini selection, a
> content-keyed cache reused by retries/previews, and explicit warning plus an
> include-all fallback on failure. Tests use only the provider fake.
>
> Review also changed two smaller shapes the tasks below still record:
> `reference_prefix/1` is now `character_<slug>_<digest>_` (Task 4), and
> `attach_character_reference/2` returns `{:error, :no_reference_image}` rather
> than the book unchanged (Task 6).

---

### Task 1: Character struct field, source-image folder, and `Book.back_cover_character/1`

**Files:**
- Modify: `lib/circle_story/books/character.ex`
- Modify: `lib/circle_story/books/book.ex`
- Create: `priv/source_images/.gitkeep`
- Create (test): `test/circle_story/books/book_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `%Character{name, image_prompt, source_image_path, reference_image_path}` — `source_image_path` is the optional user upload (input); `reference_image_path` is the AI-generated portrait (output).
  - `CircleStory.Books.Book.back_cover_character(book :: Book.t()) :: Character.t() | nil` — the character shown in the back-cover circle (currently the first character).

- [ ] **Step 1: Write the failing test**

Create `test/circle_story/books/book_test.exs`:

```elixir
defmodule CircleStory.Books.BookTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.{Book, Character}

  test "back_cover_character/1 returns the first character" do
    a = %Character{name: "Ornella", image_prompt: "baby"}
    b = %Character{name: "Nani", image_prompt: "elder"}
    book = %Book{title: "T", author: "A", characters: [a, b]}

    assert Book.back_cover_character(book) == a
  end

  test "back_cover_character/1 returns nil when there are no characters" do
    book = %Book{title: "T", author: "A", characters: []}
    assert Book.back_cover_character(book) == nil
  end

  test "Character carries an optional source_image_path" do
    c = %Character{name: "Ornella", image_prompt: "baby", source_image_path: "x.jpg"}
    assert c.source_image_path == "x.jpg"
    assert c.reference_image_path == nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/circle_story/books/book_test.exs`
Expected: FAIL — `back_cover_character/1` undefined and/or `KeyError` on `:source_image_path`.

- [ ] **Step 3: Add the struct field**

In `lib/circle_story/books/character.ex`, replace the `defstruct` and type:

```elixir
defmodule CircleStory.Books.Character do
  @enforce_keys [:name, :image_prompt]
  defstruct [:name, :image_prompt, :source_image_path, :reference_image_path]

  @type t :: %__MODULE__{
          name: String.t(),
          image_prompt: String.t(),
          source_image_path: String.t() | nil,
          reference_image_path: String.t() | nil
        }
end
```

- [ ] **Step 4: Add the `back_cover_character/1` helper**

In `lib/circle_story/books/book.ex`, add the function after the `@type` block (inside the module):

```elixir
  @doc "The character shown in the back-cover circle (currently the first)."
  @spec back_cover_character(t()) :: Character.t() | nil
  def back_cover_character(%__MODULE__{characters: characters}), do: List.first(characters)
```

`Character` is already aliased at the top of `book.ex`.

- [ ] **Step 5: Create the source-images folder**

Create `priv/source_images/.gitkeep` with empty content (keeps the input folder in the repo; you drop character source photos and dedication photos here and reference them with `Path.join(:code.priv_dir(:circle_story), "source_images/<file>")`).

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/circle_story/books/book_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add lib/circle_story/books/character.ex lib/circle_story/books/book.ex test/circle_story/books/book_test.exs priv/source_images/.gitkeep
git commit -m "feat: character source_image_path + Book.back_cover_character/1"
```

---

### Task 2: `CharacterSelector` — the character-selection seam

**Files:**
- Create: `lib/circle_story/books/character_selector.ex`
- Create (test): `test/circle_story/books/character_selector_test.exs`

**Interfaces:**
- Consumes: `%Character{name}`, and a spread that may be an `InnerSpread` (has `:text` + `:image_prompt`) or `CoverSpread` (has `:image_prompt` only).
- Produces: `CircleStory.Books.CharacterSelector.for_spread(spread, characters :: [Character.t()]) :: [Character.t()]` — the subset that appears in the spread. Only public entry; strategy (name matching) is internal and swappable.

- [ ] **Step 1: Write the failing test**

Create `test/circle_story/books/character_selector_test.exs`:

```elixir
defmodule CircleStory.Books.CharacterSelectorTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.{Character, CharacterSelector, CoverSpread, InnerSpread}

  defp chars do
    [
      %Character{name: "Ornella", image_prompt: "baby"},
      %Character{name: "Nani", image_prompt: "elder"},
      %Character{name: "Asha", image_prompt: "professor"}
    ]
  end

  test "selects characters named in the spread text" do
    spread = %InnerSpread{position: 1, text: "Meet Ornella.", image_prompt: "a nursery"}
    assert CharacterSelector.for_spread(spread, chars()) |> Enum.map(& &1.name) == ["Ornella"]
  end

  test "selects characters named in the image_prompt too" do
    spread = %InnerSpread{position: 2, text: "A quiet night.", image_prompt: "Nani watches over the house"}
    assert CharacterSelector.for_spread(spread, chars()) |> Enum.map(& &1.name) == ["Nani"]
  end

  test "matching is case-insensitive" do
    spread = %InnerSpread{position: 3, text: "meet ORNELLA and nani", image_prompt: "x"}
    assert CharacterSelector.for_spread(spread, chars()) |> Enum.map(& &1.name) == ["Ornella", "Nani"]
  end

  test "matches whole words only (no substring false positives)" do
    spread = %InnerSpread{position: 4, text: "Sasha felt ashamed.", image_prompt: "x"}
    assert CharacterSelector.for_spread(spread, chars()) == []
  end

  test "returns [] when no character is named" do
    spread = %InnerSpread{position: 5, text: "A quiet meadow.", image_prompt: "rolling hills"}
    assert CharacterSelector.for_spread(spread, chars()) == []
  end

  test "works with a CoverSpread (image_prompt only, no :text)" do
    cover = %CoverSpread{tagline: "t", image_prompt: "Nani sits with baby Ornella"}
    assert CharacterSelector.for_spread(cover, chars()) |> Enum.map(& &1.name) == ["Ornella", "Nani"]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/circle_story/books/character_selector_test.exs`
Expected: FAIL — `CharacterSelector` undefined.

- [ ] **Step 3: Implement `CharacterSelector`**

Create `lib/circle_story/books/character_selector.ex`:

```elixir
defmodule CircleStory.Books.CharacterSelector do
  @moduledoc """
  Decides which characters belong in a given spread. This is the single seam for
  character selection: callers use only `for_spread/2`. The current strategy is
  whole-word name matching against the spread's text and image prompt; it can be
  swapped for an LLM call later without touching any caller.
  """

  alias CircleStory.Books.Character

  @doc "The subset of `characters` that appear in `spread` (by name)."
  @spec for_spread(struct(), [Character.t()]) :: [Character.t()]
  def for_spread(spread, characters) do
    haystack =
      [Map.get(spread, :text), Map.get(spread, :image_prompt)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    Enum.filter(characters, fn %Character{name: name} -> mentioned?(haystack, name) end)
  end

  defp mentioned?(haystack, name) do
    Regex.match?(~r/\b#{Regex.escape(String.downcase(name))}\b/, haystack)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/circle_story/books/character_selector_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/character_selector.ex test/circle_story/books/character_selector_test.exs
git commit -m "feat: CharacterSelector.for_spread/2 name-matching seam"
```

---

### Task 3: `PromptBuilder` — shared master style, `:character` prompt, `character_message/1`

**Files:**
- Modify: `lib/circle_story/books/prompt_builder.ex`
- Modify (test): `test/circle_story/books/prompt_builder_test.exs`

**Interfaces:**
- Consumes: `%Character{name, image_prompt}`.
- Produces:
  - `PromptBuilder.system_prompt(:inner | :cover | :character) :: String.t()` (adds `:character`).
  - `PromptBuilder.character_message(character :: Character.t()) :: String.t()` — the single-character block for reference generation.
  - `PromptBuilder.user_message/2` is unchanged in signature; it already builds `<CHARACTERS>` blocks for exactly the list it is handed (callers now hand it a filtered list).

- [ ] **Step 1: Write the failing tests**

Add to `test/circle_story/books/prompt_builder_test.exs`, inside the `describe "system_prompt/1"` block:

```elixir
    test "returns a character portrait prompt for :character" do
      prompt = PromptBuilder.system_prompt(:character)
      assert is_binary(prompt)
      assert prompt =~ "MASTER STYLE"
      assert prompt =~ "reference portrait"
      assert prompt =~ "plain"
    end

    test ":inner still contains the shared master style after extraction" do
      assert PromptBuilder.system_prompt(:inner) =~
               "Antoine de Saint-Exupéry's The Little Prince"
    end
```

Add a new `describe` block at the end of the module (before the final `end`):

```elixir
  describe "character_message/1" do
    test "wraps a single character's prompt in an uppercased name tag" do
      character = %Character{name: "Ornella", image_prompt: "A joyful baby girl."}
      msg = PromptBuilder.character_message(character)
      assert msg =~ "<ORNELLA>"
      assert msg =~ "A joyful baby girl."
      assert msg =~ "</ORNELLA>"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/circle_story/books/prompt_builder_test.exs`
Expected: FAIL — `system_prompt(:character)` has no clause; `character_message/1` undefined.

- [ ] **Step 3: Extract the shared master style and add the character prompt**

In `lib/circle_story/books/prompt_builder.ex`, add a `@master_style_core` attribute above `@inner_system_prompt` (this is the descriptive block that is byte-for-byte identical in the current inner and cover prompts):

```elixir
  @master_style_core """
                     Style: Children's book \
                     illustration inspired by Antoine de Saint-Exupéry's The Little Prince, modernized \
                     with bolder, more saturated colors. Watercolor and gouache painting style with \
                     delicate ink linework — loose, expressive, and slightly whimsical. Soft, blended \
                     color washes with smooth gradients. Characters have simple, charming proportions \
                     with expressive faces rendered in minimal, confident lines. Color palette: Warm and \
                     vibrant but still soft — rich golden yellows, deep sky blues, blush pinks, sage \
                     greens, terracotta, and creamy off-whites. Colors should feel sun-drenched and \
                     emotionally warm, not pastel or washed out. Backgrounds feature gentle color washes \
                     or open negative space to keep focus on the characters. Composition: Storybook \
                     layouts with a sense of openness and air. Soft, dreamy lighting. Clean linework \
                     with a handmade, timeless quality. Smooth finish suitable for high-quality print \
                     reproduction. Mood: Tender, nostalgic, joyful, and gently magical — like a modern \
                     classic.\
                     """
                     |> String.trim()
```

Then replace the descriptive run inside `@inner_system_prompt` with `#{@master_style_core}`. The attribute becomes:

```elixir
  @inner_system_prompt """
                       You are generating inner page spreads for a children's book. You should follow \
                       this Master Style for every image generation <MASTER STYLE> #{@master_style_core} \
                       Avoid: Photorealism, 3D rendering, anime, sharp digital lines, neon colors, \
                       busy backgrounds, generic AI "storybook" aesthetic, paper texture, canvas texture, \
                       grainy or rough surfaces, visible brushstrokes, scanned-art look, book spines, \
                       page edges, gutters, fold lines, center creases, white borders, any book anatomy. \
                       Do not include any story text in the artwork. Text is only acceptable on objects \
                       in the image. </MASTER STYLE> You will be provided with a SCENE prompt as well as \
                       one or more CHARACTERS prompts. You may also receive reference images for the scene \
                       and characters. Your job is to compose all of these prompts and images into a well \
                       designed page for a book. IMPORTANT: Generate a full-bleed illustration that fills the entire image \
                       edge to edge, with no white borders. Compose with the main subject placed off-center toward one \
                       side or corner — never dead center — leaving the opposite area calm and uncluttered with soft, \
                       simple background washes and open negative space. Keep backgrounds clean and unbusy. Do not render any text.
                       """
                       |> String.trim()
```

Replace the descriptive run inside `@cover_system_prompt` the same way:

```elixir
  @cover_system_prompt """
                       You are generating the front cover artwork for a children's board book. You should \
                       follow this Master Style for every image generation <MASTER STYLE> #{@master_style_core} \
                       Avoid: Photorealism, 3D rendering, anime, \
                       sharp digital lines, neon colors, busy backgrounds, generic AI "storybook" aesthetic, \
                       paper texture, canvas texture, grainy or rough surfaces, visible brushstrokes, \
                       scanned-art look. </MASTER STYLE> You will be provided with a SCENE prompt and \
                       CHARACTER prompts. Compose a compelling front cover image. IMPORTANT: Do not render \
                       any text, letters, words, or typography anywhere in the image — no title, no author \
                       name, no labels of any kind. The book title and author name will be overlaid \
                       separately in post-production. Leave clear space at the top for text overlay. Design \
                       with a strong focal point featuring the main character, with an inviting, eye-catching \
                       composition suitable for a children's board book cover.
                       """
                       |> String.trim()
```

Add the character prompt attribute after `@cover_system_prompt`:

```elixir
  @character_system_prompt """
                           You are generating a single character reference portrait for a children's \
                           book. You should follow this Master Style for every image generation \
                           <MASTER STYLE> #{@master_style_core} Avoid: Photorealism, 3D rendering, anime, \
                           sharp digital lines, neon colors, busy backgrounds, generic AI "storybook" \
                           aesthetic, paper texture, canvas texture, grainy or rough surfaces, visible \
                           brushstrokes, scanned-art look. </MASTER STYLE> You will be provided with one \
                           CHARACTER prompt, and you may receive a reference photo of the real person. \
                           Generate a clean, appealing reference portrait of this single character alone, \
                           centered in the frame, from roughly the waist up (or a full figure for a baby \
                           or toddler), with a calm, friendly expression. Place the character on a soft, \
                           plain, uncluttered background wash in the master-style palette so the figure \
                           can be cleanly cropped into a circle. Do not include any other characters, \
                           props, scenery, text, letters, or words. If a reference photo is provided, \
                           capture that person's likeness — face shape, features, hair, and skin tone — \
                           while rendering them fully in the master illustration style.
                           """
                           |> String.trim()
```

Add the `:character` clause and `character_message/1`. Update `system_prompt/1`'s spec and add the clause:

```elixir
  @spec system_prompt(:inner | :cover | :character) :: String.t()
  def system_prompt(:inner), do: @inner_system_prompt
  def system_prompt(:cover), do: @cover_system_prompt
  def system_prompt(:character), do: @character_system_prompt
```

Add after `user_message/2` (reuses the existing `<TAG>` convention):

```elixir
  @doc "The single-character block used when generating a reference portrait."
  @spec character_message(Character.t()) :: String.t()
  def character_message(%Character{name: name, image_prompt: prompt}) do
    tag = String.upcase(name)
    "<#{tag}>\n#{prompt}\n</#{tag}>"
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/circle_story/books/prompt_builder_test.exs`
Expected: PASS (all prior tests plus the 3 new ones).

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/prompt_builder.ex test/circle_story/books/prompt_builder_test.exs
git commit -m "feat: shared master style + character system prompt in PromptBuilder"
```

---

### Task 4: Shared `GeminiImage` helpers + `GenerateCharacterReference` action

Extract the Gemini message/call/extract/MIME helpers shared by both image
actions into `GeminiImage`, refactor the existing `GenerateSpreadImage` onto it
(no behavior change), then build the new character-reference action on it.

**Files:**
- Create: `lib/circle_story/books/actions/gemini_image.ex`
- Modify: `lib/circle_story/books/actions/generate_spread_image.ex` (refactor onto `GeminiImage`)
- Create: `lib/circle_story/books/actions/generate_character_reference.ex`
- Create (test): `test/circle_story/books/actions/gemini_image_test.exs`
- Create (test): `test/circle_story/books/actions/generate_character_reference_test.exs`

**Interfaces:**
- Consumes: `PromptBuilder.system_prompt(:character)`, `PromptBuilder.character_message/1`, `%Character{}` (incl. `source_image_path`).
- Produces:
  - `GeminiImage.generate(system_prompt :: String.t(), messages :: [map()], aspect_ratio :: String.t()) :: {:ok, ReqLLM.Response.t()} | {:error, term()}`.
  - `GeminiImage.build_messages(text :: String.t(), image_parts :: [{binary(), String.t()}]) :: [map()]`.
  - `GeminiImage.extract_image(response) :: {:ok, binary()} | {:error, term()}`.
  - `GeminiImage.mime_type(path :: Path.t()) :: String.t()`.
  - `GenerateCharacterReference.run(%{character: Character.t()}, map()) :: {:ok, %{image_path: String.t()}} | {:error, term()}`.
  - `GenerateCharacterReference.reference_prefix(name :: String.t()) :: String.t()` — the filename prefix `"character_<slug>_"` (used by the action to name the file and by `Generator` to find the latest).

- [ ] **Step 1: Write the failing `GeminiImage` test**

Create `test/circle_story/books/actions/gemini_image_test.exs`:

```elixir
defmodule CircleStory.Books.Actions.GeminiImageTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Actions.GeminiImage

  describe "build_messages/2" do
    test "returns a plain-text user message when there are no images" do
      assert GeminiImage.build_messages("hello", []) == [%{role: "user", content: "hello"}]
    end

    test "embeds image parts as base64 data URLs alongside the text" do
      [msg] = GeminiImage.build_messages("scene", [{"rawbytes", "image/png"}])
      assert %{role: "user", content: [text_part | image_parts]} = msg
      assert text_part == %{type: "text", text: "scene"}
      assert [%{type: "image_url", image_url: %{url: url}}] = image_parts
      assert url == "data:image/png;base64,#{Base.encode64("rawbytes")}"
    end
  end

  describe "mime_type/1" do
    test "maps known extensions (case-insensitively)" do
      assert GeminiImage.mime_type("a.png") == "image/png"
      assert GeminiImage.mime_type("a.JPG") == "image/jpeg"
      assert GeminiImage.mime_type("a.jpeg") == "image/jpeg"
      assert GeminiImage.mime_type("a.webp") == "image/webp"
    end

    test "defaults unknown or missing extensions to image/jpeg" do
      assert GeminiImage.mime_type("a.gif") == "image/jpeg"
      assert GeminiImage.mime_type("noext") == "image/jpeg"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/circle_story/books/actions/gemini_image_test.exs`
Expected: FAIL — `GeminiImage` undefined.

- [ ] **Step 3: Implement `GeminiImage`**

Create `lib/circle_story/books/actions/gemini_image.ex`:

```elixir
defmodule CircleStory.Books.Actions.GeminiImage do
  @moduledoc """
  Shared helpers for the Gemini image-generation actions
  (`GenerateSpreadImage`, `GenerateCharacterReference`): user-message assembly,
  the model call, response image extraction, and MIME detection.
  """

  @model "google:gemini-3.1-flash-image"

  @doc "Prepend the system prompt and call the Gemini image model."
  @spec generate(String.t(), [map()], String.t()) ::
          {:ok, ReqLLM.Response.t()} | {:error, term()}
  def generate(system_prompt, messages, aspect_ratio) do
    # System prompt passed as role: "system" — split_messages_for_gemini
    # converts it to systemInstruction for the Gemini API.
    all_messages = [%{role: "system", content: system_prompt} | messages]

    ReqLLM.generate_image(@model, all_messages,
      aspect_ratio: aspect_ratio,
      google_thinking_level: :high
    )
  end

  @doc "Build the `user` message list: plain text, or text plus image parts."
  @spec build_messages(String.t(), [{binary(), String.t()}]) :: [map()]
  def build_messages(text, []), do: [%{role: "user", content: text}]

  def build_messages(text, image_parts) do
    parts =
      Enum.map(image_parts, fn {binary, mime} ->
        %{type: "image_url", image_url: %{url: "data:#{mime};base64,#{Base.encode64(binary)}"}}
      end)

    [%{role: "user", content: [%{type: "text", text: text} | parts]}]
  end

  @doc "Extract the generated image binary from a ReqLLM response."
  @spec extract_image(ReqLLM.Response.t()) :: {:ok, binary()} | {:error, term()}
  def extract_image(response) do
    case ReqLLM.Response.image_data(response) do
      nil -> {:error, "no image data in response: #{inspect(response)}"}
      data when is_binary(data) -> {:ok, data}
    end
  end

  @doc "Guess the MIME type from a file extension (defaults to `image/jpeg`)."
  @spec mime_type(Path.t()) :: String.t()
  def mime_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      _ -> "image/jpeg"
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/circle_story/books/actions/gemini_image_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Refactor `GenerateSpreadImage` onto `GeminiImage`**

In `lib/circle_story/books/actions/generate_spread_image.ex`: add `alias CircleStory.Books.Actions.GeminiImage` (below the existing `alias CircleStory.Books.{Character, PromptBuilder}`), delete the `@model` attribute, and delete the private `build_messages/2`, `call_llm/3`, `extract_image/1`, and `mime_type/1` functions. Update `run/2` to call the shared helpers:

```elixir
  def run(%{spread: spread, characters: characters, spread_type: spread_type}, _context) do
    system_prompt = PromptBuilder.system_prompt(spread_type)
    user_msg = PromptBuilder.user_message(spread, characters)
    ref_image_parts = load_reference_images(characters)
    messages = GeminiImage.build_messages(user_msg, ref_image_parts)

    with {:ok, response} <- GeminiImage.generate(system_prompt, messages, aspect_ratio(spread_type)),
         {:ok, image_binary} <- GeminiImage.extract_image(response),
         {:ok, path} <- save_image(image_binary, spread, spread_type) do
      {:ok, %{image_path: path}}
    end
  end
```

Update `load_reference_images/1` to use `GeminiImage.mime_type/1`:

```elixir
  defp load_reference_images(characters) do
    characters
    |> Enum.filter(& &1.reference_image_path)
    |> Enum.flat_map(fn %Character{reference_image_path: path} ->
      case File.read(path) do
        {:ok, binary} -> [{binary, GeminiImage.mime_type(path)}]
        {:error, _} -> []
      end
    end)
  end
```

Leave `aspect_ratio/1`, `save_image/3`, and `build_filename/2` unchanged.

- [ ] **Step 6: Run the suite to confirm no regression**

Run: `mix test`
Expected: PASS (existing suite still green; `GenerateSpreadImage` still compiles and behaves identically — the `:integration` test is excluded).

- [ ] **Step 7: Write the failing `GenerateCharacterReference` test**

Create `test/circle_story/books/actions/generate_character_reference_test.exs`:

```elixir
defmodule CircleStory.Books.Actions.GenerateCharacterReferenceTest do
  use ExUnit.Case

  alias CircleStory.Books.Character
  alias CircleStory.Books.Actions.GenerateCharacterReference

  describe "reference_prefix/1" do
    test "slugifies the character name" do
      assert GenerateCharacterReference.reference_prefix("Ornella") == "character_ornella_"
    end

    test "collapses spaces and punctuation to single underscores" do
      assert GenerateCharacterReference.reference_prefix("Nani Ji!") == "character_nani_ji_"
    end
  end

  @tag :integration
  test "generates a reference portrait and saves it to disk" do
    character = %Character{
      name: "Ornella",
      image_prompt: "A joyful, rosy-cheeked baby girl with a bright smile and hazel eyes."
    }

    assert {:ok, %{image_path: path}} =
             GenerateCharacterReference.run(%{character: character}, %{})

    assert File.exists?(path)
    assert Path.basename(path) =~ ~r/^character_ornella_\d+\.png$/
    IO.puts("Generated character reference saved to: #{path}")
  end
end
```

- [ ] **Step 8: Run test to verify it fails**

Run: `mix test test/circle_story/books/actions/generate_character_reference_test.exs`
Expected: FAIL — `GenerateCharacterReference` undefined. (The `:integration` test is excluded by default, so only the two `reference_prefix/1` tests run.)

- [ ] **Step 9: Implement the action on `GeminiImage`**

Create `lib/circle_story/books/actions/generate_character_reference.ex`:

```elixir
defmodule CircleStory.Books.Actions.GenerateCharacterReference do
  use Jido.Action,
    name: "generate_character_reference",
    description: "Generate an AI character reference portrait via Google Gemini",
    schema: [
      character: [type: :any, required: true, doc: "Character struct"]
    ]

  alias CircleStory.Books.{Character, PromptBuilder}
  alias CircleStory.Books.Actions.GeminiImage

  @impl true
  def run(%{character: %Character{} = character}, _context) do
    system_prompt = PromptBuilder.system_prompt(:character)
    user_msg = PromptBuilder.character_message(character)
    messages = GeminiImage.build_messages(user_msg, source_image_part(character))

    with {:ok, response} <- GeminiImage.generate(system_prompt, messages, "1:1"),
         {:ok, image_binary} <- GeminiImage.extract_image(response),
         {:ok, path} <- save_image(image_binary, character) do
      {:ok, %{image_path: path}}
    end
  end

  @doc "Filename prefix for a character's reference images: `character_<slug>_`."
  @spec reference_prefix(String.t()) :: String.t()
  def reference_prefix(name), do: "character_#{slug(name)}_"

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp source_image_part(%Character{source_image_path: nil}), do: []

  defp source_image_part(%Character{source_image_path: path}) do
    case File.read(path) do
      {:ok, binary} -> [{binary, GeminiImage.mime_type(path)}]
      {:error, _} -> []
    end
  end

  defp save_image(binary, %Character{name: name}) do
    output_dir = Path.join(:code.priv_dir(:circle_story), "generated_images")

    with :ok <- File.mkdir_p(output_dir) do
      filename = "#{reference_prefix(name)}#{System.os_time(:second)}.png"
      path = Path.join(output_dir, filename)

      case File.write(path, binary) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, "failed to write image: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, "failed to create output directory: #{inspect(reason)}"}
    end
  end
end
```

Note: `slug/1` maps non-alphanumerics to `_` then trims edge underscores so `reference_prefix("Ornella") == "character_ornella_"` and `reference_prefix("Nani Ji!") == "character_nani_ji_"`.

- [ ] **Step 10: Run tests to verify they pass**

Run: `mix test test/circle_story/books/actions/generate_character_reference_test.exs`
Expected: PASS (2 `reference_prefix/1` tests; the `:integration` test is skipped).

- [ ] **Step 11: Commit**

```bash
git add lib/circle_story/books/actions/gemini_image.ex lib/circle_story/books/actions/generate_spread_image.ex lib/circle_story/books/actions/generate_character_reference.ex test/circle_story/books/actions/gemini_image_test.exs test/circle_story/books/actions/generate_character_reference_test.exs
git commit -m "feat: shared GeminiImage helpers + GenerateCharacterReference action"
```

---

### Task 5: Route spread generation + prompt preview through `CharacterSelector`

**Files:**
- Modify: `lib/circle_story/books/actions/generate_spread_image.ex:16-38`
- Modify: `lib/circle_story/books/generator.ex:75-84`
- Create (test): `test/circle_story/books/generator_test.exs`

**Interfaces:**
- Consumes: `CharacterSelector.for_spread/2`, `PromptBuilder.user_message/2`, `Generator.inspect_prompt/2`.
- Produces: no new public functions; behavior change — only selected characters' prompts (and, when present, reference images) are sent.

- [ ] **Step 1: Write the failing test**

Create `test/circle_story/books/generator_test.exs`:

```elixir
defmodule CircleStory.Books.GeneratorTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Generator
  alias CircleStory.Books.Templates.NanisMagicThread

  describe "inspect_prompt/2 character selection" do
    test "an inner spread only includes characters it names" do
      book = NanisMagicThread.book()
      {_system, user} = Generator.inspect_prompt(book, 1)

      # Spread 1 is all about Ornella.
      assert user =~ "<ORNELLA>"
      refute user =~ "<NANI>"
      refute user =~ "<ASHA>"
    end

    test "the cover includes the characters named in its art prompt" do
      book = NanisMagicThread.book()
      {_system, user} = Generator.inspect_prompt(book, :cover)

      # Cover art names Nani and baby Ornella, not Asha.
      assert user =~ "<NANI>"
      assert user =~ "<ORNELLA>"
      refute user =~ "<ASHA>"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/circle_story/books/generator_test.exs`
Expected: FAIL — currently every character is included, so `refute user =~ "<NANI>"` fails on spread 1.

- [ ] **Step 3: Apply the selector in `GenerateSpreadImage`**

In `lib/circle_story/books/actions/generate_spread_image.ex` (already refactored onto `GeminiImage` in Task 4), add `CharacterSelector` to the `CircleStory.Books` alias so it reads:

```elixir
  alias CircleStory.Books.{Character, CharacterSelector, PromptBuilder}
```

Replace the top of `run/2` (the `system_prompt`/`user_msg`/`ref_image_parts` lines) with:

```elixir
  def run(%{spread: spread, characters: characters, spread_type: spread_type}, _context) do
    selected = CharacterSelector.for_spread(spread, characters)
    system_prompt = PromptBuilder.system_prompt(spread_type)
    user_msg = PromptBuilder.user_message(spread, selected)
    ref_image_parts = load_reference_images(selected)
    messages = GeminiImage.build_messages(user_msg, ref_image_parts)
```

(The rest of `run/2` is unchanged. `load_reference_images/1` still filters on `reference_image_path`, so a selected character with no generated reference contributes text only.)

- [ ] **Step 4: Apply the selector in `Generator.inspect_prompt/2`**

In `lib/circle_story/books/generator.ex`, add `CharacterSelector` to the alias block, then replace both `inspect_prompt/2` clauses:

```elixir
  def inspect_prompt(%Book{} = book, :cover) do
    selected = CharacterSelector.for_spread(book.cover, book.characters)
    {PromptBuilder.system_prompt(:cover), PromptBuilder.user_message(book.cover, selected)}
  end

  def inspect_prompt(%Book{} = book, position) when is_integer(position) do
    spread = Enum.find(book.spreads, &(&1.position == position))
    selected = CharacterSelector.for_spread(spread, book.characters)
    {PromptBuilder.system_prompt(:inner), PromptBuilder.user_message(spread, selected)}
  end
```

Add `CharacterSelector` to the existing `alias CircleStory.Books.{...}` list in `generator.ex`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/circle_story/books/generator_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/circle_story/books/actions/generate_spread_image.ex lib/circle_story/books/generator.ex test/circle_story/books/generator_test.exs
git commit -m "feat: select only named characters for spreads and prompt previews"
```

---

### Task 6: `Generator` — generate and re-attach character references

**Files:**
- Modify: `lib/circle_story/books/generator.ex`
- Modify (test): `test/circle_story/books/generator_test.exs`

**Interfaces:**
- Consumes: `GenerateCharacterReference.run/2`, `GenerateCharacterReference.reference_prefix/1`, `ImageOps.latest_raw/1`.
- Produces:
  - `Generator.generate_character_reference(book :: Book.t(), name :: String.t()) :: {:ok, Book.t()} | {:error, term()}` — generates one reference, returns the book with that character's `reference_image_path` set.
  - `Generator.attach_character_reference(book :: Book.t(), name :: String.t()) :: {:ok, Book.t()} | {:error, term()}` — re-attaches the newest saved reference without regenerating; returns the book unchanged when none exists.

- [ ] **Step 1: Write the failing test**

Add to `test/circle_story/books/generator_test.exs` a new `describe` block (and the needed aliases at the top: `alias CircleStory.Books.{Book, Character, Generator}` and `alias CircleStory.Books.Actions.GenerateCharacterReference` and `alias CircleStory.Books.Composition.ImageOps`):

```elixir
  describe "attach_character_reference/2" do
    setup do
      dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
      File.mkdir_p!(dir)

      prefix = GenerateCharacterReference.reference_prefix("Ornella")
      path = Path.join(dir, "#{prefix}#{System.unique_integer([:positive])}.png")
      Image.write!(Image.new!(64, 64, color: :pink), path)
      on_exit(fn -> File.rm(path) end)

      book = %Book{
        title: "T",
        author: "A",
        characters: [%Character{name: "Ornella", image_prompt: "baby"}]
      }

      %{book: book, path: path}
    end

    test "attaches the newest saved reference to the named character", %{book: book, path: path} do
      assert {:ok, updated} = Generator.attach_character_reference(book, "Ornella")
      assert %Character{name: "Ornella", reference_image_path: ^path} =
               Book.back_cover_character(updated)
    end

    test "returns an error for an unknown character name", %{book: book} do
      assert {:error, _} = Generator.attach_character_reference(book, "Nobody")
    end

    test "returns the book unchanged when no reference file exists" do
      book = %Book{title: "T", author: "A", characters: [%Character{name: "Zzz", image_prompt: "x"}]}
      assert {:ok, ^book} = Generator.attach_character_reference(book, "Zzz")
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/circle_story/books/generator_test.exs`
Expected: FAIL — `attach_character_reference/2` undefined.

- [ ] **Step 3: Implement the generator functions**

In `lib/circle_story/books/generator.ex`, add `Character` to the `alias CircleStory.Books.{...}` list, and add `alias CircleStory.Books.Actions.GenerateCharacterReference` next to the existing `alias CircleStory.Books.Actions.GenerateSpreadImage`. Then add these public functions (e.g. after `compose_dedication/1`):

```elixir
  @doc "Generate an AI reference portrait for one character; returns the updated book."
  @spec generate_character_reference(Book.t(), String.t()) :: {:ok, Book.t()} | {:error, term()}
  def generate_character_reference(%Book{} = book, name) do
    with {:ok, character} <- fetch_character(book, name),
         {:ok, %{image_path: path}} <-
           GenerateCharacterReference.run(%{character: character}, %{}) do
      {:ok, put_character_reference(book, name, path)}
    end
  end

  @doc "Re-attach the newest saved reference for one character without regenerating."
  @spec attach_character_reference(Book.t(), String.t()) :: {:ok, Book.t()} | {:error, term()}
  def attach_character_reference(%Book{} = book, name) do
    with {:ok, _character} <- fetch_character(book, name) do
      case ImageOps.latest_raw(GenerateCharacterReference.reference_prefix(name)) do
        {:ok, path} -> {:ok, put_character_reference(book, name, path)}
        {:error, :no_raw_art} -> {:ok, book}
      end
    end
  end
```

Add these private helpers (e.g. near `fetch_spread/2`):

```elixir
  defp fetch_character(%Book{characters: characters}, name) do
    case Enum.find(characters, &(&1.name == name)) do
      nil -> {:error, "no character named #{name}"}
      %Character{} = character -> {:ok, character}
    end
  end

  defp put_character_reference(%Book{characters: characters} = book, name, path) do
    characters =
      Enum.map(characters, fn
        %Character{name: ^name} = c -> %{c | reference_image_path: path}
        c -> c
      end)

    %{book | characters: characters}
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/circle_story/books/generator_test.exs`
Expected: PASS (all 5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/generator.ex test/circle_story/books/generator_test.exs
git commit -m "feat: generate_character_reference/2 and attach_character_reference/2"
```

---

### Task 7: Render real images in the back-cover and dedication circles

**Files:**
- Modify: `lib/circle_story/books/page_components.ex:68-107` (dedication) and `:121-207` (cover)
- Modify (test): `test/circle_story/books/page_components_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `PageComponents.cover/1` accepts optional `character_uri` (default `nil`); `PageComponents.dedication/1` accepts optional `dedication_uri` (default `nil`). When a URI is present, the circle renders a `object-fit:cover` `<img>`; when `nil`, the existing pink placeholder is kept.

- [ ] **Step 1: Write the failing tests**

Add to `test/circle_story/books/page_components_test.exs`:

```elixir
  test "dedication/1 renders the user's photo in the circle when given a URI" do
    html =
      render_component(&PageComponents.dedication/1, %{
        text: "For Ornella.",
        dedication_uri: "data:image/png;base64,DEDI"
      })

    assert html =~ "border-radius:50%"
    assert html =~ "data:image/png;base64,DEDI"
    assert html =~ "object-fit:cover"
    refute html =~ "background:pink"
  end

  test "dedication/1 keeps the pink placeholder when no URI is given" do
    html = render_component(&PageComponents.dedication/1, %{text: "For Ornella."})
    assert html =~ "background:pink"
    refute html =~ "<img"
  end

  test "cover/1 renders the character reference in the back circle when given a URI" do
    html =
      render_component(&PageComponents.cover/1, %{
        art_uri: "data:image/png;base64,BBBB",
        rect: %{x: 200, y: 150, w: 1400, h: 500},
        align: :center,
        front_color: "#FAFAFA",
        title: "Nani's Magic Thread",
        author: "Sidd & Veronika",
        tagline: "A story of love.",
        fill: "rgb(180,170,150)",
        ink: "#1A1A1A",
        character_uri: "data:image/png;base64,CHAR"
      })

    assert html =~ "data:image/png;base64,CHAR"
    assert html =~ "object-fit:cover"
  end

  test "cover/1 keeps the pink placeholder when no character URI is given" do
    html =
      render_component(&PageComponents.cover/1, %{
        art_uri: "data:image/png;base64,BBBB",
        rect: %{x: 200, y: 150, w: 1400, h: 500},
        align: :center,
        front_color: "#FAFAFA",
        title: "T",
        author: "A",
        tagline: "t",
        fill: "rgb(1,2,3)",
        ink: "#1A1A1A"
      })

    assert html =~ "background:pink"
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/circle_story/books/page_components_test.exs`
Expected: FAIL — the URI variants aren't rendered; `object-fit:cover` on the circle and the data URIs are absent.

- [ ] **Step 3: Update the dedication component**

In `lib/circle_story/books/page_components.ex`, add a new attr immediately after the existing `attr :text, :string, required: true` line above `def dedication(assigns) do`:

```elixir
  attr :dedication_uri, :string, default: nil
```

Replace the placeholder block in `dedication/1`:

```elixir
      <%!-- User's dedication photo (circle-cropped), or a placeholder --%>
      <div style={"position:absolute;left:#{@circle_cx - @radius}px;top:#{@circle_cy - @radius}px;width:#{2 * @radius}px;height:#{2 * @radius}px;border-radius:50%;overflow:hidden;background:#{if @dedication_uri, do: "transparent", else: "pink"};"}>
        <img
          :if={@dedication_uri}
          src={@dedication_uri}
          style="width:100%;height:100%;object-fit:cover;"
        />
      </div>
```

- [ ] **Step 4: Update the cover component**

In `page_components.ex`, add to the cover attr list (with the other `attr` declarations above `def cover(assigns) do`):

```elixir
  attr :character_uri, :string, default: nil
```

Replace the back-panel placeholder block in `cover/1`:

```elixir
      <%!-- Back-cover character reference (circle-cropped), or a placeholder --%>
      <div style={"position:absolute;left:#{div(@back.w, 2) - @circle_r}px;top:#{div(@back.h, 2) - @circle_r}px;width:#{2 * @circle_r}px;height:#{2 * @circle_r}px;border-radius:50%;overflow:hidden;background:#{if @character_uri, do: "transparent", else: "pink"};"}>
        <img
          :if={@character_uri}
          src={@character_uri}
          style="width:100%;height:100%;object-fit:cover;"
        />
      </div>
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/circle_story/books/page_components_test.exs`
Expected: PASS (existing tests plus the 4 new ones; the original "renders a pink circle" dedication test still passes because `dedication_uri` defaults to `nil`).

- [ ] **Step 6: Commit**

```bash
git add lib/circle_story/books/page_components.ex test/circle_story/books/page_components_test.exs
git commit -m "feat: render circle images for back cover and dedication"
```

---

### Task 8: Resolve the circle image URIs in `Composition`

**Files:**
- Modify: `lib/circle_story/books/composition.ex`
- Modify (test): `test/circle_story/books/composition_test.exs`

**Interfaces:**
- Consumes: `Book.back_cover_character/1`, `Character.reference_image_path`, `DedicationSpread.user_image_path`, `ImageOps.fit/3`, `ImageOps.to_data_uri/1`, and the `PageComponents` assigns from Task 7.
- Produces: no new public functions; `cover_html/2` now passes `character_uri` and `dedication_html/1` now passes `dedication_uri`, each resolved to a square data URI (or `nil`).

- [ ] **Step 1: Write the failing tests**

Add to `test/circle_story/books/composition_test.exs`. First add `Character` to the existing alias: `alias CircleStory.Books.{Book, Character, CoverSpread, InnerSpread, DedicationSpread}`. Then:

```elixir
  test "cover_html/2 embeds the back-cover character's reference image" do
    raw = write_raw("cover_front", 1875, 1875, :sky_blue)
    cache_bbox(raw, [80, 150, 320, 850], "center")
    ref = write_raw("character_ornella", 512, 512, :pink)

    book = %Book{
      title: "Nani's Magic Thread",
      author: "Sidd & Veronika",
      characters: [%Character{name: "Ornella", image_prompt: "baby", reference_image_path: ref}],
      cover: %CoverSpread{tagline: "t", image_prompt: "x", generated_image_path: raw}
    }

    assert {:ok, html, _out} = Composition.cover_html(book)
    assert html =~ "object-fit:cover"
    assert html =~ "data:image/png;base64,"
    refute html =~ "background:pink"
  end

  test "cover_html/2 keeps the placeholder when the character has no reference" do
    raw = write_raw("cover_front", 1875, 1875, :sky_blue)
    cache_bbox(raw, [80, 150, 320, 850], "center")

    book = %Book{
      title: "T",
      author: "A",
      characters: [%Character{name: "Ornella", image_prompt: "baby"}],
      cover: %CoverSpread{tagline: "t", image_prompt: "x", generated_image_path: raw}
    }

    assert {:ok, html, _out} = Composition.cover_html(book)
    assert html =~ "background:pink"
  end

  test "dedication_html/1 embeds the user's photo when user_image_path is set" do
    photo = write_raw("dedication_photo", 512, 512, :pink)
    dedication = %DedicationSpread{text: "For Ornella.", user_image_path: photo}

    assert {:ok, html, _out} = Composition.dedication_html(dedication)
    assert html =~ "object-fit:cover"
    assert html =~ "data:image/png;base64,"
  end
```

Note: `write_raw/4` (already in this test file) puts files under `priv/generated_images/` and registers `on_exit` cleanup — reuse it for the reference/photo fixtures.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/circle_story/books/composition_test.exs`
Expected: FAIL — `cover_html`/`dedication_html` don't pass the URIs yet, so `object-fit:cover` is absent and the pink placeholder is still present.

- [ ] **Step 3: Resolve and pass the URIs**

In `lib/circle_story/books/composition.ex`, add `Character` and `Book` to the aliased modules (the `alias CircleStory.Books.{...}` line already includes `Book`; add `Character`). Add a module attribute near the top of the module body:

```elixir
  # Source resolution for the circle crops (object-fit:cover downstream, so an
  # exact match to the print diameter isn't required — this is comfortably above
  # both the back-cover and dedication circle sizes).
  @circle_source_px 1600
```

In `cover_html/2`, add `character_uri: back_cover_character_uri(book)` to the `PageComponents.cover(init_assigns(%{...}))` assigns map (alongside `art_uri`, `rect`, etc.).

In `dedication_html/1`, change it to resolve the photo. Replace the function body:

```elixir
  def dedication_html(%DedicationSpread{text: text} = dedication) do
    html =
      HtmlRenderer.component_to_html(
        PageComponents.dedication(
          init_assigns(%{text: text, dedication_uri: dedication_uri(dedication)})
        )
      )

    dir = Path.join(:code.priv_dir(:circle_story), "print_ready")
    File.mkdir_p!(dir)
    {:ok, html, Path.join(dir, "dedication.png")}
  end
```

Add the private resolvers (e.g. above `init_assigns/1`):

```elixir
  defp back_cover_character_uri(%Book{} = book) do
    case Book.back_cover_character(book) do
      %Character{reference_image_path: path} -> circle_uri(path)
      _ -> nil
    end
  end

  defp dedication_uri(%DedicationSpread{user_image_path: path}), do: circle_uri(path)

  # Fit an image path to a square and encode it for the circle crop. Nil/missing
  # files yield nil so the component falls back to the placeholder.
  defp circle_uri(path) when is_binary(path) do
    if File.exists?(path) do
      path |> ImageOps.fit(@circle_source_px, @circle_source_px) |> ImageOps.to_data_uri()
    end
  end

  defp circle_uri(_), do: nil
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/circle_story/books/composition_test.exs`
Expected: PASS (existing tests plus the 3 new ones; the original `dedication_html/1` test still passes because its `DedicationSpread` has no `user_image_path`, so `dedication_uri` is `nil` and the pink placeholder remains).

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/composition.ex test/circle_story/books/composition_test.exs
git commit -m "feat: embed character and dedication photos into circle crops"
```

---

### Task 9: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Run the whole suite**

Run: `mix test`
Expected: PASS, `:integration` tests excluded.

- [ ] **Step 2: Run precommit**

Run: `mix precommit`
Expected: no compile warnings, no unused deps, formatted, all tests pass. Fix anything it reports, then re-run until clean.

- [ ] **Step 3: (Manual, optional) exercise the pipeline in IEx**

This makes real Gemini calls; run only when you want to see output.

```elixir
book = CircleStory.Books.Templates.NanisMagicThread.book()
{:ok, book} = CircleStory.Books.Generator.generate_character_reference(book, "Ornella")
{:ok, %{image_path: cover}} = CircleStory.Books.Generator.generate_cover(book)
```

Confirm `priv/generated_images/character_ornella_*.png` exists and the composed cover shows the portrait (not a pink circle) in the back-cover circle.

- [ ] **Step 4: Commit any precommit fixups**

```bash
git add -A
git commit -m "chore: precommit fixups for character reference images"
```

---

## Notes for the implementer

- **Source images to test the source→reference path:** drop a photo in `priv/source_images/` and set it on a character before generating, e.g. in IEx:
  `book = put_in(book.characters, Enum.map(book.characters, fn c -> if c.name == "Ornella", do: %{c | source_image_path: Path.join(:code.priv_dir(:circle_story), "source_images/ornella.jpg")}, else: c end))`. The template intentionally leaves `source_image_path` unset so it never references a missing file.
- **Reference persistence:** paths live only in-memory on the returned `Book`. In a fresh session, `attach_character_reference(book, name)` re-attaches the newest saved portrait without paying to regenerate.
