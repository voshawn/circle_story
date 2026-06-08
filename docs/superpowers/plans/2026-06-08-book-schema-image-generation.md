# Book Schema & Gemini Image Generation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Book data structs and a `Jido.Action` that generates a spread image via Google Gemini (`gemini-3.1-flash-image`) using `ReqLLM`, with Jido telemetry events.

**Architecture:** Five plain Elixir structs represent all book data with no database layer. `PromptBuilder` assembles a hardcoded system prompt and a struct-driven user message (scene + character XML blocks). `GenerateSpreadImage` is a `Jido.Action` that calls `ReqLLM.generate_image/3` with those prompts and any character reference images, then writes the result to `priv/generated_images/`.

**Tech Stack:** Elixir `defstruct` + `@type` specs, `ReqLLM` v1.14.0 (transitive via `jido_ai`), `Jido.Action` + `Jido.Exec`, `Zoi` schemas, Google Gemini API (`v1beta`).

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/circle_story/books/character.ex` | Create | Character struct |
| `lib/circle_story/books/inner_spread.ex` | Create | InnerSpread struct |
| `lib/circle_story/books/cover_spread.ex` | Create | CoverSpread struct |
| `lib/circle_story/books/dedication_spread.ex` | Create | DedicationSpread struct |
| `lib/circle_story/books/book.ex` | Create | Book struct |
| `lib/circle_story/books/prompt_builder.ex` | Create | Pure prompt assembly |
| `lib/circle_story/books/actions/generate_spread_image.ex` | Create | Jido.Action for image gen |
| `test/circle_story/books/prompt_builder_test.exs` | Create | PromptBuilder unit tests |
| `test/circle_story/books/actions/generate_spread_image_test.exs` | Create | Action integration test |
| `priv/generated_images/.gitkeep` | Create | Output directory anchor |
| `.gitignore` | Modify | Ignore generated image files |

---

## Task 1: Output directory and gitignore

**Files:**
- Create: `priv/generated_images/.gitkeep`
- Modify: `.gitignore`

- [ ] **Step 1: Create the output directory**

```bash
mkdir -p priv/generated_images
touch priv/generated_images/.gitkeep
```

- [ ] **Step 2: Ignore generated images but keep the directory**

Add to `.gitignore` (after the existing `*.db` section):

```
# Generated AI images
/priv/generated_images/*.png
/priv/generated_images/*.jpg
/priv/generated_images/*.jpeg
/priv/generated_images/*.webp
```

- [ ] **Step 3: Commit**

```bash
git add priv/generated_images/.gitkeep .gitignore
git commit -m "chore: add generated images output directory"
```

---

## Task 2: Data structs

**Files:**
- Create: `lib/circle_story/books/character.ex`
- Create: `lib/circle_story/books/inner_spread.ex`
- Create: `lib/circle_story/books/cover_spread.ex`
- Create: `lib/circle_story/books/dedication_spread.ex`
- Create: `lib/circle_story/books/book.ex`

- [ ] **Step 1: Create Character struct**

`lib/circle_story/books/character.ex`:
```elixir
defmodule CircleStory.Books.Character do
  @enforce_keys [:name, :image_prompt]
  defstruct [:name, :image_prompt, :reference_image_path]

  @type t :: %__MODULE__{
          name: String.t(),
          image_prompt: String.t(),
          reference_image_path: String.t() | nil
        }
end
```

- [ ] **Step 2: Create InnerSpread struct**

`lib/circle_story/books/inner_spread.ex`:
```elixir
defmodule CircleStory.Books.InnerSpread do
  @enforce_keys [:position, :text, :image_prompt]
  defstruct [:position, :text, :image_prompt, :generated_image_path]

  @type t :: %__MODULE__{
          position: 1..9,
          text: String.t(),
          image_prompt: String.t(),
          generated_image_path: String.t() | nil
        }
end
```

- [ ] **Step 3: Create CoverSpread struct**

`lib/circle_story/books/cover_spread.ex`:
```elixir
defmodule CircleStory.Books.CoverSpread do
  @enforce_keys [:tagline, :image_prompt]
  defstruct [:tagline, :image_prompt, :generated_image_path]

  @type t :: %__MODULE__{
          tagline: String.t(),
          image_prompt: String.t(),
          generated_image_path: String.t() | nil
        }
end
```

- [ ] **Step 4: Create DedicationSpread struct**

`lib/circle_story/books/dedication_spread.ex`:
```elixir
defmodule CircleStory.Books.DedicationSpread do
  @enforce_keys [:text]
  defstruct [:text, :user_image_path]

  @type t :: %__MODULE__{
          text: String.t(),
          user_image_path: String.t() | nil
        }
end
```

- [ ] **Step 5: Create Book struct**

`lib/circle_story/books/book.ex`:
```elixir
defmodule CircleStory.Books.Book do
  alias CircleStory.Books.{Character, CoverSpread, DedicationSpread, InnerSpread}

  @enforce_keys [:title, :author]
  defstruct [:title, :author, :cover, :dedication, spreads: [], characters: []]

  @type t :: %__MODULE__{
          title: String.t(),
          author: String.t(),
          cover: CoverSpread.t() | nil,
          dedication: DedicationSpread.t() | nil,
          spreads: [InnerSpread.t()],
          characters: [Character.t()]
        }
end
```

- [ ] **Step 6: Compile to verify no errors**

```bash
mix compile
```

Expected: exits cleanly with no errors or warnings.

- [ ] **Step 7: Commit**

```bash
git add lib/circle_story/books/
git commit -m "feat: add Book data structs"
```

---

## Task 3: PromptBuilder

**Files:**
- Create: `test/circle_story/books/prompt_builder_test.exs`
- Create: `lib/circle_story/books/prompt_builder.ex`

- [ ] **Step 1: Write the failing tests**

`test/circle_story/books/prompt_builder_test.exs`:
```elixir
defmodule CircleStory.Books.PromptBuilderTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.{Character, CoverSpread, InnerSpread, PromptBuilder}

  describe "system_prompt/1" do
    test "returns a non-empty string for :inner" do
      prompt = PromptBuilder.system_prompt(:inner)
      assert is_binary(prompt)
      assert String.length(prompt) > 100
      assert prompt =~ "inner page spreads"
    end

    test "returns a non-empty string for :cover" do
      prompt = PromptBuilder.system_prompt(:cover)
      assert is_binary(prompt)
      assert String.length(prompt) > 100
      assert prompt =~ "front cover"
    end

    test ":inner and :cover prompts are different" do
      refute PromptBuilder.system_prompt(:inner) == PromptBuilder.system_prompt(:cover)
    end
  end

  describe "user_message/2" do
    setup do
      spread = %InnerSpread{
        position: 1,
        text: "Mama comes home.",
        image_prompt: "A heart-melting daycare pickup moment."
      }

      characters = [
        %Character{
          name: "Chloe",
          image_prompt: "A toddler girl with pigtails and rosy cheeks."
        },
        %Character{
          name: "Christine",
          image_prompt: "A young woman with long black hair and a warm smile."
        }
      ]

      %{spread: spread, characters: characters}
    end

    test "includes the spread image_prompt in a SCENE block", %{spread: spread, characters: characters} do
      msg = PromptBuilder.user_message(spread, characters)
      assert msg =~ "<SCENE>"
      assert msg =~ "A heart-melting daycare pickup moment."
      assert msg =~ "</SCENE>"
    end

    test "wraps characters in a CHARACTERS block", %{spread: spread, characters: characters} do
      msg = PromptBuilder.user_message(spread, characters)
      assert msg =~ "<CHARACTERS>"
      assert msg =~ "</CHARACTERS>"
    end

    test "each character gets an uppercased name tag", %{spread: spread, characters: characters} do
      msg = PromptBuilder.user_message(spread, characters)
      assert msg =~ "<CHLOE>"
      assert msg =~ "A toddler girl with pigtails"
      assert msg =~ "</CHLOE>"
      assert msg =~ "<CHRISTINE>"
      assert msg =~ "A young woman with long black hair"
      assert msg =~ "</CHRISTINE>"
    end

    test "works with a CoverSpread", %{characters: characters} do
      cover = %CoverSpread{
        tagline: "Every day, you choose me.",
        image_prompt: "A sun-drenched meadow scene with the main character."
      }

      msg = PromptBuilder.user_message(cover, characters)
      assert msg =~ "<SCENE>"
      assert msg =~ "A sun-drenched meadow scene"
      assert msg =~ "</SCENE>"
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

```bash
mix test test/circle_story/books/prompt_builder_test.exs
```

Expected: compile error — `CircleStory.Books.PromptBuilder` is not defined.

- [ ] **Step 3: Implement PromptBuilder**

`lib/circle_story/books/prompt_builder.ex`:
```elixir
defmodule CircleStory.Books.PromptBuilder do
  alias CircleStory.Books.Character

  @inner_system_prompt """
  You are generating inner page spreads for a children's book. You should follow \
  this Master Style for every image generation <MASTER STYLE> Style: Children's book \
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
  classic. Avoid: Photorealism, 3D rendering, anime, sharp digital lines, neon colors, \
  busy backgrounds, generic AI "storybook" aesthetic, paper texture, canvas texture, \
  grainy or rough surfaces, visible brushstrokes, scanned-art look. Do not include any \
  story text in the artwork. Text is only acceptable on objects in the image. \
  </MASTER STYLE> You will be provided with a SCENE prompt as well as one or more \
  CHARACTERS prompts. You may also receive reference images for the scene and \
  characters. Your job is to compose all of these prompts and images into a well \
  designed page for a book. IMPORTANT: Text will be overlayed on top of this image. \
  You should not generate the story text. However, you should render empty space for \
  text to naturally be placed on the image. Since this is a full page spread, avoid \
  having content in the center of the image where it would be folded by the book.
  """
  |> String.trim()

  @cover_system_prompt """
  You are generating the front cover artwork for a children's board book. You should \
  follow this Master Style for every image generation <MASTER STYLE> Style: Children's \
  book illustration inspired by Antoine de Saint-Exupéry's The Little Prince, modernized \
  with bolder, more saturated colors. Watercolor and gouache painting style with delicate \
  ink linework — loose, expressive, and slightly whimsical. Soft, blended color washes \
  with smooth gradients. Characters have simple, charming proportions with expressive \
  faces rendered in minimal, confident lines. Color palette: Warm and vibrant but still \
  soft — rich golden yellows, deep sky blues, blush pinks, sage greens, terracotta, and \
  creamy off-whites. Colors should feel sun-drenched and emotionally warm, not pastel or \
  washed out. Backgrounds feature gentle color washes or open negative space to keep \
  focus on the characters. Composition: Storybook layouts with a sense of openness and \
  air. Soft, dreamy lighting. Clean linework with a handmade, timeless quality. Smooth \
  finish suitable for high-quality print reproduction. Mood: Tender, nostalgic, joyful, \
  and gently magical — like a modern classic. Avoid: Photorealism, 3D rendering, anime, \
  sharp digital lines, neon colors, busy backgrounds, generic AI "storybook" aesthetic, \
  paper texture, canvas texture, grainy or rough surfaces, visible brushstrokes, \
  scanned-art look. Do not include any story text in the artwork. Text is only acceptable \
  on objects in the image. </MASTER STYLE> You will be provided with a SCENE prompt and \
  CHARACTER prompts. Compose a compelling front cover image. IMPORTANT: The book title \
  and author name will be overlaid on this image — leave clear space at the top or bottom \
  for text overlay. Design with a strong focal point featuring the main character, with \
  an inviting, eye-catching composition suitable for a children's board book cover.
  """
  |> String.trim()

  @spec system_prompt(:inner | :cover) :: String.t()
  def system_prompt(:inner), do: @inner_system_prompt
  def system_prompt(:cover), do: @cover_system_prompt

  @spec user_message(struct(), [Character.t()]) :: String.t()
  def user_message(spread, characters) do
    scene_block = "<SCENE>\n#{spread.image_prompt}\n</SCENE>"
    chars_inner = build_characters_inner(characters)
    "#{scene_block}\n<CHARACTERS>\n#{chars_inner}\n</CHARACTERS>"
  end

  defp build_characters_inner(characters) do
    characters
    |> Enum.map(fn %Character{name: name, image_prompt: prompt} ->
      tag = String.upcase(name)
      "<#{tag}>\n#{prompt}\n</#{tag}>"
    end)
    |> Enum.join("\n")
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/circle_story/books/prompt_builder_test.exs
```

Expected: all tests green.

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/prompt_builder.ex test/circle_story/books/prompt_builder_test.exs
git commit -m "feat: add PromptBuilder for assembling Gemini image generation prompts"
```

---

## Task 4: GenerateSpreadImage Jido.Action

**Files:**
- Create: `test/circle_story/books/actions/generate_spread_image_test.exs`
- Create: `lib/circle_story/books/actions/generate_spread_image.ex`

- [ ] **Step 1: Write the integration test**

`test/circle_story/books/actions/generate_spread_image_test.exs`:
```elixir
defmodule CircleStory.Books.Actions.GenerateSpreadImageTest do
  use ExUnit.Case

  alias CircleStory.Books.{Character, InnerSpread}
  alias CircleStory.Books.Actions.GenerateSpreadImage

  @moduletag :skip

  @tag :integration
  test "generates an image and saves it to disk" do
    spread = %InnerSpread{
      position: 1,
      text: "Mama comes home.",
      image_prompt: """
      A heart-melting daycare pickup moment. Christine (Mama) is opening the door to \
      the daycare room, kneeling with arms open. Chloe runs toward her at full toddler \
      speed — arms wide, pigtails bouncing, mouth open in a joyful squeal. Cozy daycare \
      classroom, warm afternoon light streaming through a window.
      """
    }

    characters = [
      %Character{
        name: "Chloe",
        image_prompt: """
        Chloe, a toddler girl, approximately 1.5–2 years old. East Asian features with \
        warm light skin and a round baby face. Large expressive dark brown eyes. Black hair \
        in two high pigtails tied with small bows. Cozy ribbed knit sweater in warm peach/blush.
        """
      },
      %Character{
        name: "Christine",
        image_prompt: """
        Christine, a young woman in her early-to-mid 30s. South East Asian features with \
        warm light skin. Long black slightly wavy hair. Cozy cream knit sweater. Warm, \
        loving expression.
        """
      }
    ]

    assert {:ok, %{image_path: path}} =
             Jido.Exec.run(GenerateSpreadImage, %{
               spread: spread,
               characters: characters,
               spread_type: :inner
             }, %{})

    assert File.exists?(path)
    assert Path.extname(path) in [".png", ".jpg", ".jpeg", ".webp"]

    IO.puts("Generated image saved to: #{path}")
  end
end
```

- [ ] **Step 2: Run to confirm it fails (module not defined yet)**

```bash
mix test test/circle_story/books/actions/generate_spread_image_test.exs
```

Expected: compile error — `GenerateSpreadImage` not defined.

- [ ] **Step 3: Implement the action**

`lib/circle_story/books/actions/generate_spread_image.ex`:
```elixir
defmodule CircleStory.Books.Actions.GenerateSpreadImage do
  use Jido.Action,
    name: "generate_spread_image",
    description: "Generate an AI image for a book spread via Google Gemini",
    schema: [
      spread: [type: :any, required: true, doc: "InnerSpread or CoverSpread struct"],
      characters: [type: {:list, :any}, required: true, doc: "List of Character structs"],
      spread_type: [type: {:in, [:inner, :cover]}, required: true]
    ]

  alias CircleStory.Books.{Character, PromptBuilder}

  @model "google:gemini-3.1-flash-image"

  # Pixel dimensions per spread type — passed as aspect ratio hint to the API
  @inner_aspect_ratio "2:1"
  @cover_aspect_ratio "2:1"

  @impl true
  def run(%{spread: spread, characters: characters, spread_type: spread_type}, _context) do
    system_prompt = PromptBuilder.system_prompt(spread_type)
    user_msg = PromptBuilder.user_message(spread, characters)
    ref_image_parts = load_reference_images(characters)
    messages = build_messages(user_msg, ref_image_parts)
    aspect_ratio = aspect_ratio(spread_type)

    with {:ok, response} <- call_llm(system_prompt, messages, aspect_ratio),
         {:ok, image_binary} <- extract_image(response),
         {:ok, path} <- save_image(image_binary, spread, spread_type) do
      {:ok, %{image_path: path}}
    end
  end

  defp aspect_ratio(:inner), do: @inner_aspect_ratio
  defp aspect_ratio(:cover), do: @cover_aspect_ratio

  defp load_reference_images(characters) do
    characters
    |> Enum.filter(& &1.reference_image_path)
    |> Enum.flat_map(fn %Character{reference_image_path: path} ->
      case File.read(path) do
        {:ok, binary} -> [{binary, mime_type(path)}]
        {:error, _} -> []
      end
    end)
  end

  defp build_messages(text, []) do
    [%{role: "user", content: text}]
  end

  defp build_messages(text, ref_images) do
    image_parts =
      Enum.map(ref_images, fn {binary, mime} ->
        %{type: "image_url", image_url: %{url: "data:#{mime};base64,#{Base.encode64(binary)}"}}
      end)

    [%{role: "user", content: [%{type: "text", text: text} | image_parts]}]
  end

  defp call_llm(system_prompt, messages, aspect_ratio) do
    ReqLLM.generate_image(@model, messages,
      system: system_prompt,
      provider_options: [
        google_api_version: "v1beta",
        google_image_aspect_ratio: aspect_ratio
      ]
    )
  end

  defp extract_image(response) do
    # ReqLLM normalizes responses — inspect the raw response in IEx if this fails
    # to find the correct key for your req_llm version (see Task 4 Step 6).
    case response do
      %{content: [%{data: data} | _]} when is_binary(data) ->
        {:ok, data}

      %{choices: [%{message: %{content: content}} | _]} when is_list(content) ->
        content
        |> Enum.find_value({:error, "no image data in response"}, fn
          %{data: data} when is_binary(data) -> {:ok, data}
          _ -> nil
        end)

      other ->
        {:error, "unexpected response shape — run IEx debug in Step 6: #{inspect(other)}"}
    end
  end

  defp save_image(binary, spread, spread_type) do
    output_dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
    File.mkdir_p!(output_dir)
    filename = build_filename(spread, spread_type)
    path = Path.join(output_dir, filename)

    case File.write(path, binary) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "failed to write image: #{inspect(reason)}"}
    end
  end

  defp build_filename(%{position: pos}, :inner) do
    ts = System.os_time(:second)
    "inner_#{pos}_#{ts}.png"
  end

  defp build_filename(_spread, :cover) do
    ts = System.os_time(:second)
    "cover_#{ts}.png"
  end

  defp mime_type(path) do
    case Path.extname(path) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      _ -> "image/jpeg"
    end
  end
end
```

- [ ] **Step 4: Compile to check for errors**

```bash
mix compile
```

Expected: no errors. If `Jido.Action` schema options fail, open `mix hex.docs jido_action` and check the schema format for the installed version — it may use `Zoi.object(%{...})` instead of NimbleOptions style:

```elixir
schema: Zoi.object(%{
  spread: Zoi.any(),
  characters: Zoi.list(Zoi.any()),
  spread_type: Zoi.atom()
})
```

- [ ] **Step 5: Confirm unit test suite still passes with skip**

```bash
mix test test/circle_story/books/actions/generate_spread_image_test.exs
```

Expected: `1 test, 0 failures, 1 skipped`.

- [ ] **Step 6: Set GOOGLE_API_KEY and run the integration test**

```bash
export GOOGLE_API_KEY=your_key_here
mix test test/circle_story/books/actions/generate_spread_image_test.exs --include integration
```

Expected: test passes and a file exists at `priv/generated_images/inner_1_<timestamp>.png`.

If `extract_image/1` raises "unexpected response shape", debug in IEx to find the actual response structure:

```bash
iex -S mix
```

```elixir
alias CircleStory.Books.{Character, InnerSpread, PromptBuilder}

spread = %InnerSpread{position: 1, text: "test", image_prompt: "A cheerful toddler in a sunny garden."}
characters = [%Character{name: "Chloe", image_prompt: "A toddler girl with pigtails."}]

{:ok, response} = ReqLLM.generate_image(
  "google:gemini-3.1-flash-image",
  [%{role: "user", content: PromptBuilder.user_message(spread, characters)}],
  system: PromptBuilder.system_prompt(:inner),
  provider_options: [google_api_version: "v1beta", google_image_aspect_ratio: "2:1"]
)

IO.inspect(response, label: "response", limit: :infinity)
```

Use the printed keys to update `extract_image/1` in the action so the pattern match succeeds.

- [ ] **Step 7: Commit**

```bash
git add lib/circle_story/books/actions/ test/circle_story/books/actions/
git commit -m "feat: add GenerateSpreadImage Jido.Action"
```

---

## Task 5: Final check

- [ ] **Step 1: Run the full precommit suite**

```bash
mix precommit
```

Expected: compiles without warnings, no unused deps flagged, all files formatted, non-integration tests pass.

- [ ] **Step 2: If mix format changed any files, commit them**

```bash
git add -p
git commit -m "chore: apply mix format"
```
