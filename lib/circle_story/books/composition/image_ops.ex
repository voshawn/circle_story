defmodule CircleStory.Books.Composition.ImageOps do
  @moduledoc """
  `image`/libvips wrappers for the pipeline: fill-crop resizing to exact print
  dimensions, PNG/data-URI encoding (for the HTML background), a softened average
  color (spine/back fill), and the file-path conventions for raw art, cached
  bounding boxes, and print-ready output.
  """

  @doc "Resize `image_or_path` to fill exactly `w` x `h`, center-cropping overflow."
  @spec fit(Vix.Vips.Image.t() | Path.t(), pos_integer(), pos_integer()) :: Vix.Vips.Image.t()
  def fit(image_or_path, w, h), do: Image.thumbnail!(image_or_path, "#{w}x#{h}", crop: :center)

  @doc "Encode an image to PNG bytes in memory."
  @spec to_png_bytes(Vix.Vips.Image.t()) :: binary()
  def to_png_bytes(image), do: Image.write!(image, :memory, suffix: ".png")

  @doc "Encode an image as a `data:image/png;base64,...` URI."
  @spec to_data_uri(Vix.Vips.Image.t()) :: String.t()
  def to_data_uri(image), do: "data:image/png;base64," <> Base.encode64(to_png_bytes(image))

  @doc "Mean color of `image` softened 60/40 toward white, as `[r, g, b]`."
  @spec softened_average(Vix.Vips.Image.t()) :: [non_neg_integer()]
  def softened_average(image) do
    image |> Image.average!() |> Enum.map(fn c -> round(c * 0.6 + 255 * 0.4) end)
  end

  @doc "Print-ready output path for a raw-art path (priv/print_ready/<basename>)."
  @spec print_ready_path(Path.t()) :: Path.t()
  def print_ready_path(raw_path) do
    dir = Path.join(:code.priv_dir(:circle_story), "print_ready")
    File.mkdir_p!(dir)
    Path.join(dir, Path.basename(raw_path))
  end

  @doc "Cached bounding-box JSON path for a raw-art path (<raw>.bbox.json)."
  @spec bbox_path(Path.t()) :: Path.t()
  def bbox_path(raw_path), do: Path.rootname(raw_path) <> ".bbox.json"

  @doc "Newest raw-art PNG in priv/generated_images whose basename starts with `prefix`."
  @spec latest_raw(String.t()) :: {:ok, Path.t()} | {:error, :no_raw_art}
  def latest_raw(prefix) do
    dir = Path.join(:code.priv_dir(:circle_story), "generated_images")

    case dir |> Path.join("#{prefix}*.png") |> Path.wildcard() |> Enum.sort() |> List.last() do
      nil -> {:error, :no_raw_art}
      path -> {:ok, path}
    end
  end
end
