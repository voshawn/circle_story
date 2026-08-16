defmodule CircleStory.Books.Composition.Quality.Candidates do
  @moduledoc "Finite role-aware generation, browser-fit measurement, and finalist preselection."

  alias CircleStory.Books.Composition.Quality.{Candidate, Context, Geometry, SafetyMap}

  @depth_two_per_family_limit 1

  @wrap_operations [
    {"wrap_80_left", 0.8, 1.0, :left, :top},
    {"wrap_80_center", 0.8, 1.0, :center, :top},
    {"wrap_80_right", 0.8, 1.0, :right, :top},
    {"wrap_90_left", 0.9, 1.0, :left, :top},
    {"wrap_90_center", 0.9, 1.0, :center, :top},
    {"wrap_90_right", 0.9, 1.0, :right, :top},
    {"compact_90_left_top", 0.9, 0.9, :left, :top},
    {"compact_90_left_middle", 0.9, 0.9, :left, :middle},
    {"compact_90_left_bottom", 0.9, 0.9, :left, :bottom},
    {"compact_90_center_top", 0.9, 0.9, :center, :top},
    {"compact_90_center_middle", 0.9, 0.9, :center, :middle},
    {"compact_90_center_bottom", 0.9, 0.9, :center, :bottom},
    {"compact_90_right_top", 0.9, 0.9, :right, :top},
    {"compact_90_right_middle", 0.9, 0.9, :right, :middle},
    {"compact_90_right_bottom", 0.9, 0.9, :right, :bottom}
  ]

  @spec generate(Context.t()) :: {:ok, Context.t()}
  def generate(%Context{} = context) do
    rects = candidate_rects(context)
    alignments = resolve_values(context.policy.alignments, context.placement.text_align)
    valignments = resolve_values(context.policy.valignments, context.placement.vertical_align)

    candidates =
      for {origin, rect} <- rects,
          align <- alignments,
          valign <- valignments,
          max_font <- context.policy.font_caps do
        {origin, rect, align, valign, max_font}
      end
      |> Enum.with_index()
      |> Enum.map(fn {{origin, rect, align, valign, max_font}, index} ->
        %Candidate{
          id: "candidate-#{index}",
          index: index,
          rect: rect,
          align: align,
          valign: valign,
          min_font: context.policy.min_font,
          max_font: max(max_font, context.policy.min_font),
          inset: context.policy.internal_inset,
          origin: origin
        }
      end)

    {:ok, %{context | candidates: candidates}}
  end

  @spec measure(Context.t()) :: {:ok, Context.t()} | {:error, term()}
  def measure(%Context{} = context) do
    case context.renderer.measure(context.candidates, context.content, context.policy.role) do
      {:ok, measurements} ->
        measured =
          Enum.map(context.candidates, fn candidate ->
            measure = Map.get(measurements, candidate.id)
            rejections = fit_rejections(candidate, measure, context)
            %{candidate | measure: measure, hard_rejections: rejections}
          end)

        fitting = Enum.filter(measured, &(&1.hard_rejections == []))

        cond do
          fitting != [] -> {:ok, %{context | measured: measured}}
          unusable?(measured) -> {:error, unusable_measurement_error(measured, context)}
          true -> {:error, overflow_error(measured, context)}
        end

      {:error, reason} ->
        {:error, {:composition_measurement_failed, reason}}
    end
  end

  # A page whose text genuinely cannot fit and a browser that returned nothing
  # usable are different faults with different operator responses, so they are
  # never reported under the same reason. Rejection frequencies travel with both.
  defp unusable?(measured),
    do: Enum.all?(measured, &(&1.hard_rejections == [:unusable_measurement]))

  defp unusable_measurement_error(measured, context) do
    {:composition_measurement_failed,
     %{
       role: context.policy.role,
       candidates_tried: length(measured),
       reason: :no_usable_measurement,
       rejection_reasons: rejection_reasons(measured)
     }}
  end

  defp overflow_error(measured, context) do
    {:composition_overflow,
     %{
       role: context.policy.role,
       minimum_font: context.policy.min_font,
       candidates_tried: length(measured),
       reason: :no_candidate_fits_without_clipping,
       rejection_reasons: rejection_reasons(measured),
       closest_fit: closest_fit(measured)
     }}
  end

  # Overflow evidence carries only the browser's own numbers — the box a
  # candidate had, the box its text wanted, and the derived deltas — so an
  # operator can see how far the page overran. No story text is ever included,
  # and the candidate reported is the one that came closest to fitting.
  defp closest_fit(measured) do
    case Enum.filter(measured, &(geometry(&1.measure) != nil)) do
      [] -> nil
      candidates -> candidates |> Enum.min_by(&{overflow_extent(&1), &1.index}) |> fit_evidence()
    end
  end

  defp geometry(%{
         scroll_width: scroll_width,
         scroll_height: scroll_height,
         available_width: available_width,
         available_height: available_height
       })
       when is_number(scroll_width) and is_number(scroll_height) and
              is_number(available_width) and is_number(available_height) do
    %{
      scroll_width: round(scroll_width),
      scroll_height: round(scroll_height),
      available_width: round(available_width),
      available_height: round(available_height),
      overflow_width: max(round(scroll_width - available_width), 0),
      overflow_height: max(round(scroll_height - available_height), 0)
    }
  end

  defp geometry(_measure), do: nil

  defp overflow_extent(candidate) do
    %{overflow_width: width, overflow_height: height} = geometry(candidate.measure)
    width + height
  end

  defp fit_evidence(candidate) do
    candidate.measure
    |> geometry()
    |> Map.merge(%{
      candidate_id: candidate.id,
      font_size: number_or_nil(candidate.measure.font_size),
      line_count: number_or_nil(candidate.measure.line_count)
    })
  end

  defp number_or_nil(value) when is_number(value), do: value
  defp number_or_nil(_value), do: nil

  defp rejection_reasons(measured) do
    measured |> Enum.flat_map(& &1.hard_rejections) |> Enum.frequencies()
  end

  @spec select_finalists(Context.t()) :: {:ok, Context.t()}
  def select_finalists(%Context{} = context) do
    finalists =
      context.measured
      |> Enum.filter(&(&1.hard_rejections == []))
      |> Enum.uniq_by(&layout_key/1)
      |> Enum.map(&put_preselection_evidence(&1, context))
      |> Enum.sort_by(&{-&1.metrics.preselection_score, &1.index})
      |> Enum.take(context.policy.finalist_limit)

    {:ok, %{context | finalists: finalists}}
  end

  # Distinct font caps that the browser fits to the same size describe the same
  # rendered layout, so only the earliest of them may occupy a finalist slot.
  defp layout_key(candidate) do
    {candidate.rect, candidate.align, candidate.valign,
     Float.round(candidate.measure.font_size * 1.0, 2)}
  end

  @doc false
  @spec candidate_rects(Context.t()) :: [{atom() | String.t(), map()}]
  def candidate_rects(%Context{} = context) do
    transforms = context.policy.candidate_transforms
    seed_base = [{:seed, context.seed_rect}]
    growth = if :grow in transforms, do: growth_rects(context), else: []
    translations = if :translate in transforms, do: translated_rects(context), else: []

    baseline =
      []
      |> maybe_add(:seed in transforms, seed_base)
      |> Kernel.++(growth)
      |> Kernel.++(translations)

    {seed_wrapped, composable} =
      if :wrap in transforms do
        {Enum.to_list(wrap_chains(seed_base)), [growth, translations]}
      else
        {[], []}
      end

    baseline
    |> Kernel.++(seed_wrapped)
    |> deduplicate_rects()
    |> compose_families(composable)
    |> Enum.take(context.policy.rectangle_limit)
  end

  defp compose_families(generated, families) do
    seen = MapSet.new(generated, fn {_origin, rect} -> rect_key(rect) end)

    {_seen, composed} =
      Enum.reduce(families, {seen, []}, fn bases, {family_seen, acc} ->
        {family_seen, chains} =
          take_novel_chains(bases, family_seen, @depth_two_per_family_limit)

        {family_seen, acc ++ chains}
      end)

    generated ++ composed
  end

  defp take_novel_chains(_bases, seen, limit) when limit <= 0, do: {seen, []}

  defp take_novel_chains(bases, seen, limit) do
    bases
    |> wrap_chains()
    |> Enum.reduce_while({seen, []}, fn {label, rect}, {chain_seen, acc} ->
      key = rect_key(rect)

      cond do
        MapSet.member?(chain_seen, key) ->
          {:cont, {chain_seen, acc}}

        length(acc) + 1 < limit ->
          {:cont, {MapSet.put(chain_seen, key), acc ++ [{label, rect}]}}

        true ->
          {:halt, {MapSet.put(chain_seen, key), acc ++ [{label, rect}]}}
      end
    end)
  end

  defp growth_rects(context) do
    seed = context.seed_rect
    canvas = context.safe_canvas
    step = context.policy.growth_step

    left = Geometry.extend(seed, :left, step, canvas)
    right = Geometry.extend(seed, :right, step, canvas)
    up = Geometry.extend(seed, :up, step, canvas)
    down = Geometry.extend(seed, :down, step, canvas)

    horizontal = Geometry.extend(left, :right, step, canvas)
    vertical = Geometry.extend(up, :down, step, canvas)

    all =
      vertical
      |> Geometry.extend(:left, step, canvas)
      |> Geometry.extend(:right, step, canvas)

    [
      {:grow_left, left},
      {:grow_right, right},
      {:grow_up, up},
      {:grow_down, down},
      {:grow_horizontal, horizontal},
      {:grow_vertical, vertical},
      {:grow_all, all},
      {:safe_canvas, canvas}
    ]
  end

  defp translated_rects(context) do
    step = context.policy.growth_step
    bounds = context.safe_canvas
    seed = context.seed_rect

    [
      {:translate_left, Geometry.translate(seed, -step, 0, bounds)},
      {:translate_right, Geometry.translate(seed, step, 0, bounds)},
      {:translate_up, Geometry.translate(seed, 0, -step, bounds)},
      {:translate_down, Geometry.translate(seed, 0, step, bounds)},
      {:translate_up_left, Geometry.translate(seed, -step, -step, bounds)},
      {:translate_up_right, Geometry.translate(seed, step, -step, bounds)},
      {:translate_down_left, Geometry.translate(seed, -step, step, bounds)},
      {:translate_down_right, Geometry.translate(seed, step, step, bounds)}
    ]
  end

  defp wrap_chains(bases) do
    Stream.flat_map(bases, fn {base_label, base_rect} ->
      Stream.map(@wrap_operations, fn
        {operation, width_factor, height_factor, horizontal, vertical} ->
          {
            transform_chain_label(base_label, operation),
            Geometry.resize_within(
              base_rect,
              width_factor,
              height_factor,
              horizontal,
              vertical
            )
          }
      end)
    end)
  end

  defp transform_chain_label(base_label, operation), do: "#{base_label}>#{operation}"

  # A renderer is an external boundary: an absent candidate id, or a field the
  # browser could not produce (a `NaN` fit font serializes as `null`), is a hard
  # rejection rather than a raise escaping the {:ok, _} | {:error, _} contract.
  defp fit_rejections(candidate, measure, context) do
    if usable_measure?(measure) do
      []
      |> reject_if(measure.overflow, :text_overflow)
      |> reject_if(measure.clipped, :text_clipped)
      |> reject_if(measure.font_size + 0.01 < candidate.min_font, :below_minimum_font)
      |> reject_if(measure.line_count < 1, :no_rendered_lines)
      |> reject_if(not Geometry.contains?(context.bounds, candidate.rect), :outside_page_or_fold)
    else
      [:unusable_measurement]
    end
  end

  defp usable_measure?(%{
         font_size: font_size,
         line_count: line_count,
         lines: lines,
         overflow: overflow,
         clipped: clipped
       })
       when is_number(font_size) and is_integer(line_count) and is_list(lines) and
              is_boolean(overflow) and is_boolean(clipped),
       do: Enum.all?(lines, &usable_line?/1)

  defp usable_measure?(_measure), do: false

  defp usable_line?(%{x: x, y: y, w: w, h: h})
       when is_number(x) and is_number(y) and is_number(w) and is_number(h),
       do: true

  defp usable_line?(_line), do: false

  defp put_preselection_evidence(candidate, context) do
    line_rects =
      Enum.map(candidate.measure.lines, fn line ->
        %{
          x: candidate.rect.x + round(line.x),
          y: candidate.rect.y + round(line.y),
          w: max(round(line.w), 1),
          h: max(round(line.h), 1)
        }
      end)

    black = SafetyMap.summarize(context.safety_map, line_rects, :black, context.policy)
    white = SafetyMap.summarize(context.safety_map, line_rects, :white, context.policy)

    {ink, best} =
      Enum.min_by([black: black, white: white], fn {_ink, summary} ->
        {summary.unsafe_fraction, summary.edge_fraction, -summary.mean_contrast}
      end)

    fit_ratio = candidate.measure.font_size / context.policy.preferred_font
    compactness = Geometry.area(context.seed_rect) / Geometry.area(candidate.rect)
    seed_fidelity = Geometry.seed_fidelity(context.seed_rect, candidate.rect)

    score =
      (1 - best.unsafe_fraction) * 5 +
        min(best.mean_contrast / context.policy.target_contrast, 2) +
        fit_ratio + compactness + seed_fidelity - best.edge_fraction - best.saliency_fraction

    %{
      candidate
      | metrics: %{
          preselection_score: score,
          preferred_ink: ink,
          seed_fidelity: seed_fidelity,
          map_black: black,
          map_white: white
        }
    }
  end

  defp resolve_values(configured, seed) do
    configured
    |> Enum.map(fn
      :seed -> seed
      value -> value
    end)
    |> Enum.uniq()
  end

  defp maybe_add(existing, true, values), do: existing ++ values
  defp maybe_add(existing, false, _values), do: existing

  defp rect_key(rect), do: {rect.x, rect.y, rect.w, rect.h}

  defp deduplicate_rects(rects) do
    rects
    |> Enum.reduce({MapSet.new(), []}, fn {origin, rect}, {seen, acc} ->
      key = rect_key(rect)

      if MapSet.member?(seen, key) do
        {seen, acc}
      else
        {MapSet.put(seen, key), [{origin, rect} | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp reject_if(reasons, true, reason), do: [reason | reasons]
  defp reject_if(reasons, false, _reason), do: reasons
end
