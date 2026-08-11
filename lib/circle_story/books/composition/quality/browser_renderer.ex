defmodule CircleStory.Books.Composition.Quality.BrowserRenderer do
  @moduledoc "Chrome-backed implementation of exact font fitting and finalist glyph masks."

  @behaviour CircleStory.Books.Composition.Quality.Renderer

  alias CircleStory.Books.Composition.{HtmlRenderer, Quality.MeasureProtocol}
  alias CircleStory.Books.PageComponents

  @measurement_script """
  (async function(){
    while(!document.body.hasAttribute('data-ready')){
      await new Promise(function(resolve){ requestAnimationFrame(resolve); });
    }

    function lineRects(inner, boxRect){
      var walker = document.createTreeWalker(inner, NodeFilter.SHOW_TEXT);
      var rects = [];
      while(walker.nextNode()){
        var node = walker.currentNode;
        if(!node.nodeValue || !node.nodeValue.trim()){ continue; }
        var range = document.createRange();
        range.selectNodeContents(node);
        Array.from(range.getClientRects()).forEach(function(rect){
          if(rect.width > 0.5 && rect.height > 0.5){
            rects.push({
              x: rect.left - boxRect.left,
              y: rect.top - boxRect.top,
              w: rect.width,
              h: rect.height
            });
          }
        });
      }

      rects.sort(function(a, b){ return a.y - b.y || a.x - b.x; });
      return rects.reduce(function(lines, rect){
        var line = lines[lines.length - 1];
        if(line && Math.abs(line.y - rect.y) <= 2){
          var right = Math.max(line.x + line.w, rect.x + rect.w);
          line.x = Math.min(line.x, rect.x);
          line.w = right - line.x;
          line.h = Math.max(line.h, rect.h);
        } else {
          lines.push(rect);
        }
        return lines;
      }, []);
    }

    var result = {};
    document.querySelectorAll('.fit-text[data-candidate-id]').forEach(function(box){
      var safe = box.querySelector('.fit-safe');
      var inner = box.querySelector('.fit-inner');
      var boxRect = box.getBoundingClientRect();
      var lines = lineRects(inner, boxRect);
      var clipped = lines.some(function(line){
        return line.x < -0.5 || line.y < -0.5 ||
          line.x + line.w > box.clientWidth + 0.5 ||
          line.y + line.h > box.clientHeight + 0.5;
      });

      result[box.getAttribute('data-candidate-id')] = {
        font_size: parseFloat(box.getAttribute('data-fit-font')),
        line_count: lines.length,
        lines: lines,
        overflow: box.getAttribute('data-fit-overflow') === 'true',
        clipped: clipped,
        scroll_width: inner.scrollWidth,
        scroll_height: inner.scrollHeight,
        available_width: safe.clientWidth,
        available_height: safe.clientHeight
      };
    });
    return JSON.stringify(result);
  })()
  """

  @impl true
  def measure(candidates, content, role) do
    html =
      PageComponents.quality_sheet(
        changed(%{candidates: candidates, content: content, role: role})
      )
      |> HtmlRenderer.component_to_html()
      |> HtmlRenderer.document()

    case ChromicPDF.run_protocol(MeasureProtocol,
           source_type: :html,
           html: html,
           measurement_script: @measurement_script
         ) do
      {:ok, encoded} -> decode_measurements(encoded)
      {:error, reason} -> {:error, reason}
      encoded when is_binary(encoded) -> decode_measurements(encoded)
    end
  rescue
    exception ->
      {:error, {:renderer_exception, exception.__struct__, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:renderer_exit, reason}}
  end

  @impl true
  def mask(candidate, content, role) do
    page_html =
      PageComponents.quality_mask(changed(%{candidate: candidate, content: content, role: role}))
      |> HtmlRenderer.component_to_html()

    clip = %{
      "x" => 0,
      "y" => 0,
      "width" => candidate.rect.w,
      "height" => candidate.rect.h,
      "scale" => 1
    }

    case ChromicPDF.capture_screenshot({:html, HtmlRenderer.document(page_html)},
           wait_for: %{selector: "body", attribute: "data-ready"},
           capture_screenshot: %{
             "format" => "png",
             "clip" => clip,
             "captureBeyondViewport" => true
           }
         ) do
      {:ok, encoded} -> encoded |> Base.decode64!() |> Image.from_binary()
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception ->
      {:error, {:renderer_exception, exception.__struct__, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:renderer_exit, reason}}
  end

  defp decode_measurements(encoded) do
    with {:ok, decoded} <- Jason.decode(encoded) do
      {:ok,
       Map.new(decoded, fn {id, measurement} ->
         {id,
          %{
            font_size: measurement["font_size"],
            line_count: measurement["line_count"],
            lines:
              Enum.map(measurement["lines"], fn line ->
                %{x: line["x"], y: line["y"], w: line["w"], h: line["h"]}
              end),
            overflow: measurement["overflow"],
            clipped: measurement["clipped"],
            scroll_width: measurement["scroll_width"],
            scroll_height: measurement["scroll_height"],
            available_width: measurement["available_width"],
            available_height: measurement["available_height"]
          }}
       end)}
    end
  end

  defp changed(assigns), do: Map.put(assigns, :__changed__, %{})
end
