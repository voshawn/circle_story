defmodule CircleStory.Books.CharacterSelector.Gemini do
  @moduledoc """
  Gemini-backed character selection for rendered spreads.

  This provider performs only the language-model classification. Caching,
  validation, and the include-all failure policy live in `CharacterSelector`.
  """

  @behaviour CircleStory.Books.CharacterSelector.Provider

  @model "google:gemini-3.1-flash-lite"

  @instructions """
  Select which candidate character names are explicitly referenced in this
  children's-book spread. A reference may occur in either the story text or
  the image prompt.

  Treat each candidate as a complete name, not as a substring of a different
  name or word. Correctly recognize names in every writing system, including
  scripts such as Chinese, Japanese, and Thai that may not put spaces around
  names. Do not infer a character who is not explicitly referenced.

  Return each selected name exactly as it appears in CANDIDATE_NAMES. Return an
  empty list when no candidate is referenced.
  """

  @instructions_digest :crypto.hash(:sha256, @instructions) |> Base.encode16(case: :lower)

  @impl true
  def select(spread, candidate_names) do
    messages = [ReqLLM.Context.user(selection_prompt(spread, candidate_names))]

    with {:ok, response} <-
           ReqLLM.generate_object(@model, messages, object_schema(candidate_names),
             google_thinking_level: :minimal
           ),
         %{"character_names" => names} when is_list(names) <- ReqLLM.Response.object(response) do
      {:ok, names}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_character_selection_response, other}}
    end
  end

  @impl true
  def selection_version, do: {@model, @instructions_digest}

  @doc false
  @spec object_schema([String.t()]) :: keyword()
  def object_schema(candidate_names) do
    [character_names: [type: {:list, {:in, candidate_names}}, required: true]]
  end

  @doc false
  @spec selection_prompt(struct(), [String.t()]) :: String.t()
  def selection_prompt(spread, candidate_names) do
    """
    #{@instructions}
    CANDIDATE_NAMES: #{Jason.encode!(candidate_names)}
    STORY_TEXT: #{Jason.encode!(Map.get(spread, :text) || "")}
    IMAGE_PROMPT: #{Jason.encode!(Map.get(spread, :image_prompt) || "")}
    """
  end
end
