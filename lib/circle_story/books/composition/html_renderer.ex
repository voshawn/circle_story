defmodule CircleStory.Books.Composition.HtmlRenderer do
  @moduledoc """
  Turns a rendered page component into a print-ready PNG: wraps the page HTML in a
  self-contained document (embedded `@font-face`, CSS reset, exact-size body, and
  a fit-script that scales `.fit-text` blocks once fonts are ready), then captures
  a pixel-exact screenshot with ChromicPDF.
  """

  alias CircleStory.Books.Composition.Fonts

  @fit_script """
  function fitOne(box){
    var safe = box.querySelector('.fit-safe');
    var inner = box.querySelector('.fit-inner');
    if(!safe || !inner){return;}
    var lo = parseFloat(box.getAttribute('data-min-font')) || 8;
    var hi = parseFloat(box.getAttribute('data-max-font')) || 400;
    var fits = function(){
      return safe.clientWidth > 0 && safe.clientHeight > 0 &&
        inner.scrollWidth <= safe.clientWidth + 0.5 &&
        inner.scrollHeight <= safe.clientHeight + 0.5;
    };
    inner.style.fontSize = lo + 'px';
    if(fits()){
      for(var i = 0; i < 22; i++){
        var mid = (lo + hi) / 2;
        inner.style.fontSize = mid + 'px';
        if(fits()){ lo = mid; } else { hi = mid; }
      }
    }
    inner.style.fontSize = lo + 'px';
    box.setAttribute('data-fit-font', lo.toFixed(3));
    box.setAttribute('data-fit-overflow', fits() ? 'false' : 'true');
  }
  document.fonts.ready.then(function(){
    var boxes = document.querySelectorAll('.fit-text');
    for(var i = 0; i < boxes.length; i++){ fitOne(boxes[i]); }
    document.body.setAttribute('data-ready', 'true');
  });
  """

  @doc "Render a `Phoenix.LiveView.Rendered` (or safe HEEx result) to an HTML string."
  @spec component_to_html(Phoenix.LiveView.Rendered.t()) :: String.t()
  def component_to_html(rendered) do
    rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
  end

  @doc "Wrap page HTML in a self-contained render document."
  @spec document(String.t()) :: String.t()
  def document(page_html) do
    """
    <!DOCTYPE html>
    <html>
      <head>
        <meta charset="utf-8" />
        <style>
          #{Fonts.font_face_css()}
          * { margin:0; padding:0; box-sizing:border-box; }
          html, body { margin:0; padding:0; }
          #{debug_css()}
        </style>
      </head>
      <body>
        #{page_html}
        <script>#{@fit_script}</script>
      </body>
    </html>
    """
  end

  # When `:debug_bounding_boxes` is enabled (dev), outline each text box in red.
  # `outline` is used (not `border`) so it does not affect layout/autofit.
  defp debug_css do
    if Application.get_env(:circle_story, :debug_bounding_boxes, false) do
      ".fit-text { outline: 6px solid red; }"
    else
      ""
    end
  end

  @doc """
  Screenshot `page_html` to `output_path` as a pixel-exact `width` x `height` PNG.

  Uses the CDP `clip` region with `captureBeyondViewport` and `scale: 1`, so the
  exact print dimensions are captured regardless of the headless viewport size.
  Waits for fonts + fit completion via the `data-ready` body attribute.
  """
  @spec to_png(String.t(), {pos_integer(), pos_integer()}, Path.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def to_png(page_html, {width, height}, output_path) do
    clip = %{"x" => 0, "y" => 0, "width" => width, "height" => height, "scale" => 1}

    case ChromicPDF.capture_screenshot({:html, document(page_html)},
           # `selector` must match an element that already exists; ChromicPDF polls
           # `querySelector(selector).hasAttribute(attribute)`, so a selector that
           # itself requires the attribute (e.g. "body[data-ready]") is null until
           # ready and throws. Wait on plain "body" gaining `data-ready`.
           wait_for: %{selector: "body", attribute: "data-ready"},
           capture_screenshot: %{
             "format" => "png",
             "clip" => clip,
             "captureBeyondViewport" => true
           },
           output: output_path
         ) do
      :ok -> {:ok, output_path}
      {:ok, _} -> {:ok, output_path}
      {:error, reason} -> {:error, reason}
    end
  end
end
