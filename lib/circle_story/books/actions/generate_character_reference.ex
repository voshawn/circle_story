defmodule CircleStory.Books.Actions.GenerateCharacterReference do
  use Jido.Action,
    name: "generate_character_reference",
    description: "Generate an AI character reference portrait via Google Gemini",
    schema: [
      character: [type: :any, required: true, doc: "Character struct"]
    ]

  require Logger

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

  @doc """
  Filename prefix for a character's reference images: `character_<slug>_<digest>_`.

  The slug is lossy on purpose — it keeps filenames readable ASCII, which avoids
  the NFC/NFD normalization traps of unicode filenames. That alone is not enough
  to identify a character: every non-ASCII letter is dropped, so "José"/"Jos"
  and 李明/小华 slug identically and would share a prefix, and `ImageOps.latest_raw/1`
  would hand one character's portrait to another. The digest of the exact name
  restores uniqueness for arbitrary scripts.
  """
  @spec reference_prefix(String.t()) :: String.t()
  def reference_prefix(name), do: "character_#{slug(name)}_#{digest(name)}_"

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp digest(name) do
    :sha256
    |> :crypto.hash(name)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  defp source_image_part(%Character{source_image_path: nil}), do: []

  defp source_image_part(%Character{source_image_path: path}) do
    case File.read(path) do
      {:ok, binary} ->
        [{binary, GeminiImage.mime_type(path)}]

      {:error, reason} ->
        # Degrade to text-prompt-only, but say so: otherwise a typo'd path buys a
        # paid portrait that silently ignores the source photo.
        Logger.warning(
          "GenerateCharacterReference: source image unreadable, generating from text only " <>
            "(#{inspect(reason)}): #{path}"
        )

        []
    end
  end

  defp save_image(binary, %Character{name: name}) do
    GeminiImage.save(binary, "#{reference_prefix(name)}#{System.os_time(:second)}.png")
  end
end
