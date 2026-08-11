defmodule CircleStory.Books.CompositionPlacementProvenanceTest do
  use ExUnit.Case, async: true

  alias CircleStory.Books.Composition
  alias CircleStory.Books.Composition.ImageOps

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
      contract_version: "composition-quality-v1",
      candidate_id: "candidate-7",
      final_rect: %{x: 140, y: 160, w: 700, h: 320},
      adjustment: "translate_right",
      align: :center,
      valign: :top,
      font_size: 61.25,
      line_count: 4,
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
      rejected_count: 5
    }

    assert :ok = Composition.cache_placement(raw, box, quality)
    assert {:ok, cached} = Composition.cached_placement(raw)

    assert cached.composition_quality.contract_version == "composition-quality-v1"
    assert cached.composition_quality.final_rect == quality.final_rect
    assert cached.composition_quality.metrics.worst_tile_p10 == 6.2

    encoded = raw |> ImageOps.bbox_path() |> File.read!()
    refute encoded =~ "story_text"
    refute encoded =~ "image_path"
  end

  test "a superseded deterministic contract is invalidated on read", %{raw: raw} do
    box = %{
      bounding_box: [100, 120, 350, 460],
      text_align: :left,
      vertical_align: :top,
      source: :model
    }

    stale_quality = %{
      contract_version: "composition-quality-v0",
      candidate_id: "stale",
      final_rect: %{x: 1, y: 1, w: 1, h: 1}
    }

    assert :ok = Composition.cache_placement(raw, box, stale_quality)
    assert {:ok, %{composition_quality: nil}} = Composition.cached_placement(raw)
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
