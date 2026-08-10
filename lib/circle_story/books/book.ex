defmodule CircleStory.Books.Book do
  alias CircleStory.Books.{Character, CoverSpread, DedicationSpread, InnerSpread}

  @enforce_keys [:title, :author]
  defstruct [:title, :author, :cover, :dedication, spreads: [], characters: []]

  @type t :: %__MODULE__{
          title: String.t(),
          author: String.t(),
          cover: CoverSpread.t() | nil,
          dedication: DedicationSpread.t() | nil,
          spreads: [InnerSpread.t()],
          characters: [Character.t()]
        }

  @doc "The character shown in the back-cover circle (currently the first)."
  @spec back_cover_character(t()) :: Character.t() | nil
  def back_cover_character(%__MODULE__{characters: characters}), do: List.first(characters)
end
