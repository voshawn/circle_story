defmodule CircleStory.Books.Composition.Quality.Selection do
  @moduledoc "Hard-gate filtering followed by named, configurable soft ranking."

  alias CircleStory.Books.Composition.Quality.{Candidate, Geometry, Policy}

  @spec choose([Candidate.t()], map(), Policy.t()) :: {:ok, Candidate.t()} | {:error, term()}
  def choose(candidates, seed_rect, %Policy{} = policy) do
    case Enum.filter(candidates, &(&1.hard_rejections == [])) do
      [] ->
        {:error, :no_candidate_passed_hard_gates}

      passing ->
        {:ok,
         passing
         |> weakest_passing_treatment()
         |> Enum.map(&rank(&1, seed_rect, policy))
         |> Enum.max_by(fn candidate ->
           {
             candidate.soft_total,
             candidate.measure.font_size,
             -Geometry.area(candidate.rect),
             -candidate.index
           }
         end)}
    end
  end

  @doc false
  @spec rank(Candidate.t(), map(), Policy.t()) :: Candidate.t()
  def rank(%Candidate{} = candidate, seed_rect, %Policy{} = policy) do
    margins = glyph_margins(candidate)

    soft_metrics = %{
      readability: min(candidate.metrics.worst_tile_p10 / policy.target_contrast, 2.0),
      font_size: min(candidate.measure.font_size / policy.preferred_font, 1.0),
      compactness: min(Geometry.area(seed_rect) / Geometry.area(candidate.rect), 1.5),
      seed_proximity:
        1 /
          (1 +
             Geometry.distance(seed_rect, candidate.rect) /
               max(policy.growth_step, 1)),
      whitespace_balance: whitespace_balance(margins),
      edge_quietness: max(1 - candidate.metrics.edge_density, 0)
    }

    contributions =
      Map.new(soft_metrics, fn {name, value} ->
        {name, value * Map.get(policy.soft_weights, name, 0.0)}
      end)

    %{
      candidate
      | soft_metrics: soft_metrics,
        soft_contributions: contributions,
        soft_total: Enum.sum(Map.values(contributions))
    }
  end

  # Soft weights rank layouts, never treatment strength: a stronger backing can
  # only win when no weaker treatment passed the hard gates at all. Because that
  # is settled here, before ranking, no soft weight over treatment strength could
  # affect the ordering, so none exists.
  defp weakest_passing_treatment(passing) do
    weakest = passing |> Enum.map(&treatment_strength(&1.treatment)) |> Enum.min()
    Enum.filter(passing, &(treatment_strength(&1.treatment) == weakest))
  end

  defp treatment_strength(nil), do: 0.0
  defp treatment_strength(%{opacity: opacity}), do: opacity

  defp glyph_margins(candidate) do
    bounds = candidate.glyph_bounds

    %{
      left: bounds.x,
      top: bounds.y,
      right: candidate.rect.w - bounds.x - bounds.w,
      bottom: candidate.rect.h - bounds.y - bounds.h
    }
  end

  defp whitespace_balance(margins) do
    horizontal = 1 - abs(margins.left - margins.right) / max(margins.left + margins.right, 1)
    vertical = 1 - abs(margins.top - margins.bottom) / max(margins.top + margins.bottom, 1)
    max((horizontal + vertical) / 2, 0)
  end
end
