defmodule CircleStory.Books.Composition.Quality.Geometry do
  @moduledoc "Pure rectangle operations for bounded deterministic composition search."

  @spec clamp_rect(map(), map()) :: map()
  def clamp_rect(rect, bounds) do
    width = rect.w |> min(bounds.w) |> max(1)
    height = rect.h |> min(bounds.h) |> max(1)
    x = rect.x |> max(bounds.x) |> min(bounds.x + bounds.w - width)
    y = rect.y |> max(bounds.y) |> min(bounds.y + bounds.h - height)
    %{x: round(x), y: round(y), w: round(width), h: round(height)}
  end

  @spec intersection(map(), map()) :: map() | nil
  def intersection(left, right) do
    x0 = max(left.x, right.x)
    y0 = max(left.y, right.y)
    x1 = min(left.x + left.w, right.x + right.w)
    y1 = min(left.y + left.h, right.y + right.h)

    if x1 > x0 and y1 > y0 do
      %{x: x0, y: y0, w: x1 - x0, h: y1 - y0}
    end
  end

  @spec contains?(map(), map()) :: boolean()
  def contains?(outer, inner) do
    inner.x >= outer.x and inner.y >= outer.y and
      inner.x + inner.w <= outer.x + outer.w and
      inner.y + inner.h <= outer.y + outer.h
  end

  @spec inset(map(), non_neg_integer()) :: map()
  def inset(rect, amount) do
    %{
      x: rect.x + amount,
      y: rect.y + amount,
      w: max(rect.w - 2 * amount, 1),
      h: max(rect.h - 2 * amount, 1)
    }
  end

  @spec translate(map(), integer(), integer(), map()) :: map()
  def translate(rect, dx, dy, bounds) do
    rect |> Map.update!(:x, &(&1 + dx)) |> Map.update!(:y, &(&1 + dy)) |> clamp_rect(bounds)
  end

  @spec resize_around_center(map(), number(), number(), map()) :: map()
  def resize_around_center(rect, width_factor, height_factor, bounds) do
    width = max(round(rect.w * width_factor), 1)
    height = max(round(rect.h * height_factor), 1)
    center_x = rect.x + rect.w / 2
    center_y = rect.y + rect.h / 2

    clamp_rect(
      %{x: round(center_x - width / 2), y: round(center_y - height / 2), w: width, h: height},
      bounds
    )
  end

  @spec extend(map(), atom(), non_neg_integer(), map()) :: map()
  def extend(rect, direction, amount, bounds) do
    candidate =
      case direction do
        :left -> %{rect | x: rect.x - amount, w: rect.w + amount}
        :right -> %{rect | w: rect.w + amount}
        :up -> %{rect | y: rect.y - amount, h: rect.h + amount}
        :down -> %{rect | h: rect.h + amount}
      end

    clamp_rect(candidate, bounds)
  end

  @spec distance(map(), map()) :: float()
  def distance(left, right) do
    left_center = {left.x + left.w / 2, left.y + left.h / 2}
    right_center = {right.x + right.w / 2, right.y + right.h / 2}
    {lx, ly} = left_center
    {rx, ry} = right_center
    :math.sqrt(:math.pow(lx - rx, 2) + :math.pow(ly - ry, 2))
  end

  @spec area(map()) :: pos_integer()
  def area(rect), do: max(rect.w * rect.h, 1)
end
