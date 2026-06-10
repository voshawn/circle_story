defmodule CircleStory.Books.Composition.LuminanceTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Composition.Luminance

  test "luminance/1 is 0..255" do
    assert Luminance.luminance([0, 0, 0]) == 0.0
    assert_in_delta Luminance.luminance([255, 255, 255]), 255.0, 0.01
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
