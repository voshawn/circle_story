defmodule CircleStory.Books.Composition.Luminance do
  @moduledoc """
  Chooses black or white ink for legibility over artwork by sampling the mean
  color of the placement region. Favors black: regions brighter than 60%
  luminance get black, darker get white.
  """

  defmodule Srgb do
    @moduledoc false

    @doc "sRGB gamma expansion of one channel expressed on the 0..255 scale."
    @spec linear(number()) :: float()
    def linear(channel) do
      normalized = channel / 255

      if normalized <= 0.04045 do
        normalized / 12.92
      else
        :math.pow((normalized + 0.055) / 1.055, 2.4)
      end
    end
  end

  @threshold 153.0
  @black "#1A1A1A"
  @white "#FAFAFA"

  @linear_channels 0..255 |> Enum.map(&Srgb.linear/1) |> List.to_tuple()

  @doc "Rec. 709 luminance of an `[r, g, b]` (or `[r, g, b, a]`) pixel, 0..255."
  @spec luminance([number()]) :: float()
  def luminance([r, g, b | _]), do: 0.2126 * r + 0.7152 * g + 0.0722 * b

  @doc "Relative sRGB luminance (0.0..1.0) for contrast calculations."
  @spec relative([number()]) :: float()
  def relative([r, g, b | _]) do
    0.2126 * linear_channel(r) + 0.7152 * linear_channel(g) + 0.0722 * linear_channel(b)
  end

  @doc "WCAG-style contrast ratio between two relative luminances."
  @spec contrast_ratio(number(), number()) :: float()
  def contrast_ratio(left, right) do
    (max(left, right) + 0.05) / (min(left, right) + 0.05)
  end

  @doc "`:black` for light pixels, `:white` for dark pixels."
  @spec color_for([number()]) :: :black | :white
  def color_for(rgb) when is_list(rgb) do
    if luminance(rgb) >= @threshold, do: :black, else: :white
  end

  @doc "Ink hex for a chosen color."
  @spec hex(:black | :white) :: String.t()
  def hex(:black), do: @black
  def hex(:white), do: @white

  defp linear_channel(channel) when is_integer(channel) and channel >= 0 and channel <= 255,
    do: elem(@linear_channels, channel)

  defp linear_channel(channel), do: Srgb.linear(channel)
end
