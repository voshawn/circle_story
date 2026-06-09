# Text Composition Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compose AI-generated book artwork with text into print-ready PNGs (cover, dedication, inner spreads) by rendering each page as a reusable HTML/CSS Phoenix component and rasterizing it with headless Chrome — so the same markup powers the future in-app editor.

**Architecture:** Decoupled. `generate_*` runs art generation → `image` fill-crops to print dims → Gemini bounding-box call → cache bbox → render a HEEx page component → screenshot to PNG (ChromicPDF). `compose_*` re-renders cheaply from cached raw art + cached bbox. Pure geometry (`Layout`), luminance (`Luminance`), source prep (`ImageOps`), and font embedding (`Fonts`) are isolated units; `PageComponents` produce the markup; `HtmlRenderer` rasterizes; a `Composition` facade and `Generator` orchestrate.

**Tech Stack:** Elixir/Phoenix HEEx function components, `{:chromic_pdf, "~> 1.17"}` (headless Chrome screenshots), `{:image, "~> 0.68"}` (Vix/libvips — fill-crop + luminance only), `ReqLLM.generate_object/4` (Gemini bounding boxes), Jido for the AI action. Fonts Fredoka + Nunito vendored as TTFs, embedded via base64 `@font-face`.

**Reference spec:** `docs/superpowers/specs/2026-06-09-text-composition-pipeline-design.md`

---

## File structure

```
lib/circle_story/books/
  page_components.ex                # HEEx components: cover/1, inner_spread/1, dedication/1 (NEW)
  composition.ex                    # facade + *_html builders (NEW)
  composition/
    layout.ex                       # pure geometry (NEW)
    luminance.ex                    # region → :black | :white (NEW)
    image_ops.ex                    # fill-crop, png/data-uri, paths, latest-raw (NEW)
    fonts.ex                        # base64 @font-face CSS (NEW)
    html_renderer.ex                # component → document → ChromicPDF screenshot (NEW)
  actions/
    place_text.ex                   # Jido action: bbox AI call (NEW)
  generator.ex                      # wire generate_* / compose_* (MODIFY)
lib/circle_story/application.ex     # start ChromicPDF (MODIFY)
config/test.exs                     # disable ChromicPDF at boot in tests (MODIFY)
mix.exs                             # add image + chromic_pdf (MODIFY)
priv/fonts/                         # Fredoka.ttf, Nunito.ttf, Nunito-Italic.ttf (NEW)
```

---

## Task 1: Dependencies, ChromicPDF supervision, vendored fonts

**Files:**
- Modify: `mix.exs`
- Modify: `lib/circle_story/application.ex`
- Modify: `config/test.exs`
- Create: `priv/fonts/Fredoka.ttf`, `priv/fonts/Nunito.ttf`, `priv/fonts/Nunito-Italic.ttf`

- [ ] **Step 1: Add dependencies**

In `mix.exs`, add after the `{:jido, "~> 2.0"},` line:

```elixir
      {:jido, "~> 2.0"},
      {:image, "~> 0.68"},
      {:chromic_pdf, "~> 1.17"},
```

- [ ] **Step 2: Fetch deps**

Run: `mix deps.get`
Expected: fetches `image`, `vix`, `color`, `sweet_xml`, `chromic_pdf`. Vix downloads precompiled libvips.

- [ ] **Step 3: Download the vendored TTFs**

```bash
mkdir -p priv/fonts
curl -fsSL "https://raw.githubusercontent.com/google/fonts/main/ofl/fredoka/Fredoka%5Bwdth%2Cwght%5D.ttf" -o priv/fonts/Fredoka.ttf
curl -fsSL "https://raw.githubusercontent.com/google/fonts/main/ofl/nunito/Nunito%5Bwght%5D.ttf" -o priv/fonts/Nunito.ttf
curl -fsSL "https://raw.githubusercontent.com/google/fonts/main/ofl/nunito/Nunito-Italic%5Bwght%5D.ttf" -o priv/fonts/Nunito-Italic.ttf
```

Expected: `ls -l priv/fonts` shows three `.ttf` files > 50 KB. If a URL 404s, the font path moved — locate it under `ofl/fredoka` / `ofl/nunito` in `github.com/google/fonts`.

- [ ] **Step 4: Start ChromicPDF in the supervision tree (guarded for tests)**

In `lib/circle_story/application.ex`, change the `children` list in `start/2` to prepend ChromicPDF conditionally. Replace the `children = [ ... ]` assignment with:

```elixir
    children =
      maybe_chromic_pdf() ++
        [
          CircleStoryWeb.Telemetry,
          CircleStory.Repo,
          {Ecto.Migrator,
           repos: Application.fetch_env!(:circle_story, :ecto_repos), skip: skip_migrations?()},
          {DNSCluster, query: Application.get_env(:circle_story, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: CircleStory.PubSub},
          CircleStoryWeb.Endpoint,
          CircleStory.Jido
        ]
```

And add this private function to the module (e.g. above `skip_migrations?/0`):

```elixir
  defp maybe_chromic_pdf do
    if Application.get_env(:circle_story, :start_chromic_pdf, true) do
      [{ChromicPDF, []}]
    else
      []
    end
  end
```

- [ ] **Step 5: Disable ChromicPDF at boot in tests**

