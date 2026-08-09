defmodule CircleStory.Books.CharacterSelector do
  @moduledoc """
  Decides which characters belong in a given spread. This is the single seam for
  character selection: callers use only `for_spread/2`. The current strategy is
  whole-word name matching against the spread's text and image prompt; it can be
  swapped for an LLM call later without touching any caller.
  """

  alias CircleStory.Books.Character

  @doc "The subset of `characters` that appear in `spread` (by name)."
  @spec for_spread(struct(), [Character.t()]) :: [Character.t()]
  def for_spread(spread, characters) do
    haystack =
      [Map.get(spread, :text), Map.get(spread, :image_prompt)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    Enum.filter(characters, fn %Character{name: name} -> mentioned?(haystack, name) end)
  end

  defp mentioned?(haystack, name) do
    # The /u modifier is required: without it \b treats accented letters as
    # non-word characters, so a name starting or ending in one (José, Zoë) never
    # matches its own mention and does match a longer word ("zoëtrope").
    Regex.match?(~r/\b#{Regex.escape(String.downcase(name))}\b/u, haystack)
  end
end
