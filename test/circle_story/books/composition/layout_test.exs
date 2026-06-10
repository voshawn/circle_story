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

  test "denormalize floors a tiny box up to the requested minimum size" do
    # A stingy top-left box grown to >= 40% width / 30% height of a 1000-region.
    rect =
      Layout.denormalize([0, 0, 100, 100], %{x: 0, y: 0, w: 1000, h: 1000},
        min_w_frac: 0.4,
        min_h_frac: 0.3
      )

    assert rect.w >= 400
    assert rect.h >= 300
    # Still inside the safe inset.
    assert rect.x >= 112 and rect.y >= 112
    assert rect.x + rect.w <= 888 and rect.y + rect.h <= 888
  end

  test "denormalize leaves a box larger than the minimum unchanged" do
    rect =
      Layout.denormalize([200, 200, 800, 800], %{x: 0, y: 0, w: 1000, h: 1000},
        min_w_frac: 0.4,
        min_h_frac: 0.3
      )

    assert rect == %{x: 200, y: 200, w: 600, h: 600}
  end

  test "denormalize floor is capped by the available safe area" do
    # Requesting 100% width can't exceed the safe span (1000 - 2*112 = 776).
    rect = Layout.denormalize([0, 0, 50, 50], %{x: 0, y: 0, w: 1000, h: 1000}, min_w_frac: 1.0)
    assert rect.x == 112
    assert rect.x + rect.w == 888
  end
end
