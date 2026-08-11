defmodule CircleStory.Books.Composition.QualityTest do
  use ExUnit.Case, async: false

  alias CircleStory.Books.Composition.Quality

  alias CircleStory.Books.Composition.Quality.{
    BrowserRenderer,
    Candidate,
    Policy,
    Result,
    Scorer
  }

  @story "With fierce love she built a successful business, became a professor, and wrote her own story."

  setup_all do
    start_supervised!({ChromicPDF, []})
    :ok
  end

  setup do
    previous = Application.get_env(:circle_story, :debug_bounding_boxes, false)
    Application.put_env(:circle_story, :debug_bounding_boxes, false)
    on_exit(fn -> Application.put_env(:circle_story, :debug_bounding_boxes, previous) end)
    :ok
  end

  test "captain-geometry regression rejects a narrow dark edge and selects a passing adjustment" do
    art =
      Image.new!(800, 400, color: :white)
      |> Image.compose!(Image.new!(60, 300, color: :black), x: 480, y: 40)

    policy = test_policy()
    seed = %{x: 480, y: 40, w: 280, h: 260}
    placement = placement(:left, :top)
    content = %{text: @story}
    unsafe = candidate(seed, :left, :top)

    assert {:ok, measurements} = BrowserRenderer.measure([unsafe], content, :inner)
    unsafe = %{unsafe | measure: Map.fetch!(measurements, unsafe.id)}
    assert {:ok, mask} = BrowserRenderer.mask(unsafe, content, :inner)
    scored_unsafe = Scorer.score(art, unsafe, mask, policy, :black)

    assert Enum.any?(scored_unsafe.hard_rejections, fn reason ->
             reason in [:local_contrast_percentile, :local_contrast_fraction]
           end)

    assert {:ok, result} = Quality.optimize(art, content, placement, seed, policy: policy)
    selected = result.candidate

    assert selected.hard_rejections == []
    assert selected.ink == :black
    assert selected.treatment == nil
    assert selected.metrics.worst_tile_p10 >= policy.hard_contrast
    assert selected.metrics.worst_tile_low_contrast_fraction <= policy.max_low_contrast_fraction
    assert selected.origin != :seed or selected.align != :left
    assert selected.measure.line_count >= 2

    provenance = Result.provenance(result)
    assert provenance.final_rect == selected.rect
    assert length(provenance.lines) == selected.measure.line_count
    assert provenance.glyph_bounds.w > 0
    assert provenance.effect_bounds == provenance.glyph_bounds
    assert provenance.duration_ms > 0
    refute Map.has_key?(provenance, :text)
    refute Map.has_key?(provenance, :image_path)
  end

  test "inverse light edge on dark art selects safe white text" do
    art =
      Image.new!(800, 400, color: :black)
      |> Image.compose!(Image.new!(60, 300, color: :white), x: 480, y: 40)

    policy = test_policy()
    seed = %{x: 480, y: 40, w: 280, h: 260}
    content = %{text: @story}

    assert {:ok, result} =
             Quality.optimize(art, content, placement(:left, :top), seed, policy: policy)

    assert result.candidate.hard_rejections == []
    assert result.candidate.ink == :white
    assert result.candidate.metrics.worst_tile_p10 >= policy.hard_contrast
    assert result.candidate.origin != :seed or result.candidate.align != :left
  end

  test "busy mixed art uses the first deterministic backing that passes" do
    art = checkerboard(800, 400, 24)
    policy = test_policy(candidate_transforms: [:seed], finalist_limit: 4)
    seed = %{x: 480, y: 40, w: 280, h: 260}

    assert {:ok, result} =
             Quality.optimize(art, %{text: @story}, placement(:center, :middle), seed,
               policy: policy
             )

    assert %{type: :backing, opacity: 0.44} = result.candidate.treatment
    assert result.candidate.hard_rejections == []
    assert result.candidate.metrics.worst_tile_p10 >= policy.hard_contrast
  end

  test "long unbreakable text returns structured overflow at the role minimum" do
    art = Image.new!(800, 400, color: :white)
    seed = %{x: 520, y: 120, w: 150, h: 90}

    policy =
      test_policy(
        candidate_transforms: [:seed],
        alignments: [:seed],
        valignments: [:seed],
        font_caps: [24],
        min_font: 24,
        internal_inset: 24,
        finalist_limit: 1
      )

    content = %{text: String.duplicate("unbreakable", 30)}

    assert {:error,
            {:composition_overflow,
             %{
               minimum_font: 24,
               reason: :no_candidate_fits_without_clipping,
               candidates_tried: 1
             }}} =
             Quality.optimize(art, content, placement(:left, :top), seed, policy: policy)
  end

  defp test_policy(overrides \\ []) do
    Policy.new(
      :inner,
      Keyword.merge(
        [
          dimensions: {800, 400},
          outer_inset: 20,
          internal_inset: 20,
          growth_step: 32,
          growth_steps: 2,
          map_cell_size: 16,
          font_caps: [36, 30],
          preferred_font: 36,
          min_font: 18,
          finalist_limit: 6,
          min_tile_samples: 12
        ],
        overrides
      )
    )
  end

  defp placement(align, valign) do
    %{
      bounding_box: [100, 600, 750, 950],
      text_align: align,
      vertical_align: valign,
      source: :model
    }
  end

  defp candidate(rect, align, valign) do
    %Candidate{
      id: "unsafe-seed",
      index: 0,
      rect: rect,
      align: align,
      valign: valign,
      min_font: 18,
      max_font: 36,
      inset: 20,
      origin: :seed
    }
  end

  defp checkerboard(width, height, cell) do
    rects =
      for y <- 0..(div(height, cell) - 1),
          x <- 0..(div(width, cell) - 1),
          rem(x + y, 2) == 0 do
        ~s(<rect x="#{x * cell}" y="#{y * cell}" width="#{cell}" height="#{cell}" fill="#000" />)
      end

    Image.from_svg!("""
    <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}">
      <rect width="100%" height="100%" fill="#fff" />
      #{Enum.join(rects)}
    </svg>
    """)
  end
end
