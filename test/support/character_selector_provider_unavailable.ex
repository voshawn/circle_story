defmodule CircleStory.CharacterSelectorProviderUnavailable do
  @moduledoc false

  @behaviour CircleStory.Books.CharacterSelector.Provider

  @impl true
  def selection_version, do: :unavailable

  @impl true
  def select(_spread, _candidate_names), do: {:error, :character_selector_provider_not_available}
end
