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
end
