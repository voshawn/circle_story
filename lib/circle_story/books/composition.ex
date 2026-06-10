defmodule CircleStory.Books.Composition do
  @moduledoc """
  Orchestrates page composition. `*_html/_` build the page HTML (cheap; reuse a
  cached bounding box, no Chrome). `compose_*` build then screenshot to a
  print-ready PNG. Pass `force_bbox: true` (used by `Generator.generate_*`) to
  refresh the bounding box.
  """

  alias CircleStory.Books.Composition.{HtmlRenderer, ImageOps, Layout, Luminance}
  alias CircleStory.Books.Actions.PlaceText
  alias CircleStory.Books.{Book, CoverSpread, DedicationSpread, InnerSpread, PageComponents}

  # ----- compose_* (build + screenshot) -----

  @spec compose_spread(InnerSpread.t(), keyword()) ::
          {:ok, %{image_path: String.t()}} | {:error, term()}
  def compose_spread(%InnerSpread{} = spread, opts \\ []) do
    with {:ok, html, out} <- spread_html(spread, opts),
         {:ok, path} <- HtmlRenderer.to_png(html, Layout.inner_dims(), out) do
      {:ok, %{image_path: path}}
    end
  end

  @spec compose_cover(Book.t(), keyword()) :: {:ok, %{image_path: String.t()}} | {:error, term()}
  def compose_cover(%Book{} = book, opts \\ []) do
    with {:ok, html, out} <- cover_html(book, opts),
         {:ok, path} <- HtmlRenderer.to_png(html, Layout.cover_dims(), out) do
      {:ok, %{image_path: path}}
    end
  end

  @spec compose_dedication(DedicationSpread.t()) ::
          {:ok, %{image_path: String.t()}} | {:error, term()}
  def compose_dedication(%DedicationSpread{} = dedication) do
    with {:ok, html, out} <- dedication_html(dedication),
         {:ok, path} <- HtmlRenderer.to_png(html, Layout.inner_dims(), out) do
      {:ok, %{image_path: path}}
    end
  end

  # ----- *_html (build only) -----

  @spec spread_html(InnerSpread.t(), keyword()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def spread_html(%InnerSpread{generated_image_path: raw, text: text}, opts \\ []) do
    {w, h} = Layout.inner_dims()
    fitted = ImageOps.fit(raw, w, h)

    with {:ok, box} <- placement(raw, fitted, text, :inner, opts) do
      region = Layout.inner_region()
      # No size floor — trust the AI box (the quadrant prompt keeps it sensible).
      # `denormalize/2` still applies the safe-inset clamp so text stays inside
      # the printer bleed margin; body font size is capped in the component.
      rect = Layout.denormalize(box.bounding_box, region)
      color = fitted |> Luminance.pick_for_region(rect) |> Luminance.hex()

      html =
        HtmlRenderer.component_to_html(
          PageComponents.inner_spread(
            init_assigns(%{
              art_uri: ImageOps.to_data_uri(fitted),
              text: text,
              rect: rect,
              align: box.text_align,
              color: color,
              debug_rect: debug_rect(box.bounding_box, region)
            })
          )
        )

      {:ok, html, ImageOps.print_ready_path(raw)}
    end
  end

  @spec cover_html(Book.t(), keyword()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def cover_html(%Book{cover: %CoverSpread{generated_image_path: raw} = cover} = book, opts \\ []) do
    %{w: pw, h: ph} = Layout.front_region_local()
    front = ImageOps.fit(raw, pw, ph)
    text = "#{book.title}\n#{book.author}"

    with {:ok, box} <- placement(raw, front, text, :cover, opts) do
      region = Layout.front_region_local()
      # The title is the cover's hero — floor the box so a stingy model answer
      # can't shrink it into a corner.
      rect = Layout.denormalize(box.bounding_box, region, min_w_frac: 0.55, min_h_frac: 0.22)

      front_color = front |> Luminance.pick_for_region(rect) |> Luminance.hex()
      fill_rgb = ImageOps.softened_average(front)
      ink = fill_rgb |> Luminance.color_for() |> Luminance.hex()

      html =
        HtmlRenderer.component_to_html(
          PageComponents.cover(
            init_assigns(%{
              art_uri: ImageOps.to_data_uri(front),
              rect: rect,
              align: box.text_align,
              front_color: front_color,
              title: book.title,
              author: book.author,
              tagline: cover.tagline,
              fill: rgb_css(fill_rgb),
              ink: ink,
              debug_rect: debug_rect(box.bounding_box, region)
            })
          )
        )

      {:ok, html, ImageOps.print_ready_path(raw)}
    end
  end

  @spec dedication_html(DedicationSpread.t()) :: {:ok, String.t(), String.t()}
  def dedication_html(%DedicationSpread{text: text}) do
    html =
      HtmlRenderer.component_to_html(PageComponents.dedication(init_assigns(%{text: text})))

    dir = Path.join(:code.priv_dir(:circle_story), "print_ready")
    File.mkdir_p!(dir)
    {:ok, html, Path.join(dir, "dedication.png")}
  end

  # ----- bbox cache -----

  # Load a cached bbox, or fetch (and cache) via PlaceText. `force_bbox: true` always refetches.
  defp placement(raw, fitted_image, text, mode, opts) do
    cache = ImageOps.bbox_path(raw)

    if not Keyword.get(opts, :force_bbox, false) and File.exists?(cache) do
      load_cached(cache)
    else
      png = ImageOps.to_png_bytes(fitted_image)

      with {:ok, box} <- PlaceText.run(%{image_png: png, text: text, mode: mode}, %{}) do
        # Caching is best-effort: the box is already computed, so a write failure
        # (disk full, permissions) must not crash the render pipeline.
        _ =
          File.write(
            cache,
            Jason.encode!(%{
              "bounding_box" => box.bounding_box,
              "text_align" => Atom.to_string(box.text_align)
            })
          )

        {:ok, box}
      end
    end
  end

  defp load_cached(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{"bounding_box" => bbox, "text_align" => align}} <- Jason.decode(raw) do
      {:ok, %{bounding_box: bbox, text_align: align_atom(align)}}
    end
  end

  defp align_atom("left"), do: :left
  defp align_atom("right"), do: :right
  defp align_atom(_), do: :center

  defp rgb_css([r, g, b | _]), do: "rgb(#{r},#{g},#{b})"

  # The raw AI box (no clamp/floor) for the debug overlay, or nil when debugging
  # is off. Same coordinate space as the page/panel the box belongs to.
  defp debug_rect(bounding_box, region) do
    if Application.get_env(:circle_story, :debug_bounding_boxes, false) do
      Layout.to_pixels(bounding_box, region)
    end
  end

  # Inject Phoenix.Component change-tracking metadata so components can be called
  # outside of a HEEx template (e.g. from the composition pipeline).
  defp init_assigns(assigns), do: Map.put(assigns, :__changed__, %{})
end
