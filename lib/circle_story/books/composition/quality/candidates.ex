defmodule CircleStory.Books.Composition.Quality.Candidates do
  @moduledoc "Finite role-aware generation, browser-fit measurement, and finalist preselection."

  alias CircleStory.Books.Composition.Quality.{Candidate, Context, Geometry, SafetyMap}

  @spec generate(Context.t()) :: {:ok, Context.t()}
  def generate(%Context{} = context) do
    rects = candidate_rects(context)
    alignments = resolve_values(context.policy.alignments, context.placement.text_align)
    valignments = resolve_values(context.policy.valignments, context.placement.vertical_align)

    candidates =
      for {{origin, rect}, rect_index} <- Enum.with_index(rects),
          align <- alignments,
          valign <- valignments,
          max_font <- context.policy.font_caps do
        {origin, rect, rect_index, align, valign, max_font}
      end
      |> Enum.with_index()
      |> Enum.map(fn {{origin, rect, _rect_index, align, valign, max_font}, index} ->
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
       rejection_reasons: rejection_reasons(measured)
     }}
  end

  defp rejection_reasons(measured) do
    measured |> Enum.flat_map(& &1.hard_rejections) |> Enum.frequencies()
  end

  @spec select_finalists(Context.t()) :: {:ok, Context.t()}
  def select_finalists(%Context{} = context) do
    finalists =
      context.measured
      |> Enum.filter(&(&1.hard_rejections == []))
      |> Enum.map(&put_preselection_evidence(&1, context))
      |> Enum.sort_by(&{-&1.metrics.preselection_score, &1.index})
      |> Enum.take(context.policy.finalist_limit)

    {:ok, %{context | finalists: finalists}}
  end

  @doc false
  @spec candidate_rects(Context.t()) :: [{atom(), map()}]
  def candidate_rects(%Context{} = context) do
    transforms = context.policy.candidate_transforms

    []
    |> maybe_add(:seed in transforms, [{:seed, context.seed_rect}])
    |> maybe_add(:grow in transforms, growth_rects(context))
    |> maybe_add(:translate in transforms, translated_rects(context))
    |> maybe_add(:wrap in transforms, wrapped_rects(context))
    |> deduplicate_rects()
  end

  defp growth_rects(context) do
    seed = context.seed_rect
    canvas = context.safe_canvas
    step = context.policy.growth_step

    left = Geometry.extend(seed, :left, step, canvas)
    right = Geometry.extend(seed, :right, step, canvas)
    up = Geometry.extend(seed, :up, step, canvas)
    down = Geometry.extend(seed, :down, step, canvas)

    horizontal =
      seed |> Geometry.extend(:left, step, canvas) |> Geometry.extend(:right, step, canvas)

    vertical = seed |> Geometry.extend(:up, step, canvas) |> Geometry.extend(:down, step, canvas)

    all =
      seed
      |> Geometry.extend(:left, step, canvas)
      |> Geometry.extend(:right, step, canvas)
      |> Geometry.extend(:up, step, canvas)
      |> Geometry.extend(:down, step, canvas)

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

  defp wrapped_rects(context) do
    [
      {:wrap_narrow,
       Geometry.resize_around_center(context.seed_rect, 0.8, 1.0, context.safe_canvas)},
      {:wrap_comfortable,
       Geometry.resize_around_center(context.seed_rect, 0.9, 1.0, context.safe_canvas)},
      {:region_compact,
       Geometry.resize_around_center(context.seed_rect, 0.9, 0.9, context.safe_canvas)}
    ]
  end

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
    distance = Geometry.distance(context.seed_rect, candidate.rect)

    score =
      (1 - best.unsafe_fraction) * 5 +
        min(best.mean_contrast / context.policy.target_contrast, 2) +
        fit_ratio + compactness - best.edge_fraction - best.saliency_fraction -
        distance / max(context.policy.growth_step * context.policy.growth_steps, 1)

    %{
      candidate
      | metrics: %{
          preselection_score: score,
          preferred_ink: ink,
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

  defp deduplicate_rects(rects) do
    rects
    |> Enum.reduce({MapSet.new(), []}, fn {origin, rect}, {seen, acc} ->
      key = {rect.x, rect.y, rect.w, rect.h}

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
