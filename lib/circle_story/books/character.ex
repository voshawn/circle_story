defmodule CircleStory.Books.Character do
  @enforce_keys [:name, :image_prompt]
  defstruct [:name, :image_prompt, :reference_image_path]

  @type t :: %__MODULE__{
          name: String.t(),
          image_prompt: String.t(),
          reference_image_path: String.t() | nil
        }
end
