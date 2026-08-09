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

  test "matches a name whose last character is non-ASCII" do
    # Without the /u modifier \b treats "ë" as a non-word character, so the
    # trailing boundary never fires and Zoë is silently dropped from her own
    # spread — no <ZOË> block and no reference image.
    accented = [%Character{name: "Zoë", image_prompt: "girl"}]
    spread = %InnerSpread{position: 6, text: "Zoë waved.", image_prompt: "a garden"}

    assert CharacterSelector.for_spread(spread, accented) |> Enum.map(& &1.name) == ["Zoë"]
  end

  test "a non-ASCII name does not match a longer word starting with it" do
    accented = [%Character{name: "Zoë", image_prompt: "girl"}]
    spread = %InnerSpread{position: 7, text: "The zoëtrope spun.", image_prompt: "a fair"}

    assert CharacterSelector.for_spread(spread, accented) == []
  end

  test "matches a name with an interior and a trailing accent" do
    accented = [
      %Character{name: "José", image_prompt: "father"},
      %Character{name: "Anaïs", image_prompt: "cousin"}
    ]

    spread = %InnerSpread{position: 8, text: "José and Anaïs sang.", image_prompt: "a kitchen"}

    assert CharacterSelector.for_spread(spread, accented) |> Enum.map(& &1.name) == [
             "José",
             "Anaïs"
           ]
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
