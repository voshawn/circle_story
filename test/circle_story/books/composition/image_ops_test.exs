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

  test "latest_raw/1 ignores a longer sibling that shares the prefix" do
    # A bare "<prefix>*.png" glob also matches a longer name built on the same
    # prefix, and because a letter sorts above every digit the sibling sorts
    # last and wins -- returning the wrong file even though it is older. The
    # ^prefix\d+\.png$ anchor is what excludes it; drop the anchor and this
    # test fails by returning anchortest_more_456.png.
    dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
    File.mkdir_p!(dir)
    mine = Path.join(dir, "anchortest_123.png")
    sibling = Path.join(dir, "anchortest_more_456.png")
    Image.write!(Image.new!(4, 4, color: :white), mine)
    Image.write!(Image.new!(4, 4, color: :white), sibling)

    assert ImageOps.latest_raw("anchortest_") == {:ok, mine}
    assert ImageOps.latest_raw("anchortest_more_") == {:ok, sibling}
  after
    dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
    Enum.each(Path.wildcard(Path.join(dir, "anchortest_*.png")), &File.rm/1)
  end
end
