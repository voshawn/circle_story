defmodule CircleStoryWeb.NaniEvaluationQualityPanelTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias CircleStoryWeb.NaniEvaluationLive

  test "the panel reports untreated ink and backing attempts as separate evidence" do
    html =
      render_component(&NaniEvaluationLive.composition_quality/1, %{
        id: "composition-quality-inner-1",
        quality:
          quality(
            treatment: "white_backing_44",
            scored_count: 16,
            rejected_count: 15,
            attempts: %{
              untreated: %{
                kind: :untreated,
                scanned: 8,
                passed: 0,
                rejected: 8,
                rejection_reasons: %{"local_contrast_percentile" => 6, "edge_density" => 2}
              },
              treated: %{
                kind: :treated,
                scanned: 8,
                passed: 1,
                rejected: 7,
                rejection_reasons: %{"local_contrast_fraction" => 7}
              }
            }
          )
      })

    assert html =~ "white_backing_44"
    assert html =~ "Untreated ink: 0/8 passed"
    assert html =~ "local_contrast_percentile ×6"
    assert html =~ "edge_density ×2"
    assert html =~ "Backing attempts: 1/8 passed"
    assert html =~ "local_contrast_fraction ×7"
    assert html =~ "16 scans"
    assert html =~ "15 rejected variants"
  end

  test "a page that needed no backing says so instead of implying an untried treatment" do
    html =
      render_component(&NaniEvaluationLive.composition_quality/1, %{
        id: "composition-quality-inner-2",
        quality:
          quality(
            scored_count: 4,
            rejected_count: 3,
            attempts: %{
              untreated: %{
                kind: :untreated,
                scanned: 4,
                passed: 1,
                rejected: 3,
                rejection_reasons: %{"local_contrast_percentile" => 3}
              },
              treated: %{
                kind: :treated,
                scanned: 0,
                passed: 0,
                rejected: 0,
                rejection_reasons: %{}
              }
            }
          )
      })

    assert html =~ "Untreated ink: 1/4 passed"
    assert html =~ "Backing attempts: none scanned"
    refute html =~ "Mask render failures"
  end

  test "renderer faults that dropped a finalist mask are surfaced" do
    html =
      render_component(&NaniEvaluationLive.composition_quality/1, %{
        id: "composition-quality-inner-3",
        quality:
          quality(mask_render_errors: [%{candidate_id: "candidate-3", reason: ":mask_timeout"}])
      })

    assert html =~ "Mask render failures: candidate-3 (:mask_timeout)"
  end

  test "a legacy entry with no attempt evidence renders without crashing" do
    html =
      render_component(&NaniEvaluationLive.composition_quality/1, %{
        id: "composition-quality-inner-4",
        quality: Map.drop(quality(), [:attempts, :scored_count, :mask_render_errors])
      })

    assert html =~ "Untreated ink: no recorded evidence"
    assert html =~ "— scans"
  end

  # The decoded shape `Composition.cached_placement/1` hands the evaluation page.
  defp quality(overrides \\ []) do
    Map.merge(
      %{
        contract_version: "composition-quality-v1",
        candidate_id: "candidate-7",
        final_rect: %{x: 140, y: 160, w: 700, h: 320},
        adjustment: "translate_right",
        align: :center,
        valign: :top,
        font_size: 61.25,
        line_count: 4,
        glyph_bounds: %{x: 188, y: 208, w: 600, h: 220},
        effect_bounds: %{x: 140, y: 160, w: 700, h: 320},
        overflow: false,
        treatment: "none",
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
          untreated: %{
            kind: :untreated,
            scanned: 12,
            passed: 1,
            rejected: 11,
            rejection_reasons: %{}
          },
          treated: %{kind: :treated, scanned: 0, passed: 0, rejected: 0, rejection_reasons: %{}}
        },
        mask_render_errors: [],
        duration_ms: 8412.0
      },
      Map.new(overrides)
    )
  end
end
