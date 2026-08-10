defmodule CircleStory.Books.CharacterSelector.Provider do
  @moduledoc """
  Provider contract for choosing the configured characters referenced by a spread.

  Implementations return character names exactly as supplied. Keeping the model
  behind this boundary lets selection be tested without external calls.
  """

  @callback select(spread :: struct(), candidate_names :: [String.t()]) ::
              {:ok, [String.t()]} | {:error, term()}
end
