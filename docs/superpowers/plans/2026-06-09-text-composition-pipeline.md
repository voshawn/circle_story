# Text Composition Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compose AI-generated book artwork with text to produce print-ready PNGs for the cover, dedication, and inner spreads — text placement on artwork pages driven by a Gemini bounding-box call, fixed-layout pages composited deterministically.

**Architecture:** Decoupled pipeline. `generate_*` runs art generation → fill-crop to print dimensions → bounding-box AI call → cache bbox → composite → write print-ready PNG. `compose_*` re-composites cheaply from cached raw art + cached bbox (no model calls). Pure geometry (`Layout`), text rendering (`TextRenderer`), and luminance (`Luminance`) are isolated, testable units; per-surface composers (`CoverComposer`, `SpreadComposer`, `DedicationComposer`) consume them; a `Composition` facade and `Generator` orchestrate.

**Tech Stack:** Elixir, the `image` library (Vix / precompiled libvips) for resize/crop/compose/text/draw, `ReqLLM.generate_object/4` (Gemini) for bounding boxes, Jido for the AI action. Fonts: Fredoka + Nunito vendored as TTFs, resolved via fontconfig.

**Reference spec:** `docs/superpowers/specs/2026-06-09-text-composition-pipeline-design.md`

---

## File structure

```
lib/circle_story/books/
  fonts.ex                          # fontconfig setup at boot (NEW)
  composition.ex                    # facade (NEW)
  composition/
    layout.ex                       # pure geometry (NEW)
    luminance.ex                    # region → :black | :white (NEW)
    text_renderer.ex                # text run → RGBA layer, autofit (NEW)
    image_ops.ex                    # fill-crop fit, blank canvas, paths (NEW)
    cover_composer.ex               # (NEW)
    spread_composer.ex              # (NEW)
    dedication_composer.ex          # (NEW)
  actions/
    place_text.ex                   # Jido action: bbox AI call (NEW)
  generator.ex                      # wire generate_* / compose_* (MODIFY)
lib/circle_story/application.ex     # call Fonts.setup/0 at boot (MODIFY)
mix.exs                             # add {:image, "~> 0.68"} (MODIFY)
priv/fonts/                         # Fredoka.ttf, Nunito.ttf, Nunito-Italic.ttf (NEW)
```

---

## Task 1: Add the `image` dependency and font infrastructure

**Files:**
- Modify: `mix.exs`
- Create: `priv/fonts/Fredoka.ttf`, `priv/fonts/Nunito.ttf`, `priv/fonts/Nunito-Italic.ttf`
- Create: `lib/circle_story/books/fonts.ex`
- Modify: `lib/circle_story/application.ex:9` (children list / start function)
- Test: `test/circle_story/books/fonts_test.exs`

- [ ] **Step 1: Add the dependency**

In `mix.exs`, add `{:image, "~> 0.68"},` immediately after the `{:jido, "~> 2.0"},` line:

```elixir
      {:jido_ai, "~> 2.0"},
      {:jido, "~> 2.0"},
      {:image, "~> 0.68"},
```

- [ ] **Step 2: Fetch deps**

Run: `mix deps.get`
Expected: fetches `image`, `vix`, `color`, `sweet_xml`. Vix downloads precompiled libvips (no brew needed).

- [ ] **Step 3: Download the vendored TTFs**

Run (downloads variable-weight TTFs from the official Google Fonts repo):

```bash
mkdir -p priv/fonts
curl -fsSL "https://raw.githubusercontent.com/google/fonts/main/ofl/fredoka/Fredoka%5Bwdth%2Cwght%5D.ttf" -o priv/fonts/Fredoka.ttf
curl -fsSL "https://raw.githubusercontent.com/google/fonts/main/ofl/nunito/Nunito%5Bwght%5D.ttf" -o priv/fonts/Nunito.ttf
curl -fsSL "https://raw.githubusercontent.com/google/fonts/main/ofl/nunito/Nunito-Italic%5Bwght%5D.ttf" -o priv/fonts/Nunito-Italic.ttf
```

Expected: three non-empty `.ttf` files. Verify: `ls -l priv/fonts` shows all > 50 KB. If a URL 404s, the font moved — find it under `ofl/fredoka` / `ofl/nunito` in `github.com/google/fonts`.

- [ ] **Step 4: Write the Fonts module**

Create `lib/circle_story/books/fonts.ex`:

```elixir
defmodule CircleStory.Books.Fonts do
  @moduledoc """
  Makes the vendored TTFs in `priv/fonts` discoverable by libvips/Pango via
  fontconfig. `:font_file` is unsupported on macOS, so fonts must be resolved by
  family name ("Fredoka", "Nunito") through a fontconfig config that points at
  our font directory. Call `setup/0` once at application boot, before any text
  rendering.
  """

  @doc "Generate a fontconfig config pointing at priv/fonts and register it via env vars."
  @spec setup() :: :ok
  def setup do
    fonts_dir = Path.join(:code.priv_dir(:circle_story), "fonts")
    cache_dir = Path.join(System.tmp_dir!(), "circle_story_fontconfig")
    File.mkdir_p!(cache_dir)

    conf = """
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
    <fontconfig>
      <dir>#{fonts_dir}</dir>
      <cachedir>#{cache_dir}</cachedir>
      <config></config>
    </fontconfig>
    """

    conf_path = Path.join(cache_dir, "fonts.conf")
    File.write!(conf_path, conf)
    System.put_env("FONTCONFIG_FILE", conf_path)
    System.put_env("FONTCONFIG_PATH", cache_dir)
    :ok
  end
end
```

- [ ] **Step 5: Call setup at boot**

In `lib/circle_story/application.ex`, add `CircleStory.Books.Fonts.setup()` as the first line of `start/2`, before `children = [...]`:

```elixir
  def start(_type, _args) do
    CircleStory.Books.Fonts.setup()

    children = [
```

- [ ] **Step 6: Write the test (proves both fonts actually load, not silent fallback)**

Create `test/circle_story/books/fonts_test.exs`:

```elixir
defmodule CircleStory.Books.FontsTest do
  use ExUnit.Case, async: false

  alias CircleStory.Books.Fonts

  setup do
    Fonts.setup()
    :ok
  end

  test "setup/0 registers a fontconfig file" do
    assert Fonts.setup() == :ok
    assert System.get_env("FONTCONFIG_FILE") =~ "fonts.conf"
  end

  test "Fredoka and Nunito render as distinct fonts" do
    # If a family fails to load, Pango silently falls back to the same default
    # font, so identical strings would render identically. Distinct widths prove
    # the two vendored families actually loaded.
    {:ok, fredoka} = Image.Text.text("WWWWmmmm", font: "Fredoka", font_size: 120)
    {:ok, nunito} = Image.Text.text("WWWWmmmm", font: "Nunito", font_size: 120)

    assert Image.width(fredoka) > 0
    assert Image.width(nunito) > 0
    refute Image.width(fredoka) == Image.width(nunito)
  end
end
```

- [ ] **Step 7: Run the test**

Run: `mix test test/circle_story/books/fonts_test.exs`
Expected: PASS. If the distinct-fonts assertion fails, fontconfig isn't picking up the dir — confirm `priv/fonts/*.ttf` exist and `FONTCONFIG_FILE` points at the generated conf.

