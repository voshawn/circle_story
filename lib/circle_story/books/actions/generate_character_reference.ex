defmodule CircleStory.Books.Actions.GenerateCharacterReference do
  use Jido.Action,
    name: "generate_character_reference",
    description: "Generate an AI character reference portrait via Google Gemini",
    schema: [
      character: [type: :any, required: true, doc: "Character struct"]
    ]

  alias CircleStory.Books.{Character, PromptBuilder}
  alias CircleStory.Books.Actions.GeminiImage

  @impl true
  def run(%{character: %Character{} = character}, _context) do
    system_prompt = PromptBuilder.system_prompt(:character)
    user_msg = PromptBuilder.character_message(character)
    messages = GeminiImage.build_messages(user_msg, source_image_part(character))

    with {:ok, response} <- GeminiImage.generate(system_prompt, messages, "1:1"),
         {:ok, image_binary} <- GeminiImage.extract_image(response),
         {:ok, path} <- save_image(image_binary, character) do
      {:ok, %{image_path: path}}
    end
  end

  @doc "Filename prefix for a character's reference images: `character_<slug>_`."
  @spec reference_prefix(String.t()) :: String.t()
  def reference_prefix(name), do: "character_#{slug(name)}_"

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp source_image_part(%Character{source_image_path: nil}), do: []

  defp source_image_part(%Character{source_image_path: path}) do
    case File.read(path) do
      {:ok, binary} -> [{binary, GeminiImage.mime_type(path)}]
      {:error, _} -> []
    end
  end

  defp save_image(binary, %Character{name: name}) do
    output_dir = Path.join(:code.priv_dir(:circle_story), "generated_images")

    with :ok <- File.mkdir_p(output_dir) do
      filename = "#{reference_prefix(name)}#{System.os_time(:second)}.png"
      path = Path.join(output_dir, filename)

      case File.write(path, binary) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, "failed to write image: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, "failed to create output directory: #{inspect(reason)}"}
    end
  end
end
