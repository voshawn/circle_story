defmodule CircleStory.Books.Composition.LuminanceTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Composition.Luminance

  test "luminance/1 is 0..255" do
    assert Luminance.luminance([0, 0, 0]) == 0.0
    assert_in_delta Luminance.luminance([255, 255, 255]), 255.0, 0.01
  end

  test "relative luminance and contrast use the sRGB reference formula" do
    assert Luminance.relative([0, 0, 0]) == 0.0
    assert_in_delta Luminance.relative([255, 255, 255]), 1.0, 0.0001
    assert_in_delta Luminance.contrast_ratio(0.0, 1.0), 21.0, 0.001
  end

  test "color_for/1 picks black on light, white on dark" do
    assert Luminance.color_for([240, 240, 240]) == :black
    assert Luminance.color_for([10, 10, 10]) == :white
  end

  test "hex/1 maps atoms to ink" do
    assert Luminance.hex(:black) == "#1A1A1A"
    assert Luminance.hex(:white) == "#FAFAFA"
  end
end
