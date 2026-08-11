defmodule CircleStoryWeb.DevArtifactControllerTest do
  use ExUnit.Case, async: false

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

  test "serves a thumbnail when an artifact version query is present" do
    dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
    basename = "inner_9_99#{System.unique_integer([:positive])}.png"
    path = Path.join(dir, basename)

    File.mkdir_p!(dir)
    Image.write!(Image.new!(8, 8, color: :blue), path)
    on_exit(fn -> File.rm(path) end)

    conn =
      :get
      |> Plug.Test.conn("/dev/books/nani/artifacts/generated/#{basename}")
      |> DevArtifactController.show(%{
        "root" => "generated",
        "basename" => basename,
        "variant" => "thumbnail",
        "v" => "1786417847-1234"
      })

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert <<0xFF, 0xD8, _rest::binary>> = conn.resp_body
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
