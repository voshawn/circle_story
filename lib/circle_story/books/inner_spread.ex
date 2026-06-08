defmodule CircleStory.Books.InnerSpread do
  @enforce_keys [:position, :text, :image_prompt]
  defstruct [:position, :text, :image_prompt, :generated_image_path]

  @type t :: %__MODULE__{
          position: 1..9,
          text: String.t(),
          image_prompt: String.t(),
          generated_image_path: String.t() | nil
        }
end
