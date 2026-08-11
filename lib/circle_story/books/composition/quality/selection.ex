defmodule CircleStory.Books.Composition.Quality.Selection do
  @moduledoc "Hard-gate filtering followed by named, configurable soft ranking."

  alias CircleStory.Books.Composition.Quality.{Candidate, Geometry, Policy}

  @spec choose([Candidate.t()], map(), Policy.t()) :: {:ok, Candidate.t()} | {:error, term()}
  def choose(candidates, seed_rect, %Policy{} = policy) do
    ranked = Enum.map(candidates, &rank(&1, seed_rect, policy))
    passing = Enum.filter(ranked, &(&1.hard_rejections == []))

    case passing do
      [] ->
        {:error, :no_candidate_passed_hard_gates}

      _ ->
        {:ok,
         Enum.max_by(passing, fn candidate ->
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
      edge_quietness: max(1 - candidate.metrics.edge_density, 0),
      treatment_restraint: treatment_restraint(candidate.treatment)
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

  defp treatment_restraint(nil), do: 1.0
  defp treatment_restraint(%{opacity: opacity}), do: max(1 - opacity, 0)
end
