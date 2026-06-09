defmodule CircleStory.Books.Composition.Layout do
  @moduledoc """
  Pure print geometry: canvas/panel dimensions, the text-safe inset, and mapping
  a Gemini bounding box (normalized to 1000x1000, `[ymin, xmin, ymax, xmax]`)
  into clamped pixel coordinates within a target region.

  A "region" is `%{x:, y:, w:, h:}`; `denormalize/2` returns a pixel "rect" of the
  same shape (used as CSS left/top/width/height).
  """

  @inner_w 3675
  @inner_h 1875
  @cover_w 3863
  @cover_h 1875
  @panel 1875
  @spine 113
  @safe_inset 112

  def inner_dims, do: {@inner_w, @inner_h}
  def cover_dims, do: {@cover_w, @cover_h}
  def safe_inset, do: @safe_inset

  def back_panel, do: %{x: 0, y: 0, w: @panel, h: @panel}
  def spine_panel, do: %{x: @panel, y: 0, w: @spine, h: @panel}
  def front_panel, do: %{x: @panel + @spine, y: 0, w: @panel, h: @panel}

  def inner_region, do: %{x: 0, y: 0, w: @inner_w, h: @inner_h}

  @doc "Front-cover region in panel-local coordinates (origin 0,0) for luminance + in-panel text positioning."
  def front_region_local, do: %{x: 0, y: 0, w: @panel, h: @panel}

  @doc "Left/right page split x of an inner spread (the fold)."
  def inner_half, do: div(@inner_w, 2) - 1

  @doc """
  Map a normalized `[ymin, xmin, ymax, xmax]` box into a pixel rect within
  `region`, clamped so the whole rect stays inside the safe inset. Inverted
  coordinates are normalized.
  """
  @spec denormalize([number()], map()) :: %{x: integer(), y: integer(), w: integer(), h: integer()}
  def denormalize([ymin, xmin, ymax, xmax], region) do
    x0 = region.x + min(xmin, xmax) / 1000 * region.w
    x1 = region.x + max(xmin, xmax) / 1000 * region.w
    y0 = region.y + min(ymin, ymax) / 1000 * region.h
    y1 = region.y + max(ymin, ymax) / 1000 * region.h

    sx0 = region.x + @safe_inset
    sx1 = region.x + region.w - @safe_inset
    sy0 = region.y + @safe_inset
    sy1 = region.y + region.h - @safe_inset

    cx0 = clamp(x0, sx0, sx1)
    cx1 = clamp(x1, sx0, sx1)
    cy0 = clamp(y0, sy0, sy1)
    cy1 = clamp(y1, sy0, sy1)

    %{x: round(cx0), y: round(cy0), w: max(round(cx1 - cx0), 1), h: max(round(cy1 - cy0), 1)}
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end
