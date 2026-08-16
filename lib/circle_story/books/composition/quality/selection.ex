defmodule CircleStory.Books.Composition.Quality.Selection do
  @moduledoc """
  Preferred-threshold selection with a deterministic transparent fallback.

  Non-negotiable geometry and renderer failures are never selectable. When no
  geometry-safe transparent candidate meets every readability threshold, the
  existing glyph-mask contrast and edge metrics rank the best available result.
  """

  alias CircleStory.Books.Composition.Quality.{Candidate, Geometry, Policy}

  @spec choose([Candidate.t()], map(), Policy.t()) :: {:ok, Candidate.t()} | {:error, term()}
  def choose(candidates, seed_rect, %Policy{} = policy) do
    case Enum.filter(candidates, &Candidate.preferred?/1) do
      [] -> choose_fallback(candidates, seed_rect, policy)
      passing -> {:ok, choose_preferred(passing, seed_rect, policy)}
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
      seed_fidelity: Geometry.seed_fidelity(seed_rect, candidate.rect),
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

  defp choose_preferred(passing, seed_rect, policy) do
    passing
    |> Enum.map(&rank(&1, seed_rect, policy))
    |> Enum.max_by(fn candidate ->
      {
        candidate.soft_total,
        candidate.measure.font_size,
        -Geometry.area(candidate.rect),
        -candidate.index,
        ink_tie_breaker(candidate.ink)
      }
    end)
    |> Map.put(:selection_outcome, :threshold_pass)
  end

  defp choose_fallback(candidates, seed_rect, policy) do
    case Enum.filter(candidates, &fallback_eligible?/1) do
      [] ->
        {:error, :no_geometry_safe_candidate}

      eligible ->
        selected =
          eligible
          |> Enum.max_by(&fallback_rank/1)
          |> rank(seed_rect, policy)
          |> Map.put(:selection_outcome, :below_threshold_transparent_fallback)

        {:ok, selected}
    end
  end

  # This tuple is intentionally lexicographic and contains only existing,
  # persisted glyph-mask readability evidence before deterministic tie-breakers:
  # maximize the weakest contrast distribution, minimize locally low-contrast
  # ink, then prefer stronger tile/line contrast and quieter texture.
  defp fallback_rank(candidate) do
    tile_contrast = candidate.metrics.worst_tile_p10
    line_contrast = candidate.metrics.worst_line_p05

    {
      min(tile_contrast, line_contrast),
      -candidate.metrics.worst_tile_low_contrast_fraction,
      tile_contrast,
      line_contrast,
      -candidate.metrics.edge_density,
      -candidate.index,
      ink_tie_breaker(candidate.ink)
    }
  end

  defp fallback_eligible?(candidate) do
    candidate.hard_rejections == [] and not Candidate.preferred?(candidate) and
      readability_metrics?(candidate.metrics)
  end

  defp readability_metrics?(metrics) do
    Enum.all?(
      [
        Map.get(metrics, :worst_tile_p10),
        Map.get(metrics, :worst_tile_low_contrast_fraction),
        Map.get(metrics, :worst_line_p05),
        Map.get(metrics, :edge_density)
      ],
      &is_number/1
    )
  end

  defp ink_tie_breaker(:black), do: 1
  defp ink_tie_breaker(:white), do: 0

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
