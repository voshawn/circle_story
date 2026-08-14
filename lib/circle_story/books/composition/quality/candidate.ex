defmodule CircleStory.Books.Composition.Quality.Candidate do
  @moduledoc "A deterministic text-layout candidate and its inspectable evaluation evidence."

  @enforce_keys [
    :id,
    :index,
    :rect,
    :align,
    :valign,
    :min_font,
    :max_font,
    :inset,
    :origin
  ]

  defstruct @enforce_keys ++
              [
                :measure,
                :ink,
                :glyph_bounds,
                :selection_outcome,
                hard_rejections: [],
                readability_rejections: [],
                metrics: %{},
                soft_metrics: %{},
                soft_contributions: %{},
                soft_total: 0.0
              ]

  @type t :: %__MODULE__{}

  @doc """
  True when a candidate meets the preferred thresholds.

  Selection and the scan accounting must agree on this predicate: if they
  diverge, `attempts.transparent.passed` and `selection_outcome` can contradict
  each other in the provenance an operator audits a below-threshold publish with.
  """
  @spec preferred?(t()) :: boolean()
  def preferred?(%__MODULE__{} = candidate),
    do: candidate.hard_rejections == [] and candidate.readability_rejections == []
end
