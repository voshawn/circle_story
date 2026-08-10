defmodule CircleStoryWeb.DevArtifactControllerTest do
  use ExUnit.Case, async: true

  alias CircleStoryWeb.DevArtifactController

  setup do
    priv_dir =
      Path.join(
        System.tmp_dir!(),
        "circle_story_artifacts_#{System.unique_integer([:positive])}"
      )

    for directory <- ~w(generated_images print_ready source_images) do
      File.mkdir_p!(Path.join(priv_dir, directory))
    end

    generated = Path.join([priv_dir, "generated_images", "inner_1_1786000100.png"])
    composed = Path.join([priv_dir, "print_ready", "inner_1_1786000100.png"])
    source = Path.join([priv_dir, "source_images", "nani.png"])

    File.write!(generated, "generated")
    File.write!(composed, "composed")
    File.write!(source, "private source")
    on_exit(fn -> File.rm_rf(priv_dir) end)

    %{priv_dir: priv_dir, generated: generated, composed: composed, source: source}
  end

  test "serves only canonical allowlisted generated and print-ready basenames", context do
    assert {:ok, context.generated} ==
             DevArtifactController.resolve_artifact(
               "generated",
               "inner_1_1786000100.png",
               priv_dir: context.priv_dir
             )

    assert {:ok, context.composed} ==
             DevArtifactController.resolve_artifact(
               "print-ready",
               "inner_1_1786000100.png",
               priv_dir: context.priv_dir
             )

    assert {:error, :not_found} =
             DevArtifactController.resolve_artifact(
               "generated",
               "noise_src.png",
               priv_dir: context.priv_dir
             )
  end

  test "rejects traversal and never resolves the private source root", context do
    for {root, basename} <- [
          {"generated", "../source_images/nani.png"},
          {"generated", "..%2Fsource_images%2Fnani.png"},
          {"source_images", "nani.png"},
          {"source", "nani.png"}
        ] do
      assert {:error, :not_found} =
               DevArtifactController.resolve_artifact(root, basename, priv_dir: context.priv_dir)
    end
  end

  test "rejects an allowlisted-looking symlink instead of following it", context do
    symlink = Path.join([context.priv_dir, "generated_images", "inner_2_1786000100.png"])
    File.ln_s!(context.source, symlink)

    assert {:error, :not_found} =
             DevArtifactController.resolve_artifact(
               "generated",
               Path.basename(symlink),
               priv_dir: context.priv_dir
             )
  end
end
