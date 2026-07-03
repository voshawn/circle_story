defmodule CircleStory.Books.Actions.GenerateSpreadImage do
  use Jido.Action,
    name: "generate_spread_image",
    description: "Generate an AI image for a book spread via Google Gemini",
    schema: [
      spread: [type: :any, required: true, doc: "InnerSpread or CoverSpread struct"],
      characters: [type: {:list, :any}, required: true, doc: "List of Character structs"],
      spread_type: [type: {:in, [:inner, :cover]}, required: true]
    ]

  alias CircleStory.Books.{Character, CharacterSelector, PromptBuilder}
  alias CircleStory.Books.Actions.GeminiImage

  @impl true
  def run(%{spread: spread, characters: characters, spread_type: spread_type}, _context) do
    selected = CharacterSelector.for_spread(spread, characters)
    system_prompt = PromptBuilder.system_prompt(spread_type)
    user_msg = PromptBuilder.user_message(spread, selected)
    ref_image_parts = load_reference_images(selected)
    messages = GeminiImage.build_messages(user_msg, ref_image_parts)

    with {:ok, response} <-
           GeminiImage.generate(system_prompt, messages, aspect_ratio(spread_type)),
         {:ok, image_binary} <- GeminiImage.extract_image(response),
         {:ok, path} <- save_image(image_binary, spread, spread_type) do
      {:ok, %{image_path: path}}
    end
  end

  defp load_reference_images(characters) do
    characters
    |> Enum.filter(& &1.reference_image_path)
    |> Enum.flat_map(fn %Character{reference_image_path: path} ->
      case File.read(path) do
        {:ok, binary} -> [{binary, GeminiImage.mime_type(path)}]
        {:error, _} -> []
      end
    end)
  end

  defp aspect_ratio(:cover), do: "1:1"
  defp aspect_ratio(:inner), do: "16:9"

  defp save_image(binary, spread, spread_type) do
    GeminiImage.save(binary, build_filename(spread, spread_type))
  end

  defp build_filename(%{position: pos}, :inner) do
    ts = System.os_time(:second)
    "inner_#{pos}_#{ts}.png"
  end

  defp build_filename(_spread, :cover) do
    ts = System.os_time(:second)
    "cover_front_#{ts}.png"
  end
end
