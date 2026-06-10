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
      image_png: [type: :any, required: true, doc: "Print-size page image as raw PNG bytes"],
      text: [type: :string, required: true, doc: "Text to place"],
      mode: [type: {:in, [:inner, :cover]}, required: true]
    ]

  require Logger

  alias ReqLLM.Message.ContentPart

  # Gemini 3.1 Flash-Lite: cost-efficient, low-latency, supports image input +
  # structured JSON output — plenty for bounding-box placement, and less prone to
  # the 503 overload seen on gemini-3.5-flash. On any failure `run/2` returns
  # `default_box/1`, so a bad model id degrades to a fixed box rather than
  # crashing — watch the Logger warning to catch it.
  @model "google:gemini-3.1-flash-lite"

  @object_schema [
    bounding_box: [type: {:list, :integer}, required: true],
    text_align: [type: :string, required: true]
  ]

  @impl true
  def run(%{image_png: png, text: text, mode: mode}, _context) do
    # Build the message with ReqLLM ContentPart structs. Plain maps like
    # `%{type: "image_url", ...}` are silently dropped by `Context.normalize/2`,
    # which would send the model an empty message (and a garbage box).
    messages = [
      ReqLLM.Context.user([
        ContentPart.text(prompt(mode, text)),
        ContentPart.image(png, "image/png")
      ])
    ]

    with {:ok, response} <- ReqLLM.generate_object(@model, messages, @object_schema),
         object when is_map(object) <- ReqLLM.Response.object(response),
         {:ok, result} <- parse_result(object) do
      Logger.info(
        "PlaceText[#{mode}] model=#{@model} raw=#{inspect(object)} parsed=#{inspect(result)}"
      )

      {:ok, result}
    else
      other ->
        Logger.warning(
          "PlaceText[#{mode}] falling back to default box: #{summarize_error(other)}"
        )

        {:ok, default_box(mode)}
    end
  end

  # Concise error summary for logs — avoids dumping the full request body (which
  # includes the base64 image) on API errors like a 503.
  defp summarize_error({:error, %{reason: reason}}) when is_binary(reason), do: reason
  defp summarize_error({:error, err}), do: inspect(err, limit: 5, printable_limit: 200)
  defp summarize_error(other), do: inspect(other, limit: 5, printable_limit: 200)

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
    {role_clause, size_clause, fold_clause} = mode_clauses(mode)

    """
    You will be given text (including new lines) and an image. Choose where to
    place that text to compose a page for a children's book.

    #{role_clause}

    IMPORTANT: the text is scaled to FILL the bounding box you return, so the size
    of the box directly controls how large the text appears. #{size_clause}

    #{fold_clause}Keep the box inside the central area, away from the outer ~6% \
    near each edge (the printer needs a bleed margin), and prefer a calm, \
    uncluttered part of the art.

    Return only:
    1) a bounding box in the format [ymin, xmin, ymax, xmax] normalized to a 1000 x 1000 grid.
    2) a text-align recommendation (left, right, or center only).

    Return JSON only. No additional text. Example of a generous box:
    {"bounding_box": [80, 120, 360, 880], "text_align": "center"}

    TEXT:
    #{text}
    """
  end

  # {role_clause, size_clause, fold_clause}
  defp mode_clauses(:cover) do
    {
      "This text is the book TITLE and author line — it is the hero of the cover and must be large and prominent.",
      "Choose a GENEROUS box: roughly 55-80% of the image width and tall enough for a bold, eye-catching title (about 20-35% of the height). Do not return a small box or tuck it into a corner.",
      ""
    }
  end

  defp mode_clauses(:inner) do
    {
      "This is the story text for the page.",
      "Choose a box large enough for comfortable, easily readable text — typically spanning a wide portion of an open area of the art.",
      "Because the two-page spread folds down the vertical center, avoid placing text that crosses the vertical midline of the image.\n\n"
    }
  end
end