In `config/test.exs`, add (so the suite doesn't spawn Chrome at boot; integration tests start it themselves):

```elixir
config :circle_story, start_chromic_pdf: false
```

- [ ] **Step 6: Exclude `:integration` tests by default**

In `test/test_helper.exs`, change the `ExUnit.start()` line so browser/network tests are skipped unless explicitly requested:

```elixir
ExUnit.start(exclude: [:integration])
```

Run integration tests later with `mix test --only integration`.

- [ ] **Step 7: Verify the app boots and a screenshot works (manual smoke test)**

Run: `mix compile` then in `iex -S mix`:

```elixir
{:ok, png} = ChromicPDF.capture_screenshot({:html, "<html><body style='margin:0'><div style='width:200px;height:100px;background:teal'></div></body></html>"}, full_page: true)
is_binary(png)  #=> true (base64 PNG)
```

Expected: `true`. If ChromicPDF can't find Chrome, install Chromium or set `chrome_executable:` in the `{ChromicPDF, [...]}` opts. (Dev macOS: Google Chrome at the default `/Applications` path is auto-detected.)

- [ ] **Step 8: Commit**

```bash
git add mix.exs mix.lock priv/fonts lib/circle_story/application.ex config/test.exs test/test_helper.exs
git commit -m "feat: add image + chromic_pdf deps, ChromicPDF supervision, vendored fonts"
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

  test "canvas dimensions and inset" do
    assert Layout.inner_dims() == {3675, 1875}
    assert Layout.cover_dims() == {3863, 1875}
    assert Layout.safe_inset() == 112
  end

  test "cover panels tile the canvas with a 113px spine" do
    assert Layout.back_panel() == %{x: 0, y: 0, w: 1875, h: 1875}
    assert Layout.spine_panel() == %{x: 1875, y: 0, w: 113, h: 1875}
    assert Layout.front_panel() == %{x: 1988, y: 0, w: 1875, h: 1875}
    assert Layout.back_panel().w + Layout.spine_panel().w + Layout.front_panel().w == 3863
  end

  test "regions" do
    assert Layout.inner_region() == %{x: 0, y: 0, w: 3675, h: 1875}
    assert Layout.front_region_local() == %{x: 0, y: 0, w: 1875, h: 1875}
  end

  test "denormalize maps an interior 1000-grid box into region pixels" do
    # Interior box (all coords within the 112..888 safe band) maps straight through.
    rect = Layout.denormalize([200, 200, 800, 800], %{x: 0, y: 0, w: 1000, h: 1000})
    assert rect == %{x: 200, y: 200, w: 600, h: 600}
  end

  test "denormalize clamps to the safe inset" do
    rect = Layout.denormalize([0, 0, 1000, 1000], %{x: 0, y: 0, w: 1000, h: 1000})
    assert rect.x == 112 and rect.y == 112
    assert rect.x + rect.w == 888 and rect.y + rect.h == 888
  end

  test "denormalize normalizes inverted coordinates" do
    rect = Layout.denormalize([800, 800, 200, 200], %{x: 0, y: 0, w: 1000, h: 1000})
    assert rect == %{x: 200, y: 200, w: 600, h: 600}
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/circle_story/books/composition/layout_test.exs`
Expected: FAIL — `Layout` undefined.

- [ ] **Step 3: Write the implementation**

Create `lib/circle_story/books/composition/layout.ex`:

```elixir
defmodule CircleStory.Books.Composition.Layout do
  @moduledoc """
  Pure print geometry: canvas/panel dimensions, the text-safe inset, and mapping
  a Gemini bounding box (normalized to 1000x1000, `[ymin, xmin, ymax, xmax]`)
  into clamped pixel coordinates within a target region.

  A "region" is `%{x:, y:, w:, h:}`; `denormalize/2` returns a pixel "rect" of the
  same shape (used as CSS left/top/width/height).
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

  @doc "Front-cover region in panel-local coordinates (origin 0,0) for luminance + in-panel text positioning."
  def front_region_local, do: %{x: 0, y: 0, w: @panel, h: @panel}

  @doc "Left/right page split x of an inner spread (the fold)."
  def inner_half, do: div(@inner_w, 2) - 1

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

    %{x: round(cx0), y: round(cy0), w: max(round(cx1 - cx0), 1), h: max(round(cy1 - cy0), 1)}
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/circle_story/books/composition/layout_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/composition/layout.ex test/circle_story/books/composition/layout_test.exs
git commit -m "feat: add Layout pure print geometry"
```

---

## Task 3: Luminance — pick black or white ink

**Files:**
- Create: `lib/circle_story/books/composition/luminance.ex`
- Test: `test/circle_story/books/composition/luminance_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/circle_story/books/composition/luminance_test.exs`:

```elixir
defmodule CircleStory.Books.Composition.LuminanceTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Composition.Luminance

  test "luminance/1 is 0..255" do
    assert Luminance.luminance([0, 0, 0]) == 0.0
    assert Luminance.luminance([255, 255, 255]) == 255.0
  end

  test "color_for/1 picks black on light, white on dark" do
    assert Luminance.color_for([240, 240, 240]) == :black
    assert Luminance.color_for([10, 10, 10]) == :white
  end

  test "hex/1 maps atoms to ink" do
    assert Luminance.hex(:black) == "#1A1A1A"
    assert Luminance.hex(:white) == "#FAFAFA"
  end

  test "pick_for_region/2 samples a cropped region" do
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
  Chooses black or white ink for legibility over artwork by sampling the mean
  color of the placement region. Favors black: regions brighter than 60%
  luminance get black, darker get white.
  """

  @threshold 153.0
  @black "#1A1A1A"
  @white "#FAFAFA"

  @doc "Rec. 709 luminance of an `[r, g, b]` (or `[r, g, b, a]`) pixel, 0..255."
  @spec luminance([number()]) :: float()
  def luminance([r, g, b | _]), do: 0.2126 * r + 0.7152 * g + 0.0722 * b

  @doc "`:black` for light pixels, `:white` for dark pixels."
  @spec color_for([number()]) :: :black | :white
  def color_for(rgb) when is_list(rgb) do
    if luminance(rgb) >= @threshold, do: :black, else: :white
  end

  @doc "Ink hex for a chosen color."
  @spec hex(:black | :white) :: String.t()
  def hex(:black), do: @black
  def hex(:white), do: @white

  @doc "Sample the mean color of `rect` within `image` and pick an ink color."
  @spec pick_for_region(Vix.Vips.Image.t(), map()) :: :black | :white
  def pick_for_region(image, %{x: x, y: y, w: w, h: h}) do
    image |> Image.crop!(x, y, w, h) |> Image.average!() |> color_for()
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

## Task 4: ImageOps — source prep, encoding, paths

**Files:**
- Create: `lib/circle_story/books/composition/image_ops.ex`
- Test: `test/circle_story/books/composition/image_ops_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/circle_story/books/composition/image_ops_test.exs`:

```elixir
defmodule CircleStory.Books.Composition.ImageOpsTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Composition.ImageOps

  test "fit/3 fill-crops to exact dimensions (image or path)" do
    src = Image.new!(1600, 900, color: :teal)
    fitted = ImageOps.fit(src, 3675, 1875)
    assert Image.width(fitted) == 3675 and Image.height(fitted) == 1875

    path = Path.join(System.tmp_dir!(), "io_src_#{System.unique_integer([:positive])}.png")
    Image.write!(Image.new!(1600, 1600, color: :coral), path)
    sq = ImageOps.fit(path, 1875, 1875)
    assert Image.width(sq) == 1875 and Image.height(sq) == 1875
  end

  test "to_png_bytes/1 and to_data_uri/1" do
    img = Image.new!(10, 10, color: :white)
    assert <<0x89, "PNG", _::binary>> = ImageOps.to_png_bytes(img)
    assert "data:image/png;base64," <> rest = ImageOps.to_data_uri(img)
    assert byte_size(rest) > 0
  end

  test "softened_average/1 lightens the mean toward white" do
    img = Image.new!(10, 10, color: [40, 40, 40])
    [r, g, b] = ImageOps.softened_average(img)
    assert r > 40 and g > 40 and b > 40
  end

  test "path helpers" do
    raw = "/app/priv/generated_images/inner_3_123.png"
    assert ImageOps.print_ready_path(raw) |> Path.basename() == "inner_3_123.png"
    assert ImageOps.print_ready_path(raw) =~ "print_ready"
    assert ImageOps.bbox_path(raw) == "/app/priv/generated_images/inner_3_123.bbox.json"
  end

  test "latest_raw/1 returns the newest file matching a prefix" do
    dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
    File.mkdir_p!(dir)
    older = Path.join(dir, "iotest_100.png")
    newer = Path.join(dir, "iotest_200.png")
    Image.write!(Image.new!(4, 4, color: :white), older)
    Image.write!(Image.new!(4, 4, color: :white), newer)

    assert ImageOps.latest_raw("iotest_") == {:ok, newer}
    assert ImageOps.latest_raw("nope_") == {:error, :no_raw_art}
  after
    dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
    Enum.each(Path.wildcard(Path.join(dir, "iotest_*.png")), &File.rm/1)
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
  `image`/libvips wrappers for the pipeline: fill-crop resizing to exact print
  dimensions, PNG/data-URI encoding (for the HTML background), a softened average
  color (spine/back fill), and the file-path conventions for raw art, cached
  bounding boxes, and print-ready output.
  """

  @doc "Resize `image_or_path` to fill exactly `w` x `h`, center-cropping overflow."
  @spec fit(Vix.Vips.Image.t() | Path.t(), pos_integer(), pos_integer()) :: Vix.Vips.Image.t()
  def fit(image_or_path, w, h), do: Image.thumbnail!(image_or_path, "#{w}x#{h}", crop: :center)

  @doc "Encode an image to PNG bytes in memory."
  @spec to_png_bytes(Vix.Vips.Image.t()) :: binary()
  def to_png_bytes(image), do: Image.write!(image, :memory, suffix: ".png")

  @doc "Encode an image as a `data:image/png;base64,...` URI."
  @spec to_data_uri(Vix.Vips.Image.t()) :: String.t()
  def to_data_uri(image), do: "data:image/png;base64," <> Base.encode64(to_png_bytes(image))

  @doc "Mean color of `image` softened 60/40 toward white, as `[r, g, b]`."
  @spec softened_average(Vix.Vips.Image.t()) :: [non_neg_integer()]
  def softened_average(image) do
    image |> Image.average!() |> Enum.map(fn c -> round(c * 0.6 + 255 * 0.4) end)
  end

  @doc "Print-ready output path for a raw-art path (priv/print_ready/<basename>)."
  @spec print_ready_path(Path.t()) :: Path.t()
  def print_ready_path(raw_path) do
    dir = Path.join(:code.priv_dir(:circle_story), "print_ready")
    File.mkdir_p!(dir)
    Path.join(dir, Path.basename(raw_path))
  end

  @doc "Cached bounding-box JSON path for a raw-art path (<raw>.bbox.json)."
  @spec bbox_path(Path.t()) :: Path.t()
  def bbox_path(raw_path), do: Path.rootname(raw_path) <> ".bbox.json"

  @doc "Newest raw-art PNG in priv/generated_images whose basename starts with `prefix`."
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
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/composition/image_ops.ex test/circle_story/books/composition/image_ops_test.exs
git commit -m "feat: add ImageOps fill-crop, encoding, path helpers"
```

---

## Task 5: Fonts — base64 @font-face CSS

**Files:**
- Create: `lib/circle_story/books/composition/fonts.ex`
- Test: `test/circle_story/books/composition/fonts_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/circle_story/books/composition/fonts_test.exs`:

```elixir
defmodule CircleStory.Books.Composition.FontsTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Composition.Fonts

  test "font_face_css/0 embeds both families as base64 truetype" do
    css = Fonts.font_face_css()
    assert css =~ "font-family: 'Fredoka'"
    assert css =~ "font-family: 'Nunito'"
    assert css =~ "font-style: italic"
    assert css =~ "data:font/ttf;base64,"
    assert css =~ "format('truetype')"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/circle_story/books/composition/fonts_test.exs`
Expected: FAIL — `Fonts` undefined.

- [ ] **Step 3: Write the implementation**

Create `lib/circle_story/books/composition/fonts.ex`:

```elixir
defmodule CircleStory.Books.Composition.Fonts do
  @moduledoc """
  Reads the vendored TTFs in `priv/fonts` and emits base64 `@font-face` rules so
  the render document is fully self-contained (no fontconfig, no static-serving).
  The CSS is built once and cached in a module attribute at compile time.
  """

  @fonts [
    %{family: "Fredoka", file: "Fredoka.ttf", style: "normal"},
    %{family: "Nunito", file: "Nunito.ttf", style: "normal"},
    %{family: "Nunito", file: "Nunito-Italic.ttf", style: "italic"}
  ]

  @font_face_css (for %{family: family, file: file, style: style} <- @fonts do
                    path = Path.join([:code.priv_dir(:circle_story), "fonts", file])
                    base64 = path |> File.read!() |> Base.encode64()

                    """
                    @font-face {
                      font-family: '#{family}';
                      font-style: #{style};
                      font-weight: 100 900;
                      src: url(data:font/ttf;base64,#{base64}) format('truetype');
                    }
                    """
                  end)
                  |> Enum.join("\n")

  @doc "All `@font-face` rules (Fredoka, Nunito, Nunito italic) with embedded base64 TTFs."
  @spec font_face_css() :: String.t()
  def font_face_css, do: @font_face_css
end
```

> Note: the TTFs are read at **compile time** via `:code.priv_dir`. This works in
> dev/test and in releases (priv is bundled). If a font file is missing, the
> module fails to compile with a clear `File.read!` error — that is the desired
> fail-fast.

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/circle_story/books/composition/fonts_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/composition/fonts.ex test/circle_story/books/composition/fonts_test.exs
git commit -m "feat: add Fonts base64 @font-face CSS"
```

---

## Task 6: PlaceText — the bounding-box AI action

**Files:**
- Create: `lib/circle_story/books/actions/place_text.ex`
- Test: `test/circle_story/books/actions/place_text_test.exs`

The network call is integration-only; the pure parsing/fallback logic is unit-tested.

- [ ] **Step 1: Write the failing test**

Create `test/circle_story/books/actions/place_text_test.exs`:

```elixir
defmodule CircleStory.Books.Actions.PlaceTextTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Actions.PlaceText

  describe "parse_result/1" do
    test "reads a valid string-keyed map" do
      assert {:ok, %{bounding_box: [150, 680, 480, 950], text_align: :right}} =
               PlaceText.parse_result(%{"bounding_box" => [150, 680, 480, 950], "text_align" => "right"})
    end

    test "defaults an unknown alignment to :center" do
      assert {:ok, %{text_align: :center}} =
               PlaceText.parse_result(%{"bounding_box" => [0, 0, 100, 100], "text_align" => "weird"})
    end

    test "rejects malformed output" do
      assert {:error, _} = PlaceText.parse_result(%{"bounding_box" => [1, 2], "text_align" => "left"})
      assert {:error, _} = PlaceText.parse_result(%{"text_align" => "left"})
      assert {:error, _} = PlaceText.parse_result(:nonsense)
    end
  end

  describe "default_box/1" do
    test "inner vs cover differ" do
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
  bounding box (normalized 1000x1000, `[ymin, xmin, ymax, xmax]`) and a text
  alignment. Used for the cover (title+author) and inner spreads.
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
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/actions/place_text.ex test/circle_story/books/actions/place_text_test.exs
git commit -m "feat: add PlaceText bounding-box AI action"
```

---

## Task 7: PageComponents — HEEx page components

**Files:**
- Create: `lib/circle_story/books/page_components.ex`
- Test: `test/circle_story/books/page_components_test.exs`

Each component renders a fixed-size page `<div>`. Text blocks marked `.fit-text`
are auto-sized by the JS in `HtmlRenderer` (Task 8). Components are pure markup —
no browser needed to test them.

- [ ] **Step 1: Write the failing test**

Create `test/circle_story/books/page_components_test.exs`:

```elixir
defmodule CircleStory.Books.PageComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias CircleStory.Books.PageComponents

  test "inner_spread/1 renders a sized page with positioned, colored text" do
    html =
      render_component(&PageComponents.inner_spread/1, %{
        art_uri: "data:image/png;base64,AAAA",
        text: "Meet Ornella.",
        rect: %{x: 300, y: 1300, w: 1200, h: 400},
        align: :left,
        color: "#1A1A1A"
      })

    assert html =~ "width:3675px"
    assert html =~ "height:1875px"
    assert html =~ "Meet Ornella."
    assert html =~ "left:300px"
    assert html =~ "top:1300px"
    assert html =~ "color:#1A1A1A"
    assert html =~ "fit-text"
    assert html =~ "data:image/png;base64,AAAA"
  end

  test "dedication/1 renders cream page, text, and a pink circle" do
    html = render_component(&PageComponents.dedication/1, %{text: "For Ornella."})

    assert html =~ "width:3675px"
    assert html =~ "For Ornella."
    assert html =~ "border-radius:50%"
    assert html =~ "pink"
  end

  test "cover/1 renders all three panels, title/author, tagline, blurb, spine" do
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
        ink: "#1A1A1A"
      })

    assert html =~ "width:3863px"
    assert html =~ "Nani's Magic Thread"
    assert html =~ "Sidd &amp; Veronika"
    assert html =~ "A story of love."
    assert html =~ "Circle Storybooks"
    assert html =~ "www.circlestorybooks.com"
    assert html =~ "rotate(-90deg)"
    # front panel positioned at x=1988
    assert html =~ "left:1988px"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/circle_story/books/page_components_test.exs`
Expected: FAIL — `PageComponents` undefined.

- [ ] **Step 3: Write the implementation**

Create `lib/circle_story/books/page_components.ex`:

```elixir
defmodule CircleStory.Books.PageComponents do
  @moduledoc """
  HEEx function components for each print page (`cover/1`, `inner_spread/1`,
  `dedication/1`). Pure presentation: a fixed-size page `<div>` with absolutely
  positioned art and text. Text blocks marked `.fit-text` are auto-sized by the
  render document's fit-script. The future in-app editor reuses these components.

  Coordinates are in print pixels. Cover panel positions come from `Layout`; the
  front text `rect` is in panel-local coordinates and is positioned inside the
  front-panel div.
  """

  use Phoenix.Component

  alias CircleStory.Books.Composition.Layout

  @blurb_lines [
    "Circle Storybooks",
    "A one of a kind story.",
    "Make your own at:",
    "www.circlestorybooks.com"
  ]

  attr :art_uri, :string, required: true
  attr :text, :string, required: true
  attr :rect, :map, required: true
  attr :align, :atom, required: true
  attr :color, :string, required: true

  def inner_spread(assigns) do
    {w, h} = Layout.inner_dims()
    assigns = assign(assigns, w: w, h: h)

    ~H"""
    <div style={"position:relative;overflow:hidden;width:#{@w}px;height:#{@h}px;"}>
      <img src={@art_uri} style="position:absolute;inset:0;width:100%;height:100%;object-fit:cover;" />
      <.fit_text rect={@rect} align={@align} color={@color} font="Nunito" weight="700">
        {@text}
      </.fit_text>
    </div>
    """
  end

  attr :text, :string, required: true

  def dedication(assigns) do
    {w, h} = Layout.inner_dims()
    inset = Layout.safe_inset()
    half = Layout.inner_half()
    radius = round((min(w - half, h) - 2 * inset) / 2 * 0.85)

    assigns =
      assign(assigns,
        w: w,
        h: h,
        inset: inset,
        half: half,
        radius: radius,
        circle_cx: half + div(w - half, 2),
        circle_cy: div(h, 2)
      )

    ~H"""
    <div style={"position:relative;overflow:hidden;width:#{@w}px;height:#{@h}px;background:#FBF6EC;"}>
      <.fit_text
        rect={%{x: @inset, y: @inset, w: @half - 2 * @inset, h: @h - 2 * @inset}}
        align={:center}
        color="#3A2E26"
        font="Nunito"
        weight="700"
      >
        {@text}
      </.fit_text>
      <div style={"position:absolute;left:#{@circle_cx - @radius}px;top:#{@circle_cy - @radius}px;width:#{2 * @radius}px;height:#{2 * @radius}px;border-radius:50%;background:pink;"}>
      </div>
    </div>
    """
  end

  attr :art_uri, :string, required: true
  attr :rect, :map, required: true
  attr :align, :atom, required: true
  attr :front_color, :string, required: true
  attr :title, :string, required: true
  attr :author, :string, required: true
  attr :tagline, :string, required: true
  attr :fill, :string, required: true
  attr :ink, :string, required: true

  def cover(assigns) do
    {w, h} = Layout.cover_dims()
    inset = Layout.safe_inset()
    front = Layout.front_panel()
    spine = Layout.spine_panel()
    back = Layout.back_panel()
    circle_r = round(back.w * 0.19)

    assigns =
      assign(assigns,
        w: w,
        h: h,
        inset: inset,
        front: front,
        spine: spine,
        back: back,
        circle_r: circle_r,
        blurb_lines: @blurb_lines
      )

    ~H"""
    <div style={"position:relative;overflow:hidden;width:#{@w}px;height:#{@h}px;background:#{@fill};"}>
      <%!-- BACK PANEL --%>
      <.fit_text
        rect={%{x: @back.x + @inset, y: @inset, w: @back.w - 2 * @inset, h: 200}}
        align={:center}
        color={@ink}
        font="Nunito"
        weight="700"
        italic={true}
      >
        {@tagline}
      </.fit_text>

      <div style={"position:absolute;left:#{div(@back.w, 2) - @circle_r}px;top:#{div(@back.h, 2) - @circle_r}px;width:#{2 * @circle_r}px;height:#{2 * @circle_r}px;border-radius:50%;background:pink;"}>
      </div>

      <div style={"position:absolute;left:#{@inset}px;bottom:#{@inset}px;font-family:'Nunito';font-weight:700;font-size:44px;line-height:1.4;color:#{@ink};text-align:left;"}>
        <div :for={line <- @blurb_lines}>{line}</div>
      </div>

      <%!-- SPINE --%>
      <div style={"position:absolute;left:#{@spine.x}px;top:0;width:#{@spine.w}px;height:#{@spine.h}px;display:flex;align-items:center;justify-content:center;"}>
        <div style={"white-space:nowrap;transform:rotate(-90deg);font-family:'Fredoka';font-weight:700;font-size:48px;color:#{@ink};"}>
          {@title} · {@author}
        </div>
      </div>

      <%!-- FRONT PANEL --%>
      <div style={"position:absolute;left:#{@front.x}px;top:0;width:#{@front.w}px;height:#{@front.h}px;overflow:hidden;"}>
        <img src={@art_uri} style="position:absolute;inset:0;width:100%;height:100%;object-fit:cover;" />
        <.fit_text rect={@rect} align={@align} color={@front_color} font="Fredoka" weight="700">
          <div style="font-family:'Fredoka';font-weight:700;font-size:1em;">{@title}</div>
          <div style="font-family:'Nunito';font-weight:700;font-size:0.5em;margin-top:0.18em;">
            by {@author}
          </div>
        </.fit_text>
      </div>
    </div>
    """
  end

  # A fixed-size, absolutely positioned text box. The `.fit-inner` child is scaled
  # to fit by the render document's fit-script. `font`/`weight`/`italic` set the
  # default run style; cover title/author override per-line with em sizes.
  attr :rect, :map, required: true
  attr :align, :atom, required: true
  attr :color, :string, required: true
  attr :font, :string, required: true
  attr :weight, :string, required: true
  attr :italic, :boolean, default: false
  slot :inner_block, required: true

  def fit_text(assigns) do
    ~H"""
    <div
      class="fit-text"
      style={"position:absolute;left:#{@rect.x}px;top:#{@rect.y}px;width:#{@rect.w}px;height:#{@rect.h}px;display:flex;flex-direction:column;justify-content:center;overflow:hidden;"}
    >
      <div
        class="fit-inner"
        style={"width:100%;text-align:#{@align};color:#{@color};line-height:1.2;font-family:'#{@font}';font-weight:#{@weight};#{if @italic, do: "font-style:italic;"}"}
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/circle_story/books/page_components_test.exs`
Expected: PASS. (`render_component/2` from `Phoenix.LiveViewTest` renders a function component to an HTML string with no browser.)

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/page_components.ex test/circle_story/books/page_components_test.exs
git commit -m "feat: add PageComponents HEEx page components"
```

---

## Task 8: HtmlRenderer — document wrapper + ChromicPDF screenshot

**Files:**
- Create: `lib/circle_story/books/composition/html_renderer.ex`
- Test: `test/circle_story/books/composition/html_renderer_test.exs`

- [ ] **Step 1: Write the failing test (unit: document; integration: screenshot)**

Create `test/circle_story/books/composition/html_renderer_test.exs`:

```elixir
defmodule CircleStory.Books.Composition.HtmlRendererTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Composition.HtmlRenderer

  test "component_to_html/1 renders a function component to a string" do
    assigns = %{name: "World"}

    component = fn assigns ->
      import Phoenix.Component
      ~H"<p>Hello {@name}</p>"
    end

    assert HtmlRenderer.component_to_html(component.(assigns)) == "<p>Hello World</p>"
  end

  test "document/1 wraps page html with fonts, reset, fit-script and data-ready hook" do
    doc = HtmlRenderer.document("<div>PAGE</div>")

    assert doc =~ "<!DOCTYPE html>"
    assert doc =~ "@font-face"
    assert doc =~ "<div>PAGE</div>"
    assert doc =~ "fit-text"
    assert doc =~ "data-ready"
    assert doc =~ "document.fonts.ready"
    assert doc =~ "margin:0"
  end

  @tag :integration
  test "to_png/2 screenshots a page to an exact-size PNG" do
    start_supervised!({ChromicPDF, []})

    page = ~s(<div style="width:400px;height:200px;background:teal"></div>)
    out = Path.join(System.tmp_dir!(), "hr_#{System.unique_integer([:positive])}.png")

    assert {:ok, ^out} = HtmlRenderer.to_png(page, out)
    img = Image.open!(out)
    assert Image.width(img) == 400
    assert Image.height(img) == 200
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/circle_story/books/composition/html_renderer_test.exs`
Expected: FAIL — `HtmlRenderer` undefined. (The `:integration` screenshot test is excluded by default via `test_helper.exs`; the two unit tests drive implementation.)

- [ ] **Step 3: Write the implementation**

Create `lib/circle_story/books/composition/html_renderer.ex`:

```elixir
defmodule CircleStory.Books.Composition.HtmlRenderer do
  @moduledoc """
  Turns a rendered page component into a print-ready PNG: wraps the page HTML in a
  self-contained document (embedded `@font-face`, CSS reset, exact-size body, and
  a fit-script that scales `.fit-text` blocks once fonts are ready), then captures
  a pixel-exact screenshot with ChromicPDF.
  """

  alias CircleStory.Books.Composition.Fonts

  @fit_script """
  function fitOne(box){
    var inner = box.querySelector('.fit-inner');
    if(!inner){return;}
    var lo = 8, hi = 400;
    for(var i = 0; i < 22; i++){
      var mid = (lo + hi) / 2;
      inner.style.fontSize = mid + 'px';
      if(inner.scrollWidth <= box.clientWidth && inner.scrollHeight <= box.clientHeight){ lo = mid; } else { hi = mid; }
    }
    inner.style.fontSize = lo + 'px';
  }
  document.fonts.ready.then(function(){
    var boxes = document.querySelectorAll('.fit-text');
    for(var i = 0; i < boxes.length; i++){ fitOne(boxes[i]); }
    document.body.setAttribute('data-ready', 'true');
  });
  """

  @doc "Render a `Phoenix.LiveView.Rendered` (or safe HEEx result) to an HTML string."
  @spec component_to_html(Phoenix.LiveView.Rendered.t()) :: String.t()
  def component_to_html(rendered) do
    rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
  end

  @doc "Wrap page HTML in a self-contained render document."
  @spec document(String.t()) :: String.t()
  def document(page_html) do
    """
    <!DOCTYPE html>
    <html>
      <head>
        <meta charset="utf-8" />
        <style>
          #{Fonts.font_face_css()}
          * { margin: 0; padding: 0; box-sizing: border-box; }
          html, body { margin: 0; padding: 0; }
        </style>
      </head>
      <body>
        #{page_html}
        <script>#{@fit_script}</script>
      </body>
    </html>
    """
  end

  @doc """
  Screenshot `page_html` to `output_path` as a pixel-exact PNG. Waits for fonts +
  fit completion via the `data-ready` body attribute. Returns `{:ok, output_path}`.
  """
  @spec to_png(String.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def to_png(page_html, output_path) do
    case ChromicPDF.capture_screenshot({:html, document(page_html)},
           full_page: true,
           wait_for: %{selector: "body[data-ready]", attribute: "data-ready"},
           capture_screenshot: %{format: "png"},
           output: output_path
         ) do
      :ok -> {:ok, output_path}
      {:ok, _} -> {:ok, output_path}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

- [ ] **Step 4: Run the unit tests**

Run: `mix test test/circle_story/books/composition/html_renderer_test.exs --exclude integration`
Expected: PASS (the two unit tests). If `Phoenix.HTML.Safe.to_iodata/1` raises for the `Rendered` struct, confirm the component used `~H` (returns a `Phoenix.LiveView.Rendered` which implements `Phoenix.HTML.Safe`).

- [ ] **Step 5: Commit**

```bash
git add lib/circle_story/books/composition/html_renderer.ex test/circle_story/books/composition/html_renderer_test.exs
git commit -m "feat: add HtmlRenderer document wrapper and ChromicPDF screenshot"
```

---

## Task 9: Composition facade + Generator wiring

**Files:**
- Create: `lib/circle_story/books/composition.ex`
- Modify: `lib/circle_story/books/generator.ex`
- Test: `test/circle_story/books/composition_test.exs`

The facade exposes `*_html` builders (pure up to the HTML string — testable with a
cached bbox, no Chrome) and `compose_*` (builders + screenshot — `:integration`).

- [ ] **Step 1: Write the failing test**

Create `test/circle_story/books/composition_test.exs`:

```elixir
defmodule CircleStory.Books.CompositionTest do
  use ExUnit.Case, async: false

  alias CircleStory.Books.Composition
  alias CircleStory.Books.Composition.ImageOps
  alias CircleStory.Books.{Book, CoverSpread, InnerSpread, DedicationSpread}

  defp write_raw(name, w, h, color) do
    dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{name}_#{System.unique_integer([:positive])}.png")
    Image.write!(Image.new!(w, h, color: color), path)
    path
  end

  defp cache_bbox(raw, box, align) do
    File.write!(ImageOps.bbox_path(raw), Jason.encode!(%{"bounding_box" => box, "text_align" => align}))
  end

  test "spread_html/2 builds a 3675px page with the story text using a cached bbox" do
    raw = write_raw("inner_1", 1600, 900, :sage)
    cache_bbox(raw, [650, 100, 900, 900], "center")
    spread = %InnerSpread{position: 1, text: "Meet Ornella.", image_prompt: "x", generated_image_path: raw}

    assert {:ok, html, out} = Composition.spread_html(spread)
    assert html =~ "width:3675px"
    assert html =~ "Meet Ornella."
    assert out =~ "print_ready"
  end

  test "cover_html/2 builds a 3863px wrap with title and author using a cached bbox" do
    raw = write_raw("cover_front", 1875, 1875, :sky_blue)
    cache_bbox(raw, [80, 150, 320, 850], "center")

    book = %Book{
      title: "Nani's Magic Thread",
      author: "Sidd & Veronika",
      cover: %CoverSpread{tagline: "A story of love.", image_prompt: "x", generated_image_path: raw}
    }

    assert {:ok, html, _out} = Composition.cover_html(book)
    assert html =~ "width:3863px"
    assert html =~ "Nani's Magic Thread"
    assert html =~ "left:1988px"
  end

  test "dedication_html/1 builds a fixed page with no AI call" do
    assert {:ok, html, out} = Composition.dedication_html(%DedicationSpread{text: "For Ornella."})
    assert html =~ "For Ornella."
    assert html =~ "border-radius:50%"
    assert Path.basename(out) == "dedication.png"
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
  Orchestrates page composition. `*_html/_` build the page HTML (cheap; reuse a
  cached bounding box, no Chrome). `compose_*` build then screenshot to a
  print-ready PNG. Pass `force_bbox: true` (used by `Generator.generate_*`) to
  refresh the bounding box.
  """

  alias CircleStory.Books.Composition.{HtmlRenderer, ImageOps, Layout, Luminance}
  alias CircleStory.Books.Actions.PlaceText
  alias CircleStory.Books.{Book, CoverSpread, DedicationSpread, InnerSpread, PageComponents}

  # ----- compose_* (build + screenshot) -----

  @spec compose_spread(InnerSpread.t(), keyword()) :: {:ok, %{image_path: String.t()}} | {:error, term()}
  def compose_spread(%InnerSpread{} = spread, opts \\ []) do
    with {:ok, html, out} <- spread_html(spread, opts),
         {:ok, path} <- HtmlRenderer.to_png(html, out) do
      {:ok, %{image_path: path}}
    end
  end

  @spec compose_cover(Book.t(), keyword()) :: {:ok, %{image_path: String.t()}} | {:error, term()}
  def compose_cover(%Book{} = book, opts \\ []) do
    with {:ok, html, out} <- cover_html(book, opts),
         {:ok, path} <- HtmlRenderer.to_png(html, out) do
      {:ok, %{image_path: path}}
    end
  end

  @spec compose_dedication(DedicationSpread.t()) :: {:ok, %{image_path: String.t()}} | {:error, term()}
  def compose_dedication(%DedicationSpread{} = dedication) do
    with {:ok, html, out} <- dedication_html(dedication),
         {:ok, path} <- HtmlRenderer.to_png(html, out) do
      {:ok, %{image_path: path}}
    end
  end

  # ----- *_html (build only) -----

  @spec spread_html(InnerSpread.t(), keyword()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def spread_html(%InnerSpread{generated_image_path: raw, text: text}, opts \\ []) do
    {w, h} = Layout.inner_dims()
    fitted = ImageOps.fit(raw, w, h)

    with {:ok, box} <- placement(raw, fitted, text, :inner, opts) do
      rect = Layout.denormalize(box.bounding_box, Layout.inner_region())
      color = fitted |> Luminance.pick_for_region(rect) |> Luminance.hex()

      html =
        HtmlRenderer.component_to_html(
          PageComponents.inner_spread(%{
            art_uri: ImageOps.to_data_uri(fitted),
            text: text,
            rect: rect,
            align: box.text_align,
            color: color
          })
        )

      {:ok, html, ImageOps.print_ready_path(raw)}
    end
  end

  @spec cover_html(Book.t(), keyword()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def cover_html(%Book{cover: %CoverSpread{generated_image_path: raw} = cover} = book, opts \\ []) do
    front = ImageOps.fit(raw, 1875, 1875)
    text = "#{book.title}\n#{book.author}"

    with {:ok, box} <- placement(raw, front, text, :cover, opts) do
      rect = Layout.denormalize(box.bounding_box, Layout.front_region_local())
      front_color = front |> Luminance.pick_for_region(rect) |> Luminance.hex()
      fill_rgb = ImageOps.softened_average(front)
      ink = fill_rgb |> Luminance.color_for() |> Luminance.hex()

      html =
        HtmlRenderer.component_to_html(
          PageComponents.cover(%{
            art_uri: ImageOps.to_data_uri(front),
            rect: rect,
            align: box.text_align,
            front_color: front_color,
            title: book.title,
            author: book.author,
            tagline: cover.tagline,
            fill: rgb_css(fill_rgb),
            ink: ink
          })
        )

      {:ok, html, ImageOps.print_ready_path(raw)}
    end
  end

  @spec dedication_html(DedicationSpread.t()) :: {:ok, String.t(), String.t()}
  def dedication_html(%DedicationSpread{text: text}) do
    html = HtmlRenderer.component_to_html(PageComponents.dedication(%{text: text}))
    dir = Path.join(:code.priv_dir(:circle_story), "print_ready")
    File.mkdir_p!(dir)
    {:ok, html, Path.join(dir, "dedication.png")}
  end

  # ----- bbox cache -----

  # Load a cached bbox, or fetch (and cache) via PlaceText. `force_bbox: true` always refetches.
  defp placement(raw, fitted_image, text, mode, opts) do
    cache = ImageOps.bbox_path(raw)

    if not Keyword.get(opts, :force_bbox, false) and File.exists?(cache) do
      load_cached(cache)
    else
      png = ImageOps.to_png_bytes(fitted_image)

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

  defp rgb_css([r, g, b | _]), do: "rgb(#{r},#{g},#{b})"
end
```

- [ ] **Step 4: Run to verify the facade tests pass**

Run: `mix test test/circle_story/books/composition_test.exs`
Expected: PASS (no Chrome — these stop at the HTML string).

- [ ] **Step 5: Wire the Generator**

Replace `lib/circle_story/books/generator.ex` with:

```elixir
defmodule CircleStory.Books.Generator do
  @moduledoc """
  Generate and compose print-ready book pages.

  ## IEx workflow

      book = CircleStory.Books.Templates.NanisMagicThread.book()

      # Full path: generate art + bounding box + render component -> print-ready PNG
      {:ok, %{image_path: path}} = CircleStory.Books.Generator.generate_cover(book)
      {:ok, %{image_path: path}} = CircleStory.Books.Generator.generate_spread(book, 1)

      # Cheap re-render from cached raw art + cached bbox (no model calls)
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
      book |> put_cover_raw(raw) |> Composition.compose_cover(force_bbox: true)
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
      Composition.compose_spread(%{spread | generated_image_path: raw}, force_bbox: true)
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

- [ ] **Step 6: Run facade + prompt tests (no regression)**

Run: `mix test test/circle_story/books/composition_test.exs test/circle_story/books/prompt_builder_test.exs`
Expected: PASS. (`generate_*` hit the network + Chrome; exercised manually in Task 10.)

- [ ] **Step 7: Commit**

```bash
git add lib/circle_story/books/composition.ex lib/circle_story/books/generator.ex test/circle_story/books/composition_test.exs
git commit -m "feat: wire HTML composition facade into Generator"
```

---

## Task 10: Final verification

- [ ] **Step 1: Run the full precommit**

Run: `mix precommit`
Expected: compiles with no warnings, no unused deps, formatted, all non-integration tests pass.

- [ ] **Step 2: Run the integration tests (requires Chrome)**

Run: `mix test --only integration`
Expected: the `HtmlRenderer.to_png/2` test passes, producing an exact-size PNG. If ChromicPDF can't find Chrome, install Chromium or pass `chrome_executable:` in the `{ChromicPDF, []}` child opts.

- [ ] **Step 3: Manual end-to-end smoke test (requires Google API key + Chrome)**

In `iex -S mix`:

```elixir
book = CircleStory.Books.Templates.NanisMagicThread.book()
{:ok, %{image_path: cover}} = CircleStory.Books.Generator.generate_cover(book)
{:ok, %{image_path: spread}} = CircleStory.Books.Generator.generate_spread(book, 1)
{:ok, %{image_path: ded}} = CircleStory.Books.Generator.compose_dedication(book)
```

Open the three PNGs in `priv/print_ready/` and confirm: cover wrap is 3863×1875 with title/author on the front, vertical spine text, back tagline/circle/blurb; inner spread is 3675×1875 with legible story text inside the safe area; dedication has centered text + pink circle. Re-run `compose_cover(book)` and confirm it's fast (no image-model call) and reuses the cached `.bbox.json`.

- [ ] **Step 4: Commit any fixes**

```bash
git add -A
git commit -m "chore: final verification fixes for composition pipeline"
```

---

## Notes for the implementer

- **Chrome dependency:** ChromicPDF needs a Chrome/Chromium binary. Dev macOS auto-detects Google Chrome. CI/prod must install Chromium (or set `chrome_executable:`). The suite disables ChromicPDF at boot in `:test` (`config :circle_story, start_chromic_pdf: false`); integration tests start it via `start_supervised!({ChromicPDF, []})`.
- **Pixel-exactness:** `full_page: true` sizes the viewport to the body's content at `deviceScaleFactor: 1`. Each page component's outer `<div>` is exactly the print dimensions and the CSS reset removes margins, so the screenshot is exactly W×H.
- **Fonts:** embedded as base64 `@font-face` (no fontconfig). The fit-script waits for `document.fonts.ready` before measuring, so embedded fonts are loaded before autofit + capture.
- **`gemini-3.5-flash`:** not in the local `llm_db` registry but req_llm accepts unlisted ids. If it errors at runtime, change `@model` in `PlaceText` to `"google:gemini-2.5-flash"`.
- **Rendering components to strings:** `~H` returns a `Phoenix.LiveView.Rendered` struct that implements `Phoenix.HTML.Safe`; `HtmlRenderer.component_to_html/1` converts it. Component unit tests use `Phoenix.LiveViewTest.render_component/2`.
- **No Ecto:** all state is sidecar files (`priv/generated_images/*.bbox.json`, `priv/print_ready/*.png`).
- **Future editor:** `PageComponents` are the reuse seam — the in-app editor renders the same components live (text/placement/color edits → re-`compose_*`); interactive crop later moves the front/inner art crop into CSS (`object-position`/scale) instead of the server-side `ImageOps.fit`.
```
