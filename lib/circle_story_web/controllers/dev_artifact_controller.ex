defmodule CircleStoryWeb.DevArtifactController do
  @moduledoc false

  use CircleStoryWeb, :controller

  @generated_pattern ~r/^(?:cover_front_\d+|inner_[1-9]_\d+|character_[a-z0-9_]*_[0-9a-f]{8}_\d+)\.png$/
  @print_ready_pattern ~r/^(?:cover_front_\d+|inner_[1-9]_\d+|dedication)\.png$/

  @roots %{
    "generated" => {"generated_images", @generated_pattern},
    "print-ready" => {"print_ready", @print_ready_pattern}
  }

  def show(conn, %{"root" => root, "basename" => basename} = params) do
    with {:ok, path} <- resolve_artifact(root, basename),
         {:ok, response} <- render_variant(path, Map.get(params, "variant", "full")) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_artifact(response)
    else
      _ -> send_resp(conn, :not_found, "Artifact not found")
    end
  end

  @doc false
  @spec resolve_artifact(String.t(), String.t(), keyword()) :: {:ok, Path.t()} | {:error, atom()}
  def resolve_artifact(root, basename, opts \\ [])

  def resolve_artifact(root, basename, opts) when is_binary(root) and is_binary(basename) do
    priv_dir = Keyword.get_lazy(opts, :priv_dir, fn -> :code.priv_dir(:circle_story) end)

    with {:ok, {directory, pattern}} <- Map.fetch(@roots, root),
         true <- Path.basename(basename) == basename,
         true <- Regex.match?(pattern, basename),
         base <- Path.expand(Path.join(to_string(priv_dir), directory)),
         path <- Path.expand(Path.join(base, basename)),
         true <- Path.dirname(path) == base,
         {:ok, %{type: :regular}} <- File.lstat(path) do
      {:ok, path}
    else
      _ -> {:error, :not_found}
    end
  end

  def resolve_artifact(_root, _basename, _opts), do: {:error, :not_found}

  defp render_variant(path, "full"), do: {:ok, {:file, path}}

  defp render_variant(path, "thumbnail") do
    try do
      thumbnail = Image.thumbnail!(path, "960x960")
      jpeg = Image.write!(thumbnail, :memory, suffix: ".jpg", quality: 82)
      {:ok, {:bytes, "image/jpeg", jpeg}}
    rescue
      _exception -> {:error, :invalid_image}
    end
  end

  defp render_variant(_path, _variant), do: {:error, :invalid_variant}

  defp send_artifact(conn, {:file, path}) do
    conn
    |> put_resp_content_type("image/png", nil)
    |> send_file(200, path)
  end

  defp send_artifact(conn, {:bytes, content_type, bytes}) do
    conn
    |> put_resp_content_type(content_type, nil)
    |> send_resp(200, bytes)
  end
end
