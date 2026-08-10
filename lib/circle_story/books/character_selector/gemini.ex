defmodule CircleStory.Books.CharacterSelector.Gemini do
  @moduledoc """
  Gemini-backed character selection for rendered spreads.

  This provider performs only the language-model classification. Caching,
  validation, and the include-all failure policy live in `CharacterSelector`.
  """

  @behaviour CircleStory.Books.CharacterSelector.Provider

  @model "google:gemini-3.1-flash-lite"
  @object_schema [character_names: [type: {:list, :string}, required: true]]

  @impl true
  def select(spread, candidate_names) do
    messages = [ReqLLM.Context.user(selection_prompt(spread, candidate_names))]

    with {:ok, response} <-
           ReqLLM.generate_object(@model, messages, @object_schema,
             google_thinking_level: :minimal
           ),
         %{"character_names" => names} when is_list(names) <- ReqLLM.Response.object(response) do
      {:ok, names}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_character_selection_response, other}}
    end
  end

  @doc false
  @spec selection_prompt(struct(), [String.t()]) :: String.t()
  def selection_prompt(spread, candidate_names) do
    """
    Select which candidate character names are explicitly referenced in this
    children's-book spread. A reference may occur in either the story text or
    the image prompt.

    Treat each candidate as a complete name, not as a substring of a different
    name or word. Correctly recognize names in every writing system, including
    scripts such as Chinese, Japanese, and Thai that may not put spaces around
    names. Do not infer a character who is not explicitly referenced.

    Return each selected name exactly as it appears in CANDIDATE_NAMES. Return an
    empty list when no candidate is referenced.

    CANDIDATE_NAMES: #{Jason.encode!(candidate_names)}
    STORY_TEXT: #{Jason.encode!(Map.get(spread, :text) || "")}
    IMAGE_PROMPT: #{Jason.encode!(Map.get(spread, :image_prompt) || "")}
    """
  end
end
