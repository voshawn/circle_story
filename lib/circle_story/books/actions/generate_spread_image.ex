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

  # Pixel dimensions per spread type — passed as aspect ratio hint to the API
  @inner_aspect_ratio "2:1"
  @cover_aspect_ratio "2:1"

  @impl true
  def run(%{spread: spread, characters: characters, spread_type: spread_type}, _context) do
    system_prompt = PromptBuilder.system_prompt(spread_type)
    user_msg = PromptBuilder.user_message(spread, characters)
    ref_image_parts = load_reference_images(characters)
    messages = build_messages(user_msg, ref_image_parts)
    aspect_ratio = aspect_ratio(spread_type)

    with {:ok, response} <- call_llm(system_prompt, messages, aspect_ratio),
         {:ok, image_binary} <- extract_image(response),
         {:ok, path} <- save_image(image_binary, spread, spread_type) do
      {:ok, %{image_path: path}}
    end
  end

  defp aspect_ratio(:inner), do: @inner_aspect_ratio
  defp aspect_ratio(:cover), do: @cover_aspect_ratio

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

  defp call_llm(system_prompt, messages, aspect_ratio) do
    ReqLLM.generate_image(@model, messages,
      system: system_prompt,
      provider_options: [
        google_api_version: "v1beta",
        google_image_aspect_ratio: aspect_ratio
      ]
    )
  end

  defp extract_image(response) do
    # ReqLLM normalizes responses — inspect the raw response in IEx if this fails
    # to find the correct key for your req_llm version (see Task 4 Step 6).
    case response do
      %{content: [%{data: data} | _]} when is_binary(data) ->
        {:ok, data}

      %{choices: [%{message: %{content: content}} | _]} when is_list(content) ->
        content
        |> Enum.find_value({:error, "no image data in response"}, fn
          %{data: data} when is_binary(data) -> {:ok, data}
          _ -> nil
        end)

      other ->
        {:error, "unexpected response shape — run IEx debug in Step 6: #{inspect(other)}"}
    end
  end

  defp save_image(binary, spread, spread_type) do
    output_dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
    File.mkdir_p!(output_dir)
    filename = build_filename(spread, spread_type)
    path = Path.join(output_dir, filename)

    case File.write(path, binary) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, "failed to write image: #{inspect(reason)}"}
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
