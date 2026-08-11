defmodule CircleStory.Books.Composition.Quality do
  @moduledoc """
  Deterministic Stage A text composition.

  A model placement remains a semantic seed. Explicit immutable steps build a
  local safety map, expand a bounded canvas, search browser-fitted candidates,
  apply hard glyph-level gates, and rank only passing candidates. This module
  performs no provider calls.
  """

  alias CircleStory.Books.Composition.Quality.{
    BrowserRenderer,
    Candidates,
    Context,
    Policy,
    Regions,
    Result,
    SafetyMap,
    Scorer,
    Selection
  }

  @default_steps [
    {__MODULE__, :build_safety_map},
    {Regions, :expand},
    {Candidates, :generate},
    {Candidates, :measure},
    {Candidates, :select_finalists},
    {__MODULE__, :evaluate_finalists},
    {__MODULE__, :select_candidate}
  ]

  @type step :: {module(), atom()}

  @doc "Optimize final text geometry and treatment with no model/provider calls."
  @spec optimize(Vix.Vips.Image.t(), map(), map(), map(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def optimize(image, content, placement, seed_rect, opts \\ []) do
    policy =
      case Keyword.get(opts, :policy) do
        %Policy{} = policy -> policy
        nil -> Policy.new(mode_to_role(placement, opts), Keyword.get(opts, :policy_overrides, []))
      end

    context = %Context{
      image: image,
      content: content,
      placement: placement,
      seed_rect: seed_rect,
      policy: policy,
      renderer: Keyword.get(opts, :renderer, BrowserRenderer),
      bounds: Policy.bounds_for_seed(policy, seed_rect)
    }

    started_at = System.monotonic_time()

    case run_steps(context, Keyword.get(opts, :steps, @default_steps)) do
      {:ok, %Result{} = result} ->
        duration_ms =
          System.monotonic_time()
          |> Kernel.-(started_at)
          |> System.convert_time_unit(:native, :microsecond)
          |> Kernel./(1_000)

        {:ok, %{result | duration_ms: duration_ms}}

      other ->
        other
    end
  end

  @doc false
  @spec run_steps(Context.t(), [step()]) :: {:ok, Result.t() | Context.t()} | {:error, term()}
  def run_steps(context, steps) do
    Enum.reduce_while(steps, {:ok, context}, fn {module, function}, {:ok, current} ->
      case apply(module, function, [current]) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  @spec build_safety_map(Context.t()) :: {:ok, Context.t()}
  def build_safety_map(%Context{} = context) do
    {:ok, %{context | safety_map: SafetyMap.build(context.image, context.policy)}}
  end

  @doc false
  @spec evaluate_finalists(Context.t()) :: {:ok, Context.t()} | {:error, term()}
  def evaluate_finalists(%Context{} = context) do
    {rendered, errors} = render_finalist_masks(context)

    if rendered == [] do
      {:error, {:composition_mask_render_failed, Enum.reverse(errors)}}
    else
      untreated =
        Enum.flat_map(rendered, fn {candidate, mask} ->
          preferred = candidate.metrics.preferred_ink
          inks = [preferred, opposite(preferred)]

          Enum.map(inks, fn ink ->
            Scorer.score(context.image, candidate, mask, context.policy, ink)
          end)
        end)

      {evaluated, backing_scans} =
        if Enum.any?(untreated, &(&1.hard_rejections == [])) do
          {untreated, 0}
        else
          backing_variants(rendered, context)
        end

      evidence =
        context.evidence
        |> Map.put(:mask_render_errors, Enum.reverse(errors))
        |> Map.put(:scored_count, length(untreated) + backing_scans)

      {:ok, %{context | evaluated: evaluated, evidence: evidence}}
    end
  end

  @doc false
  @spec select_candidate(Context.t()) :: {:ok, Result.t()} | {:error, term()}
  def select_candidate(%Context{} = context) do
    with {:ok, selected} <- Selection.choose(context.evaluated, context.seed_rect, context.policy) do
      rejected_count = Enum.count(context.evaluated, &(&1.hard_rejections != []))

      {:ok,
       %Result{
         candidate: selected,
         contract_version: context.policy.contract_version,
         candidate_count: length(context.candidates),
         rejected_count: rejected_count,
         scored_count: Map.get(context.evidence, :scored_count, length(context.evaluated))
       }}
    else
      {:error, :no_candidate_passed_hard_gates} ->
        {:error,
         {:composition_quality_failed,
          %{
            role: context.policy.role,
            candidates_tried: length(context.candidates),
            finalists_scored: length(context.evaluated),
            rejection_reasons:
              context.evaluated
              |> Enum.flat_map(& &1.hard_rejections)
              |> Enum.frequencies()
          }}}
    end
  end

  defp render_finalist_masks(context) do
    Enum.reduce(context.finalists, {[], []}, fn candidate, {rendered, errors} ->
      case context.renderer.mask(candidate, context.content, context.policy.role) do
        {:ok, mask} -> {[{candidate, mask} | rendered], errors}
        {:error, reason} -> {rendered, [{candidate.id, reason} | errors]}
      end
    end)
    |> then(fn {rendered, errors} -> {Enum.reverse(rendered), errors} end)
  end

  # The bounded opacity list is walked weakest-to-strongest and abandoned at the
  # first opacity where some finalist/ink pair clears the hard gates, so the
  # stronger backings are never scanned once a lighter one works. Every finalist
  # and both inks are retained at that opacity so ranking still has the full
  # field, and the total scan count is reported for bounded-work assertions.
  defp backing_variants(rendered, context) do
    pairs =
      for {candidate, mask} <- rendered,
          {ink, color} <- [black: :white, white: :black],
          do: {candidate, mask, ink, color}

    Enum.reduce_while(context.policy.backing_opacities, {[], 0}, fn opacity, {_previous, scans} ->
      {variants, scans} =
        Enum.map_reduce(pairs, scans, fn {candidate, mask, ink, color}, scanned ->
          treatment = %{type: :backing, color: color, opacity: opacity}

          {Scorer.score(context.image, candidate, mask, context.policy, ink, treatment),
           scanned + 1}
        end)

      if Enum.any?(variants, &(&1.hard_rejections == [])) do
        {:halt, {variants, scans}}
      else
        {:cont, {variants, scans}}
      end
    end)
  end

  defp mode_to_role(placement, opts) do
    Keyword.get(opts, :role, Map.get(placement, :mode, :inner))
  end

  defp opposite(:black), do: :white
  defp opposite(:white), do: :black
end
