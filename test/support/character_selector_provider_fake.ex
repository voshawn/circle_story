defmodule CircleStory.CharacterSelectorProviderFake do
  @moduledoc false

  @behaviour CircleStory.Books.CharacterSelector.Provider

  @impl true
  def selection_version, do: Process.get(:character_selector_fake_version, :v1)

  @impl true
  def select(spread, candidate_names) do
    send(self(), {:character_selector_called, spread, candidate_names})

    receive do
      {:character_selector_response, response} -> response
    after
      0 -> {:error, :unexpected_character_selector_call}
    end
  end
end
