defmodule CircleStory.Books.Actions.GenerateSpreadImage do
  use Jido.Action,
    name: "generate_spread_image",
    description: "Generate an AI image for a book spread via Google Gemini",
    schema: [
      spread: [type: :any, required: true, doc: "InnerSpread or CoverSpread struct"],
      characters: [type: {:list, :any}, required: true, doc: "List of Character structs"],
      spread_type: [type: {:in, [:inner, :cover]}, required: true]
    ]

  alias CircleStory.Books.{Character, PromptBuilder}

  @model "google:gemini-3.1-flash-image"

  @impl true
  def run(%{spread: spread, characters: characters, spread_type: spread_type}, _context) do
    system_prompt = PromptBuilder.system_prompt(spread_type)
    user_msg = PromptBuilder.user_message(spread, characters)
    ref_image_parts = load_reference_images(characters)
    messages = build_messages(user_msg, ref_image_parts)

    with {:ok, response} <- call_llm(system_prompt, messages),
         {:ok, image_binary} <- extract_image(response),
         {:ok, path} <- save_image(image_binary, spread, spread_type) do
      {:ok, %{image_path: path}}
    end
  end

  defp load_reference_images(characters) do
    characters
    |> Enum.filter(& &1.reference_image_path)
    |> Enum.flat_map(fn %Character{reference_image_path: path} ->
      case File.read(path) do
        {:ok, binary} -> [{binary, mime_type(path)}]
        {:error, _} -> []
      end
    end)
  end

  defp build_messages(text, []) do
    [%{role: "user", content: text}]
  end

  defp build_messages(text, ref_images) do
    image_parts =
      Enum.map(ref_images, fn {binary, mime} ->
        %{type: "image_url", image_url: %{url: "data:#{mime};base64,#{Base.encode64(binary)}"}}
      end)

    [%{role: "user", content: [%{type: "text", text: text} | image_parts]}]
  end

  defp call_llm(system_prompt, messages) do
    # System prompt passed as role: "system" message — split_messages_for_gemini
    # converts it to systemInstruction for the Gemini API.
    all_messages = [%{role: "system", content: system_prompt} | messages]

    ReqLLM.generate_image(@model, all_messages,
      aspect_ratio: "16:9",
      google_thinking_level: :high
    )
  end

  defp extract_image(response) do
    case ReqLLM.Response.image_data(response) do
      nil -> {:error, "no image data in response: #{inspect(response)}"}
      data when is_binary(data) -> {:ok, data}
    end
  end

  defp save_image(binary, spread, spread_type) do
    output_dir = Path.join(:code.priv_dir(:circle_story), "generated_images")

    with :ok <- File.mkdir_p(output_dir) do
      filename = build_filename(spread, spread_type)
      path = Path.join(output_dir, filename)

      case File.write(path, binary) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, "failed to write image: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, "failed to create output directory: #{inspect(reason)}"}
    end
  end

  defp build_filename(%{position: pos}, :inner) do
    ts = System.os_time(:second)
    "inner_#{pos}_#{ts}.png"
  end

  defp build_filename(_spread, :cover) do
    ts = System.os_time(:second)
    "cover_#{ts}.png"
  end

  defp mime_type(path) do
    case Path.extname(path) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      _ -> "image/jpeg"
    end
  end
end
