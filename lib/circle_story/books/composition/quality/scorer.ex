defmodule CircleStory.Books.Composition.Quality.Scorer do
  @moduledoc "Full-resolution hard readability gates over actual browser-rendered glyph masks."

  alias CircleStory.Books.Composition.Luminance
  alias CircleStory.Books.Composition.Quality.{Candidate, ImageRead, Policy}
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @core_threshold 128

  @spec score(
          Vix.Vips.Image.t(),
          Candidate.t(),
          Vix.Vips.Image.t(),
          Policy.t(),
          atom(),
          map() | nil
        ) ::
          Candidate.t()
  def score(art, %Candidate{} = candidate, mask, %Policy{} = policy, ink, treatment \\ nil)
      when ink in [:black, :white] do
    with {:ok, art_binary, mask_binary} <- binaries(art, candidate.rect, mask) do
      tile_size = max(round(candidate.measure.font_size * policy.tile_size_ratio), 16)
      tile_stride = max(round(tile_size * policy.tile_stride_ratio), 1)
      ink_luminance = ink |> Luminance.rgb() |> Luminance.relative()

      samples =
        scan(
          mask_binary,
          art_binary,
          candidate.rect.w,
          candidate.rect.h,
          candidate.measure.lines,
          tile_size,
          tile_stride,
          ink_luminance,
          treatment,
          policy.edge_threshold,
          0,
          empty_samples()
        )

      put_score(candidate, samples, policy, ink, treatment)
    else
      {:error, reason} ->
        %{candidate | ink: ink, treatment: treatment, hard_rejections: [reason]}
    end
  end

  defp binaries(art, rect, mask) do
    ImageRead.guard(fn ->
      art_crop =
        art
        |> Image.crop!(rect.x, rect.y, rect.w, rect.h)
        |> normalize_rgb()

      mask_band =
        mask
        |> normalize_rgb()
        |> Operation.extract_band!(0)

      with true <- Image.width(mask_band) == rect.w and Image.height(mask_band) == rect.h,
           {:ok, art_binary} <- ImageRead.write_to_binary(art_crop),
           {:ok, mask_binary} <- ImageRead.write_to_binary(mask_band) do
        {:ok, art_binary, mask_binary}
      else
        false -> {:error, :mask_geometry_mismatch}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # Raw binary reads below assume exactly one byte per band, so the source art
  # format (a 16-bit PNG, say) is cast rather than trusted.
  defp normalize_rgb(image) do
    image =
      image
      |> Image.to_colorspace!(:srgb)
      |> Operation.cast!(:VIPS_FORMAT_UCHAR)

    if VipsImage.bands(image) > 3 do
      Operation.extract_band!(image, 0, n: 3)
    else
      image
    end
  end

  defp empty_samples do
    %{
      count: 0,
      all: [],
      lines: %{},
      tiles: %{},
      edge_count: 0,
      min_x: nil,
      min_y: nil,
      max_x: nil,
      max_y: nil
    }
  end

  defp scan(
         <<>>,
         <<>>,
         _width,
         _height,
         _lines,
         _tile_size,
         _tile_stride,
         _ink_luminance,
         _treatment,
         _edge_threshold,
         _index,
         state
       ),
       do: state

  # The pixel index is threaded as a plain argument: every pixel of the rect
  # walks this clause, and most fall below the core threshold, so it must not
  # cost a copy of the sample accumulator.
  defp scan(
         <<mask, mask_rest::binary>>,
         <<red, green, blue, art_rest::binary>> = art_binary,
         width,
         height,
         lines,
         tile_size,
         tile_stride,
         ink_luminance,
         treatment,
         edge_threshold,
         index,
         state
       ) do
    x = rem(index, width)
    y = div(index, width)

    state =
      if mask >= @core_threshold do
        background = effective_background([red, green, blue], treatment)
        contrast = Luminance.contrast_ratio(ink_luminance, Luminance.relative(background))
        edge? = edge_pixel?(art_binary, x, y, width, height, edge_threshold)
        line = line_index(lines, x, y)
        tile_keys = tile_keys(x, y, tile_size, tile_stride)

        state
        |> Map.update!(:count, &(&1 + 1))
        |> Map.update!(:all, &[contrast | &1])
        |> Map.update!(:edge_count, &(&1 + if(edge?, do: 1, else: 0)))
        |> put_group(:lines, line, contrast)
        |> put_groups(:tiles, tile_keys, contrast)
        |> update_bounds(x, y)
      else
        state
      end

    scan(
      mask_rest,
      art_rest,
      width,
      height,
      lines,
      tile_size,
      tile_stride,
      ink_luminance,
      treatment,
      edge_threshold,
      index + 1,
      state
    )
  end

  defp edge_pixel?(_remaining_art, x, y, width, height, _threshold)
       when x == 0 or y == 0 or x == width - 1 or y == height - 1,
       do: false

  defp edge_pixel?(remaining_art, _x, _y, width, _height, threshold) do
    # `remaining_art` begins at the current pixel. Right/down are available in
    # this suffix; left/up are represented by the corresponding negative offset
    # into the full crop, so use a forward central proxy (right + down). This is
    # only transparent secondary evidence, never a hard contrast override.
    current = relative_at(remaining_art, 0)
    right = relative_at(remaining_art, 3)
    down = relative_at(remaining_art, width * 3)
    (abs(right - current) + abs(down - current)) / 2 >= threshold
  end

  defp relative_at(binary, offset) do
    Luminance.relative([
      :binary.at(binary, offset),
      :binary.at(binary, offset + 1),
      :binary.at(binary, offset + 2)
    ])
  end

  defp effective_background(rgb, nil), do: rgb

  defp effective_background(rgb, %{type: :backing, color: color, opacity: opacity}) do
    Enum.zip_with(rgb, Luminance.rgb(color), fn source, overlay ->
      round(source * (1 - opacity) + overlay * opacity)
    end)
  end

  defp line_index(lines, x, y) do
    Enum.find_index(lines, fn line ->
      x >= line.x - 1 and x <= line.x + line.w + 1 and
        y >= line.y - 1 and y <= line.y + line.h + 1
    end) || :unassigned
  end

  defp tile_keys(x, y, tile_size, stride) do
    xs = tile_origins(x, tile_size, stride)
    ys = tile_origins(y, tile_size, stride)
    for tile_x <- xs, tile_y <- ys, do: {tile_x, tile_y}
  end

  defp tile_origins(coordinate, tile_size, stride) do
    latest = div(coordinate, stride) * stride
    earliest = max(coordinate - tile_size + 1, 0)

    latest
    |> Stream.iterate(&(&1 - stride))
    |> Enum.take_while(&(&1 >= earliest))
  end

  defp put_group(state, key, group, contrast) do
    Map.update!(
      state,
      key,
      &Map.update(&1, group, [contrast], fn values -> [contrast | values] end)
    )
  end

  defp put_groups(state, key, groups, contrast) do
    Enum.reduce(groups, state, &put_group(&2, key, &1, contrast))
  end

  defp update_bounds(state, x, y) do
    state
    |> Map.update!(:min_x, &if(is_nil(&1), do: x, else: min(&1, x)))
    |> Map.update!(:min_y, &if(is_nil(&1), do: y, else: min(&1, y)))
    |> Map.update!(:max_x, &if(is_nil(&1), do: x, else: max(&1, x)))
    |> Map.update!(:max_y, &if(is_nil(&1), do: y, else: max(&1, y)))
  end

  defp put_score(candidate, %{count: 0}, _policy, ink, treatment) do
    %{
      candidate
      | ink: ink,
        treatment: treatment,
        hard_rejections: [:empty_glyph_mask],
        metrics: Map.put(candidate.metrics, :glyph_samples, 0)
    }
  end

  defp put_score(candidate, samples, policy, ink, treatment) do
    all_summary = summarize(samples.all, policy)

    tile_summaries =
      samples.tiles
      |> Enum.filter(fn {_tile, values} -> length(values) >= policy.min_tile_samples end)
      |> Enum.map(fn {tile, values} -> Map.put(summarize(values, policy), :tile, tile) end)

    tile_summaries =
      if tile_summaries == [], do: [Map.put(all_summary, :tile, :all)], else: tile_summaries

    line_summaries =
      samples.lines
      |> Enum.reject(fn {line, _values} -> line == :unassigned end)
      |> Enum.map(fn {line, values} -> Map.put(summarize(values, policy), :line, line) end)

    line_summaries =
      if line_summaries == [], do: [Map.put(all_summary, :line, :all)], else: line_summaries

    worst_tile = Enum.min_by(tile_summaries, &{&1.p10, -&1.low_fraction})
    worst_tile_fraction = Enum.max_by(tile_summaries, &{&1.low_fraction, -&1.p10})
    worst_line = Enum.min_by(line_summaries, &{&1.p05, -&1.low_fraction})
    worst_line_fraction = Enum.max_by(line_summaries, &{&1.low_fraction, -&1.p05})

    glyph_bounds = %{
      x: samples.min_x,
      y: samples.min_y,
      w: samples.max_x - samples.min_x + 1,
      h: samples.max_y - samples.min_y + 1
    }

    rejections =
      candidate.hard_rejections
      |> reject_if(worst_tile.p10 < policy.hard_contrast, :local_contrast_percentile)
      |> reject_if(
        worst_tile_fraction.low_fraction > policy.max_low_contrast_fraction,
        :local_contrast_fraction
      )
      |> reject_if(worst_line.p05 < policy.hard_contrast, :line_contrast)
      |> reject_if(not glyph_within_inset?(glyph_bounds, candidate), :glyph_effect_inset)

    metrics =
      candidate.metrics
      |> Map.merge(%{
        glyph_samples: samples.count,
        overall_p05: all_summary.p05,
        overall_low_contrast_fraction: all_summary.low_fraction,
        worst_tile_p10: worst_tile.p10,
        worst_tile_low_contrast_fraction: worst_tile_fraction.low_fraction,
        worst_line_p05: worst_line.p05,
        worst_line_low_contrast_fraction: worst_line_fraction.low_fraction,
        edge_density: samples.edge_count / samples.count,
        tile_count: length(tile_summaries),
        line_count: length(line_summaries)
      })

    %{
      candidate
      | ink: ink,
        treatment: treatment,
        glyph_bounds: glyph_bounds,
        hard_rejections: Enum.uniq(rejections),
        metrics: metrics
    }
  end

  defp summarize(contrasts, policy) do
    sorted = Enum.sort(contrasts)
    count = length(sorted)

    %{
      p05: percentile(sorted, count, 0.05),
      p10: percentile(sorted, count, 0.10),
      low_fraction: Enum.count(sorted, &(&1 < policy.hard_contrast)) / count,
      count: count
    }
  end

  defp percentile(sorted, count, fraction) do
    Enum.at(sorted, floor((count - 1) * fraction))
  end

  defp glyph_within_inset?(bounds, candidate) do
    tolerance = 2
    inset = max(candidate.inset - tolerance, 0)

    bounds.x >= inset and bounds.y >= inset and
      bounds.x + bounds.w <= candidate.rect.w - inset and
      bounds.y + bounds.h <= candidate.rect.h - inset
  end

  defp reject_if(reasons, true, reason), do: [reason | reasons]
  defp reject_if(reasons, false, _reason), do: reasons
end
