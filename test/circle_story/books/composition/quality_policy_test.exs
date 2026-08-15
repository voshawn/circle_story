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

  defmodule OverflowingMeasurementRenderer do
    @moduledoc false
    @behaviour CircleStory.Books.Composition.Quality.Renderer

    # One candidate the browser could not measure at all; every other candidate
    # measured cleanly and genuinely overflows its box.
    @impl true
    def measure([unusable | rest], _content, _role) do
      overflowing =
        rest
        |> Enum.with_index()
        |> Map.new(fn {candidate, index} ->
          {candidate.id,
           %{
             font_size: 24.0,
             line_count: 3,
             lines: [%{x: 0, y: 0, w: 10, h: 10}],
             overflow: true,
             clipped: false,
             scroll_width: 200,
             scroll_height: 300 + index * 10,
             available_width: 180,
             available_height: 180
           }}
        end)

      {:ok,
       Map.put(overflowing, unusable.id, %{
         font_size: nil,
         line_count: 1,
         lines: [],
         overflow: false,
         clipped: false
       })}
    end

    @impl true
    def mask(_candidate, _content, _role), do: {:error, :not_used}
  end

  defmodule GeometrylessOverflowRenderer do
    @moduledoc false
    @behaviour CircleStory.Books.Composition.Quality.Renderer

    # A renderer that overflows without reporting any fit geometry, which is
    # what a legacy or non-Chrome measurement source looks like.
    @impl true
    def measure(candidates, _content, _role) do
      {:ok,
       Map.new(
         candidates,
         &{&1.id,
          %{
            font_size: 24.0,
            line_count: 3,
            lines: [%{x: 0, y: 0, w: 10, h: 10}],
            overflow: true,
            clipped: false
          }}
       )}
    end

    @impl true
    def mask(_candidate, _content, _role), do: {:error, :not_used}
  end

  defmodule MaskFailureRenderer do
    @moduledoc false
    @behaviour CircleStory.Books.Composition.Quality.Renderer

    @page_document "<html><body>Nani wove her fierce love into every thread</body></html>"

    def page_document, do: @page_document

    @impl true
    def measure(candidates, _content, _role) do
      {:ok,
       Map.new(
         candidates,
         &{&1.id,
          %{
            font_size: 24.0,
            line_count: 1,
            lines: [%{x: 10, y: 10, w: &1.rect.w - 20, h: 30}],
            overflow: false,
            clipped: false
          }}
       )}
    end

    # The shape a ChromicPDF call timeout actually exits with: the page document
    # rides along inside the `GenServer.call/3` argument list.
    @impl true
    def mask(_candidate, _content, _role) do
      {:error,
       {:renderer_exit,
        {:timeout,
         {GenServer, :call, [self(), {:capture_screenshot, {:html, @page_document}}, 5_000]}}}}
    end
  end

  defmodule ConvergedFitRenderer do
    @moduledoc false
    @behaviour CircleStory.Books.Composition.Quality.Renderer

    # Every font cap fits to the same size, which is exactly the case where
    # candidates that differ only in their cap describe one rendered layout.
    @impl true
    def measure(candidates, _content, _role) do
      {:ok,
       Map.new(
         candidates,
         &{&1.id,
          %{
            font_size: 24.0,
            line_count: 1,
            lines: [%{x: 10, y: 10, w: &1.rect.w - 20, h: 30}],
            overflow: false,
            clipped: false
          }}
       )}
    end

    @impl true
    def mask(_candidate, _content, _role), do: {:error, :not_used}
  end

  defmodule SolidMaskRenderer do
    @moduledoc false
    @behaviour CircleStory.Books.Composition.Quality.Renderer

    @impl true
    def measure(candidates, _content, _role) do
      {:ok,
       Map.new(
         candidates,
         &{&1.id, %{font_size: 40.0, line_count: 1, lines: [], overflow: false, clipped: false}}
       )}
    end

    @impl true
    def mask(candidate, _content, _role) do
      {:ok, Image.new!(candidate.rect.w, candidate.rect.h, color: :white)}
    end
  end

  alias CircleStory.Books.Composition.Layout
  alias CircleStory.Books.Composition.Quality

  alias CircleStory.Books.Composition.Quality.{
    Attempts,
    Candidate,
    Candidates,
    Context,
    Diagnostics,
    Geometry,
    Policy,
    Regions,
    Result,
    SafetyMap,
    Scorer,
    Selection
  }

  test "safety map keeps separate black and white readability evidence" do
    art =
      Image.new!(400, 200, color: :black)
      |> Image.compose!(Image.new!(200, 200, color: :white), x: 200, y: 0)

    policy = Policy.new(:cover, dimensions: {400, 200}, outer_inset: 0, map_cell_size: 20)
    map = safety_map(art, policy)

    dark_for_white = SafetyMap.summarize(map, %{x: 0, y: 0, w: 180, h: 200}, :white, policy)
    dark_for_black = SafetyMap.summarize(map, %{x: 0, y: 0, w: 180, h: 200}, :black, policy)
    light_for_black = SafetyMap.summarize(map, %{x: 220, y: 0, w: 180, h: 200}, :black, policy)

    assert dark_for_white.unsafe_fraction == 0.0
    assert dark_for_black.unsafe_fraction == 1.0
    assert light_for_black.unsafe_fraction == 0.0
  end

  test "safety map cells stay aligned to the art when the grid does not divide evenly" do
    art =
      Image.new!(401, 199, color: :black)
      |> Image.compose!(Image.new!(200, 199, color: :white), x: 201, y: 0)

    policy = Policy.new(:cover, dimensions: {401, 199}, outer_inset: 0, map_cell_size: 20)
    map = safety_map(art, policy)

    assert tuple_size(map.cells) == map.grid_w * map.grid_h

    dark_for_black = SafetyMap.summarize(map, %{x: 0, y: 0, w: 180, h: 199}, :black, policy)
    light_for_black = SafetyMap.summarize(map, %{x: 221, y: 0, w: 180, h: 199}, :black, policy)

    assert dark_for_black.unsafe_fraction == 1.0
    assert light_for_black.unsafe_fraction == 0.0
  end

  test "an unusable map cell size is a bounded geometry error, not an image fault" do
    art = Image.new!(400, 200, color: :black)
    policy = Policy.new(:cover, dimensions: {400, 200}, outer_inset: 0, map_cell_size: 0)

    assert SafetyMap.build(art, policy) ==
             {:error, {:safety_map_invalid_geometry, :cell_size}}
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

    map = safety_map(art, policy)
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
      safety_map: safety_map(art, policy)
    }

    assert {:ok, expanded} = Regions.expand(context)
    assert expanded.safe_canvas.x < seed.x
    assert expanded.safe_canvas.y < seed.y
    assert expanded.safe_canvas.x + expanded.safe_canvas.w > seed.x + seed.w
    assert expanded.safe_canvas.y + expanded.safe_canvas.h > seed.y + seed.h

    assert Map.keys(expanded.evidence.region_expansion) |> Enum.sort() ==
             [:down, :left, :right, :up]
  end

  test "a zero growth-step policy grows the canvas in no direction at all" do
    policy = test_policy(growth_steps: 0)
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
      safety_map: safety_map(art, policy)
    }

    assert {:ok, expanded} = Regions.expand(context)
    assert expanded.seed_rect == seed
    assert expanded.safe_canvas == seed
    assert Map.values(expanded.evidence.region_expansion) == [[], [], [], []]
  end

  test "finalist slots are never spent twice on font caps that fit the same layout" do
    policy =
      test_policy(
        candidate_transforms: [:seed, :translate],
        alignments: [:center],
        valignments: [:middle],
        font_caps: [36, 30, 24],
        finalist_limit: 3
      )

    seed = %{x: 520, y: 40, w: 160, h: 160}
    art = Image.new!(800, 400, color: :white)
    bounds = Policy.bounds_for_seed(policy, seed)

    context = %Context{
      image: art,
      content: %{text: "hello"},
      placement: placement(),
      seed_rect: seed,
      policy: policy,
      renderer: ConvergedFitRenderer,
      bounds: bounds,
      safe_canvas: bounds,
      safety_map: safety_map(art, policy)
    }

    assert {:ok, generated} = Candidates.generate(context)
    assert {:ok, measured} = Candidates.measure(generated)
    assert {:ok, preselected} = Candidates.select_finalists(measured)

    rect_count = measured.measured |> Enum.map(& &1.rect) |> Enum.uniq() |> length()
    assert length(measured.measured) == 3 * rect_count
    assert rect_count > policy.finalist_limit

    assert length(preselected.finalists) == policy.finalist_limit
    assert preselected.finalists |> Enum.map(& &1.rect) |> Enum.uniq() |> length() == 3
    assert preselected.finalists |> Enum.map(& &1.max_font) |> Enum.uniq() == [36]
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

    refute :local_contrast_percentile in scored.readability_rejections
    refute :local_contrast_fraction in scored.readability_rejections
    assert scored.metrics.overall_low_contrast_fraction < 0.01

    pressed = Scorer.score(art, %{candidate | id: "pressed", inset: 30}, mask, policy, :black)
    assert :glyph_inset in pressed.hard_rejections
  end

  # The tile with the weakest contrast percentile and the tile with the largest
  # low-contrast fraction are different tiles here, so a gate applied to only
  # one of them lets the other's unreadable pixels through.
  test "every tile is gated on its own low-contrast fraction, not the weakest tile's" do
    art =
      Image.new!(80, 40, color: :white)
      |> Image.compose!(Image.new!(8, 4, color: [90, 90, 90]), x: 0, y: 0)
      |> Image.compose!(Image.new!(16, 8, color: [105, 105, 105]), x: 0, y: 8)
      |> Image.compose!(Image.new!(14, 8, color: [90, 90, 90]), x: 40, y: 0)

    mask = Image.new!(80, 40, color: :white)

    policy =
      Policy.new(:cover,
        dimensions: {80, 40},
        outer_inset: 0,
        internal_inset: 0,
        min_tile_samples: 100,
        tile_size_ratio: 1.0,
        tile_stride_ratio: 1.0
      )

    candidate = %Candidate{
      id: "two-tiles",
      index: 0,
      rect: %{x: 0, y: 0, w: 80, h: 40},
      align: :left,
      valign: :middle,
      min_font: 18,
      max_font: 40,
      inset: 0,
      origin: :seed,
      measure: %{
        font_size: 40.0,
        line_count: 1,
        lines: [],
        overflow: false,
        clipped: false
      }
    }

    scored = Scorer.score(art, candidate, mask, policy, :black)

    assert scored.metrics.tile_count == 2
    assert scored.metrics.worst_tile_p10 >= policy.hard_contrast
    assert_in_delta scored.metrics.worst_tile_low_contrast_fraction, 0.07, 0.0001
    assert :local_contrast_fraction in scored.readability_rejections
    refute :local_contrast_percentile in scored.readability_rejections
    refute :line_contrast in scored.readability_rejections
  end

  # The scan threads its pixel index outside the sample accumulator, so the art
  # a glyph pixel is judged against must still be the art under its own x/y.
  test "glyph geometry and contrast follow the mask's actual position in the rect" do
    art =
      Image.new!(200, 100, color: :white)
      |> Image.compose!(Image.new!(100, 100, color: :black), x: 100, y: 0)

    mask =
      Image.new!(200, 100, color: :black)
      |> Image.compose!(Image.new!(60, 20, color: :white), x: 120, y: 40)

    candidate = %Candidate{
      id: "positioned",
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
        lines: [%{x: 120, y: 40, w: 60, h: 20}],
        overflow: false,
        clipped: false
      }
    }

    policy =
      Policy.new(:cover,
        dimensions: {200, 100},
        outer_inset: 0,
        internal_inset: 10,
        min_tile_samples: 12
      )

    white = Scorer.score(art, candidate, mask, policy, :white)

    assert white.glyph_bounds == %{x: 120, y: 40, w: 60, h: 20}
    assert white.metrics.glyph_samples == 60 * 20
    assert white.hard_rejections == []
    assert white.readability_rejections == []

    # The same glyph pixels sit entirely on the black half, so black ink there
    # must fail: proof the scan read that half of the art, not the white half.
    black = Scorer.score(art, candidate, mask, policy, :black)

    assert black.glyph_bounds == white.glyph_bounds
    assert :local_contrast_percentile in black.readability_rejections
  end

  test "non-negotiable geometry gates take precedence over favorable soft weights" do
    policy = test_policy(soft_weights: %{readability: 10_000.0})
    safe = evaluated_candidate("safe", 0, %{x: 520, y: 40, w: 160, h: 160}, 24, [])

    unsafe =
      evaluated_candidate(
        "unsafe",
        1,
        %{x: 520, y: 40, w: 160, h: 160},
        64,
        [:glyph_inset]
      )

    assert {:ok, selected} = Selection.choose([unsafe, safe], safe.rect, policy)
    assert selected.id == "safe"
  end

  test "a threshold-passing transparent candidate is always preferred over fallback evidence" do
    rect = %{x: 520, y: 40, w: 160, h: 160}
    preferred = evaluated_candidate("preferred", 1, rect, 24, [])

    below_threshold =
      evaluated_candidate("below-threshold", 0, rect, 64, [:local_contrast_fraction])
      |> put_readability_metrics(12.0, 0.08, 12.0, 0.0)

    assert {:ok, selected} =
             Selection.choose([below_threshold, preferred], rect, test_policy())

    assert selected.id == "preferred"
    assert selected.selection_outcome == :threshold_pass
  end

  test "transparent fallback uses glyph metrics, refuses geometry failures, and breaks ink ties" do
    rect = %{x: 520, y: 40, w: 160, h: 160}

    weaker =
      evaluated_candidate("weaker", 0, rect, 24, [:local_contrast_percentile])
      |> put_readability_metrics(2.0, 0.2, 2.2, 0.4)

    black =
      evaluated_candidate("tie", 1, rect, 24, [:local_contrast_fraction])
      |> put_readability_metrics(2.8, 0.08, 2.9, 0.1)

    white = %{black | ink: :white}

    geometry_failure =
      evaluated_candidate("clipped", 2, rect, 24, [:glyph_inset])
      |> put_readability_metrics(20.0, 0.0, 20.0, 0.0)

    assert {:ok, selected} =
             Selection.choose([white, geometry_failure, weaker, black], rect, test_policy())

    assert selected.id == "tie"
    assert selected.ink == :black
    assert selected.selection_outcome == :below_threshold_transparent_fallback
    assert selected.hard_rejections == []
    assert selected.readability_rejections == [:local_contrast_fraction]
  end

  test "scan accounting and the selection outcome never contradict each other" do
    rect = %{x: 520, y: 40, w: 160, h: 160}
    policy = test_policy()

    scenarios = [
      [[]],
      [[:local_contrast_percentile]],
      [[:glyph_inset]],
      [[:glyph_inset], [:line_contrast]],
      [[:glyph_inset, :local_contrast_fraction]],
      [[:local_contrast_fraction], [], [:glyph_inset]]
    ]

    for rejection_sets <- scenarios do
      variants =
        rejection_sets
        |> Enum.with_index()
        |> Enum.map(fn {rejections, index} ->
          "v#{index}"
          |> evaluated_candidate(index, rect, 24, rejections)
          |> put_readability_metrics(2.5, 0.2, 2.6, 0.1)
        end)

      attempts = Attempts.summarize(:transparent, variants)
      assert attempts.scanned == length(variants)
      assert attempts.passed + attempts.rejected == attempts.scanned

      outcome =
        case Selection.choose(variants, rect, policy) do
          {:ok, selected} -> selected.selection_outcome
          {:error, reason} -> reason
        end

      if attempts.passed > 0 do
        assert outcome == :threshold_pass,
               "#{inspect(rejection_sets)} counted #{attempts.passed} passing scans " <>
                 "but selected #{inspect(outcome)}"
      else
        refute outcome == :threshold_pass,
               "#{inspect(rejection_sets)} counted no passing scan but selected a threshold pass"
      end
    end
  end

  test "finalist evaluation scans exactly black and white transparent ink" do
    rect = %{x: 0, y: 0, w: 60, h: 40}
    art = Image.new!(200, 100, color: [150, 150, 150])

    policy =
      Policy.new(:cover,
        dimensions: {200, 100},
        outer_inset: 0,
        internal_inset: 0,
        hard_contrast: 8.0,
        min_tile_samples: 100,
        tile_size_ratio: 1.0,
        tile_stride_ratio: 1.0,
        finalist_limit: 4
      )

    finalists = [scan_candidate("first", 0, rect), scan_candidate("second", 1, rect)]

    context = %Context{
      image: art,
      content: %{text: "hello"},
      placement: placement(),
      seed_rect: rect,
      policy: policy,
      renderer: SolidMaskRenderer,
      bounds: Policy.bounds_for_seed(policy, rect),
      candidates: finalists,
      finalists: finalists
    }

    assert {:ok, evaluated} = Quality.run_steps(context, [{Quality, :evaluate_finalists}])
    assert length(evaluated.evaluated) == 4

    assert evaluated.evaluated |> Enum.map(& &1.ink) |> Enum.frequencies() == %{
             black: 2,
             white: 2
           }

    assert Enum.all?(evaluated.evaluated, &(&1.hard_rejections == []))
    assert Enum.all?(evaluated.evaluated, &(&1.readability_rejections != []))

    assert {:ok, result} = Quality.select_candidate(evaluated)
    assert result.candidate.selection_outcome == :below_threshold_transparent_fallback
    assert result.scored_count == 4
    assert result.transparent.scanned == 4
    assert result.transparent.passed == 0
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
          edge_quietness: 0.0
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
          edge_quietness: 0.0
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
      safety_map: safety_map(art, policy)
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

    assert {:error, :no_geometry_safe_candidate} = Selection.choose([unscored], rect, policy)
  end

  test "an incomplete browser measurement is a rejection, not a raise" do
    assert {:ok, generated} = Candidates.generate(measurement_context(PartialMeasurementRenderer))
    assert length(generated.candidates) > 1

    assert {:error, {:composition_measurement_failed, details}} = Candidates.measure(generated)

    assert details.reason == :no_usable_measurement
    assert details.candidates_tried == length(generated.candidates)

    assert details.rejection_reasons == %{
             unusable_measurement: length(generated.candidates)
           }
  end

  test "content that genuinely cannot fit is still reported as overflow, with reasons" do
    assert {:ok, generated} =
             Candidates.generate(measurement_context(OverflowingMeasurementRenderer))

    assert {:error, {:composition_overflow, details}} = Candidates.measure(generated)

    assert details.reason == :no_candidate_fits_without_clipping
    assert details.minimum_font == 18
    assert details.rejection_reasons[:unusable_measurement] == 1
    assert details.rejection_reasons[:text_overflow] == length(generated.candidates) - 1
  end

  test "overflow details report how far the closest candidate overran, as numbers only" do
    assert {:ok, generated} =
             Candidates.generate(measurement_context(OverflowingMeasurementRenderer))

    assert {:error, {:composition_overflow, details}} = Candidates.measure(generated)

    # The unmeasurable candidate carries no geometry at all, so the closest fit
    # is the least-overflowing candidate the browser did measure.
    assert details.closest_fit == %{
             candidate_id: Enum.at(generated.candidates, 1).id,
             font_size: 24.0,
             line_count: 3,
             scroll_width: 200,
             scroll_height: 300,
             available_width: 180,
             available_height: 180,
             overflow_width: 20,
             overflow_height: 120
           }

    assert Enum.all?(Map.values(details.closest_fit), &(is_number(&1) or is_binary(&1)))
  end

  test "overflow details omit fit geometry when the browser reported none" do
    assert {:ok, generated} =
             Candidates.generate(measurement_context(GeometrylessOverflowRenderer))

    assert {:error, {:composition_overflow, details}} = Candidates.measure(generated)
    assert details.closest_fit == nil
    assert details.rejection_reasons[:text_overflow] == length(generated.candidates)
  end

  test "provenance keeps transparent attempt and fallback evidence JSON-safe" do
    rect = %{x: 520, y: 40, w: 160, h: 160}
    winner = evaluated_candidate("winner", 3, rect, 24, [])

    variants = [
      winner,
      evaluated_candidate("u0", 0, rect, 24, [:local_contrast_percentile]),
      evaluated_candidate("u1", 1, rect, 24, [:local_contrast_percentile]),
      evaluated_candidate("u2", 2, rect, 24, [:local_contrast_fraction]),
      evaluated_candidate("g1", 4, rect, 24, [:glyph_inset]),
      evaluated_candidate("g2", 5, rect, 24, [:glyph_inset])
    ]

    result = %Result{
      candidate: winner,
      contract_version: Policy.contract_version(),
      candidate_count: 12,
      rejected_count: 5,
      scored_count: 6,
      transparent: Attempts.summarize(:transparent, variants),
      mask_render_errors: [{"candidate-9", :mask_timeout}]
    }

    provenance = Result.provenance(result)

    assert provenance.scored_count == 6
    assert provenance.treatment == "none"
    assert provenance.selection_outcome == "threshold_pass"
    assert provenance.readability_thresholds_met

    assert provenance.attempts.transparent == %{
             scanned: 6,
             passed: 1,
             rejected: 5,
             rejection_reasons: %{
               "local_contrast_percentile" => 2,
               "local_contrast_fraction" => 1,
               "glyph_inset" => 2
             }
           }

    assert provenance.mask_render_errors == [
             %{candidate_id: "candidate-9", reason: "mask_timeout"}
           ]

    assert {:ok, encoded} = Jason.encode(provenance)
    assert %{"attempts" => %{"transparent" => %{"scanned" => 6}}} = Jason.decode!(encoded)
    refute encoded =~ "backing"
  end

  test "renderer and image-library faults persist as bounded classes, not their raw terms" do
    rect = %{x: 520, y: 40, w: 160, h: 160}
    page_text = "Nani wove her fierce love into every single thread"
    document = "<html><body>#{page_text}</body></html>"
    vips_detail = String.duplicate("VipsJpeg: out of order read at line 3; ", 60)
    other_vips_detail = String.duplicate("VipsJpeg: unable to load line 91; ", 60)

    result = %Result{
      candidate: evaluated_candidate("winner", 0, rect, 24, []),
      contract_version: Policy.contract_version(),
      candidate_count: 4,
      rejected_count: 2,
      scored_count: 3,
      transparent:
        Attempts.summarize(:transparent, [
          evaluated_candidate("winner", 0, rect, 24, []),
          evaluated_candidate("u0", 1, rect, 24, [{:image_binary_failed, vips_detail}]),
          evaluated_candidate("u1", 2, rect, 24, [{:image_binary_failed, other_vips_detail}])
        ]),
      mask_render_errors: [
        {"candidate-1",
         {:renderer_exit,
          {:timeout,
           {GenServer, :call, [self(), {:capture_screenshot, {:html, document}}, 5_000]}}}},
        {"candidate-2",
         {:renderer_exception, ArgumentError, "argument error raised over #{document}"}},
        {"candidate-3", document}
      ]
    }

    provenance = Result.provenance(result)

    assert provenance.mask_render_errors == [
             %{candidate_id: "candidate-1", reason: "renderer_exit:timeout:GenServer:call"},
             %{candidate_id: "candidate-2", reason: "renderer_exception:ArgumentError"},
             %{candidate_id: "candidate-3", reason: "string"}
           ]

    assert provenance.attempts.transparent.rejection_reasons == %{"image_binary_failed" => 2}

    assert {:ok, encoded} = Jason.encode(provenance)
    refute encoded =~ page_text
    refute encoded =~ "<html"
    refute encoded =~ "VipsJpeg"
  end

  test "every finalist mask failing is reported as a renderer fault with bounded reasons" do
    policy = test_policy(candidate_transforms: [:seed], finalist_limit: 2)
    seed = %{x: 520, y: 40, w: 220, h: 220}

    assert {:error, {:composition_mask_render_failed, errors}} =
             Quality.optimize(
               Image.new!(800, 400, color: :white),
               %{text: "hello"},
               placement(),
               seed,
               policy: policy,
               renderer: MaskFailureRenderer
             )

    assert errors != []

    classes = Enum.map(errors, fn {_id, reason} -> Diagnostics.reason_class(reason) end)
    assert Enum.uniq(classes) == ["renderer_exit:timeout:GenServer:call"]

    assert MaskFailureRenderer.page_document() =~ "Nani wove"
    refute Enum.any?(classes, &String.contains?(&1, "Nani"))
  end

  test "unlike raw reasons that share a class are summed, never overwritten" do
    rect = %{x: 520, y: 40, w: 160, h: 160}

    rejected = [
      evaluated_candidate("u0", 0, rect, 24, [{:image_binary_failed, "out of order read"}]),
      evaluated_candidate("u1", 1, rect, 24, [{:image_binary_failed, "unable to load line 91"}]),
      evaluated_candidate("u2", 2, rect, 24, [{:image_binary_failed, :vips_closed}]),
      evaluated_candidate("u3", 3, rect, 24, [:local_contrast_percentile])
    ]

    attempts = Attempts.summarize(:transparent, rejected)

    assert map_size(attempts.rejection_reasons) == 4
    assert attempts.rejected == 4

    provenance = Attempts.provenance(attempts)

    assert provenance.rejection_reasons == %{
             "image_binary_failed" => 2,
             "image_binary_failed:vips_closed" => 1,
             "local_contrast_percentile" => 1
           }

    assert provenance.rejection_reasons |> Map.values() |> Enum.sum() == provenance.rejected
  end

  test "a diagnostic class is capped in depth and in length" do
    assert Diagnostics.reason_class({:a, {:b, {:c, {:d, {:e, :f}}}}}) == "a:b:c:d"

    long = String.to_atom(String.duplicate("renderer_", 20))
    assert String.length(Diagnostics.reason_class({long, long})) == 96
  end

  test "cover geometry is derived from the front panel rather than restated" do
    front = Layout.front_region_local()
    policy = Policy.new(:cover)

    assert policy.dimensions == {front.w, front.h}

    bounds = Policy.bounds_for_seed(policy, %{x: 0, y: 0, w: front.w, h: front.h})
    assert Geometry.contains?(front, bounds)
  end

  defp measurement_context(renderer) do
    policy = test_policy(candidate_transforms: [:seed])
    seed = %{x: 520, y: 40, w: 220, h: 220}

    %Context{
      image: Image.new!(800, 400, color: :white),
      content: %{text: "hello"},
      placement: placement(),
      seed_rect: seed,
      policy: policy,
      renderer: renderer,
      bounds: Policy.bounds_for_seed(policy, seed),
      safe_canvas: Policy.bounds_for_seed(policy, seed)
    }
  end

  defp safety_map(art, policy) do
    assert {:ok, map} = SafetyMap.build(art, policy)
    map
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

  defp scan_candidate(id, index, rect) do
    %Candidate{
      id: id,
      index: index,
      rect: rect,
      align: :center,
      valign: :middle,
      min_font: 18,
      max_font: 40,
      inset: 0,
      origin: :seed,
      measure: %{
        font_size: 40.0,
        line_count: 1,
        lines: [],
        overflow: false,
        clipped: false
      },
      metrics: %{preferred_ink: :black}
    }
  end

  defp put_readability_metrics(candidate, tile, low_fraction, line, edge) do
    %{
      candidate
      | metrics: %{
          candidate.metrics
          | worst_tile_p10: tile,
            worst_tile_low_contrast_fraction: low_fraction,
            worst_line_p05: line,
            edge_density: edge
        }
    }
  end

  defp evaluated_candidate(id, index, rect, font_size, rejections) do
    {readability_rejections, hard_rejections} =
      Enum.split_with(rejections, &(&1 in Scorer.readability_reasons()))

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
      hard_rejections: hard_rejections,
      readability_rejections: readability_rejections,
      metrics: %{
        overall_p05: 6.0,
        overall_low_contrast_fraction: 0.0,
        worst_tile_p10: 6.0,
        worst_tile_low_contrast_fraction: 0.0,
        worst_line_p05: 6.0,
        worst_line_low_contrast_fraction: 0.0,
        edge_density: 0.0
      }
    }
  end
end
