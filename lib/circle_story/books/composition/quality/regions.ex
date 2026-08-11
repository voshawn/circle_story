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
    Enum.reduce_while(1..context.policy.growth_steps, {rect, []}, fn _step, {current, evidence} ->
      next = Geometry.extend(current, direction, context.policy.growth_step, context.bounds)

      if next == current do
        {:halt, {current, Enum.reverse(evidence)}}
      else
        strip = added_strip(current, next, direction)
        {pass?, summary} = SafetyMap.passable_strip?(context.safety_map, strip, context.policy)
        item = %{strip: strip, pass: pass?, summary: summary}

        if pass? do
          {:cont, {next, [item | evidence]}}
        else
          {:halt, {current, Enum.reverse([item | evidence])}}
        end
      end
    end)
  end

  defp added_strip(current, next, :left) do
    %{x: next.x, y: next.y, w: current.x - next.x, h: next.h}
  end

  defp added_strip(current, next, :right) do
    %{x: current.x + current.w, y: next.y, w: next.x + next.w - current.x - current.w, h: next.h}
  end

  defp added_strip(current, next, :up) do
    %{x: next.x, y: next.y, w: next.w, h: current.y - next.y}
  end

  defp added_strip(current, next, :down) do
    %{x: next.x, y: current.y + current.h, w: next.w, h: next.y + next.h - current.y - current.h}
  end
end
