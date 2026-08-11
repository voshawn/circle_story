defmodule CircleStory.Books.Composition do
  @moduledoc """
  Orchestrates page composition. `*_html/_` reuse a cached model placement and
  run deterministic local Chrome quality search without taking the final page
  screenshot. `compose_*` then capture a print-ready PNG and persist matching
  quality provenance. Pass `force_bbox: true` (used by `Generator.generate_*`)
  to refresh the model bounding box.
  """

  require Logger

  alias CircleStory.Books.Composition.{HtmlRenderer, ImageOps, Layout, Luminance, Quality}
  alias CircleStory.Books.Composition.Quality.{Policy, Result}
  alias CircleStory.Books.Actions.PlaceText

  @quality_contract Policy.contract_version()

  alias CircleStory.Books.{
    Book,
    Character,
    CoverSpread,
    DedicationSpread,
    InnerSpread,
    PageComponents
  }

  # Source resolution for the circle crops (object-fit:cover downstream, so an
  # exact match to the print diameter isn't required — this is comfortably above
  # both the back-cover and dedication circle sizes).
  @circle_source_px 1600

  # ----- compose_* (build + screenshot) -----

  @spec compose_spread(InnerSpread.t(), keyword()) ::
          {:ok, %{image_path: String.t()}} | {:error, term()}
  def compose_spread(%InnerSpread{} = spread, opts \\ []) do
    with {:ok, html, out, cache} <- build_spread_html(spread, opts),
         {:ok, path} <- HtmlRenderer.to_png(html, Layout.inner_dims(), out) do
      persist_quality(cache)
      {:ok, %{image_path: path}}
    end
  end

  @spec compose_cover(Book.t(), keyword()) :: {:ok, %{image_path: String.t()}} | {:error, term()}
  def compose_cover(%Book{} = book, opts \\ []) do
    with {:ok, html, out, cache} <- build_cover_html(book, opts),
         {:ok, path} <- HtmlRenderer.to_png(html, Layout.cover_dims(), out) do
      persist_quality(cache)
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
  def spread_html(%InnerSpread{} = spread, opts \\ []) do
    with {:ok, html, out, _cache} <- build_spread_html(spread, opts), do: {:ok, html, out}
  end

  defp build_spread_html(%InnerSpread{generated_image_path: raw, text: text}, opts) do
    {w, h} = Layout.inner_dims()
    fitted = ImageOps.fit(raw, w, h)

    with {:ok, box} <- placement(raw, fitted, text, :inner, opts) do
      region = Layout.inner_region()
      seed_rect = Layout.denormalize(box.bounding_box, region)

      with {:ok, quality} <-
             optimize_quality(fitted, %{text: text}, box, seed_rect, :inner, opts) do
        candidate = quality.candidate

        html =
          HtmlRenderer.component_to_html(
            PageComponents.inner_spread(
              init_assigns(%{
                art_uri: ImageOps.to_data_uri(fitted),
                text: text,
                rect: candidate.rect,
                align: candidate.align,
                valign: candidate.valign,
                color: Luminance.hex(candidate.ink),
                text_inset: candidate.inset,
                text_max_font: candidate.max_font,
                text_backing: candidate.treatment,
                debug_rect: debug_rect(box.bounding_box, region)
              })
            )
          )

        cache = {raw, box, Result.provenance(quality)}
        {:ok, html, ImageOps.print_ready_path(raw), cache}
      end
    end
  end

  @spec cover_html(Book.t(), keyword()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def cover_html(%Book{} = book, opts \\ []) do
    with {:ok, html, out, _cache} <- build_cover_html(book, opts), do: {:ok, html, out}
  end

  defp build_cover_html(
         %Book{cover: %CoverSpread{generated_image_path: raw} = cover} = book,
         opts
       ) do
    %{w: pw, h: ph} = Layout.front_region_local()
    front = ImageOps.fit(raw, pw, ph)
    text = "#{book.title}\n#{book.author}"

    with {:ok, box} <- placement(raw, front, text, :cover, opts) do
      region = Layout.front_region_local()
      # Preserve the established cover floor as the semantic seed; deterministic
      # quality search may then use a smaller comfortable region or grow safely.
      seed_rect =
        Layout.denormalize(box.bounding_box, region, min_w_frac: 0.55, min_h_frac: 0.22)

      with {:ok, quality} <-
             optimize_quality(
               front,
               %{title: book.title, author: book.author},
               box,
               seed_rect,
               :cover,
               opts
             ) do
        candidate = quality.candidate
        fill_rgb = ImageOps.softened_average(front)
        ink = fill_rgb |> Luminance.color_for() |> Luminance.hex()

        html =
          HtmlRenderer.component_to_html(
            PageComponents.cover(
              init_assigns(%{
                art_uri: ImageOps.to_data_uri(front),
                rect: candidate.rect,
                align: candidate.align,
                valign: candidate.valign,
                front_color: Luminance.hex(candidate.ink),
                title: book.title,
                author: book.author,
                tagline: cover.tagline,
                fill: rgb_css(fill_rgb),
                ink: ink,
                character_uri: back_cover_character_uri(book),
                text_inset: candidate.inset,
                text_max_font: candidate.max_font,
                text_backing: candidate.treatment,
                debug_rect: debug_rect(box.bounding_box, region)
              })
            )
          )

        cache = {raw, box, Result.provenance(quality)}
        {:ok, html, ImageOps.print_ready_path(raw), cache}
      end
    end
  end

  @spec dedication_html(DedicationSpread.t()) :: {:ok, String.t(), String.t()}
  def dedication_html(%DedicationSpread{text: text} = dedication) do
    html =
      HtmlRenderer.component_to_html(
        PageComponents.dedication(
          init_assigns(%{text: text, dedication_uri: dedication_uri(dedication)})
        )
      )

    dir = Path.join(:code.priv_dir(:circle_story), "print_ready")
    File.mkdir_p!(dir)
    {:ok, html, Path.join(dir, "dedication.png")}
  end

  # ----- bbox cache -----

  @doc "Read the cached placement for raw art without making a model call."
  @spec cached_placement(Path.t()) :: {:ok, map()} | {:error, term()}
  def cached_placement(raw_path) do
    case File.read(ImageOps.bbox_path(raw_path)) do
      {:ok, encoded} -> load_cached(encoded)
      {:error, :enoent} -> {:error, :no_cached_bounding_box}
      {:error, reason} -> {:error, {:bounding_box_cache_read_failed, reason}}
    end
  end

  @doc false
  @spec cache_placement(Path.t(), map(), map() | nil) :: :ok | {:error, term()}
  def cache_placement(raw_path, box, quality \\ nil) do
    payload = %{
      "bounding_box" => box.bounding_box,
      "text_align" => Atom.to_string(box.text_align),
      "vertical_align" => Atom.to_string(box.vertical_align),
      "source" => box |> Map.get(:source, :unknown) |> placement_source() |> Atom.to_string()
    }

    payload = if quality, do: Map.put(payload, "composition_quality", quality), else: payload
    File.write(ImageOps.bbox_path(raw_path), Jason.encode!(payload))
  end

  # Load a cached bbox, or fetch (and cache) via PlaceText. `force_bbox: true` always refetches.
  # `cached_bbox_only: true` makes the operation provably free instead of fetching on a miss.
  defp placement(raw, fitted_image, text, mode, opts) do
    cache_exists? = File.exists?(ImageOps.bbox_path(raw))
    force? = Keyword.get(opts, :force_bbox, false)
    cached_only? = Keyword.get(opts, :cached_bbox_only, false)

    cond do
      not force? and cache_exists? ->
        cached_placement(raw)

      not force? and cached_only? ->
        {:error, :no_cached_bounding_box}

      true ->
        png = ImageOps.to_png_bytes(fitted_image)

        with {:ok, box} <- PlaceText.run(%{image_png: png, text: text, mode: mode}, %{}) do
          # Caching is best-effort: the box is already computed, so a write failure
          # (disk full, permissions) must not crash the render pipeline.
          _ = cache_placement(raw, box)
          {:ok, box}
        end
    end
  end

  defp load_cached(encoded) do
    with {:ok, %{"bounding_box" => bbox} = decoded} <- Jason.decode(encoded) do
      {:ok,
       %{
         bounding_box: bbox,
         text_align: align_atom(Map.get(decoded, "text_align")),
         vertical_align: valign_atom(Map.get(decoded, "vertical_align")),
         source: decoded |> Map.get("source", "unknown") |> placement_source(),
         composition_quality: decode_quality(Map.get(decoded, "composition_quality"))
       }}
    end
  end

  defp placement_source(:model), do: :model
  defp placement_source("model"), do: :model
  defp placement_source(:fallback), do: :fallback
  defp placement_source("fallback"), do: :fallback
  defp placement_source(_), do: :unknown

  defp align_atom("left"), do: :left
  defp align_atom("right"), do: :right
  defp align_atom(_), do: :center

  defp valign_atom("top"), do: :top
  defp valign_atom("bottom"), do: :bottom
  defp valign_atom(_), do: :middle

  defp optimize_quality(image, content, box, seed_rect, role, opts) do
    optimizer = Keyword.get(opts, :quality_optimizer, &Quality.optimize/5)
    quality_opts = Keyword.get(opts, :quality_opts, []) |> Keyword.put(:role, role)
    optimizer.(image, content, Map.put(box, :mode, role), seed_rect, quality_opts)
  end

  defp persist_quality({raw, box, provenance}) do
    # The final render already succeeded. Provenance is best-effort so a sidecar
    # write failure cannot discard a valid print-ready page.
    _ = cache_placement(raw, box, provenance)
    :ok
  end

  defp decode_quality(nil), do: nil

  defp decode_quality(%{"contract_version" => @quality_contract} = quality) do
    %{
      contract_version: @quality_contract,
      candidate_id: quality["candidate_id"],
      final_rect: atomize_rect(quality["final_rect"]),
      adjustment: quality["adjustment"],
      align: align_atom(quality["align"]),
      valign: valign_atom(quality["valign"]),
      font_size: quality["font_size"],
      line_count: quality["line_count"],
      lines: Enum.map(quality["lines"] || [], &atomize_rect/1),
      glyph_bounds: atomize_rect(quality["glyph_bounds"]),
      effect_bounds: atomize_rect(quality["effect_bounds"]),
      overflow: quality["overflow"],
      treatment: quality["treatment"],
      metrics: decode_quality_metrics(quality["metrics"] || %{}),
      candidate_count: quality["candidate_count"],
      rejected_count: quality["rejected_count"],
      duration_ms: quality["duration_ms"]
    }
  end

  defp decode_quality(_), do: nil

  defp decode_quality_metrics(metrics) do
    %{
      worst_tile_p10: metrics["worst_tile_p10"],
      worst_tile_low_contrast_fraction: metrics["worst_tile_low_contrast_fraction"],
      worst_line_p05: metrics["worst_line_p05"],
      edge_density: metrics["edge_density"],
      soft_total: metrics["soft_total"]
    }
  end

  defp atomize_rect(%{"x" => x, "y" => y, "w" => w, "h" => h}),
    do: %{x: x, y: y, w: w, h: h}

  defp atomize_rect(_), do: nil

  defp rgb_css([r, g, b | _]), do: "rgb(#{r},#{g},#{b})"

  # The raw AI box (no clamp/floor) for the debug overlay, or nil when debugging
  # is off. Same coordinate space as the page/panel the box belongs to.
  defp debug_rect(bounding_box, region) do
    if Application.get_env(:circle_story, :debug_bounding_boxes, false) do
      Layout.to_pixels(bounding_box, region)
    end
  end

  defp back_cover_character_uri(%Book{} = book) do
    case Book.back_cover_character(book) do
      %Character{reference_image_path: path} -> circle_uri(path)
      _ -> nil
    end
  end

  defp dedication_uri(%DedicationSpread{user_image_path: path}), do: circle_uri(path)

  # Fit an image path to a square and encode it for the circle crop. Nil/missing
  # files yield nil so the component falls back to the placeholder.
  defp circle_uri(path) when is_binary(path) do
    if File.exists?(path) do
      try do
        path |> ImageOps.fit(@circle_source_px, @circle_source_px) |> ImageOps.to_data_uri()
      rescue
        error ->
          Logger.warning(
            "Composition: circle photo unreadable, rendering the placeholder instead " <>
              "(#{inspect(error)}): #{path}"
          )

          nil
      end
    else
      Logger.warning(
        "Composition: circle photo missing, rendering the placeholder instead: #{path}"
      )

      nil
    end
  end

  defp circle_uri(_), do: nil

  # Inject Phoenix.Component change-tracking metadata so components can be called
  # outside of a HEEx template (e.g. from the composition pipeline).
  defp init_assigns(assigns), do: Map.put(assigns, :__changed__, %{})
end
