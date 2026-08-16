defmodule CircleStory.Books.Composition.QualityTest do
  use ExUnit.Case, async: false

  alias CircleStory.Books.Composition.{Layout, Quality}

  alias CircleStory.Books.Composition.Quality.{
    BrowserRenderer,
    Candidate,
    Geometry,
    Policy,
    Result,
    Scorer
  }

  @story "With fierce love she built a successful business, became a professor, and wrote her own story."
  @neutral_text "Clear lines of type keep each sentence balanced, readable, and calm in open space for every reader."

  # Chrome takes a long nap between launch and its first DevTools reply on cold
  # CI machines, which blows through ChromicPDF's 5s pool defaults and fails
  # every renderer test with a checkout/init timeout. `warm_up/1` is the
  # library's documented mitigation; the raised timeouts cover the remaining
  # slack so these tests measure composition, not Chrome start-up latency.
  @pool_timeout 30_000

  # Ubuntu 23.10+ (so `ubuntu-latest` on GitHub Actions) ships
  # `kernel.apparmor_restrict_unprivileged_userns=1`, which blocks Chrome's
  # namespace sandbox: Chrome exits immediately and every renderer call fails
  # with ConnectionLostError. These tests only render our own local HTML, so
  # they launch Chrome sandbox-less on every platform to stay deterministic.
  @chrome_opts [no_sandbox: true]

  setup_all do
    {:ok, _stderr} = ChromicPDF.warm_up(@chrome_opts)

    start_supervised!(
      {ChromicPDF,
       @chrome_opts ++
         [
           session_pool: [
             timeout: @pool_timeout,
             init_timeout: @pool_timeout,
             checkout_timeout: @pool_timeout
           ]
         ]}
    )

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
    content = %{text: @neutral_text}
    unsafe = candidate(seed, :left, :top)

    assert {:ok, measurements} = BrowserRenderer.measure([unsafe], content, :inner)
    unsafe = %{unsafe | measure: Map.fetch!(measurements, unsafe.id)}
    assert {:ok, mask} = BrowserRenderer.mask(unsafe, content, :inner)
    scored_unsafe = Scorer.score(art, unsafe, mask, policy, :black)

    assert Enum.any?(scored_unsafe.readability_rejections, fn reason ->
             reason in [:local_contrast_percentile, :local_contrast_fraction]
           end)

    assert {:ok, result} = Quality.optimize(art, content, placement, seed, policy: policy)
    selected = result.candidate

    assert selected.hard_rejections == []
    assert selected.readability_rejections == []
    assert selected.selection_outcome == :threshold_pass
    assert selected.ink == :black
    assert selected.metrics.worst_tile_p10 >= policy.hard_contrast
    assert selected.metrics.worst_tile_low_contrast_fraction <= policy.max_low_contrast_fraction
    assert selected.origin in ["seed>wrap_80_center", "seed>wrap_80_right"]
    assert selected.rect.x > seed.x
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

  test "page-8-style bounded left wrap beats the centered detailed-art counterfactual" do
    normalized_seed = [650, 60, 930, 450]
    seed = Layout.denormalize(normalized_seed, Layout.inner_region())
    placement = placement(:left, :top) |> Map.put(:bounding_box, normalized_seed)
    detail_x = 1_340
    art = bounded_composition_art(detail_x)

    policy =
      Policy.new(:inner,
        candidate_transforms: [:wrap],
        rectangle_limit: 15,
        alignments: [:seed],
        valignments: [:seed],
        font_caps: [64],
        finalist_limit: 3
      )

    content = %{
      text:
        "Clear typography belongs in calm open space where every neutral sentence can wrap " <>
          "with steady rhythm and generous breathing room beside a field of abstract detail."
    }

    assert seed == %{x: 221, y: 1219, w: 1433, h: 525}
    left_wrap = Geometry.resize_within(seed, 0.8, 1.0, :left, :top)
    centered_wrap = Geometry.resize_within(seed, 0.8, 1.0, :center, :top)
    assert left_wrap == %{x: 221, y: 1219, w: 1146, h: 525}
    assert centered_wrap == %{x: 365, y: 1219, w: 1146, h: 525}
    assert centered_wrap.x + centered_wrap.w > detail_x

    centered = %{candidate(centered_wrap, :left, :top) | id: "centered-counterfactual"}
    assert {:ok, centered_measurements} = BrowserRenderer.measure([centered], content, :inner)
    centered = %{centered | measure: Map.fetch!(centered_measurements, centered.id)}
    assert {:ok, centered_mask} = BrowserRenderer.mask(centered, content, :inner)
    scored_centered = Scorer.score(art, centered, centered_mask, policy, :black)

    centered_glyph_right =
      centered.rect.x + scored_centered.glyph_bounds.x + scored_centered.glyph_bounds.w

    assert centered_glyph_right > detail_x
    assert scored_centered.readability_rejections != []

    assert {:ok, result} = Quality.optimize(art, content, placement, seed, policy: policy)
    selected = result.candidate
    bounds = Policy.bounds_for_seed(policy, seed)
    global_glyph_right = selected.rect.x + selected.glyph_bounds.x + selected.glyph_bounds.w
    global_glyph_bottom = selected.rect.y + selected.glyph_bounds.y + selected.glyph_bounds.h

    assert selected.origin == "seed>wrap_80_left"
    assert selected.rect == left_wrap
    assert selected.selection_outcome == :threshold_pass
    assert selected.ink == :black
    assert selected.hard_rejections == []
    assert selected.readability_rejections == []
    assert selected.measure.font_size >= policy.min_font
    refute selected.measure.overflow
    refute selected.measure.clipped
    assert selected.metrics.glyph_samples > 0
    assert Geometry.contains?(bounds, selected.rect)
    assert selected.rect.x >= policy.outer_inset
    assert selected.rect.x + selected.rect.w <= div(elem(policy.dimensions, 0), 2)
    assert selected.glyph_bounds.x >= selected.inset
    assert selected.glyph_bounds.y >= selected.inset
    assert global_glyph_right <= selected.rect.x + selected.rect.w - selected.inset
    assert global_glyph_bottom <= selected.rect.y + selected.rect.h - selected.inset
    assert global_glyph_right < detail_x
    assert result.candidate_count == 15
    assert result.scored_count <= 2 * policy.finalist_limit
    assert result.transparent.passed > 0

    provenance = Result.provenance(result)
    assert provenance.adjustment == "seed>wrap_80_left"
    assert provenance.contract_version == "composition-quality-v3"
    assert provenance.selection_outcome == "threshold_pass"
  end

  test "inverse light edge on dark art selects safe white text" do
    art =
      Image.new!(800, 400, color: :black)
      |> Image.compose!(Image.new!(60, 300, color: :white), x: 480, y: 40)

    policy = test_policy()
    seed = %{x: 480, y: 40, w: 280, h: 260}
    content = %{text: @neutral_text}

    assert {:ok, result} =
             Quality.optimize(art, content, placement(:left, :top), seed, policy: policy)

    assert result.candidate.hard_rejections == []
    assert result.candidate.ink == :white
    assert result.candidate.metrics.worst_tile_p10 >= policy.hard_contrast
    assert result.candidate.origin in ["seed>wrap_80_center", "seed>wrap_80_right"]
    assert result.candidate.rect.x > seed.x
  end

  test "busy mixed art publishes the best transparent fallback with contrast provenance" do
    art = checkerboard(800, 400, 24)
    policy = test_policy(candidate_transforms: [:seed], finalist_limit: 4)
    seed = %{x: 480, y: 40, w: 280, h: 260}

    assert {:ok, result} =
             Quality.optimize(art, %{text: @story}, placement(:center, :middle), seed,
               policy: policy
             )

    selected = result.candidate
    assert selected.ink in [:black, :white]
    assert selected.hard_rejections == []
    assert selected.readability_rejections != []
    assert selected.selection_outcome == :below_threshold_transparent_fallback
    assert result.scored_count > 0
    assert result.scored_count <= 2 * policy.finalist_limit
    assert result.transparent.scanned == result.scored_count
    assert result.transparent.passed == 0
    assert result.transparent.rejection_reasons != %{}
    assert result.rejected_count == result.transparent.rejected

    provenance = Result.provenance(result)
    assert provenance.treatment == "none"
    assert provenance.selection_outcome == "below_threshold_transparent_fallback"
    refute provenance.readability_thresholds_met
    assert provenance.readability_rejections != []
    assert is_number(provenance.metrics.worst_tile_p10)
    assert is_number(provenance.metrics.worst_tile_low_contrast_fraction)
    assert provenance.attempts.transparent.scanned == result.transparent.scanned
    assert provenance.attempts.transparent.passed == 0
    assert provenance.attempts.transparent.rejection_reasons != %{}
    assert {:ok, encoded} = Jason.encode(provenance)
    refute encoded =~ "backing"
  end

  test "a transparent threshold pass is selected without any additional scan phase" do
    art = Image.new!(800, 400, color: :white)
    policy = test_policy(candidate_transforms: [:seed], finalist_limit: 2)
    seed = %{x: 480, y: 40, w: 280, h: 260}

    assert {:ok, result} =
             Quality.optimize(art, %{text: @story}, placement(:center, :middle), seed,
               policy: policy
             )

    assert result.candidate.selection_outcome == :threshold_pass
    assert result.candidate.readability_rejections == []
    assert result.scored_count <= 2 * policy.finalist_limit
    assert result.transparent.passed > 0
    assert result.scored_count == result.transparent.scanned
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

  defp bounded_composition_art(detail_x) do
    {width, height} = Layout.inner_dims()
    detail_width = div(width, 2) - detail_x

    Image.from_svg!("""
    <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}">
      <defs>
        <linearGradient id="calm" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#fffdf8"/>
          <stop offset="1" stop-color="#f3efe6"/>
        </linearGradient>
        <pattern id="detail" width="24" height="24" patternUnits="userSpaceOnUse">
          <rect width="12" height="12" fill="#111827"/>
          <rect x="12" y="12" width="12" height="12" fill="#111827"/>
          <rect x="12" width="12" height="12" fill="#f8fafc"/>
          <rect y="12" width="12" height="12" fill="#f8fafc"/>
        </pattern>
      </defs>
      <rect width="100%" height="100%" fill="url(#calm)"/>
      <rect x="#{detail_x}" y="1120" width="#{detail_width}" height="643" rx="28" fill="url(#detail)"/>
      <circle cx="1560" cy="1040" r="90" fill="#d7c5a2"/>
      <path d="M1390 1090 C1480 980 1650 980 1780 1110" fill="none" stroke="#64748b" stroke-width="18"/>
    </svg>
    """)
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
