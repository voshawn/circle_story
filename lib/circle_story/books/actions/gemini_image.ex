defmodule CircleStory.Books.Actions.GeminiImage do
  @moduledoc """
  Shared helpers for the Gemini image-generation actions
  (`GenerateSpreadImage`, `GenerateCharacterReference`): user-message assembly,
  the model call, response image extraction, and MIME detection.
  """

  alias ReqLLM.Message.ContentPart

  @model "google:gemini-3.1-flash-image"

  @doc "Prepend the system prompt and call the Gemini image model."
  @spec generate(String.t(), [map()], String.t()) ::
          {:ok, ReqLLM.Response.t()} | {:error, term()}
  def generate(system_prompt, messages, aspect_ratio) do
    # System prompt passed as role: "system" — split_messages_for_gemini
    # converts it to systemInstruction for the Gemini API.
    all_messages = [%{role: "system", content: system_prompt} | messages]

    ReqLLM.generate_image(@model, all_messages,
      aspect_ratio: aspect_ratio,
      google_thinking_level: :high
    )
  end

  @doc "Build the `user` message list: plain text, or text plus image parts."
  @spec build_messages(String.t(), [{binary(), String.t()}]) :: [map()]
  def build_messages(text, []), do: [%{role: "user", content: text}]

  def build_messages(text, image_parts) do
    # Use ReqLLM.Message.ContentPart structs, not hand-rolled maps: a map with an
    # atom key but a string value (e.g. %{type: "image_url", ...}) is silently
    # dropped by ReqLLM.Context.normalize, so the image never reaches the model.
    parts = Enum.map(image_parts, fn {binary, mime} -> ContentPart.image(binary, mime) end)
    [%{role: "user", content: [ContentPart.text(text) | parts]}]
  end

  @doc "Extract the generated image binary from a ReqLLM response."
  @spec extract_image(ReqLLM.Response.t()) :: {:ok, binary()} | {:error, term()}
  def extract_image(response) do
    case ReqLLM.Response.image_data(response) do
      nil -> {:error, "no image data in response: #{inspect(response)}"}
      data when is_binary(data) -> {:ok, data}
    end
  end

  @doc "Write image binary to priv/generated_images/<filename>; returns {:ok, path}."
  @spec save(binary(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def save(binary, filename) do
    output_dir = Path.join(:code.priv_dir(:circle_story), "generated_images")

    with :ok <- File.mkdir_p(output_dir) do
      path = Path.join(output_dir, filename)

      case File.write(path, binary) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, "failed to write image: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, "failed to create output directory: #{inspect(reason)}"}
    end
  end

  @doc "Guess the MIME type from a file extension (defaults to `image/jpeg`)."
  @spec mime_type(Path.t()) :: String.t()
  def mime_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      _ -> "image/jpeg"
    end
  end
end
