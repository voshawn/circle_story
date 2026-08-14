defmodule CircleStory.Books.Composition.Quality.Result do
  @moduledoc "Selected deterministic composition and privacy-safe evaluation provenance."

  alias CircleStory.Books.Composition.Quality.{Attempts, Candidate, Diagnostics}

  @enforce_keys [:candidate, :contract_version, :candidate_count, :rejected_count]
  defstruct @enforce_keys ++
              [
                duration_ms: nil,
                scored_count: 0,
                transparent: %Attempts{kind: :transparent},
                mask_render_errors: []
              ]

  @type t :: %__MODULE__{
          candidate: Candidate.t(),
          contract_version: String.t(),
          candidate_count: non_neg_integer(),
          rejected_count: non_neg_integer(),
          duration_ms: float() | nil,
          scored_count: non_neg_integer(),
          transparent: Attempts.t(),
          mask_render_errors: [{String.t(), term()}]
        }

  @doc "Compact provenance suitable for the placement sidecar and development UI."
  @spec provenance(t()) :: map()
  def provenance(%__MODULE__{candidate: candidate} = result) do
    %{
      contract_version: result.contract_version,
      candidate_id: candidate.id,
      final_rect: candidate.rect,
      adjustment: Atom.to_string(candidate.origin),
      align: candidate.align,
      valign: candidate.valign,
      font_size: round_metric(candidate.measure.font_size),
      line_count: candidate.measure.line_count,
      lines: global_lines(candidate),
      glyph_bounds: global_glyph_bounds(candidate),
      effect_bounds: global_glyph_bounds(candidate),
      overflow: candidate.measure.overflow,
      ink: ink_label(candidate.ink),
      # Retained for the serialized placement contract. Transparent text has no
      # treatment layer, so this value is deliberately fixed rather than derived.
      treatment: "none",
      selection_outcome: selection_outcome(candidate),
      readability_thresholds_met: candidate.readability_rejections == [],
      readability_rejections: reason_classes(candidate.readability_rejections),
      metrics: %{
        overall_p05: metric(candidate, :overall_p05),
        overall_low_contrast_fraction: metric(candidate, :overall_low_contrast_fraction),
        worst_tile_p10: metric(candidate, :worst_tile_p10),
        worst_tile_low_contrast_fraction: metric(candidate, :worst_tile_low_contrast_fraction),
        worst_line_p05: metric(candidate, :worst_line_p05),
        worst_line_low_contrast_fraction:
          metric(
            candidate,
            :worst_line_low_contrast_fraction
          ),
        edge_density: metric(candidate, :edge_density),
        soft_total: round_metric(candidate.soft_total)
      },
      candidate_count: result.candidate_count,
      rejected_count: result.rejected_count,
      scored_count: result.scored_count,
      attempts: %{transparent: Attempts.provenance(result.transparent)},
      mask_render_errors: mask_render_errors(result.mask_render_errors),
      duration_ms: round_metric(result.duration_ms)
    }
  end

  # Mask failures name a candidate and a bounded fault class. The raw renderer
  # term is never persisted: it can embed the page document it failed over.
  defp mask_render_errors(errors) do
    Enum.map(errors, fn {candidate_id, reason} ->
      %{candidate_id: candidate_id, reason: Diagnostics.reason_class(reason)}
    end)
  end

  defp reason_classes(reasons), do: Enum.map(reasons, &Diagnostics.reason_class/1)

  defp global_lines(candidate) do
    Enum.map(candidate.measure.lines, fn line ->
      %{
        x: round(candidate.rect.x + line.x),
        y: round(candidate.rect.y + line.y),
        w: max(round(line.w), 1),
        h: max(round(line.h), 1)
      }
    end)
  end

  defp global_glyph_bounds(candidate) do
    %{
      x: candidate.rect.x + candidate.glyph_bounds.x,
      y: candidate.rect.y + candidate.glyph_bounds.y,
      w: candidate.glyph_bounds.w,
      h: candidate.glyph_bounds.h
    }
  end

  defp ink_label(:black), do: "black"
  defp ink_label(:white), do: "white"

  defp selection_outcome(%{selection_outcome: :below_threshold_transparent_fallback}),
    do: "below_threshold_transparent_fallback"

  defp selection_outcome(_candidate), do: "threshold_pass"

  defp metric(candidate, name), do: candidate.metrics |> Map.get(name) |> round_metric()

  defp round_metric(value) when is_number(value), do: Float.round(value * 1.0, 3)
  defp round_metric(_), do: nil
end
