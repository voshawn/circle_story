defmodule CircleStory.Books.Composition.Quality.SafetyMap do
  @moduledoc """
  A low-resolution, deterministic readability map of fitted art.

  Every cell keeps separate black/white contrast plus a transparent local edge
  proxy. It guides bounded region search; finalist hard gates still use the
  actual full-resolution glyph mask.
  """

  alias CircleStory.Books.Composition.Luminance
  alias CircleStory.Books.Composition.Quality.Policy
  alias Vix.Vips.Image, as: VipsImage

  @enforce_keys [:cell_size, :grid_w, :grid_h, :image_w, :image_h, :cells]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @doc "Build black/white readability information from fitted art."
  @spec build(Vix.Vips.Image.t(), Policy.t()) :: t()
  def build(image, %Policy{} = policy) do
    image_w = Image.width(image)
    image_h = Image.height(image)
    grid_w = ceil_div(image_w, policy.map_cell_size)
    grid_h = ceil_div(image_h, policy.map_cell_size)

    sampled =
      image
      |> Image.to_colorspace!(:srgb)
      |> Image.thumbnail!("#{grid_w}x#{grid_h}", resize: :force)

    {:ok, binary} = VipsImage.write_to_binary(sampled)
    bands = Image.bands(sampled)

    luminances =
      for index <- 0..(grid_w * grid_h - 1) do
        offset = index * bands

        Luminance.relative([
          :binary.at(binary, offset),
          :binary.at(binary, offset + min(1, bands - 1)),
          :binary.at(binary, offset + min(2, bands - 1))
        ])
      end
      |> List.to_tuple()

    black_luminance = Luminance.relative([26, 26, 26])
    white_luminance = Luminance.relative([250, 250, 250])

    cells =
      for y <- 0..(grid_h - 1), x <- 0..(grid_w - 1) do
        luminance = elem(luminances, y * grid_w + x)
        edge = local_edge(luminances, x, y, grid_w, grid_h)

        %{
          luminance: luminance,
          black_contrast: Luminance.contrast_ratio(black_luminance, luminance),
          white_contrast: Luminance.contrast_ratio(white_luminance, luminance),
          edge: edge,
          # A deliberately modest attention proxy, not semantic subject/face detection.
          saliency: min(edge + local_deviation(luminances, x, y, grid_w, grid_h), 1.0)
        }
      end
      |> List.to_tuple()

    %__MODULE__{
      cell_size: policy.map_cell_size,
      grid_w: grid_w,
      grid_h: grid_h,
      image_w: image_w,
      image_h: image_h,
      cells: cells
    }
  end

  @doc "Summarize map cells beneath one or more pixel rects for a fixed ink."
  @spec summarize(t(), [map()] | map(), :black | :white, Policy.t()) :: map()
  def summarize(%__MODULE__{} = map, rects, ink, %Policy{} = policy) do
    cells =
      rects
      |> List.wrap()
      |> Enum.flat_map(&cells_for_rect(map, &1))

    cells = if cells == [], do: [cell_at(map, 0, 0)], else: cells
    contrast_key = if ink == :black, do: :black_contrast, else: :white_contrast
    count = length(cells)

    %{
      sample_count: count,
      unsafe_fraction:
        Enum.count(cells, &(Map.fetch!(&1, contrast_key) < policy.hard_contrast)) / count,
      edge_fraction: Enum.count(cells, &(&1.edge >= policy.edge_threshold)) / count,
      saliency_fraction: Enum.count(cells, &(&1.saliency >= policy.edge_threshold)) / count,
      mean_contrast: Enum.sum(Enum.map(cells, &Map.fetch!(&1, contrast_key))) / count,
      mean_edge: Enum.sum(Enum.map(cells, & &1.edge)) / count,
      mean_saliency: Enum.sum(Enum.map(cells, & &1.saliency)) / count
    }
  end

  @doc "Whether a newly exposed strip is safe enough to continue region growth."
  @spec passable_strip?(t(), map(), Policy.t()) :: {boolean(), map()}
  def passable_strip?(%__MODULE__{} = map, rect, %Policy{} = policy) do
    black = summarize(map, rect, :black, policy)
    white = summarize(map, rect, :white, policy)
    best = Enum.min_by([black, white], &{&1.unsafe_fraction, &1.edge_fraction})

    pass? =
      best.unsafe_fraction <= policy.max_unsafe_strip_fraction and
        best.edge_fraction <= policy.max_edge_strip_fraction and
        best.saliency_fraction <= policy.max_saliency_strip_fraction

    {pass?, %{black: black, white: white, best: best}}
  end

  defp cells_for_rect(map, %{x: x, y: y, w: width, h: height}) do
    x0 = grid_index(x, map.cell_size, map.grid_w)
    x1 = grid_index(x + max(width - 1, 0), map.cell_size, map.grid_w)
    y0 = grid_index(y, map.cell_size, map.grid_h)
    y1 = grid_index(y + max(height - 1, 0), map.cell_size, map.grid_h)

    for gy <- y0..y1, gx <- x0..x1, do: cell_at(map, gx, gy)
  end

  defp cell_at(map, x, y), do: elem(map.cells, y * map.grid_w + x)

  defp grid_index(pixel, cell_size, length) do
    pixel |> floor() |> max(0) |> div(cell_size) |> min(length - 1)
  end

  defp local_edge(luminances, x, y, width, height) do
    {left, right, up, down} = neighbors(luminances, x, y, width, height)
    (abs(right - left) + abs(down - up)) / 2
  end

  defp local_deviation(luminances, x, y, width, height) do
    {left, right, up, down} = neighbors(luminances, x, y, width, height)
    center = elem(luminances, y * width + x)
    abs(center - (left + right + up + down) / 4)
  end

  defp neighbors(luminances, x, y, width, height) do
    {
      elem(luminances, y * width + max(x - 1, 0)),
      elem(luminances, y * width + min(x + 1, width - 1)),
      elem(luminances, max(y - 1, 0) * width + x),
      elem(luminances, min(y + 1, height - 1) * width + x)
    }
  end

  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)
end
