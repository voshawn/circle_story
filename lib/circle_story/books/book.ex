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
end
