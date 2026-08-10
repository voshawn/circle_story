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

  test "an old cache with no provenance loads as unknown", %{raw: raw} do
    File.write!(
      ImageOps.bbox_path(raw),
      Jason.encode!(%{
        "bounding_box" => [650, 100, 900, 900],
        "text_align" => "center",
        "vertical_align" => "middle"
      })
    )

    assert {:ok, %{source: :unknown}} = Composition.cached_placement(raw)
  end
end
