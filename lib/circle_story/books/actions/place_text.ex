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

  # Gemini 3.7 Flash: supports image input and structured JSON output. On any
  # failure `run/2` returns `default_box/1`, so a bad model id degrades to a
  # fixed box rather than crashing — watch the Logger warning to catch it.
  #
  # This id is absent from the bundled llm_db catalog snapshot, so ReqLLM logs
  # "Using unverified model: google:gemini-3.7-flash" and passes it through
  # unchanged. That line is expected, not a failure signal.
  @model "google:gemini-3.7-flash"

  @object_schema [
    bounding_box: [type: {:list, :integer}, required: true],
    text_align: [type: :string, required: true],
    vertical_align: [type: :string, required: true]
  ]

  # Thinking level for the placement reasoning (:minimal | :low | :medium | :high).
  #
  # ReqLLM >= 1.16.0 disables thought summaries for Google `:object` requests
  # while retaining internal reasoning (https://github.com/agentjido/req_llm/pull/762).
  # Earlier releases sent `includeThoughts: true` alongside JSON mode, allowing
  # thought-summary prose to make otherwise valid structured output undecodable.
  @thinking_level :medium

  @doc "The configured text-placement model identity."
  @spec model() :: String.t()
  def model, do: @model

  @impl true
  def run(params, context), do: run(params, context, [])

  @doc """
  Run text placement with additional ReqLLM request options.

  `:google_thinking_level` and `:json_repair` are owned by this module and
  always override `request_opts`; a caller cannot change them. Strict decoding
  (`json_repair: false`) is what keeps thought-summary prose from being repaired
  into a plausible-looking box, so the invariant holds for every caller.
  """
  def run(%{image_png: png, text: text, mode: mode}, _context, request_opts)
      when is_list(request_opts) do
    # Build the message with ReqLLM ContentPart structs. Plain maps like
    # `%{type: "image_url", ...}` are silently dropped by `Context.normalize/2`,
    # which would send the model an empty message (and a garbage box).
    messages = [
      ReqLLM.Context.user([
        ContentPart.text(prompt(mode, text)),
        ContentPart.image(png, "image/png")
      ])
    ]

    request_opts =
      request_opts
      |> Keyword.put(:google_thinking_level, @thinking_level)
      |> Keyword.put(:json_repair, false)

    with {:ok, response} <-
           ReqLLM.generate_object(@model, messages, @object_schema, request_opts),
         {:ok, result} <- parse_response(response) do
      Logger.info(
        "PlaceText[#{mode}] model=#{@model} thinking=#{@thinking_level} parsed=#{inspect(result)}"
      )

      {:ok, Map.put(result, :source, :model)}
    else
      other ->
        Logger.warning(
          "PlaceText[#{mode}] falling back to default box: #{summarize_error(other)}"
        )

        {:ok, Map.put(default_box(mode), :source, :fallback)}
    end
  end

  @doc false
  @spec parse_response(ReqLLM.Response.t()) :: {:ok, map()} | {:error, term()}
  def parse_response(response) do
    with {:ok, object} <- ReqLLM.Response.unwrap_object(response, json_repair: false),
         {:ok, result} <- parse_result(object) do
      {:ok, result}
    end
  end

  # Deliberately classify errors instead of inspecting them: ReqLLM errors can
  # contain request/response bodies, including the image and model output. The
  # exception module name is the only part of an unrecognized error that is
  # emitted — a struct name carries no payload, prompt, image, or credential.
  defp summarize_error({:error, %ReqLLM.Error.API.Request{status: status}})
       when is_integer(status),
       do: "model request failed (HTTP #{status})"

  defp summarize_error({:error, %ReqLLM.Error.API.Request{}}), do: "model request failed"

  defp summarize_error({:error, %ReqLLM.Error.API.Response{reason: reason}}) do
    case reason do
      "No message in response" -> "structured output response had no message"
      "Decoded JSON is not an object" -> "structured output was not a JSON object"
      "Failed to parse JSON from text content" -> "structured output JSON could not be parsed"
      "No structured output found in response" -> "structured output was absent"
      _ -> "structured output response was unusable"
    end
  end

  defp summarize_error({:error, {:invalid_place_text_result, _}}),
    do: "structured object failed placement validation"

  defp summarize_error({:error, %mod{} = error}),
    do: "model request failed: #{error_class_label(error)} (#{inspect(mod)})"

  defp summarize_error({:error, _}), do: "model request failed: unclassified error"
  defp summarize_error(_), do: "structured output was absent"

  # Every ReqLLM error is a Splode struct tagged with its error class.
  defp error_class_label(%{class: :invalid}), do: "invalid request configuration"
  defp error_class_label(%{class: :validation}), do: "invalid request configuration"
  defp error_class_label(%{class: :api}), do: "provider API error"
  defp error_class_label(%{class: :unknown}), do: "unknown error"
  defp error_class_label(_), do: "transport or unexpected error"

  @doc """
  Validate and normalize a raw object map into
  `%{bounding_box: [..], text_align: atom, vertical_align: atom}`. `text_align`
  and `vertical_align` default to `:center`/`:middle` when missing/unknown so
  older cached results without a vertical anchor still load.
  """
  @spec parse_result(map() | term()) :: {:ok, map()} | {:error, term()}
  def parse_result(%{"bounding_box" => [a, b, c, d]} = obj)
      when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    {:ok,
     %{
       bounding_box: [a, b, c, d],
       text_align: to_align(Map.get(obj, "text_align")),
       vertical_align: to_valign(Map.get(obj, "vertical_align"))
     }}
  end

  def parse_result(other), do: {:error, {:invalid_place_text_result, other}}

  @doc "Fallback box when the model output is unusable."
  @spec default_box(:inner | :cover) :: map()
  def default_box(:inner),
    do: %{bounding_box: [650, 100, 900, 900], text_align: :center, vertical_align: :middle}

  def default_box(:cover),
    do: %{bounding_box: [80, 150, 320, 850], text_align: :center, vertical_align: :middle}

  defp to_align("left"), do: :left
  defp to_align("right"), do: :right
  defp to_align(_), do: :center

  defp to_valign("top"), do: :top
  defp to_valign("bottom"), do: :bottom
  defp to_valign(_), do: :middle

  defp prompt(mode, text) do
    {role_clause, size_clause, fold_clause} = mode_clauses(mode)

    """
    You will be given text (including new lines) and an image. Choose where to
    place that text to compose a page for a children's book.

    #{role_clause}

     #{size_clause}

    #{fold_clause}

    Keep the box inside the central area, away from the outer ~5% \
    near each edge (the printer needs a bleed margin), and prefer a calm, \
    uncluttered part of the art.

    Return only:
    1) a bounding box in the format [ymin, xmin, ymax, xmax] normalized to a 1000 x 1000 grid.
    2) a text-align recommendation (left, right, or center only).
    3) a vertical-align recommendation (top, middle, or bottom).

    For images that are more cluttered or busy, anchor the text within the box \
    toward the calmest, emptiest part — away from faces, heads, and the main subject.

    For images that have more empty space, anchor the text in a space that will balance out \
    the overall composition of the image. 


    Return JSON only. No additional text. Example of a generous box:
    {"bounding_box": [80, 120, 360, 880], "text_align": "center", "vertical_align": "top"}

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
      "Place the text in ONE corner region of the page — upper-left, lower-left, upper-right, or lower-right — choosing the calmest, least-busy area of the art (open sky, a soft background wash, empty negative space). Keep the box within that single quadrant: do NOT span the full width and do NOT place it in the center. Make it comfortably sized for readable text.",
      "The two-page spread folds down the vertical center, so the box must stay entirely on one side of the midline — left half (xmax at most 480) OR right half (xmin at least 520) — never crossing it.\n\n"
    }
  end
end
