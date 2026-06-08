defmodule CircleStory.Books.DedicationSpread do
  @enforce_keys [:text]
  defstruct [:text, :user_image_path]

  @type t :: %__MODULE__{
          text: String.t(),
          user_image_path: String.t() | nil
        }
end
