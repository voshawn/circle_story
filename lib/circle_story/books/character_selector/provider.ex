defmodule CircleStory.Books.CharacterSelector.Provider do
  @moduledoc """
  Provider contract for choosing the configured characters referenced by a spread.

  Implementations return character names exactly as supplied. Keeping the model
  behind this boundary lets selection be tested without external calls.
  """

  @callback select(spread :: struct(), candidate_names :: [String.t()]) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc """
  A term identifying everything that determines this provider's selections,
  such as the model and its instructions.

  `CharacterSelector` records it with each cached selection and re-selects on a
  render when it no longer matches, so changing the model or the instructions
  refreshes stale entries without a manual cache bump.
  """
  @callback selection_version() :: term()
end
