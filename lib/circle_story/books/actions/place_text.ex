defmodule CircleStory.Books.Actions.PlaceText do
  @moduledoc """
  Asks Gemini where to place text on a print-size page image, returning a
  bounding box (normalized 1000x1000, `[ymin, xmin, ymax, xmax]`) and a text
  alignment. Used for the cover (title+author) and inner spreads.
  """

  use Jido.Action,
    name: "place_text",
    description: "Generate a text bounding box for a book page via Gemini",
    schema: [
      image_png: [type: :string, required: true, doc: "Print-size page image as PNG bytes"],
      text: [type: :string, required: true, doc: "Text to place"],
      mode: [type: {:in, [:inner, :cover]}, required: true]
    ]

  require Logger

  @model "google:gemini-3.5-flash"

  @object_schema [
    bounding_box: [type: {:list, :integer}, required: true],
    text_align: [type: :string, required: true]
  ]

  @impl true
  def run(%{image_png: png, text: text, mode: mode}, _context) do
    messages = [
      %{
        role: "user",
        content: [
          %{type: "text", text: prompt(mode, text)},
          %{type: "image_url", image_url: %{url: "data:image/png;base64,#{Base.encode64(png)}"}}
        ]
      }
    ]

    with {:ok, response} <- ReqLLM.generate_object(@model, messages, @object_schema),
         object when is_map(object) <- ReqLLM.Response.object(response),
         {:ok, result} <- parse_result(object) do
      {:ok, result}
    else
      other ->
        Logger.warning("PlaceText falling back to default box: #{inspect(other)}")
        {:ok, default_box(mode)}
    end
  end

  @doc "Validate and normalize a raw object map into `%{bounding_box: [..], text_align: atom}`."
  @spec parse_result(map() | term()) :: {:ok, map()} | {:error, term()}
  def parse_result(%{"bounding_box" => [a, b, c, d], "text_align" => align})
      when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    {:ok, %{bounding_box: [a, b, c, d], text_align: to_align(align)}}
  end

  def parse_result(other), do: {:error, {:invalid_place_text_result, other}}

  @doc "Fallback box when the model output is unusable."
  @spec default_box(:inner | :cover) :: map()
  def default_box(:inner), do: %{bounding_box: [650, 100, 900, 900], text_align: :center}
  def default_box(:cover), do: %{bounding_box: [80, 150, 320, 850], text_align: :center}

  defp to_align("left"), do: :left
  defp to_align("right"), do: :right
  defp to_align(_), do: :center

  defp prompt(mode, text) do
    fold_clause =
      case mode do
        :inner ->
          "Given that the book will be folded in the middle, try to avoid putting " <>
            "text that crosses the midpoint of the book.\n\n"

        :cover ->
          ""
      end

    """
    You will be given text (including new lines) and an image. Your job is to
    figure out the best place to put that text to compose a page for a
    children's book.

    #{fold_clause}Keep the text inside the central area of the image and away from \
    the outer ~6% near each edge, since the printer needs a bleed margin.

    Return only:
    1) a bounding box in the format [ymin, xmin, ymax, xmax] normalized to a 1000 x 1000 grid.
    2) a text-align recommendation (left, right, or center only).

    Return JSON only. No additional text. Example:
    {"bounding_box": [150, 680, 480, 950], "text_align": "right"}

    TEXT:
    #{text}
    """
  end
end