- [ ] **Step 8: Commit**

```bash
git add mix.exs mix.lock priv/fonts lib/circle_story/books/fonts.ex lib/circle_story/application.ex test/circle_story/books/fonts_test.exs
git commit -m "feat: add image dep and vendored-font fontconfig setup"
```

---

## Task 2: Layout — pure geometry

**Files:**
- Create: `lib/circle_story/books/composition/layout.ex`
- Test: `test/circle_story/books/composition/layout_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/circle_story/books/composition/layout_test.exs`:

```elixir
defmodule CircleStory.Books.Composition.LayoutTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Composition.Layout

  test "canvas dimensions" do
    assert Layout.inner_dims() == {3675, 1875}
    assert Layout.cover_dims() == {3863, 1875}
    assert Layout.safe_inset() == 112
  end

  test "cover panels tile the canvas with a 113px spine" do
    back = Layout.back_panel()
    spine = Layout.spine_panel()
    front = Layout.front_panel()

    assert back == %{x: 0, y: 0, w: 1875, h: 1875}
    assert spine == %{x: 1875, y: 0, w: 113, h: 1875}
    assert front == %{x: 1988, y: 0, w: 1875, h: 1875}
    assert back.w + spine.w + front.w == 3863
  end

  test "inner_region spans the full inner page" do
    assert Layout.inner_region() == %{x: 0, y: 0, w: 3675, h: 1875}
  end

  test "denormalize maps a 1000-grid box into region pixels" do
    region = %{x: 0, y: 0, w: 1000, h: 1000}
    rect = Layout.denormalize([100, 200, 400, 600], region)
    assert rect == %{x: 200, y: 100, w: 400, h: 300}
  end

  test "denormalize clamps to the safe inset" do
    region = %{x: 0, y: 0, w: 1000, h: 1000}
    # Box hugging all edges (0..1000) must be pulled inside the 112px inset.
    rect = Layout.denormalize([0, 0, 1000, 1000], region)
    assert rect.x == 112
    assert rect.y == 112
    assert rect.x + rect.w == 888
    assert rect.y + rect.h == 888
  end

  test "denormalize normalizes inverted coordinates" do
    region = %{x: 0, y: 0, w: 1000, h: 1000}
    rect = Layout.denormalize([400, 600, 100, 200], region)
    assert rect == %{x: 200, y: 100, w: 400, h: 300}
  end

  test "denormalize offsets by region origin (front cover panel)" do
    rect = Layout.denormalize([200, 200, 800, 800], Layout.front_panel())
    assert rect.x == 1988 + 375
    assert rect.y == 375
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/circle_story/books/composition/layout_test.exs`
Expected: FAIL — `Layout` is undefined.

- [ ] **Step 3: Write the implementation**

Create `lib/circle_story/books/composition/layout.ex`:

