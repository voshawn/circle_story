defmodule CircleStory.Books.Composition.Quality.Regions do
  @moduledoc "Bounded safe-canvas expansion from the model placement seed."

  alias CircleStory.Books.Composition.Quality.{Context, Geometry, SafetyMap}

  @directions [:left, :right, :up, :down]

  @spec expand(Context.t()) :: {:ok, Context.t()}
  def expand(%Context{} = context) do
    bounds = context.bounds

    seed =
      Geometry.intersection(context.seed_rect, bounds) ||
        Geometry.clamp_rect(context.seed_rect, bounds)

    {canvas, evidence} =
      Enum.reduce(@directions, {seed, %{}}, fn direction, {rect, all_evidence} ->
        {expanded, direction_evidence} = expand_direction(context, rect, direction)
        {expanded, Map.put(all_evidence, direction, direction_evidence)}
      end)

    {:ok,
     %{
       context
       | seed_rect: seed,
         safe_canvas: canvas,
         evidence: Map.put(context.evidence, :region_expansion, evidence)
     }}
  end

  defp expand_direction(context, rect, direction) do
    1..context.policy.growth_steps//1
    |> Enum.reduce_while({rect, []}, fn _step, {current, evidence} ->
      next = Geometry.extend(current, direction, context.policy.growth_step, context.bounds)

      if next == current do
        {:halt, {current, Enum.reverse(evidence)}}
      else
        strips = added_strips(current, next)

        summaries =
          Enum.map(strips, fn strip ->
            {pass?, summary} =
              SafetyMap.passable_strip?(context.safety_map, strip, context.policy)

            %{strip: strip, pass: pass?, summary: summary}
          end)

        pass? = summaries != [] and Enum.all?(summaries, & &1.pass)
        item = %{strips: summaries, pass: pass?}

        if pass? do
          {:cont, {next, [item | evidence]}}
        else
          {:halt, {current, Enum.reverse([item | evidence])}}
        end
      end
    end)
  end

  # `Geometry.extend/4` clamps, so a step whose requested edge is already flush
  # against the bound grows the opposite edge instead. Evaluate every region of
  # `next` that `current` did not already cover so no art enters the canvas
  # unchecked.
  defp added_strips(current, next) do
    current_right = current.x + current.w
    current_bottom = current.y + current.h

    [
      %{x: next.x, y: next.y, w: current.x - next.x, h: next.h},
      %{x: current_right, y: next.y, w: next.x + next.w - current_right, h: next.h},
      %{x: current.x, y: next.y, w: current.w, h: current.y - next.y},
      %{x: current.x, y: current_bottom, w: current.w, h: next.y + next.h - current_bottom}
    ]
    |> Enum.filter(&(&1.w > 0 and &1.h > 0))
  end
end
