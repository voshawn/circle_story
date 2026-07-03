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
    spread = %InnerSpread{
      position: 2,
      text: "A quiet night.",
      image_prompt: "Nani watches over the house"
    }

    assert CharacterSelector.for_spread(spread, chars()) |> Enum.map(& &1.name) == ["Nani"]
  end

  test "matching is case-insensitive" do
    spread = %InnerSpread{position: 3, text: "meet ORNELLA and nani", image_prompt: "x"}

    assert CharacterSelector.for_spread(spread, chars()) |> Enum.map(& &1.name) == [
             "Ornella",
             "Nani"
           ]
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

    assert CharacterSelector.for_spread(cover, chars()) |> Enum.map(& &1.name) == [
             "Ornella",
             "Nani"
           ]
  end
end
