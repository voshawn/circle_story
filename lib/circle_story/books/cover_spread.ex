defmodule CircleStory.Books.CoverSpread do
  @enforce_keys [:tagline, :image_prompt]
  defstruct [:tagline, :image_prompt, :generated_image_path]

  @type t :: %__MODULE__{
          tagline: String.t(),
          image_prompt: String.t(),
          generated_image_path: String.t() | nil
        }
end
