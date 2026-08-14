defmodule CircleStory.Books.CompositionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CircleStory.Books.Composition
  alias CircleStory.Books.Composition.ImageOps
  alias CircleStory.CompositionQualityOptimizerFake
  alias CircleStory.Books.{Book, Character, CoverSpread, InnerSpread, DedicationSpread}

  defp write_raw(name, w, h, color) do
    dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{name}_#{System.unique_integer([:positive])}.png")
    Image.write!(Image.new!(w, h, color: color), path)

    on_exit(fn ->
      File.rm(path)
      File.rm(ImageOps.bbox_path(path))
    end)

    path
  end

  defp cache_bbox(raw, box, align) do
    File.write!(
      ImageOps.bbox_path(raw),
      Jason.encode!(%{"bounding_box" => box, "text_align" => align})
    )
  end

  test "spread_html/2 builds a 3675px page with the story text using a cached bbox" do
    raw = write_raw("inner_1", 1600, 900, :green)
    cache_bbox(raw, [650, 100, 900, 900], "center")

    spread = %InnerSpread{
      position: 1,
      text: "Meet Ornella.",
      image_prompt: "x",
      generated_image_path: raw
    }

    assert {:ok, html, out} = Composition.spread_html(spread, quality_opts())
    assert html =~ "width:3675px"
    assert html =~ "Meet Ornella."
    assert out =~ "print_ready"
  end

  test "spread_html/2 uses the deterministic winner without publishing build-only provenance" do
    raw = write_raw("inner_2", 1600, 900, :white)
    cache_bbox(raw, [100, 600, 400, 950], "left")

    spread = %InnerSpread{
      position: 2,
      text: "A deterministic winner.",
      image_prompt: "x",
      generated_image_path: raw
    }

    optimizer = fn image, content, placement, seed_rect, opts ->
      send(
        self(),
        {:quality_optimized, Image.width(image), content, placement.source, opts[:role]}
      )

      {:ok, result} =
        CompositionQualityOptimizerFake.optimize(image, content, placement, seed_rect, opts)

      rect = %{result.candidate.rect | x: result.candidate.rect.x + 17}
      candidate = %{result.candidate | rect: rect, align: :center, origin: :translate_right}
      {:ok, %{result | candidate: candidate}}
    end

    assert {:ok, html, _out} =
             Composition.spread_html(spread, quality_optimizer: optimizer)

    assert_receive {:quality_optimized, 3675, %{text: "A deterministic winner."}, :unknown,
                    :inner}

    assert html =~ "left:2222px"
    assert html =~ "text-align:center"
    assert html =~ "left:48px;right:48px"

    assert {:ok, cached} = Composition.cached_placement(raw)
    assert cached.composition_quality == nil
  end

  test "the printed page uses the selected candidate's font floor, not the component default" do
    raw = write_raw("inner_min_font", 1600, 900, :white)
    cache_bbox(raw, [100, 600, 400, 950], "left")

    spread = %InnerSpread{
      position: 4,
      text: "A lower configured floor.",
      image_prompt: "x",
      generated_image_path: raw
    }

    assert {:ok, html, _out} =
             Composition.spread_html(spread, quality_optimizer: min_font_optimizer(18))

    # The fit script gates on data-min-font, so a page that ships the component
    # default while the gates scored 18px would overflow its box unreported.
    assert html =~ ~s(data-min-font="18")
    refute html =~ ~s(data-min-font="24")
  end

  test "the printed cover uses the selected candidate's font floor on the front panel" do
    raw = write_raw("cover_min_font", 1875, 1875, :sky_blue)
    cache_bbox(raw, [80, 150, 320, 850], "center")

    book = %Book{
      title: "T",
      author: "A",
      cover: %CoverSpread{tagline: "t", image_prompt: "x", generated_image_path: raw}
    }

    assert {:ok, html, _out} =
             Composition.cover_html(book, quality_optimizer: min_font_optimizer(18))

    assert html =~ ~s(data-min-font="18")
  end

  defp min_font_optimizer(min_font) do
    fn image, content, placement, seed_rect, opts ->
      {:ok, result} =
        CompositionQualityOptimizerFake.optimize(image, content, placement, seed_rect, opts)

      {:ok, %{result | candidate: %{result.candidate | min_font: min_font}}}
    end
  end

  test "spread_html/2 exposes structured deterministic overflow instead of clipping" do
    raw = write_raw("inner_3", 1600, 900, :white)
    cache_bbox(raw, [100, 600, 400, 950], "left")

    spread = %InnerSpread{
      position: 3,
      text: String.duplicate("unbreakable", 30),
      image_prompt: "x",
      generated_image_path: raw
    }

    optimizer = fn _image, _content, _placement, _seed_rect, _opts ->
      {:error,
       {:composition_overflow, %{minimum_font: 24, reason: :no_candidate_fits_without_clipping}}}
    end

    assert {:error,
            {:composition_overflow,
             %{minimum_font: 24, reason: :no_candidate_fits_without_clipping}}} =
             Composition.spread_html(spread, quality_optimizer: optimizer)
  end

  test "cover_html/2 builds a 3863px wrap with title and author using a cached bbox" do
    raw = write_raw("cover_front", 1875, 1875, :sky_blue)
    cache_bbox(raw, [80, 150, 320, 850], "center")

    book = %Book{
      title: "Nani's Magic Thread",
      author: "Sidd & Veronika",
      cover: %CoverSpread{
        tagline: "A story of love.",
        image_prompt: "x",
        generated_image_path: raw
      }
    }

    assert {:ok, html, _out} = Composition.cover_html(book, quality_opts())
    assert html =~ "width:3863px"
    # HEEx escapes the apostrophe in `{@title}`.
    assert html =~ "Nani&#39;s Magic Thread"
    assert html =~ "left:1988px"
  end

  test "dedication_html/1 builds a fixed page with no AI call" do
    assert {:ok, html, out} = Composition.dedication_html(%DedicationSpread{text: "For Ornella."})
    assert html =~ "For Ornella."
    assert html =~ "border-radius:50%"
    assert Path.basename(out) == "dedication.png"
  end

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

    assert {:ok, html, _out} = Composition.cover_html(book, quality_opts())
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

    assert {:ok, html, _out} = Composition.cover_html(book, quality_opts())
    assert html =~ "background:pink"
  end

  test "dedication_html/1 falls back to the placeholder when the photo isn't a valid image" do
    dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
    File.mkdir_p!(dir)
    bad = Path.join(dir, "not_an_image_#{System.unique_integer([:positive])}.png")
    File.write!(bad, "this is not a PNG")
    on_exit(fn -> File.rm(bad) end)

    dedication = %DedicationSpread{text: "For Ornella.", user_image_path: bad}

    log =
      capture_log(fn ->
        assert {:ok, html, _out} = Composition.dedication_html(dedication)
        assert html =~ "background:pink"
        refute html =~ "object-fit:cover"
      end)

    # Degrading to the placeholder is correct, but silently printing a pink
    # circle onto a paid artifact is not — the drop has to be audible.
    assert log =~ bad
    assert log =~ "unreadable"
  end

  test "dedication_html/1 logs the dropped photo when the file is missing" do
    missing =
      Path.join(
        :code.priv_dir(:circle_story),
        "generated_images/gone_#{System.unique_integer([:positive])}.png"
      )

    dedication = %DedicationSpread{text: "For Ornella.", user_image_path: missing}

    log =
      capture_log(fn ->
        assert {:ok, html, _out} = Composition.dedication_html(dedication)
        assert html =~ "background:pink"
      end)

    assert log =~ missing
    assert log =~ "missing"
  end

  test "cover_html/2 logs the dropped photo when a character's reference is missing" do
    raw = write_raw("cover_front", 1875, 1875, :sky_blue)
    cache_bbox(raw, [80, 150, 320, 850], "center")

    missing =
      Path.join(
        :code.priv_dir(:circle_story),
        "generated_images/gone_#{System.unique_integer([:positive])}.png"
      )

    book = %Book{
      title: "T",
      author: "A",
      characters: [%Character{name: "Ornella", image_prompt: "x", reference_image_path: missing}],
      cover: %CoverSpread{tagline: "t", image_prompt: "x", generated_image_path: raw}
    }

    log =
      capture_log(fn ->
        assert {:ok, _html, _out} = Composition.cover_html(book, quality_opts())
      end)

    assert log =~ missing
  end

  defp quality_opts do
    [quality_optimizer: &CompositionQualityOptimizerFake.optimize/5]
  end

  test "dedication_html/1 embeds the user's photo when user_image_path is set" do
    photo = write_raw("dedication_photo", 512, 512, :pink)
    dedication = %DedicationSpread{text: "For Ornella.", user_image_path: photo}

    assert {:ok, html, _out} = Composition.dedication_html(dedication)
    assert html =~ "object-fit:cover"
    assert html =~ "data:image/png;base64,"
  end
end
