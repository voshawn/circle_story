defmodule CircleStoryWeb.NaniEvaluationQualityPanelTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias CircleStory.Books.Composition.Quality.Attempts
  alias CircleStoryWeb.NaniEvaluationLive

  test "the panel explicitly identifies a below-threshold transparent fallback" do
    html =
      render_component(&NaniEvaluationLive.composition_quality/1, %{
        id: "composition-quality-inner-1",
        quality:
          quality(
            ink: :white,
            selection_outcome: "below_threshold_transparent_fallback",
            readability_thresholds_met: false,
            readability_rejections: ["local_contrast_percentile"],
            scored_count: 8,
            rejected_count: 8,
            attempts: %{
              transparent: %{
                kind: :transparent,
                scanned: 8,
                passed: 0,
                rejected: 8,
                rejection_reasons: %{
                  "local_contrast_percentile" => 6,
                  "local_contrast_fraction" => 2
                }
              }
            }
          )
      })

    assert html =~ "transparent white text"
    assert html =~ "Below preferred readability thresholds"
    assert html =~ "best geometry-safe transparent result published"
    assert html =~ "Selected threshold misses: local_contrast_percentile"
    assert html =~ "Transparent black/white attempts: 0/8 met thresholds"
    assert html =~ "local_contrast_percentile ×6"
    assert html =~ "local_contrast_fraction ×2"
    assert html =~ "8 scans"
    assert html =~ "8 variants missed preferred gates"
  end

  test "the panel identifies a preferred transparent threshold pass" do
    html =
      render_component(&NaniEvaluationLive.composition_quality/1, %{
        id: "composition-quality-inner-2",
        quality:
          quality(
            scored_count: 4,
            rejected_count: 3,
            attempts: %{
              transparent: %{
                kind: :transparent,
                scanned: 4,
                passed: 1,
                rejected: 3,
                rejection_reasons: %{"local_contrast_percentile" => 3}
              }
            }
          )
      })

    assert html =~ "transparent black text"
    assert html =~ "Preferred readability thresholds met"
    assert html =~ "Transparent black/white attempts: 1/4 met thresholds"
    refute html =~ "Selected threshold misses"
    refute html =~ "Mask render failures"
  end

  test "renderer faults that dropped a finalist mask are surfaced" do
    html =
      render_component(&NaniEvaluationLive.composition_quality/1, %{
        id: "composition-quality-inner-3",
        quality:
          quality(
            mask_render_errors: [
              %{candidate_id: "candidate-3", reason: "renderer_exit:timeout:GenServer:call"}
            ]
          )
      })

    assert html =~ "Mask render failures: candidate-3 (renderer_exit:timeout:GenServer:call)"
  end

  test "an all-finalists mask failure reads as a local browser fault, not page content" do
    page_text = "Nani wove her fierce love into every single thread"
    document = "<html><body>#{page_text}</body></html>"

    errors = [
      {"candidate-1",
       {:renderer_exit,
        {:timeout, {GenServer, :call, [self(), {:capture_screenshot, {:html, document}}, 5_000]}}}},
      {"candidate-2",
       {:renderer_exit,
        {:timeout, {GenServer, :call, [self(), {:capture_screenshot, {:html, document}}, 5_000]}}}},
      {"candidate-3", {:renderer_exception, ArgumentError, "raised over #{document}"}}
    ]

    entry = NaniEvaluationLive.error_entry({:composition_mask_render_failed, errors})

    assert entry.message ==
             "Text readability verification could not run because the local renderer failed. " <>
               "No composed page was published. Retry composition; if the problem continues, " <>
               "inspect the local Chrome renderer."

    assert entry.evidence =~ "renderer_exit:timeout:GenServer:call ×2"
    assert entry.evidence =~ "renderer_exception:ArgumentError ×1"
    refute entry.evidence =~ page_text
    refute entry.evidence =~ "<html"
  end

  test "quality failure evidence is sanitized instead of leaking raw renderer terms" do
    document = "<html><body>Nani wove her fierce love into every single thread</body></html>"

    details = %{
      role: :inner,
      candidates_tried: 4,
      variants_scored: 6,
      reason: :no_geometry_safe_transparent_candidate,
      transparent: %Attempts{
        kind: :transparent,
        scanned: 6,
        passed: 0,
        rejected: 6,
        rejection_reasons: %{
          {:image_binary_failed, "VipsJpeg: out of order read over #{document}"} => 1,
          {:image_binary_failed, :vips_closed} => 1,
          :local_contrast_percentile => 2,
          :glyph_effect_inset => 2
        }
      },
      mask_render_errors: [
        {"candidate-2", {:renderer_exception, ArgumentError, "raised over #{document}"}}
      ]
    }

    entry = NaniEvaluationLive.error_entry({:composition_quality_failed, details})

    assert entry.message =~ "No geometry-safe transparent black/white text candidate"
    assert entry.message =~ "0/6 met thresholds"
    assert entry.message =~ "image_binary_failed ×1"
    assert entry.message =~ "image_binary_failed:vips_closed ×1"
    assert entry.message =~ "local_contrast_percentile ×2"
    assert entry.message =~ "glyph_effect_inset ×2"
    assert entry.evidence == "renderer_exception:ArgumentError ×1"
    assert entry.evidence_label == "Composition diagnostics"
    refute entry.message =~ "VipsJpeg"
    refute entry.message =~ "<html"
    refute entry.evidence =~ "<html"
  end

  test "failures with no renderer diagnostics carry no evidence line" do
    entry = NaniEvaluationLive.error_entry({:composition_overflow, %{minimum_font: 18}})

    assert entry.message =~ "18px minimum"
    assert entry.evidence == nil
  end

  test "overflow evidence reports the fit geometry the page overran by" do
    page_text = "Nani wove her fierce love into every single thread"

    entry =
      NaniEvaluationLive.error_entry(
        {:composition_overflow,
         %{
           minimum_font: 18,
           closest_fit: %{
             candidate_id: "candidate-7",
             font_size: 18.0,
             line_count: 9,
             scroll_width: 612,
             scroll_height: 480,
             available_width: 600,
             available_height: 360,
             overflow_width: 12,
             overflow_height: 120
           }
         }}
      )

    assert entry.message =~ "18px minimum"
    assert entry.evidence_label == "Fit details"
    assert entry.evidence =~ "candidate-7"
    assert entry.evidence =~ "18.00px"
    assert entry.evidence =~ "12×120px"
    assert entry.evidence =~ "612×480px"
    assert entry.evidence =~ "600×360px"
    refute entry.evidence =~ page_text
  end

  test "content overflow is never labelled as a local renderer fault" do
    overflow =
      NaniEvaluationLive.error_entry(
        {:composition_overflow,
         %{
           minimum_font: 18,
           closest_fit: %{
             candidate_id: "candidate-7",
             font_size: 18.0,
             line_count: 9,
             scroll_width: 612,
             scroll_height: 480,
             available_width: 600,
             available_height: 360,
             overflow_width: 12,
             overflow_height: 120
           }
         }}
      )

    mask_render =
      NaniEvaluationLive.error_entry(
        {:composition_mask_render_failed,
         [{"candidate-1", {:renderer_exception, ArgumentError, "raised over the page"}}]}
      )

    measurement =
      NaniEvaluationLive.error_entry(
        {:composition_measurement_failed, {:renderer_exit, :timeout}}
      )

    without_evidence =
      NaniEvaluationLive.error_entry({:composition_overflow, %{minimum_font: 18}})

    assert overflow.evidence_label == "Fit details"
    assert mask_render.evidence_label == "Renderer diagnostics"
    assert measurement.evidence_label == "Renderer diagnostics"
    assert without_evidence.evidence_label == nil
  end

  test "a raw browser measurement fault is reported as a bounded class, not a raw term" do
    page_text = "Nani wove her fierce love into every single thread"
    document = "<html><body>#{page_text}</body></html>"

    reason =
      {:renderer_exit,
       {:timeout, {GenServer, :call, [self(), {:capture_screenshot, {:html, document}}, 5_000]}}}

    entry = NaniEvaluationLive.error_entry({:composition_measurement_failed, reason})

    assert entry.message =~ "local browser returned no usable text measurement"
    assert entry.evidence == "renderer_exit:timeout:GenServer:call"
    refute entry.message =~ page_text
    refute entry.evidence =~ page_text
    refute entry.evidence =~ "<html"
  end

  test "an unusable-measurement failure surfaces its bounded rejection classes" do
    entry =
      NaniEvaluationLive.error_entry(
        {:composition_measurement_failed,
         %{
           role: :inner,
           candidates_tried: 3,
           reason: :no_usable_measurement,
           rejection_reasons: %{unusable_measurement: 3}
         }}
      )

    assert entry.evidence == "unusable_measurement ×3"
  end

  test "an unrecognized failure reason is classed rather than inspected verbatim" do
    page_text = "Nani wove her fierce love into every single thread"

    entry =
      NaniEvaluationLive.error_entry(
        {:image_binary_failed, "VipsJpeg: out of order read over #{page_text}"}
      )

    assert entry.message == "Unexpected failure: image_binary_failed."
    refute entry.message =~ page_text
    refute entry.message =~ "VipsJpeg"
  end

  test "a legacy entry with no attempt evidence renders without crashing" do
    html =
      render_component(&NaniEvaluationLive.composition_quality/1, %{
        id: "composition-quality-inner-4",
        quality: Map.drop(quality(), [:attempts, :scored_count, :mask_render_errors])
      })

    assert html =~ "Transparent black/white attempts: no recorded evidence"
    assert html =~ "— scans"
  end

  # The decoded shape `Composition.cached_placement/1` hands the evaluation page.
  defp quality(overrides \\ []) do
    Map.merge(
      %{
        contract_version: "composition-quality-v2",
        candidate_id: "candidate-7",
        final_rect: %{x: 140, y: 160, w: 700, h: 320},
        adjustment: "translate_right",
        align: :center,
        valign: :top,
        font_size: 61.25,
        line_count: 4,
        glyph_bounds: %{x: 188, y: 208, w: 600, h: 220},
        effect_bounds: %{x: 188, y: 208, w: 600, h: 220},
        overflow: false,
        ink: :black,
        treatment: "none",
        selection_outcome: "threshold_pass",
        readability_thresholds_met: true,
        readability_rejections: [],
        metrics: %{
          worst_tile_p10: 6.2,
          worst_tile_low_contrast_fraction: 0.01,
          worst_line_p05: 7.1,
          edge_density: 0.03,
          soft_total: 10.5
        },
        candidate_count: 40,
        rejected_count: 5,
        scored_count: 12,
        attempts: %{
          transparent: %{
            kind: :transparent,
            scanned: 12,
            passed: 1,
            rejected: 11,
            rejection_reasons: %{}
          }
        },
        mask_render_errors: [],
        duration_ms: 8412.0
      },
      Map.new(overrides)
    )
  end
end
