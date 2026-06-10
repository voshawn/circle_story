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

  ## Options

  Because page text is scaled to *fill* its box, a stingy box from the model
  produces tiny text. These options floor the box size (as a fraction of the
  region) so the box grows — centered on its current center, capped by the safe
  area — to at least the minimum:

    * `:min_w_frac` — minimum width as a fraction of `region.w` (default `0.0`)
    * `:min_h_frac` — minimum height as a fraction of `region.h` (default `0.0`)
  """
  @spec denormalize([number()], map(), keyword()) :: %{
          x: integer(),
          y: integer(),
          w: integer(),
          h: integer()
        }
  def denormalize([ymin, xmin, ymax, xmax], region, opts \\ []) do
    x0 = region.x + min(xmin, xmax) / 1000 * region.w
    x1 = region.x + max(xmin, xmax) / 1000 * region.w
    y0 = region.y + min(ymin, ymax) / 1000 * region.h
    y1 = region.y + max(ymin, ymax) / 1000 * region.h

    sx0 = region.x + @safe_inset
    sx1 = region.x + region.w - @safe_inset
    sy0 = region.y + @safe_inset
    sy1 = region.y + region.h - @safe_inset

    min_w = Keyword.get(opts, :min_w_frac, 0.0) * region.w
    min_h = Keyword.get(opts, :min_h_frac, 0.0) * region.h

    {cx0, cx1} = clamp_span(x0, x1, sx0, sx1, min_w)
    {cy0, cy1} = clamp_span(y0, y1, sy0, sy1, min_h)

    %{x: round(cx0), y: round(cy0), w: max(round(cx1 - cx0), 1), h: max(round(cy1 - cy0), 1)}
  end

  # Clamp [lo, hi] into [bound_lo, bound_hi], then grow it (centered on its
  # current center, shifted to stay in bounds) to at least `min_size`, capped by
  # the available span.
  defp clamp_span(lo, hi, bound_lo, bound_hi, min_size) do
    lo = clamp(lo, bound_lo, bound_hi)
    hi = clamp(hi, bound_lo, bound_hi)
    size = hi - lo
    target = min_size |> min(bound_hi - bound_lo) |> max(size)

    if target <= size do
      {lo, hi}
    else
      center = (lo + hi) / 2
      half = target / 2

      cond do
        center - half < bound_lo -> {bound_lo, bound_lo + target}
        center + half > bound_hi -> {bound_hi - target, bound_hi}
        true -> {center - half, center + half}
      end
    end
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end
