defmodule CircleStory.Books.CharacterSelector do
  @moduledoc """
  Selects the configured characters referenced by a spread.

  Actual rendering uses a Gemini-backed provider and caches its selected names.
  Retries reuse a cached model selection, but re-attempt selection when the cache
  only holds a prior include-all failure fallback. Prompt previews only read the
  cache and never make a model call; before a spread has been selected they
  safely include every configured character. Provider, response, and cache
  failures are explicit in logs and also fall back to every character so
  conditioning is never silently dropped.
  """

  require Logger

  alias CircleStory.Books.Character
  alias CircleStory.Books.CharacterSelector.Gemini

  @cache_version 1

  @doc """
  Select the characters for an actual spread render.

  A cache miss invokes the configured provider. A cached include-all failure
  fallback is also re-attempted, so a transient provider failure cannot pin a
  spread to include-all forever. The resulting names (including a new fallback)
  are cached for retries and previews.
  """
  @spec for_spread(struct(), [Character.t()]) :: [Character.t()]
  def for_spread(spread, characters), do: for_spread(spread, characters, [])

  @doc false
  @spec for_spread(struct(), [Character.t()], keyword()) :: [Character.t()]
  def for_spread(_spread, [], _opts), do: []

  def for_spread(spread, characters, opts) do
    path = cache_path(spread, characters, opts)

    case load_cache(path, characters) do
      {:ok, names, "model"} ->
        characters_for_names(characters, names)

      {:ok, _names, "fallback"} ->
        Logger.warning(
          "CharacterSelector: cached selection is a prior include-all fallback; " <>
            "selecting again for this render: #{path}"
        )

        select_and_cache(spread, characters, path, opts)

      :miss ->
        select_and_cache(spread, characters, path, opts)

      {:error, reason} ->
        Logger.warning(
          "CharacterSelector: cached selection is invalid; refreshing for render " <>
            "(#{summarize_error(reason)}): #{path}"
        )

        select_and_cache(spread, characters, path, opts)
    end
  end

  @doc """
  Return the cached selection for a prompt preview without making a model call.

  When no valid cache exists, every configured character is returned. This keeps
  an unrendered preview conservative instead of silently omitting conditioning.
  """
  @spec for_preview(struct(), [Character.t()]) :: [Character.t()]
  def for_preview(spread, characters), do: for_preview(spread, characters, [])

  @doc false
  @spec for_preview(struct(), [Character.t()], keyword()) :: [Character.t()]
  def for_preview(_spread, [], _opts), do: []

  def for_preview(spread, characters, opts) do
    path = cache_path(spread, characters, opts)

    case load_cache(path, characters) do
      {:ok, names, source} ->
        warn_for_cached_fallback(source)
        characters_for_names(characters, names)

      :miss ->
        characters

      {:error, reason} ->
        Logger.warning(
          "CharacterSelector: cached selection is invalid; preview includes all characters " <>
            "without a model call (#{summarize_error(reason)}): #{path}"
        )

        characters
    end
  end

  @doc false
  @spec cache_path(struct(), [Character.t()], keyword()) :: Path.t()
  def cache_path(spread, characters, opts \\ []) do
    fingerprint =
      :erlang.term_to_binary({
        @cache_version,
        Map.get(spread, :text),
        Map.get(spread, :image_prompt),
        Enum.map(characters, & &1.name)
      })
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Path.join(cache_dir(opts), "#{fingerprint}.json")
  end

  defp select_and_cache(spread, characters, path, opts) do
    candidate_names = Enum.map(characters, & &1.name)
    provider = Keyword.get(opts, :provider, configured_provider())

    result = call_provider(provider, spread, candidate_names)

    with {:ok, names} <- result,
         {:ok, selected} <- resolve_names(names, candidate_names) do
      cache_best_effort(path, selected, "model")
      characters_for_names(characters, selected)
    else
      {:error, reason} ->
        Logger.warning(
          "CharacterSelector: character selection failed; including all configured characters " <>
            "(#{summarize_error(reason)})"
        )

        cache_best_effort(path, candidate_names, "fallback")
        characters
    end
  end

  defp call_provider(provider, spread, candidate_names) do
    try do
      case provider.select(spread, candidate_names) do
        {:ok, names} -> {:ok, names}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_provider_result, other}}
      end
    rescue
      exception -> {:error, {:provider_exception, Exception.message(exception)}}
    catch
      kind, reason -> {:error, {:provider_failure, kind, reason}}
    end
  end

  defp configured_provider do
    Application.get_env(:circle_story, :character_selector_provider, Gemini)
  end

  defp cache_dir(opts) do
    Keyword.get_lazy(opts, :cache_dir, fn ->
      Path.join([:code.priv_dir(:circle_story), "generated_images", "character_selections"])
    end)
  end

  defp cache_best_effort(path, names, source) do
    case write_cache(path, names, source) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "CharacterSelector: could not cache selection; a retry may select again " <>
            "(#{summarize_error(reason)}): #{path}"
        )
    end
  end

  defp write_cache(path, names, source) do
    contents =
      Jason.encode!(%{
        "version" => @cache_version,
        "selected_character_names" => names,
        "source" => source
      })

    temporary = "#{path}.#{System.unique_integer([:positive])}.tmp"

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(temporary, contents),
           :ok <- File.rename(temporary, path) do
        :ok
      end
    after
      File.rm(temporary)
    end
  end

  defp load_cache(path, characters) do
    candidate_names = Enum.map(characters, & &1.name)

    case File.read(path) do
      {:ok, contents} -> decode_cache(contents, candidate_names)
      {:error, :enoent} -> :miss
      {:error, reason} -> {:error, {:cache_read_failed, reason}}
    end
  end

  defp decode_cache(contents, candidate_names) do
    with {:ok,
          %{
            "version" => @cache_version,
            "selected_character_names" => names,
            "source" => source
          }} <- Jason.decode(contents),
         true <- source in ["model", "fallback"],
         {:ok, selected} <- resolve_names(names, candidate_names) do
      {:ok, selected, source}
    else
      {:error, reason} -> {:error, {:cache_decode_failed, reason}}
      false -> {:error, :invalid_cache_source}
      other -> {:error, {:invalid_cache_contents, other}}
    end
  end

  defp resolve_names(names, candidate_names) when is_list(names) do
    if Enum.all?(names, &is_binary/1) do
      configured = configured_by_normalized_name(candidate_names)
      resolved = Enum.map(names, &Map.get(configured, normalize_name(&1)))
      unknown_names = for {name, nil} <- Enum.zip(names, resolved), do: name

      cond do
        unknown_names != [] ->
          {:error, {:unknown_selected_names, unknown_names}}

        Enum.uniq(resolved) != resolved ->
          {:error, {:duplicate_selected_names, names}}

        true ->
          {:ok, resolved}
      end
    else
      {:error, {:invalid_selected_names, names}}
    end
  end

  defp resolve_names(names, _candidate_names), do: {:error, {:invalid_selected_names, names}}

  defp configured_by_normalized_name(candidate_names) do
    Map.new(candidate_names, &{normalize_name(&1), &1})
  end

  defp normalize_name(name), do: String.normalize(name, :nfc)

  defp characters_for_names(characters, names) do
    selected = MapSet.new(names)
    Enum.filter(characters, &MapSet.member?(selected, &1.name))
  end

  defp warn_for_cached_fallback("fallback") do
    Logger.warning(
      "CharacterSelector: using cached include-all fallback from a prior selection failure"
    )
  end

  defp warn_for_cached_fallback("model"), do: :ok

  defp summarize_error(error), do: inspect(error, limit: 8, printable_limit: 300)
end
