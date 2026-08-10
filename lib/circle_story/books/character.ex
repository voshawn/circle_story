defmodule CircleStory.Books.Character do
  @enforce_keys [:name, :image_prompt]
  defstruct [:name, :image_prompt, :source_image_path, :reference_image_path]

  @type t :: %__MODULE__{
          name: String.t(),
          image_prompt: String.t(),
          source_image_path: String.t() | nil,
          reference_image_path: String.t() | nil
        }
end