```elixir
defmodule CircleStory.Books.Composition.Layout do
  @moduledoc """
  Pure print geometry: canvas/panel dimensions, the text-safe inset, and mapping
  a Gemini bounding box (normalized to a 1000x1000 grid, `[ymin, xmin, ymax,
  xmax]`) into clamped pixel coordinates within a target region.

  A "region" is `%{x:, y:, w:, h:}` in absolute canvas pixels. A "rect" has the
  same shape and is the pixel result of `denormalize/2`.
  """

  @inner_w 3675
  @inner_h 1875
  @cover_w 3863
  @cover_h 1875
  @panel 1875
  @spine 113
  @safe_inset 112

  def inner_dims, do: {@inner_w, @inner_h}
  def cover_dims, do: {@cover_w, @cover_h}
  def safe_inset, do: @safe_inset

  def back_panel, do: %{x: 0, y: 0, w: @panel, h: @panel}
  def spine_panel, do: %{x: @panel, y: 0, w: @spine, h: @panel}
  def front_panel, do: %{x: @panel + @spine, y: 0, w: @panel, h: @panel}
  def inner_region, do: %{x: 0, y: 0, w: @inner_w, h: @inner_h}

  @doc "Inner-spread fold midpoint x (text should avoid crossing this)."
  def inner_midpoint_x, do: div(@inner_w, 2)

  @doc """
  Map a normalized `[ymin, xmin, ymax, xmax]` box into a pixel rect within
  `region`, clamped to the safe inset. Inverted coordinates are normalized.
  """
  @spec denormalize([number()], map()) :: %{x: integer(), y: integer(), w: integer(), h: integer()}
  def denormalize([ymin, xmin, ymax, xmax], region) do
    x0 = region.x + min(xmin, xmax) / 1000 * region.w
    x1 = region.x + max(xmin, xmax) / 1000 * region.w
    y0 = region.y + min(ymin, ymax) / 1000 * region.h
    y1 = region.y + max(ymin, ymax) / 1000 * region.h

    sx0 = region.x + @safe_inset
    sx1 = region.x + region.w - @safe_inset
    sy0 = region.y + @safe_inset
    sy1 = region.y + region.h - @safe_inset

    cx0 = clamp(x0, sx0, sx1)
    cx1 = clamp(x1, sx0, sx1)
    cy0 = clamp(y0, sy0, sy1)
    cy1 = clamp(y1, sy0, sy1)

    %{
      x: round(cx0),
      y: round(cy0),
      w: max(round(cx1 - cx0), 1),
      h: max(round(cy1 - cy0), 1)
    }
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/circle_story/books/composition/layout_test.exs`
Expected: PASS (all 7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/composition/layout.ex test/circle_story/books/composition/layout_test.exs
git commit -m "feat: add Layout pure print geometry"
```

---

## Task 3: Luminance — pick black or white text

**Files:**
- Create: `lib/circle_story/books/composition/luminance.ex`
- Test: `test/circle_story/books/composition/luminance_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/circle_story/books/composition/luminance_test.exs`:

```elixir
defmodule CircleStory.Books.Composition.LuminanceTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Composition.Luminance

  test "luminance/1 computes weighted luminance 0..255" do
    assert Luminance.luminance([0, 0, 0]) == 0.0
    assert Luminance.luminance([255, 255, 255]) == 255.0
  end

  test "color_for/1 picks black on light, white on dark" do
    assert Luminance.color_for([240, 240, 240]) == :black
    assert Luminance.color_for([10, 10, 10]) == :white
  end

  test "hex/1 maps atoms to ink hex strings" do
    assert Luminance.hex(:black) == "#1A1A1A"
    assert Luminance.hex(:white) == "#FAFAFA"
  end

  test "pick_for_region/2 samples a cropped region of a real image" do
    # Left half white, right half black via composing a black rect.
    base = Image.new!(200, 100, color: :white)
    black = Image.new!(100, 100, color: :black)
    {:ok, img} = Image.compose(base, black, x: 100, y: 0)

    assert Luminance.pick_for_region(img, %{x: 0, y: 0, w: 100, h: 100}) == :black
    assert Luminance.pick_for_region(img, %{x: 100, y: 0, w: 100, h: 100}) == :white
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/circle_story/books/composition/luminance_test.exs`
Expected: FAIL — `Luminance` undefined.

- [ ] **Step 3: Write the implementation**

Create `lib/circle_story/books/composition/luminance.ex`:

```elixir
defmodule CircleStory.Books.Composition.Luminance do
  @moduledoc """
  Chooses black or white text for legibility over artwork by sampling the mean
  color of the placement region. Threshold favors black: regions brighter than
  60% luminance get black ink, darker get white.
  """

  @threshold 153.0
  @black "#1A1A1A"
  @white "#FAFAFA"

  @doc "Weighted (Rec. 709) luminance of an `[r, g, b]` (or `[r, g, b, a]`) pixel, 0..255."
  @spec luminance([number()]) :: float()
  def luminance([r, g, b | _]), do: 0.2126 * r + 0.7152 * g + 0.0722 * b

  @doc "`:black` for light pixels, `:white` for dark pixels."
  @spec color_for([number()]) :: :black | :white
  def color_for(rgb) when is_list(rgb) do
    if luminance(rgb) >= @threshold, do: :black, else: :white
  end

  @doc "Ink hex string for a chosen color."
  @spec hex(:black | :white) :: String.t()
  def hex(:black), do: @black
  def hex(:white), do: @white

  @doc "Sample the mean color of `rect` within `image` and pick an ink color."
  @spec pick_for_region(Vix.Vips.Image.t(), map()) :: :black | :white
  def pick_for_region(image, %{x: x, y: y, w: w, h: h}) do
    cropped = Image.crop!(image, x, y, w, h)
    cropped |> Image.average!() |> color_for()
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/circle_story/books/composition/luminance_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/composition/luminance.ex test/circle_story/books/composition/luminance_test.exs
git commit -m "feat: add Luminance black/white ink picker"
```

---

## Task 4: TextRenderer — text runs with autofit

**Files:**
- Create: `lib/circle_story/books/composition/text_renderer.ex`
- Test: `test/circle_story/books/composition/text_renderer_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/circle_story/books/composition/text_renderer_test.exs`:

```elixir
defmodule CircleStory.Books.Composition.TextRendererTest do
  use ExUnit.Case, async: false

  alias CircleStory.Books.Composition.TextRenderer
  alias CircleStory.Books.Fonts

  setup do
    Fonts.setup()
    :ok
  end

  test "render/2 returns an RGBA image" do
    {:ok, img} = TextRenderer.render("Hello", font: "Nunito", font_size: 48, color: "#1A1A1A")
    assert Image.bands(img) == 4
    assert Image.width(img) > 0
  end

  test "render_fitted/2 fits within the box bounds" do
    {:ok, img, size} =
      TextRenderer.render_fitted("Meet Ornella. She is a beautiful little girl.",
        font: "Nunito",
        color: "#1A1A1A",
        align: :left,
        max_w: 800,
        max_h: 300
      )

    assert Image.width(img) <= 800
    assert Image.height(img) <= 300
    assert size >= TextRenderer.min_font_size()
  end

  test "render_fitted/2 shrinks to honor a small box" do
    {:ok, _img, small} =
      TextRenderer.render_fitted("A long line of text that must shrink",
        font: "Nunito", color: "#1A1A1A", align: :left, max_w: 300, max_h: 60)

    {:ok, _img, big} =
      TextRenderer.render_fitted("A long line of text that must shrink",
        font: "Nunito", color: "#1A1A1A", align: :left, max_w: 1200, max_h: 600)

    assert small < big
  end

  test "stack_vertical/2 stacks images into one taller transparent image" do
    {:ok, a} = TextRenderer.render("Title", font: "Fredoka", font_size: 80, color: "#1A1A1A")
    {:ok, b} = TextRenderer.render("Author", font: "Nunito", font_size: 40, color: "#1A1A1A")
    {:ok, stacked} = TextRenderer.stack_vertical([a, b], 20)

    assert Image.width(stacked) == max(Image.width(a), Image.width(b))
    assert Image.height(stacked) == Image.height(a) + 20 + Image.height(b)
    assert Image.bands(stacked) == 4
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/circle_story/books/composition/text_renderer_test.exs`
Expected: FAIL — `TextRenderer` undefined.

- [ ] **Step 3: Write the implementation**

Create `lib/circle_story/books/composition/text_renderer.ex`:

```elixir
defmodule CircleStory.Books.Composition.TextRenderer do
  @moduledoc """
  Renders text runs to transparent RGBA images using `Image.Text`, with an
  auto-fit search that picks the largest font size whose wrapped render fits a
  bounding box. Fonts are resolved by family name via fontconfig (see
  `CircleStory.Books.Fonts`).
  """

  @max_font_size 220
  @min_font_size 28
  @step 6

  def min_font_size, do: @min_font_size

  @doc """
  Render a single text run. Options: `:font` (family), `:font_size`, `:color`
  (`:text_fill_color`), `:align`, `:font_weight`, and optional `:width` (wrap).
  """
  @spec render(String.t(), keyword()) :: {:ok, Vix.Vips.Image.t()} | {:error, term()}
  def render(text, opts) do
    text_opts =
      [
        font: Keyword.fetch!(opts, :font),
        font_size: Keyword.get(opts, :font_size, 50),
        text_fill_color: Keyword.get(opts, :color, "#1A1A1A"),
        align: Keyword.get(opts, :align, :left)
      ]
      |> maybe_put(:font_weight, opts[:font_weight])
      |> maybe_put(:width, opts[:width])

    Image.Text.text(text, text_opts)
  end

  @doc """
  Render `text` at the largest font size (between `min_font_size/0` and the
  internal max) whose wrapped render fits within `max_w` x `max_h`. Returns
  `{:ok, image, font_size}`.
  """
  @spec render_fitted(String.t(), keyword()) ::
          {:ok, Vix.Vips.Image.t(), pos_integer()} | {:error, term()}
  def render_fitted(text, opts) do
    max_w = Keyword.fetch!(opts, :max_w)
    max_h = Keyword.fetch!(opts, :max_h)
    fit(text, opts, max_w, max_h, @max_font_size)
  end

  defp fit(text, opts, max_w, max_h, size) when size >= @min_font_size do
    run_opts = Keyword.merge(opts, font_size: size, width: max_w)

    case render(text, run_opts) do
      {:ok, img} ->
        if Image.width(img) <= max_w and Image.height(img) <= max_h do
          {:ok, img, size}
        else
          fit(text, opts, max_w, max_h, size - @step)
        end

      {:error, _} = err ->
        err
    end
  end

  defp fit(text, opts, max_w, _max_h, _size) do
    # Floor: render at the minimum size even if it slightly overflows.
    case render(text, Keyword.merge(opts, font_size: @min_font_size, width: max_w)) do
      {:ok, img} -> {:ok, img, @min_font_size}
      err -> err
    end
  end

  @doc "Stack RGBA images vertically (left-aligned) onto one transparent canvas with `gap` px between."
  @spec stack_vertical([Vix.Vips.Image.t()], non_neg_integer()) ::
          {:ok, Vix.Vips.Image.t()} | {:error, term()}
  def stack_vertical(images, gap) do
    width = images |> Enum.map(&Image.width/1) |> Enum.max()
    height = (images |> Enum.map(&Image.height/1) |> Enum.sum()) + gap * (length(images) - 1)
    canvas = Image.new!(width, height, bands: 4, color: [0, 0, 0, 0])

    {result, _y} =
      Enum.reduce(images, {canvas, 0}, fn img, {acc, y} ->
        {:ok, composed} = Image.compose(acc, img, x: 0, y: y)
        {composed, y + Image.height(img) + gap}
      end)

    {:ok, result}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/circle_story/books/composition/text_renderer_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/composition/text_renderer.ex test/circle_story/books/composition/text_renderer_test.exs
git commit -m "feat: add TextRenderer with autofit and vertical stacking"
```

---

## Task 5: ImageOps — fill-crop fit, blank canvas, output paths

**Files:**
- Create: `lib/circle_story/books/composition/image_ops.ex`
- Test: `test/circle_story/books/composition/image_ops_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/circle_story/books/composition/image_ops_test.exs`:

```elixir
defmodule CircleStory.Books.Composition.ImageOpsTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Composition.ImageOps

  test "fit/3 fill-crops to exact dimensions" do
    src = Image.new!(1600, 900, color: :teal)
    fitted = ImageOps.fit(src, 3675, 1875)
    assert Image.width(fitted) == 3675
    assert Image.height(fitted) == 1875
  end

  test "fit/3 accepts a path" do
    path = Path.join(System.tmp_dir!(), "imageops_src_#{System.unique_integer([:positive])}.png")
    Image.write!(Image.new!(1600, 1600, color: :coral), path)
    fitted = ImageOps.fit(path, 1875, 1875)
    assert Image.width(fitted) == 1875
    assert Image.height(fitted) == 1875
  after
    :ok
  end

  test "to_png_bytes/1 encodes a PNG binary" do
    bytes = ImageOps.to_png_bytes(Image.new!(10, 10, color: :white))
    assert <<0x89, "PNG", _::binary>> = bytes
  end

  test "print_ready_path/1 swaps the directory and keeps the basename" do
    raw = "/app/priv/generated_images/inner_3_123.png"
    assert ImageOps.print_ready_path(raw) |> Path.basename() == "inner_3_123.png"
    assert ImageOps.print_ready_path(raw) =~ "print_ready"
  end

  test "bbox_path/1 appends .bbox.json" do
    raw = "/app/priv/generated_images/inner_3_123.png"
    assert ImageOps.bbox_path(raw) == "/app/priv/generated_images/inner_3_123.bbox.json"
  end

  test "latest_raw/1 returns the newest file matching a prefix" do
    dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
    File.mkdir_p!(dir)
    older = Path.join(dir, "lrtest_100.png")
    newer = Path.join(dir, "lrtest_200.png")
    Image.write!(Image.new!(4, 4, color: :white), older)
    Image.write!(Image.new!(4, 4, color: :white), newer)

    assert ImageOps.latest_raw("lrtest_") == {:ok, newer}
    assert ImageOps.latest_raw("nope_") == {:error, :no_raw_art}
  after
    dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
    Enum.each(Path.wildcard(Path.join(dir, "lrtest_*.png")), &File.rm/1)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/circle_story/books/composition/image_ops_test.exs`
Expected: FAIL — `ImageOps` undefined.

- [ ] **Step 3: Write the implementation**

Create `lib/circle_story/books/composition/image_ops.ex`:

```elixir
defmodule CircleStory.Books.Composition.ImageOps do
  @moduledoc """
  Thin wrappers over the `image` library for the composition pipeline:
  fill-crop resizing to exact print dimensions, PNG encoding, and the file-path
  conventions for raw art, cached bounding boxes, and print-ready output.
  """

  @doc "Resize `image_or_path` to fill exactly `w` x `h`, center-cropping overflow."
  @spec fit(Vix.Vips.Image.t() | Path.t(), pos_integer(), pos_integer()) :: Vix.Vips.Image.t()
  def fit(image_or_path, w, h) do
    Image.thumbnail!(image_or_path, "#{w}x#{h}", crop: :center)
  end

  @doc "Encode an image to PNG bytes in memory."
  @spec to_png_bytes(Vix.Vips.Image.t()) :: binary()
  def to_png_bytes(image) do
    Image.write!(image, :memory, suffix: ".png")
  end

  @doc "Print-ready output path for a raw-art path (priv/print_ready/<basename>)."
  @spec print_ready_path(Path.t()) :: Path.t()
  def print_ready_path(raw_path) do
    dir = Path.join(:code.priv_dir(:circle_story), "print_ready")
    File.mkdir_p!(dir)
    Path.join(dir, Path.basename(raw_path))
  end

  @doc "Cached bounding-box JSON path for a raw-art path (<raw>.bbox.json, .png stripped)."
  @spec bbox_path(Path.t()) :: Path.t()
  def bbox_path(raw_path) do
    Path.rootname(raw_path) <> ".bbox.json"
  end

  @doc """
  Newest raw-art PNG in priv/generated_images whose basename starts with
  `prefix` (e.g. `"cover_front_"`, `"inner_1_"`). Timestamped filenames sort
  lexicographically by age. Used by the cheap re-compose path.
  """
  @spec latest_raw(String.t()) :: {:ok, Path.t()} | {:error, :no_raw_art}
  def latest_raw(prefix) do
    dir = Path.join(:code.priv_dir(:circle_story), "generated_images")

    case dir |> Path.join("#{prefix}*.png") |> Path.wildcard() |> Enum.sort() |> List.last() do
      nil -> {:error, :no_raw_art}
      path -> {:ok, path}
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/circle_story/books/composition/image_ops_test.exs`
Expected: PASS. (`#{w}x#{h}` with `crop: :center` makes libvips' thumbnail return exactly those dimensions.)

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/composition/image_ops.ex test/circle_story/books/composition/image_ops_test.exs
git commit -m "feat: add ImageOps fill-crop, png encode, path helpers"
```

---

## Task 6: PlaceText — the bounding-box AI action

**Files:**
- Create: `lib/circle_story/books/actions/place_text.ex`
- Test: `test/circle_story/books/actions/place_text_test.exs`

The action's network call is integration-only (skipped by default), mirroring
`generate_spread_image_test.exs`. The pure parsing/validation logic
(`parse_result/1`, `default_box/1`) is fully unit-tested.

- [ ] **Step 1: Write the failing test**

Create `test/circle_story/books/actions/place_text_test.exs`:

```elixir
defmodule CircleStory.Books.Actions.PlaceTextTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Actions.PlaceText

  describe "parse_result/1" do
    test "reads a valid string-keyed map" do
      assert {:ok, %{bounding_box: [150, 680, 480, 950], text_align: :right}} =
               PlaceText.parse_result(%{
                 "bounding_box" => [150, 680, 480, 950],
                 "text_align" => "right"
               })
    end

    test "defaults an unknown alignment to :center" do
      assert {:ok, %{text_align: :center}} =
               PlaceText.parse_result(%{"bounding_box" => [0, 0, 100, 100], "text_align" => "weird"})
    end

    test "rejects a malformed bounding box" do
      assert {:error, _} = PlaceText.parse_result(%{"bounding_box" => [1, 2], "text_align" => "left"})
      assert {:error, _} = PlaceText.parse_result(%{"text_align" => "left"})
      assert {:error, _} = PlaceText.parse_result(:nonsense)
    end
  end

  describe "default_box/1" do
    test "inner falls back to the lower third, cover to upper center" do
      assert %{bounding_box: [_, _, _, _], text_align: :center} = PlaceText.default_box(:inner)
      assert %{bounding_box: [_, _, _, _], text_align: :center} = PlaceText.default_box(:cover)
      refute PlaceText.default_box(:inner) == PlaceText.default_box(:cover)
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/circle_story/books/actions/place_text_test.exs`
Expected: FAIL — `PlaceText` undefined.

- [ ] **Step 3: Write the implementation**

Create `lib/circle_story/books/actions/place_text.ex`:

```elixir
defmodule CircleStory.Books.Actions.PlaceText do
  @moduledoc """
  Asks Gemini where to place text on a print-size page image, returning a
  bounding box (normalized 1000x1000, `[ymin, xmin, ymax, xmax]`) and a
  text alignment. Used for the cover (title+author) and inner spreads.
  """

  use Jido.Action,
    name: "place_text",
    description: "Generate a text bounding box for a book page via Gemini",
    schema: [
      image_png: [type: :string, required: true, doc: "Print-size page image as PNG bytes"],
      text: [type: :string, required: true, doc: "Text to place"],
      mode: [type: {:in, [:inner, :cover]}, required: true]
    ]

  require Logger

  @model "google:gemini-3.5-flash"

  @object_schema [
    bounding_box: [type: {:list, :integer}, required: true],
    text_align: [type: :string, required: true]
  ]

  @impl true
  def run(%{image_png: png, text: text, mode: mode}, _context) do
    messages = [
      %{
        role: "user",
        content: [
          %{type: "text", text: prompt(mode, text)},
          %{type: "image_url", image_url: %{url: "data:image/png;base64,#{Base.encode64(png)}"}}
        ]
      }
    ]

    with {:ok, response} <- ReqLLM.generate_object(@model, messages, @object_schema),
         object when is_map(object) <- ReqLLM.Response.object(response),
         {:ok, result} <- parse_result(object) do
      {:ok, result}
    else
      other ->
        Logger.warning("PlaceText falling back to default box: #{inspect(other)}")
        {:ok, default_box(mode)}
    end
  end

  @doc "Validate and normalize a raw object map into `%{bounding_box: [..], text_align: atom}`."
  @spec parse_result(map() | term()) :: {:ok, map()} | {:error, term()}
  def parse_result(%{"bounding_box" => [a, b, c, d], "text_align" => align})
      when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    {:ok, %{bounding_box: [a, b, c, d], text_align: to_align(align)}}
  end

  def parse_result(other), do: {:error, {:invalid_place_text_result, other}}

  @doc "Fallback box when the model output is unusable."
  @spec default_box(:inner | :cover) :: map()
  def default_box(:inner), do: %{bounding_box: [650, 100, 900, 900], text_align: :center}
  def default_box(:cover), do: %{bounding_box: [80, 150, 320, 850], text_align: :center}

  defp to_align("left"), do: :left
  defp to_align("right"), do: :right
  defp to_align(_), do: :center

  defp prompt(mode, text) do
    fold_clause =
      case mode do
        :inner ->
          "Given that the book will be folded in the middle, try to avoid putting " <>
            "text that crosses the midpoint of the book.\n\n"

        :cover ->
          ""
      end

    """
    You will be given text (including new lines) and an image. Your job is to
    figure out the best place to put that text to compose a page for a
    children's book.

    #{fold_clause}Keep the text inside the central area of the image and away from \
    the outer ~6% near each edge, since the printer needs a bleed margin.

    Return only:
    1) a bounding box in the format [ymin, xmin, ymax, xmax] normalized to a 1000 x 1000 grid.
    2) a text-align recommendation (left, right, or center only).

    Return JSON only. No additional text. Example:
    {"bounding_box": [150, 680, 480, 950], "text_align": "right"}

    TEXT:
    #{text}
    """
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/circle_story/books/actions/place_text_test.exs`
Expected: PASS (network not exercised — only `parse_result/1` and `default_box/1`).

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/actions/place_text.ex test/circle_story/books/actions/place_text_test.exs
git commit -m "feat: add PlaceText bounding-box AI action"
```

---

## Task 7: DedicationComposer — fixed layout, no AI

**Files:**
- Create: `lib/circle_story/books/composition/dedication_composer.ex`
- Test: `test/circle_story/books/composition/dedication_composer_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/circle_story/books/composition/dedication_composer_test.exs`:

```elixir
defmodule CircleStory.Books.Composition.DedicationComposerTest do
  use ExUnit.Case, async: false

  alias CircleStory.Books.Composition.DedicationComposer
  alias CircleStory.Books.{DedicationSpread, Fonts}

  setup do
    Fonts.setup()
    :ok
  end

  test "compose/1 returns a 3675x1875 image" do
    dedication = %DedicationSpread{
      text: "For Ornella — may you always feel the warmth of Nani's love."
    }

    {:ok, img} = DedicationComposer.compose(dedication)
    assert Image.width(img) == 3675
    assert Image.height(img) == 1875
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/circle_story/books/composition/dedication_composer_test.exs`
Expected: FAIL — `DedicationComposer` undefined.

- [ ] **Step 3: Write the implementation**

Create `lib/circle_story/books/composition/dedication_composer.ex`:

```elixir
defmodule CircleStory.Books.Composition.DedicationComposer do
  @moduledoc """
  Composes the dedication spread (3675x1875, no AI): dedication text centered in
  the left page, an empty pink placeholder circle centered in the right page
  (later replaced by the user's photo). Cream background.
  """

  alias CircleStory.Books.Composition.{Layout, TextRenderer}
  alias CircleStory.Books.DedicationSpread

  @bg "#FBF6EC"
  @ink "#3A2E26"
  @half 1837

  @spec compose(DedicationSpread.t()) :: {:ok, Vix.Vips.Image.t()} | {:error, term()}
  def compose(%DedicationSpread{text: text}) do
    {w, h} = Layout.inner_dims()
    inset = Layout.safe_inset()
    canvas = Image.new!(w, h, color: @bg)

    {:ok, text_img, _size} =
      TextRenderer.render_fitted(text,
        font: "Nunito",
        color: @ink,
        align: :center,
        max_w: @half - 2 * inset,
        max_h: h - 2 * inset
      )

    tx = div(@half - Image.width(text_img), 2)
    ty = div(h - Image.height(text_img), 2)
    {:ok, with_text} = Image.compose(canvas, text_img, x: tx, y: ty)

    cx = @half + div(w - @half, 2)
    cy = div(h, 2)
    radius = round((min(w - @half, h) - 2 * inset) / 2 * 0.85)

    with_circle = Image.Draw.circle!(with_text, cx, cy, radius, color: :pink, fill: true)
    {:ok, with_circle}
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/circle_story/books/composition/dedication_composer_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/composition/dedication_composer.ex test/circle_story/books/composition/dedication_composer_test.exs
git commit -m "feat: add DedicationComposer fixed layout"
```

---

## Task 8: SpreadComposer — inner spreads

**Files:**
- Create: `lib/circle_story/books/composition/spread_composer.ex`
- Test: `test/circle_story/books/composition/spread_composer_test.exs`

`compose/3` takes an already-fitted print-size base image, the text, and a
denormalized placement (`%{rect: rect, align: align}`) — keeping it free of any
network call and testable with an injected box.

- [ ] **Step 1: Write the failing test**

Create `test/circle_story/books/composition/spread_composer_test.exs`:

```elixir
defmodule CircleStory.Books.Composition.SpreadComposerTest do
  use ExUnit.Case, async: false

  alias CircleStory.Books.Composition.SpreadComposer
  alias CircleStory.Books.Fonts

  setup do
    Fonts.setup()
    :ok
  end

  test "compose/3 overlays text and keeps print dimensions" do
    base = Image.new!(3675, 1875, color: :white)
    placement = %{rect: %{x: 300, y: 1300, w: 1200, h: 400}, align: :left}

    {:ok, img} = SpreadComposer.compose(base, "Meet Ornella. Entirely made of love.", placement)

    assert Image.width(img) == 3675
    assert Image.height(img) == 1875
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/circle_story/books/composition/spread_composer_test.exs`
Expected: FAIL — `SpreadComposer` undefined.

- [ ] **Step 3: Write the implementation**

Create `lib/circle_story/books/composition/spread_composer.ex`:

```elixir
defmodule CircleStory.Books.Composition.SpreadComposer do
  @moduledoc """
  Composes an inner spread: renders the story text (Nunito) auto-fit to the
  placement rect, picks black/white ink by sampling the artwork under the rect,
  and composites it onto the fitted print-size base image (3675x1875).
  """

  alias CircleStory.Books.Composition.{Luminance, TextRenderer}

  @spec compose(Vix.Vips.Image.t(), String.t(), map()) ::
          {:ok, Vix.Vips.Image.t()} | {:error, term()}
  def compose(base, text, %{rect: rect, align: align}) do
    color = base |> Luminance.pick_for_region(rect) |> Luminance.hex()

    {:ok, text_img, _size} =
      TextRenderer.render_fitted(text,
        font: "Nunito",
        color: color,
        align: align,
        max_w: rect.w,
        max_h: rect.h
      )

    x = aligned_x(rect, Image.width(text_img), align)
    Image.compose(base, text_img, x: x, y: rect.y)
  end

  defp aligned_x(rect, _text_w, :left), do: rect.x
  defp aligned_x(rect, text_w, :center), do: rect.x + div(rect.w - text_w, 2)
  defp aligned_x(rect, text_w, :right), do: rect.x + rect.w - text_w
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/circle_story/books/composition/spread_composer_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/composition/spread_composer.ex test/circle_story/books/composition/spread_composer_test.exs
git commit -m "feat: add SpreadComposer for inner spreads"
```

---

## Task 9: CoverComposer — full wrap

**Files:**
- Create: `lib/circle_story/books/composition/cover_composer.ex`
- Test: `test/circle_story/books/composition/cover_composer_test.exs`

`compose/3` takes the `Book` (for title/author/tagline), the fitted 1875x1875
front art, and the title+author placement (`%{rect:, align:}`); it builds the
full 3863x1875 wrap.

- [ ] **Step 1: Write the failing test**

Create `test/circle_story/books/composition/cover_composer_test.exs`:

```elixir
defmodule CircleStory.Books.Composition.CoverComposerTest do
  use ExUnit.Case, async: false

  alias CircleStory.Books.Composition.CoverComposer
  alias CircleStory.Books.{Book, CoverSpread, Fonts}

  setup do
    Fonts.setup()
    :ok
  end

  test "compose/3 builds the full 3863x1875 wrap" do
    book = %Book{
      title: "Nani's Magic Thread",
      author: "Sidd & Veronika",
      cover: %CoverSpread{tagline: "A story of love woven through generations.", image_prompt: "x"}
    }

    front_art = Image.new!(1875, 1875, color: :sky_blue)
    placement = %{rect: %{x: 2100, y: 150, w: 1400, h: 500}, align: :center}

    {:ok, img} = CoverComposer.compose(book, front_art, placement)

    assert Image.width(img) == 3863
    assert Image.height(img) == 1875
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/circle_story/books/composition/cover_composer_test.exs`
Expected: FAIL — `CoverComposer` undefined.

- [ ] **Step 3: Write the implementation**

Create `lib/circle_story/books/composition/cover_composer.ex`:

```elixir
defmodule CircleStory.Books.Composition.CoverComposer do
  @moduledoc """
  Builds the full cover wrap (3863x1875): back panel + spine + front panel.

  - Front: provided 1875x1875 art with title (Fredoka) over author (Nunito)
    stacked within the AI placement box.
  - Spine: solid fill (softened average of the front art) with vertical
    "Title · Author".
  - Back: same fill, tagline top-center, an empty pink placeholder circle
    centered, and the Circle Storybooks blurb bottom-left.

  Ink color (black/white) is chosen per element by luminance.
  """

  alias CircleStory.Books.Composition.{Layout, Luminance, TextRenderer}
  alias CircleStory.Books.Book

  @blurb "Circle Storybooks\nA one of a kind story.\nMake your own at:\nwww.circlestorybooks.com"

  @spec compose(Book.t(), Vix.Vips.Image.t(), map()) ::
          {:ok, Vix.Vips.Image.t()} | {:error, term()}
  def compose(%Book{} = book, front_art, %{rect: rect, align: _align}) do
    {cw, ch} = Layout.cover_dims()
    inset = Layout.safe_inset()
    fill = softened_average(front_art)
    fill_ink = fill |> Luminance.color_for() |> Luminance.hex()

    canvas =
      Image.new!(cw, ch, color: fill)
      |> place_front(front_art, book, rect)
      |> place_spine(book, fill_ink, inset)
      |> place_back(book, fill_ink, inset)

    {:ok, canvas}
  end

  defp place_front(canvas, front_art, %Book{} = book, rect) do
    front = Layout.front_panel()
    canvas = Image.compose!(canvas, front_art, x: front.x, y: front.y)

    ink = canvas |> Luminance.pick_for_region(rect) |> Luminance.hex()

    {:ok, title} =
      TextRenderer.render_fitted(book.title,
        font: "Fredoka",
        font_weight: :bold,
        color: ink,
        align: :center,
        max_w: rect.w,
        max_h: round(rect.h * 0.6)
      )
      |> drop_size()

    {:ok, author} =
      TextRenderer.render_fitted("by #{book.author}",
        font: "Nunito",
        color: ink,
        align: :center,
        max_w: rect.w,
        max_h: round(rect.h * 0.3)
      )
      |> drop_size()

    {:ok, block} = TextRenderer.stack_vertical([title, author], 24)
    bx = rect.x + div(rect.w - Image.width(block), 2)
    Image.compose!(canvas, block, x: bx, y: rect.y)
  end

  defp place_spine(canvas, %Book{} = book, ink, _inset) do
    spine = Layout.spine_panel()

    {:ok, text, _size} =
      TextRenderer.render_fitted("#{book.title} · #{book.author}",
        font: "Fredoka",
        color: ink,
        align: :center,
        max_w: spine.h - 200,
        max_h: spine.w - 24
      )

    rotated = Image.rotate!(text, -90)
    x = spine.x + div(spine.w - Image.width(rotated), 2)
    y = div(spine.h - Image.height(rotated), 2)
    Image.compose!(canvas, rotated, x: x, y: y)
  end

  defp place_back(canvas, %Book{} = book, ink, inset) do
    back = Layout.back_panel()

    {:ok, tagline, _s} =
      TextRenderer.render_fitted(book.cover.tagline,
        font: "Nunito",
        color: ink,
        align: :center,
        max_w: back.w - 2 * inset,
        max_h: 200
      )

    tx = div(back.w - Image.width(tagline), 2)
    canvas = Image.compose!(canvas, tagline, x: tx, y: inset)

    cx = div(back.w, 2)
    cy = div(back.h, 2)
    radius = round(back.w * 0.19)
    canvas = Image.Draw.circle!(canvas, cx, cy, radius, color: :pink, fill: true)

    {:ok, blurb} = TextRenderer.render(@blurb, font: "Nunito", font_size: 44, color: ink, align: :left)
    by = back.h - inset - Image.height(blurb)
    Image.compose!(canvas, blurb, x: inset, y: by)
  end

  # Average color softened toward white for a calmer spine/back panel.
  defp softened_average(image) do
    image
    |> Image.average!()
    |> Enum.map(fn c -> round(c * 0.6 + 255 * 0.4) end)
  end

  defp drop_size({:ok, img, _size}), do: {:ok, img}
  defp drop_size(other), do: other
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/circle_story/books/composition/cover_composer_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/composition/cover_composer.ex test/circle_story/books/composition/cover_composer_test.exs
git commit -m "feat: add CoverComposer full wrap layout"
```

---

## Task 10: Composition facade + Generator wiring

**Files:**
- Create: `lib/circle_story/books/composition.ex`
- Modify: `lib/circle_story/books/generator.ex`
- Test: `test/circle_story/books/composition_test.exs`

The facade owns bbox caching and orchestration. `Generator.generate_*` runs the
full path (fresh bbox); `Generator.compose_*` re-uses the cache.

- [ ] **Step 1: Write the failing test (facade composition with an injected bbox file, no network)**

Create `test/circle_story/books/composition_test.exs`:

```elixir
defmodule CircleStory.Books.CompositionTest do
  use ExUnit.Case, async: false

  alias CircleStory.Books.Composition
  alias CircleStory.Books.Composition.ImageOps
  alias CircleStory.Books.{Book, CoverSpread, InnerSpread, Fonts}

  setup do
    Fonts.setup()
    :ok
  end

  defp write_raw(name) do
    dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{name}_#{System.unique_integer([:positive])}.png")
    # 16:9 raw art for an inner spread.
    Image.write!(Image.new!(1600, 900, color: :sage), path)
    path
  end

  test "compose_spread/3 uses a cached bbox and writes a print-ready PNG" do
    raw = write_raw("inner_1")
    File.write!(ImageOps.bbox_path(raw), Jason.encode!(%{
      "bounding_box" => [650, 100, 900, 900],
      "text_align" => "center"
    }))

    spread = %InnerSpread{position: 1, text: "Meet Ornella.", image_prompt: "x", generated_image_path: raw}

    assert {:ok, %{image_path: out}} = Composition.compose_spread(spread)
    assert File.exists?(out)
    img = Image.open!(out)
    assert Image.width(img) == 3675
    assert Image.height(img) == 1875
  end

  test "compose_cover/2 uses a cached bbox and writes a print-ready PNG" do
    raw = write_raw("cover_front")
    Image.write!(Image.new!(1875, 1875, color: :sky_blue), raw)
    File.write!(ImageOps.bbox_path(raw), Jason.encode!(%{
      "bounding_box" => [80, 150, 320, 850],
      "text_align" => "center"
    }))

    book = %Book{
      title: "Nani's Magic Thread",
      author: "Sidd & Veronika",
      cover: %CoverSpread{tagline: "A story of love.", image_prompt: "x", generated_image_path: raw}
    }

    assert {:ok, %{image_path: out}} = Composition.compose_cover(book)
    assert File.exists?(out)
    img = Image.open!(out)
    assert Image.width(img) == 3863
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/circle_story/books/composition_test.exs`
Expected: FAIL — `Composition` undefined.

- [ ] **Step 3: Write the facade**

Create `lib/circle_story/books/composition.ex`:

```elixir
defmodule CircleStory.Books.Composition do
  @moduledoc """
  Orchestrates compositing of print-ready pages from cached raw art + cached
  bounding boxes. `compose_*` reuse cached boxes (no model calls); pass
  `force_bbox: true` (used by `Generator.generate_*`) to refresh the box.
  """

  alias CircleStory.Books.Composition.{
    CoverComposer,
    DedicationComposer,
    ImageOps,
    Layout,
    SpreadComposer
  }

  alias CircleStory.Books.Actions.PlaceText
  alias CircleStory.Books.{Book, CoverSpread, InnerSpread, DedicationSpread}

  @spec compose_spread(InnerSpread.t(), keyword()) :: {:ok, %{image_path: String.t()}} | {:error, term()}
  def compose_spread(%InnerSpread{generated_image_path: raw, text: text} = _spread, opts \\ []) do
    {w, h} = Layout.inner_dims()
    base = ImageOps.fit(raw, w, h)

    with {:ok, box} <- placement(raw, base, text, :inner, opts) do
      rect = Layout.denormalize(box.bounding_box, Layout.inner_region())
      {:ok, composed} = SpreadComposer.compose(base, text, %{rect: rect, align: box.text_align})
      write_output(composed, raw)
    end
  end

  @spec compose_cover(Book.t(), keyword()) :: {:ok, %{image_path: String.t()}} | {:error, term()}
  def compose_cover(%Book{cover: %CoverSpread{generated_image_path: raw}} = book, opts \\ []) do
    front = ImageOps.fit(raw, 1875, 1875)
    text = "#{book.title}\n#{book.author}"

    with {:ok, box} <- placement(raw, front, text, :cover, opts) do
      rect = Layout.denormalize(box.bounding_box, Layout.front_panel())
      {:ok, composed} = CoverComposer.compose(book, front, %{rect: rect, align: box.text_align})
      write_output(composed, raw)
    end
  end

  @spec compose_dedication(DedicationSpread.t()) :: {:ok, %{image_path: String.t()}} | {:error, term()}
  def compose_dedication(%DedicationSpread{} = dedication) do
    {:ok, composed} = DedicationComposer.compose(dedication)
    dir = Path.join(:code.priv_dir(:circle_story), "print_ready")
    File.mkdir_p!(dir)
    path = Path.join(dir, "dedication.png")
    Image.write!(composed, path)
    {:ok, %{image_path: path}}
  end

  # Load a cached bbox, or fetch (and cache) via PlaceText. `force_bbox: true` always refetches.
  defp placement(raw, base, text, mode, opts) do
    cache = ImageOps.bbox_path(raw)
    force = Keyword.get(opts, :force_bbox, false)

    cond do
      not force and File.exists?(cache) ->
        load_cached(cache)

      true ->
        png = ImageOps.to_png_bytes(base)

        with {:ok, box} <- PlaceText.run(%{image_png: png, text: text, mode: mode}, %{}) do
          File.write!(cache, Jason.encode!(%{
            "bounding_box" => box.bounding_box,
            "text_align" => Atom.to_string(box.text_align)
          }))

          {:ok, box}
        end
    end
  end

  defp load_cached(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{"bounding_box" => bbox, "text_align" => align}} <- Jason.decode(raw) do
      {:ok, %{bounding_box: bbox, text_align: align_atom(align)}}
    end
  end

  defp align_atom("left"), do: :left
  defp align_atom("right"), do: :right
  defp align_atom(_), do: :center

  defp write_output(image, raw) do
    path = ImageOps.print_ready_path(raw)
    Image.write!(image, path)
    {:ok, %{image_path: path}}
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/circle_story/books/composition_test.exs`
Expected: PASS.

- [ ] **Step 5: Wire the Generator**

Replace `lib/circle_story/books/generator.ex` with (preserving `inspect_prompt/2`):

```elixir
defmodule CircleStory.Books.Generator do
  @moduledoc """
  Generate and compose print-ready book pages.

  ## IEx workflow

      book = CircleStory.Books.Templates.NanisMagicThread.book()

      # Full path: generate art + bounding box + composite -> print-ready PNG
      {:ok, %{image_path: path}} = CircleStory.Books.Generator.generate_cover(book)
      {:ok, %{image_path: path}} = CircleStory.Books.Generator.generate_spread(book, 1)

      # Cheap re-composite from cached raw art + cached bbox (no model calls)
      {:ok, %{image_path: path}} = CircleStory.Books.Generator.compose_cover(book)
  """

  alias CircleStory.Books.{Book, Composition, CoverSpread, InnerSpread, PromptBuilder}
  alias CircleStory.Books.Actions.GenerateSpreadImage
  alias CircleStory.Books.Composition.ImageOps

  @spec generate_cover(Book.t()) :: {:ok, map()} | {:error, term()}
  def generate_cover(%Book{} = book) do
    with {:ok, %{image_path: raw}} <-
           GenerateSpreadImage.run(
             %{spread: book.cover, characters: book.characters, spread_type: :cover},
             %{}
           ) do
      book
      |> put_cover_raw(raw)
      |> Composition.compose_cover(force_bbox: true)
    end
  end

  @spec compose_cover(Book.t()) :: {:ok, map()} | {:error, term()}
  def compose_cover(%Book{} = book) do
    with {:ok, raw} <- ImageOps.latest_raw("cover_front_") do
      book |> put_cover_raw(raw) |> Composition.compose_cover()
    end
  end

  @spec generate_spread(Book.t(), 1..9) :: {:ok, map()} | {:error, term()}
  def generate_spread(%Book{} = book, position) when position in 1..9 do
    with {:ok, spread} <- fetch_spread(book, position),
         {:ok, %{image_path: raw}} <-
           GenerateSpreadImage.run(
             %{spread: spread, characters: book.characters, spread_type: :inner},
             %{}
           ) do
      %{spread | generated_image_path: raw}
      |> Composition.compose_spread(force_bbox: true)
    end
  end

  @spec compose_spread(Book.t(), 1..9) :: {:ok, map()} | {:error, term()}
  def compose_spread(%Book{} = book, position) when position in 1..9 do
    with {:ok, spread} <- fetch_spread(book, position),
         {:ok, raw} <- ImageOps.latest_raw("inner_#{position}_") do
      Composition.compose_spread(%{spread | generated_image_path: raw})
    end
  end

  @spec compose_dedication(Book.t()) :: {:ok, map()} | {:error, term()}
  def compose_dedication(%Book{dedication: dedication}), do: Composition.compose_dedication(dedication)

  @doc "Returns `{system_prompt, user_message}` for the given page without an API call."
  @spec inspect_prompt(Book.t(), :cover | 1..9) :: {String.t(), String.t()}
  def inspect_prompt(%Book{} = book, :cover) do
    {PromptBuilder.system_prompt(:cover), PromptBuilder.user_message(book.cover, book.characters)}
  end

  def inspect_prompt(%Book{} = book, position) when is_integer(position) do
    spread = Enum.find(book.spreads, &(&1.position == position))
    {PromptBuilder.system_prompt(:inner), PromptBuilder.user_message(spread, book.characters)}
  end

  defp fetch_spread(%Book{spreads: spreads}, position) do
    case Enum.find(spreads, &(&1.position == position)) do
      nil -> {:error, "no spread at position #{position}"}
      %InnerSpread{} = spread -> {:ok, spread}
    end
  end

  defp put_cover_raw(%Book{cover: %CoverSpread{} = cover} = book, raw) do
    %{book | cover: %{cover | generated_image_path: raw}}
  end
end
```

- [ ] **Step 6: Run the Generator-facing tests and confirm no regression**

Run: `mix test test/circle_story/books/composition_test.exs test/circle_story/books/prompt_builder_test.exs`
Expected: PASS. (`generate_*` themselves hit the network and are not unit-tested here; they are exercised manually via IEx.)

- [ ] **Step 7: Commit**

```bash
git add lib/circle_story/books/composition.ex lib/circle_story/books/generator.ex test/circle_story/books/composition_test.exs
git commit -m "feat: wire composition facade into Generator generate_/compose_"
```

---

## Task 11: Final verification

- [ ] **Step 1: Run the full precommit**

Run: `mix precommit`
Expected: compiles with no warnings, no unused deps, formatted, all tests pass.

- [ ] **Step 2: Manual end-to-end smoke test (requires GEMINI/Google API key)**

In `iex -S mix`:

```elixir
book = CircleStory.Books.Templates.NanisMagicThread.book()
{:ok, %{image_path: cover}} = CircleStory.Books.Generator.generate_cover(book)
{:ok, %{image_path: spread}} = CircleStory.Books.Generator.generate_spread(book, 1)
{:ok, %{image_path: ded}} = CircleStory.Books.Generator.compose_dedication(book)
```

Open the three PNGs in `priv/print_ready/` and confirm: cover wrap is 3863x1875 with title/author on the front, vertical spine text, back tagline/circle/blurb; inner spread is 3675x1875 with legible story text inside the safe area; dedication has centered text + pink circle. Re-run `compose_cover(book)` and confirm it is fast (no image-model call) and reuses the cached `.bbox.json`.

- [ ] **Step 3: Commit any formatting fixes**

```bash
git add -A
git commit -m "chore: precommit fixes for composition pipeline"
```

---

## Notes for the implementer

- **Fonts on macOS:** `Image.Text`'s `:font_file` option is unsupported on macOS, so fonts are resolved by family name through fontconfig (`CircleStory.Books.Fonts.setup/0`). If text renders in a wrong/default font, the `priv/fonts` dir isn't being seen — re-check `FONTCONFIG_FILE`.
- **`gemini-3.5-flash`:** not in the local `llm_db` registry but req_llm accepts unlisted ids (the project already uses an unlisted image model). If the id errors at runtime, change `@model` in `PlaceText` to `"google:gemini-2.5-flash"`.
- **`Image.average!/1`** returns a per-band list (`[r, g, b]`); luminance and fill use it directly.
- **No Ecto:** all state is sidecar files (`priv/generated_images/*.bbox.json`, `priv/print_ready/*.png`), consistent with the project's in-memory struct convention.
