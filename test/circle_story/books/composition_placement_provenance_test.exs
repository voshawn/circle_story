defmodule CircleStory.Books.CompositionPlacementProvenanceTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Composition
  alias CircleStory.Books.Composition.ImageOps
  alias CircleStory.Books.Composition.Quality.{Attempts, Candidate, Policy, Result}

  @private_page_text "Nani wove her fierce love into every single thread"

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "circle_story_placement_provenance_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    raw = Path.join(dir, "inner_1_1786000100.png")
    File.write!(raw, "not read by this cache contract")
    on_exit(fn -> File.rm_rf(dir) end)
    %{raw: raw}
  end

  test "model and fallback provenance round-trip through the bbox cache", %{raw: raw} do
    for source <- [:model, :fallback] do
      box = %{
        bounding_box: [100, 120, 350, 460],
        text_align: :left,
        vertical_align: :top,
        source: source
      }

      assert :ok = Composition.cache_placement(raw, box)
      assert {:ok, cached} = Composition.cached_placement(raw)
      assert cached.source == source
      assert cached.bounding_box == box.bounding_box

      assert %{"source" => encoded_source} =
               raw |> ImageOps.bbox_path() |> File.read!() |> Jason.decode!()

      assert encoded_source == Atom.to_string(source)
    end
  end

  test "deterministic composition provenance round-trips without private content", %{raw: raw} do
    box = %{
      bounding_box: [100, 120, 350, 460],
      text_align: :left,
      vertical_align: :top,
      source: :model
    }

    quality = %{
      contract_version: Policy.contract_version(),
      candidate_id: "candidate-7",
      final_rect: %{x: 140, y: 160, w: 700, h: 320},
      adjustment: "translate_right",
      align: :center,
      valign: :top,
      font_size: 61.25,
      line_count: 4,
      overflow: false,
      ink: "black",
      treatment: "none",
      selection_outcome: "threshold_pass",
      readability_thresholds_met: true,
      readability_rejections: [],
      metrics: %{
        overall_p05: 6.2,
        overall_low_contrast_fraction: 0.01,
        worst_tile_p10: 6.2,
        worst_tile_low_contrast_fraction: 0.01,
        worst_line_p05: 7.1,
        edge_density: 0.03,
        soft_total: 10.5
      },
      candidate_count: 40,
      rejected_count: 5
    }

    assert :ok = Composition.cache_placement(raw, box, quality)
    assert {:ok, cached} = Composition.cached_placement(raw)

    assert cached.composition_quality.contract_version == Policy.contract_version()
    assert cached.composition_quality.final_rect == quality.final_rect
    assert cached.composition_quality.metrics.worst_tile_p10 == 6.2

    encoded = raw |> ImageOps.bbox_path() |> File.read!()
    refute encoded =~ "story_text"
    refute encoded =~ "image_path"
  end

  test "transparent attempt and below-threshold fallback evidence round-trip", %{raw: raw} do
    box = %{
      bounding_box: [100, 120, 350, 460],
      text_align: :left,
      vertical_align: :top,
      source: :model
    }

    assert :ok = Composition.cache_placement(raw, box, Result.provenance(fallback_result()))
    assert {:ok, cached} = Composition.cached_placement(raw)

    quality = cached.composition_quality
    assert quality.scored_count == 6

    assert quality.treatment == "none"
    assert quality.selection_outcome == "below_threshold_transparent_fallback"
    refute quality.readability_thresholds_met
    assert quality.readability_rejections == ["local_contrast_percentile"]

    assert quality.attempts.transparent == %{
             kind: :transparent,
             scanned: 6,
             passed: 0,
             rejected: 6,
             rejection_reasons: %{
               "local_contrast_percentile" => 5,
               "local_contrast_fraction" => 1
             }
           }

    assert quality.mask_render_errors == [
             %{candidate_id: "candidate-8", reason: "renderer_exit:timeout:GenServer:call"},
             %{candidate_id: "candidate-9", reason: "renderer_exception:ArgumentError"}
           ]

    encoded = raw |> ImageOps.bbox_path() |> File.read!()
    refute encoded =~ "story_text"
    refute encoded =~ "image_path"

    # The renderer terms behind those two failures both quoted the page document.
    refute encoded =~ @private_page_text
    refute encoded =~ "<html"
  end

  test "a superseded deterministic contract is invalidated on read", %{raw: raw} do
    box = %{
      bounding_box: [100, 120, 350, 460],
      text_align: :left,
      vertical_align: :top,
      source: :model
    }

    stale_quality = %{
      contract_version: "composition-quality-v1",
      candidate_id: "stale",
      final_rect: %{x: 1, y: 1, w: 1, h: 1}
    }

    assert :ok = Composition.cache_placement(raw, box, stale_quality)
    assert {:ok, %{composition_quality: nil}} = Composition.cached_placement(raw)
  end

  defp fallback_result do
    rect = %{x: 140, y: 160, w: 700, h: 320}

    winner =
      scored_candidate("winner", 4, rect, [:local_contrast_percentile])
      |> Map.put(:selection_outcome, :below_threshold_transparent_fallback)

    %Result{
      candidate: winner,
      contract_version: Policy.contract_version(),
      candidate_count: 40,
      rejected_count: 5,
      scored_count: 6,
      transparent:
        Attempts.summarize(:transparent, [
          winner,
          scored_candidate("u0", 0, rect, [:local_contrast_percentile]),
          scored_candidate("u1", 1, rect, [:local_contrast_percentile]),
          scored_candidate("u2", 2, rect, [:local_contrast_percentile]),
          scored_candidate("u3", 3, rect, [:local_contrast_percentile]),
          scored_candidate("u5", 5, rect, [:local_contrast_fraction])
        ]),
      mask_render_errors: [
        {"candidate-8", renderer_exit_quoting_the_page()},
        {"candidate-9",
         {:renderer_exception, ArgumentError,
          "no function clause matching for #{page_document()}"}}
      ]
    }
  end

  # The shape a ChromicPDF call timeout actually exits with: the whole
  # `GenServer.call/3` argument list, page document included.
  defp renderer_exit_quoting_the_page do
    {:renderer_exit,
     {:timeout,
      {GenServer, :call, [self(), {:capture_screenshot, {:html, page_document()}}, 5_000]}}}
  end

  defp page_document, do: "<html><body>#{@private_page_text}</body></html>"

  defp scored_candidate(id, index, rect, readability_rejections) do
    %Candidate{
      id: id,
      index: index,
      rect: rect,
      align: :center,
      valign: :top,
      min_font: 24,
      max_font: 64,
      inset: 48,
      origin: :translate_right,
      measure: %{
        font_size: 61.25,
        line_count: 1,
        lines: [%{x: 48, y: 48, w: 600, h: 220}],
        overflow: false,
        clipped: false
      },
      ink: :black,
      glyph_bounds: %{x: 48, y: 48, w: 600, h: 220},
      readability_rejections: readability_rejections,
      metrics: %{
        overall_p05: 6.2,
        overall_low_contrast_fraction: 0.01,
        worst_tile_p10: 6.2,
        worst_tile_low_contrast_fraction: 0.01,
        worst_line_p05: 7.1,
        worst_line_low_contrast_fraction: 0.01,
        edge_density: 0.03
      },
      soft_total: 10.5
    }
  end

  test "an old cache with no provenance loads as unknown", %{raw: raw} do
    File.write!(
      ImageOps.bbox_path(raw),
      Jason.encode!(%{
        "bounding_box" => [650, 100, 900, 900],
        "text_align" => "center",
        "vertical_align" => "middle"
      })
    )

    assert {:ok, %{source: :unknown, composition_quality: nil}} =
             Composition.cached_placement(raw)
  end
end
