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
      cover: %CoverSpread{
        tagline: "A story of love.",
        image_prompt: "x",
        generated_image_path: raw
      }
    }

    assert {:ok, html, _out} = Composition.cover_html(book)
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
end
