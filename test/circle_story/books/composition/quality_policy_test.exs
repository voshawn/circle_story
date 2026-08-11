defmodule CircleStory.Books.Composition.QualityPolicyTest do
  use ExUnit.Case, async: true

  defmodule PartialMeasurementRenderer do
    @moduledoc false
    @behaviour CircleStory.Books.Composition.Quality.Renderer

    @impl true
    def measure(candidates, _content, _role) do
      {:ok,
       candidates
       |> Enum.drop(1)
       |> Map.new(
         &{&1.id,
          %{
            font_size: nil,
            line_count: 1,
            lines: [],
            overflow: false,
            clipped: false
          }}
       )}
    end

    @impl true
    def mask(_candidate, _content, _role), do: {:error, :not_used}
  end

  alias CircleStory.Books.Composition.Layout
  alias CircleStory.Books.Composition.Quality

  alias CircleStory.Books.Composition.Quality.{
    Candidate,
    Candidates,
    Context,
    Geometry,
    Policy,
    Regions,
    SafetyMap,
    Scorer,
    Selection
  }

  test "safety map keeps separate black and white readability evidence" do
    art =
      Image.new!(400, 200, color: :black)
      |> Image.compose!(Image.new!(200, 200, color: :white), x: 200, y: 0)

    policy = Policy.new(:cover, dimensions: {400, 200}, outer_inset: 0, map_cell_size: 20)
    map = SafetyMap.build(art, policy)

    dark_for_white = SafetyMap.summarize(map, %{x: 0, y: 0, w: 180, h: 200}, :white, policy)
    dark_for_black = SafetyMap.summarize(map, %{x: 0, y: 0, w: 180, h: 200}, :black, policy)
    light_for_black = SafetyMap.summarize(map, %{x: 220, y: 0, w: 180, h: 200}, :black, policy)

    assert dark_for_white.unsafe_fraction == 0.0
    assert dark_for_black.unsafe_fraction == 1.0
    assert light_for_black.unsafe_fraction == 0.0
  end

  test "gradient cells expose a transition rather than a misleading whole-region average" do
    art =
      Image.from_svg!("""
      <svg xmlns="http://www.w3.org/2000/svg" width="400" height="200">
        <defs>
          <linearGradient id="shade"><stop offset="0" stop-color="#000"/><stop offset="1" stop-color="#fff"/></linearGradient>
        </defs>
        <rect width="400" height="200" fill="url(#shade)"/>
      </svg>
      """)

    policy =
      Policy.new(:cover,
        dimensions: {400, 200},
        outer_inset: 0,
        map_cell_size: 10,
        edge_threshold: 0.01
      )

    map = SafetyMap.build(art, policy)
    full = SafetyMap.summarize(map, %{x: 0, y: 0, w: 400, h: 200}, :black, policy)

    assert full.unsafe_fraction > 0.1
    assert full.unsafe_fraction < 0.9
    assert full.edge_fraction > 0.0
  end

  test "the explicit configured step list can add or remove a composition step" do
    policy = test_policy()
    seed = %{x: 520, y: 40, w: 220, h: 220}

    context = %Context{
      image: Image.new!(800, 400, color: :white),
      content: %{text: "hello"},
      placement: placement(),
      seed_rect: seed,
      policy: policy,
      renderer: nil,
      bounds: Policy.bounds_for_seed(policy, seed)
    }

    assert {:ok, unchanged} = Quality.run_steps(context, [])
    assert unchanged.safety_map == nil

    assert {:ok, changed} =
             Quality.run_steps(context, [{Quality, :build_safety_map}])

    assert %SafetyMap{} = changed.safety_map
  end

  test "safe canvas growth checks and expands all four directions" do
    policy = test_policy(growth_steps: 1)
    seed = %{x: 520, y: 80, w: 180, h: 180}
    art = Image.new!(800, 400, color: :white)

    context = %Context{
      image: art,
      content: %{text: "hello"},
      placement: placement(),
      seed_rect: seed,
      policy: policy,
      renderer: nil,
      bounds: Policy.bounds_for_seed(policy, seed),
      safety_map: SafetyMap.build(art, policy)
    }

    assert {:ok, expanded} = Regions.expand(context)
    assert expanded.safe_canvas.x < seed.x
    assert expanded.safe_canvas.y < seed.y
    assert expanded.safe_canvas.x + expanded.safe_canvas.w > seed.x + seed.w
    assert expanded.safe_canvas.y + expanded.safe_canvas.h > seed.y + seed.h

    assert Map.keys(expanded.evidence.region_expansion) |> Enum.sort() ==
             [:down, :left, :right, :up]
  end

  test "candidate transforms are explicit and all generated rects obey the selected page/fold" do
    seed = %{x: 520, y: 40, w: 220, h: 220}
    base_policy = test_policy(candidate_transforms: [:seed])
    bounds = Policy.bounds_for_seed(base_policy, seed)

    base_context = %Context{
      image: Image.new!(800, 400, color: :white),
      content: %{text: "hello"},
      placement: placement(),
      seed_rect: seed,
      policy: base_policy,
      renderer: nil,
      bounds: bounds,
      safe_canvas: bounds
    }

    assert [{:seed, ^seed}] = Candidates.candidate_rects(base_context)

    expanded_policy =
      test_policy(candidate_transforms: [:seed, :grow, :translate, :wrap])

    rects = Candidates.candidate_rects(%{base_context | policy: expanded_policy})

    assert length(rects) > 1
    assert Enum.all?(rects, fn {_origin, rect} -> Geometry.contains?(bounds, rect) end)
    assert Enum.all?(rects, fn {_origin, rect} -> rect.x >= 400 end)
  end

  test "a fold-crossing seed is intersected with one page instead of consuming its maximum" do
    policy = test_policy()
    crossing = %{x: 100, y: 40, w: 600, h: 220}
    bounds = Policy.bounds_for_seed(policy, crossing)
    constrained = Geometry.intersection(crossing, bounds)

    assert constrained == %{x: 400, y: 40, w: 300, h: 220}
    assert constrained.w < bounds.w
    assert Geometry.contains?(bounds, constrained)
  end

  test "meaningful tile sample rules tolerate one isolated hostile pixel" do
    art =
      Image.new!(200, 100, color: :white)
      |> Image.compose!(Image.new!(1, 1, color: :black), x: 40, y: 50)

    mask =
      Image.new!(200, 100, color: :black)
      |> Image.compose!(Image.new!(160, 20, color: :white), x: 20, y: 40)

    candidate = %Candidate{
      id: "isolated-noise",
      index: 0,
      rect: %{x: 0, y: 0, w: 200, h: 100},
      align: :left,
      valign: :middle,
      min_font: 18,
      max_font: 24,
      inset: 10,
      origin: :seed,
      measure: %{
        font_size: 20.0,
        line_count: 1,
        lines: [%{x: 20, y: 40, w: 160, h: 20}],
        overflow: false,
        clipped: false
      }
    }

    policy =
      Policy.new(:cover,
        dimensions: {200, 100},
        outer_inset: 0,
        internal_inset: 10,
        min_tile_samples: 50
      )

    scored = Scorer.score(art, candidate, mask, policy, :black)

    refute :local_contrast_percentile in scored.hard_rejections
    refute :local_contrast_fraction in scored.hard_rejections
    assert scored.metrics.overall_low_contrast_fraction < 0.01

    pressed = Scorer.score(art, %{candidate | id: "pressed", inset: 30}, mask, policy, :black)
    assert :glyph_effect_inset in pressed.hard_rejections
  end

  test "hard gates take precedence over arbitrarily favorable soft weights" do
    policy = test_policy(soft_weights: %{readability: 10_000.0})
    safe = evaluated_candidate("safe", 0, %{x: 520, y: 40, w: 160, h: 160}, 24, [])

    unsafe =
      evaluated_candidate(
        "unsafe",
        1,
        %{x: 520, y: 40, w: 160, h: 160},
        64,
        [:local_contrast_percentile]
      )

    assert {:ok, selected} = Selection.choose([unsafe, safe], safe.rect, policy)
    assert selected.id == "safe"
  end

  test "soft weights can change ranking only among passing candidates" do
    seed = %{x: 520, y: 40, w: 100, h: 100}
    compact = evaluated_candidate("compact", 0, seed, 24, [])
    large_font = evaluated_candidate("large-font", 1, %{x: 500, y: 20, w: 200, h: 200}, 64, [])

    font_policy =
      test_policy(
        preferred_font: 64,
        soft_weights: %{
          readability: 0.0,
          font_size: 10.0,
          compactness: 0.0,
          seed_proximity: 0.0,
          whitespace_balance: 0.0,
          edge_quietness: 0.0,
          treatment_restraint: 0.0
        }
      )

    compact_policy =
      %{
        font_policy
        | soft_weights: %{font_policy.soft_weights | font_size: 0.0, compactness: 10.0}
      }

    assert {:ok, %{id: "large-font"}} =
             Selection.choose([compact, large_font], seed, font_policy)

    assert {:ok, %{id: "compact"}} =
             Selection.choose([compact, large_font], seed, compact_policy)
  end

  test "deterministic ties use candidate generation order" do
    policy =
      test_policy(
        soft_weights: %{
          readability: 0.0,
          font_size: 0.0,
          compactness: 0.0,
          seed_proximity: 0.0,
          whitespace_balance: 0.0,
          edge_quietness: 0.0,
          treatment_restraint: 0.0
        }
      )

    rect = %{x: 520, y: 40, w: 160, h: 160}
    first = evaluated_candidate("first", 0, rect, 32, [])
    second = evaluated_candidate("second", 1, rect, 32, [])

    assert {:ok, %{id: "first"}} = Selection.choose([second, first], rect, policy)
  end

  test "growth that clamps to the opposite edge still evaluates the art it absorbs" do
    art = art_with_hostile_band(800, 400, 16, 112, 144)

    policy =
      Policy.new(:cover,
        dimensions: {800, 400},
        outer_inset: 16,
        map_cell_size: 16,
        growth_step: 32,
        growth_steps: 1
      )

    seed = %{x: 16, y: 96, w: 96, h: 96}

    context = %Context{
      image: art,
      content: %{text: "hello"},
      placement: placement(),
      seed_rect: seed,
      policy: policy,
      renderer: nil,
      bounds: Policy.bounds_for_seed(policy, seed),
      safety_map: SafetyMap.build(art, policy)
    }

    assert seed.x == Policy.bounds_for_seed(policy, seed).x
    assert {:ok, expanded} = Regions.expand(context)

    assert expanded.safe_canvas.x + expanded.safe_canvas.w <= 112
    assert [%{pass: false}] = expanded.evidence.region_expansion.left

    assert Enum.any?(expanded.evidence.region_expansion.left, fn step ->
             Enum.any?(step.strips, &(&1.strip.x >= 112))
           end)
  end

  test "a candidate rejected before scoring is filtered out instead of ranked" do
    policy = test_policy()
    rect = %{x: 520, y: 40, w: 160, h: 160}
    passing = evaluated_candidate("passing", 1, rect, 24, [])

    unscored = %Candidate{
      id: "unscored",
      index: 0,
      rect: rect,
      align: :center,
      valign: :middle,
      min_font: 18,
      max_font: 64,
      inset: 20,
      origin: :seed,
      measure: %{
        font_size: 24.0,
        line_count: 1,
        lines: [],
        overflow: false,
        clipped: false
      },
      hard_rejections: [:mask_geometry_mismatch],
      metrics: %{
        preselection_score: 9.0,
        preferred_ink: :black,
        map_black: %{},
        map_white: %{}
      }
    }

    assert {:ok, %{id: "passing"}} = Selection.choose([unscored, passing], rect, policy)

    assert {:error, :no_candidate_passed_hard_gates} =
             Selection.choose([unscored], rect, policy)
  end

  test "an incomplete browser measurement is a rejection, not a raise" do
    policy = test_policy(candidate_transforms: [:seed])
    seed = %{x: 520, y: 40, w: 220, h: 220}

    context = %Context{
      image: Image.new!(800, 400, color: :white),
      content: %{text: "hello"},
      placement: placement(),
      seed_rect: seed,
      policy: policy,
      renderer: PartialMeasurementRenderer,
      bounds: Policy.bounds_for_seed(policy, seed),
      safe_canvas: Policy.bounds_for_seed(policy, seed)
    }

    assert {:ok, generated} = Candidates.generate(context)
    assert length(generated.candidates) > 1

    assert {:error, {:composition_overflow, %{reason: :no_candidate_fits_without_clipping}}} =
             Candidates.measure(generated)
  end

  test "cover geometry is derived from the front panel rather than restated" do
    front = Layout.front_region_local()
    policy = Policy.new(:cover)

    assert policy.dimensions == {front.w, front.h}

    bounds = Policy.bounds_for_seed(policy, %{x: 0, y: 0, w: front.w, h: front.h})
    assert Geometry.contains?(front, bounds)
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
          font_caps: [36],
          preferred_font: 36,
          min_font: 18,
          finalist_limit: 4,
          min_tile_samples: 12
        ],
        overrides
      )
    )
  end

  defp placement do
    %{
      bounding_box: [100, 650, 750, 950],
      text_align: :left,
      vertical_align: :top,
      source: :model
    }
  end

  # White art except an aligned black/white checkerboard band, which no ink can
  # read and which therefore must block any growth step that would absorb it.
  defp art_with_hostile_band(width, height, cell, band_x0, band_x1) do
    squares =
      for y <- 0..(div(height, cell) - 1),
          x <- div(band_x0, cell)..(div(band_x1, cell) - 1),
          rem(x + y, 2) == 0 do
        ~s(<rect x="#{x * cell}" y="#{y * cell}" width="#{cell}" height="#{cell}" fill="#000" />)
      end

    Image.from_svg!("""
    <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}">
      <rect width="100%" height="100%" fill="#fff" />
      #{Enum.join(squares)}
    </svg>
    """)
  end

  defp evaluated_candidate(id, index, rect, font_size, rejections) do
    %Candidate{
      id: id,
      index: index,
      rect: rect,
      align: :center,
      valign: :middle,
      min_font: 18,
      max_font: 64,
      inset: 20,
      origin: :seed,
      measure: %{
        font_size: font_size * 1.0,
        line_count: 1,
        lines: [%{x: 20, y: 20, w: rect.w - 40, h: rect.h - 40}],
        overflow: false,
        clipped: false
      },
      ink: :black,
      glyph_bounds: %{x: 20, y: 20, w: rect.w - 40, h: rect.h - 40},
      hard_rejections: rejections,
      metrics: %{
        worst_tile_p10: 6.0,
        worst_tile_low_contrast_fraction: 0.0,
        worst_line_p05: 6.0,
        edge_density: 0.0
      }
    }
  end
end
