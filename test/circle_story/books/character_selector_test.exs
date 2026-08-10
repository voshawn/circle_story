defmodule CircleStory.Books.CharacterSelectorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CircleStory.Books.{Character, CharacterSelector, CoverSpread, InnerSpread}
  alias CircleStory.Books.CharacterSelector.Gemini
  alias CircleStory.CharacterSelectorProviderFake

  setup do
    cache_dir =
      Path.join(
        [:code.priv_dir(:circle_story), "generated_images"],
        "character_selector_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(cache_dir) end)
    %{cache_dir: cache_dir}
  end

  defp chars do
    [
      %Character{name: "Ornella", image_prompt: "baby"},
      %Character{name: "Nani", image_prompt: "elder"},
      %Character{name: "Asha", image_prompt: "professor"}
    ]
  end

  defp select(spread, characters, names, cache_dir) do
    send(self(), {:character_selector_response, {:ok, names}})

    selected =
      CharacterSelector.for_spread(spread, characters,
        provider: CharacterSelectorProviderFake,
        cache_dir: cache_dir
      )

    assert_receive {:character_selector_called, ^spread, candidate_names}
    assert candidate_names == Enum.map(characters, & &1.name)
    selected
  end

  test "selects characters named in the spread text", %{cache_dir: cache_dir} do
    spread = %InnerSpread{position: 1, text: "Meet Ornella.", image_prompt: "a nursery"}
    assert select(spread, chars(), ["Ornella"], cache_dir) |> Enum.map(& &1.name) == ["Ornella"]
  end

  test "selects characters named in the image_prompt too", %{cache_dir: cache_dir} do
    spread = %InnerSpread{
      position: 2,
      text: "A quiet night.",
      image_prompt: "Nani watches over the house"
    }

    assert select(spread, chars(), ["Nani"], cache_dir) |> Enum.map(& &1.name) == ["Nani"]
  end

  test "preserves configured order when the provider returns names in another order", %{
    cache_dir: cache_dir
  } do
    spread = %InnerSpread{position: 3, text: "meet ORNELLA and nani", image_prompt: "x"}

    assert select(spread, chars(), ["Nani", "Ornella"], cache_dir) |> Enum.map(& &1.name) == [
             "Ornella",
             "Nani"
           ]
  end

  test "whole-name selection does not confuse Asha with Sasha", %{cache_dir: cache_dir} do
    spread = %InnerSpread{position: 4, text: "Sasha felt ashamed.", image_prompt: "x"}
    assert select(spread, chars(), [], cache_dir) == []

    prompt = Gemini.selection_prompt(spread, ["Asha"])
    assert prompt =~ "not as a substring"
    assert prompt =~ ~s(STORY_TEXT: "Sasha felt ashamed.")
  end

  test "preserves accented-name selection and prefix safety", %{cache_dir: cache_dir} do
    zoe = %Character{name: "Zoë", image_prompt: "girl"}
    selected_spread = %InnerSpread{position: 5, text: "Zoë waved.", image_prompt: "a garden"}
    prefix_spread = %InnerSpread{position: 6, text: "The zoëtrope spun.", image_prompt: "a fair"}

    assert select(selected_spread, [zoe], ["Zoë"], cache_dir) == [zoe]
    assert select(prefix_spread, [zoe], [], cache_dir) == []
  end

  test "selects a CJK name in space-free text", %{cache_dir: cache_dir} do
    li_ming = %Character{name: "李明", image_prompt: "a curious child"}
    spread = %InnerSpread{position: 7, text: "李明走进花园", image_prompt: "a sunny garden"}

    assert select(spread, [li_ming], ["李明"], cache_dir) == [li_ming]

    prompt = Gemini.selection_prompt(spread, ["李明"])
    assert prompt =~ ~s(CANDIDATE_NAMES: ["李明"])
    assert prompt =~ ~s(STORY_TEXT: "李明走进花园")
  end

  test "works with a CoverSpread", %{cache_dir: cache_dir} do
    cover = %CoverSpread{tagline: "t", image_prompt: "Nani sits with baby Ornella"}

    assert select(cover, chars(), ["Ornella", "Nani"], cache_dir) |> Enum.map(& &1.name) == [
             "Ornella",
             "Nani"
           ]
  end

  test "render retries and previews reuse the cached selection without another provider call", %{
    cache_dir: cache_dir
  } do
    spread = %InnerSpread{position: 8, text: "Meet Ornella.", image_prompt: "a nursery"}

    assert select(spread, chars(), ["Ornella"], cache_dir) |> Enum.map(& &1.name) == ["Ornella"]

    assert CharacterSelector.for_spread(spread, chars(),
             provider: CharacterSelectorProviderFake,
             cache_dir: cache_dir
           )
           |> Enum.map(& &1.name) == ["Ornella"]

    assert CharacterSelector.for_preview(spread, chars(), cache_dir: cache_dir)
           |> Enum.map(& &1.name) == ["Ornella"]

    refute_receive {:character_selector_called, _, _}
  end

  test "an uncached preview includes all characters without invoking a provider", %{
    cache_dir: cache_dir
  } do
    spread = %InnerSpread{position: 9, text: "Meet Ornella.", image_prompt: "a nursery"}

    assert CharacterSelector.for_preview(spread, chars(),
             provider: CharacterSelectorProviderFake,
             cache_dir: cache_dir
           ) == chars()

    refute_receive {:character_selector_called, _, _}
  end

  test "a selection failure warns, includes all characters, and caches that explicit fallback", %{
    cache_dir: cache_dir
  } do
    spread = %InnerSpread{position: 9, text: "李明走进花园", image_prompt: "a garden"}
    characters = [%Character{name: "李明", image_prompt: "child"} | chars()]
    send(self(), {:character_selector_response, {:error, :timeout}})

    log =
      capture_log(fn ->
        assert CharacterSelector.for_spread(spread, characters,
                 provider: CharacterSelectorProviderFake,
                 cache_dir: cache_dir
               ) == characters
      end)

    assert log =~ "character selection failed"
    assert log =~ "including all configured characters"

    cached_log =
      capture_log(fn ->
        assert CharacterSelector.for_preview(spread, characters, cache_dir: cache_dir) ==
                 characters
      end)

    assert cached_log =~ "using cached include-all fallback"
  end

  test "a render re-selects when the cache only holds a prior include-all fallback", %{
    cache_dir: cache_dir
  } do
    spread = %InnerSpread{position: 10, text: "Meet Ornella.", image_prompt: "a nursery"}
    send(self(), {:character_selector_response, {:error, :timeout}})

    capture_log(fn ->
      assert CharacterSelector.for_spread(spread, chars(),
               provider: CharacterSelectorProviderFake,
               cache_dir: cache_dir
             ) == chars()
    end)

    assert_receive {:character_selector_called, ^spread, _}

    capture_log(fn ->
      assert CharacterSelector.for_preview(spread, chars(), cache_dir: cache_dir) == chars()
    end)

    refute_receive {:character_selector_called, _, _}

    send(self(), {:character_selector_response, {:ok, ["Ornella"]}})

    capture_log(fn ->
      assert CharacterSelector.for_spread(spread, chars(),
               provider: CharacterSelectorProviderFake,
               cache_dir: cache_dir
             )
             |> Enum.map(& &1.name) == ["Ornella"]
    end)

    assert_receive {:character_selector_called, ^spread, _}

    assert CharacterSelector.for_spread(spread, chars(),
             provider: CharacterSelectorProviderFake,
             cache_dir: cache_dir
           )
           |> Enum.map(& &1.name) == ["Ornella"]

    refute_receive {:character_selector_called, _, _}
  end

  test "resolves an accented name returned in another unicode normalization form", %{
    cache_dir: cache_dir
  } do
    zoe = %Character{name: String.normalize("Zoë", :nfc), image_prompt: "girl"}
    decomposed = String.normalize(zoe.name, :nfd)
    characters = [zoe | chars()]
    spread = %InnerSpread{position: 11, text: "Zoë waved.", image_prompt: "a garden"}

    refute decomposed == zoe.name

    assert select(spread, characters, [decomposed], cache_dir) == [zoe]
    assert CharacterSelector.for_preview(spread, characters, cache_dir: cache_dir) == [zoe]
  end

  test "an off-contract provider return is an explicit include-all failure", %{
    cache_dir: cache_dir
  } do
    spread = %InnerSpread{position: 12, text: "A quiet garden.", image_prompt: "x"}
    send(self(), {:character_selector_response, :ok})

    log =
      capture_log(fn ->
        assert CharacterSelector.for_spread(spread, chars(),
                 provider: CharacterSelectorProviderFake,
                 cache_dir: cache_dir
               ) == chars()
      end)

    assert log =~ "invalid_provider_result"
    assert log =~ "including all configured characters"
  end

  test "the provider configured for the test environment never calls a live model", %{
    cache_dir: cache_dir
  } do
    spread = %InnerSpread{position: 13, text: "Meet Ornella.", image_prompt: "a nursery"}

    log =
      capture_log(fn ->
        assert CharacterSelector.for_spread(spread, chars(), cache_dir: cache_dir) == chars()
      end)

    assert log =~ "character_selector_provider_not_available"
    assert log =~ "including all configured characters"
  end

  test "unknown names in a provider response are an explicit include-all failure", %{
    cache_dir: cache_dir
  } do
    spread = %InnerSpread{position: 9, text: "A quiet garden.", image_prompt: "x"}
    send(self(), {:character_selector_response, {:ok, ["Not configured"]}})

    log =
      capture_log(fn ->
        assert CharacterSelector.for_spread(spread, chars(),
                 provider: CharacterSelectorProviderFake,
                 cache_dir: cache_dir
               ) == chars()
      end)

    assert log =~ "unknown_selected_names"
    assert log =~ "including all configured characters"
  end
end
