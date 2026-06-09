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
    var inner = box.querySelector('.fit-inner');
    if(!inner){return;}
    var lo = 8, hi = 400;
    for(var i = 0; i < 22; i++){
      var mid = (lo + hi) / 2;
      inner.style.fontSize = mid + 'px';
      if(inner.scrollWidth <= box.clientWidth && inner.scrollHeight <= box.clientHeight){ lo = mid; } else { hi = mid; }
    }
    inner.style.fontSize = lo + 'px';
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
        </style>
      </head>
      <body>
        #{page_html}
        <script>#{@fit_script}</script>
      </body>
    </html>
    """
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
           wait_for: %{selector: "body[data-ready]", attribute: "data-ready"},
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
