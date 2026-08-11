defmodule CircleStory.CompositionQualityOptimizerFake do
  @moduledoc false

  alias CircleStory.Books.Composition.Quality.{Candidate, Policy, Result}

  def optimize(_image, _content, placement, seed_rect, opts) do
    role = Keyword.fetch!(opts, :role)
    policy = Policy.new(role)

    candidate = %Candidate{
      id: "test-seed",
      index: 0,
      rect: seed_rect,
      align: placement.text_align,
      valign: placement.vertical_align,
      min_font: policy.min_font,
      max_font: policy.preferred_font,
      inset: policy.internal_inset,
      origin: :seed,
      measure: %{
        font_size: policy.preferred_font * 1.0,
        line_count: 1,
        overflow: false,
        clipped: false,
        lines: []
      },
      ink: :black,
      treatment: nil,
      glyph_bounds: %{x: policy.internal_inset, y: policy.internal_inset, w: 1, h: 1},
      metrics: %{
        worst_tile_p10: 10.0,
        worst_tile_low_contrast_fraction: 0.0,
        worst_line_p05: 10.0,
        edge_density: 0.0
      },
      soft_total: 1.0
    }

    {:ok,
     %Result{
       candidate: candidate,
       contract_version: policy.contract_version,
       candidate_count: 1,
       rejected_count: 0
     }}
  end
end
