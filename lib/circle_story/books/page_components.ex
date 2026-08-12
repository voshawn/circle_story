defmodule CircleStory.Books.PageComponents do
  @moduledoc """
  HEEx function components for each print page (`cover/1`, `inner_spread/1`,
  `dedication/1`). Pure presentation: a fixed-size page `<div>` with absolutely
  positioned art and text. Text blocks marked `.fit-text` are auto-sized by the
  render document's fit-script. The future in-app editor reuses these components.

  Coordinates are in print pixels. Cover panel positions come from `Layout`; the
  front text `rect` is in panel-local coordinates and is positioned inside the
  front-panel div.
  """

  use Phoenix.Component

  alias CircleStory.Books.Composition.Layout
  alias CircleStory.Books.Composition.Luminance

  @blurb_lines [
    "Circle Storybooks",
    "A one of a kind story.",
    "Make your own at:",
    "www.circlestorybooks.com"
  ]

  # Autofit font-size bounds (px) per text role. Text is scaled to fill its box
  # but never larger than the max — keeps body text readable instead of huge.
  @min_font 24
  @max_font_title 360
  @max_font_body 64
  @max_font_tagline 90
  @max_font_dedication 120

  # Spine text (fixed size; runs vertically in the ~113px-wide spine).
  @spine_title_font 72
  @spine_author_font 44

  attr :art_uri, :string, required: true
  attr :text, :string, required: true
  attr :rect, :map, required: true
  attr :align, :atom, required: true
  attr :valign, :atom, default: :middle
  attr :color, :string, required: true
  attr :debug_rect, :map, default: nil, doc: "raw AI box to overlay (debug only)"
  attr :text_inset, :integer, default: 0
  attr :text_min_font, :integer, default: @min_font
  attr :text_max_font, :integer, default: @max_font_body
  attr :text_backing, :map, default: nil

  def inner_spread(assigns) do
    {w, h} = Layout.inner_dims()
    assigns = assign(assigns, w: w, h: h)

    ~H"""
    <div style={"position:relative;overflow:hidden;width:#{@w}px;height:#{@h}px;"}>
      <img src={@art_uri} style="position:absolute;inset:0;width:100%;height:100%;object-fit:cover;" />
      <.fit_text
        rect={@rect}
        align={@align}
        valign={@valign}
        color={@color}
        font="Nunito"
        weight="700"
        min_font={@text_min_font}
        max_font={@text_max_font}
        inset={@text_inset}
        backing={@text_backing}
      >
        <.role_content role={:inner} content={%{text: @text}} />
      </.fit_text>
      <.debug_box :if={@debug_rect} rect={@debug_rect} />
    </div>
    """
  end

  attr :text, :string, required: true
  attr :dedication_uri, :string, default: nil

  def dedication(assigns) do
    {w, h} = Layout.inner_dims()
    inset = Layout.safe_inset()
    half = Layout.inner_half()
    radius = round((min(w - half, h) - 2 * inset) / 2 * 0.85)

    assigns =
      assign(assigns,
        w: w,
        h: h,
        inset: inset,
        half: half,
        radius: radius,
        circle_cx: half + div(w - half, 2),
        circle_cy: div(h, 2),
        min_font: @min_font,
        max_font_dedication: @max_font_dedication
      )

    ~H"""
    <div style={"position:relative;overflow:hidden;width:#{@w}px;height:#{@h}px;background:#FBF6EC;"}>
      <.fit_text
        rect={%{x: @inset, y: @inset, w: @half - 2 * @inset, h: @h - 2 * @inset}}
        align={:center}
        color="#3A2E26"
        font="Nunito"
        weight="700"
        min_font={@min_font}
        max_font={@max_font_dedication}
      >
        {@text}
      </.fit_text>
      <%!-- User's dedication photo (circle-cropped), or a placeholder --%>
      <div style={"position:absolute;left:#{@circle_cx - @radius}px;top:#{@circle_cy - @radius}px;width:#{2 * @radius}px;height:#{2 * @radius}px;border-radius:50%;overflow:hidden;background:#{if @dedication_uri, do: "transparent", else: "pink"};"}>
        <img
          :if={@dedication_uri}
          src={@dedication_uri}
          style="width:100%;height:100%;object-fit:cover;"
        />
      </div>
    </div>
    """
  end

  attr :art_uri, :string, required: true
  attr :rect, :map, required: true
  attr :align, :atom, required: true
  attr :valign, :atom, default: :middle
  attr :front_color, :string, required: true
  attr :title, :string, required: true
  attr :author, :string, required: true
  attr :tagline, :string, required: true
  attr :fill, :string, required: true
  attr :ink, :string, required: true
  attr :debug_rect, :map, default: nil, doc: "raw AI box (panel-local) to overlay (debug only)"
  attr :character_uri, :string, default: nil
  attr :text_inset, :integer, default: 0
  attr :text_min_font, :integer, default: @min_font
  attr :text_max_font, :integer, default: @max_font_title
  attr :text_backing, :map, default: nil

  def cover(assigns) do
    {w, h} = Layout.cover_dims()
    inset = Layout.safe_inset()
    front = Layout.front_panel()
    spine = Layout.spine_panel()
    back = Layout.back_panel()
    circle_r = round(back.w * 0.19)

    assigns =
      assign(assigns,
        w: w,
        h: h,
        inset: inset,
        front: front,
        spine: spine,
        back: back,
        circle_r: circle_r,
        blurb_lines: @blurb_lines,
        min_font: @min_font,
        max_font_tagline: @max_font_tagline,
        spine_title_font: @spine_title_font,
        spine_author_font: @spine_author_font
      )

    ~H"""
    <div style={"position:relative;overflow:hidden;width:#{@w}px;height:#{@h}px;background:#{@fill};"}>
      <%!-- BACK PANEL --%>
      <.fit_text
        rect={%{x: @back.x + @inset, y: @inset, w: @back.w - 2 * @inset, h: 200}}
        align={:center}
        color={@ink}
        font="Nunito"
        weight="700"
        italic={true}
        min_font={@min_font}
        max_font={@max_font_tagline}
      >
        {@tagline}
      </.fit_text>

      <%!-- Back-cover character reference (circle-cropped), or a placeholder --%>
      <div style={"position:absolute;left:#{div(@back.w, 2) - @circle_r}px;top:#{div(@back.h, 2) - @circle_r}px;width:#{2 * @circle_r}px;height:#{2 * @circle_r}px;border-radius:50%;overflow:hidden;background:#{if @character_uri, do: "transparent", else: "pink"};"}>
        <img
          :if={@character_uri}
          src={@character_uri}
          style="width:100%;height:100%;object-fit:cover;"
        />
      </div>

      <div style={"position:absolute;left:#{@inset}px;bottom:#{@inset}px;font-family:'Nunito';font-weight:400;font-size:44px;line-height:1.4;color:#{@ink};text-align:left;"}>
        <div :for={line <- @blurb_lines}>{line}</div>
      </div>

      <%!-- SPINE: title in Fredoka (bold), author in Nunito (smaller, normal) --%>
      <div style={"position:absolute;left:#{@spine.x}px;top:0;width:#{@spine.w}px;height:#{@spine.h}px;display:flex;align-items:center;justify-content:center;"}>
        <div style={"white-space:nowrap;transform:rotate(-90deg);display:inline-flex;align-items:baseline;color:#{@ink};"}>
          <span style={"font-family:'Fredoka';font-weight:700;font-size:#{@spine_title_font}px;"}>
            {@title}
          </span>
          <span style={"font-family:'Nunito';font-weight:400;font-size:#{@spine_author_font}px;margin-left:0.45em;"}>
            · {@author}
          </span>
        </div>
      </div>

      <%!-- FRONT PANEL --%>
      <div style={"position:absolute;left:#{@front.x}px;top:0;width:#{@front.w}px;height:#{@front.h}px;overflow:hidden;"}>
        <img
          src={@art_uri}
          style="position:absolute;inset:0;width:100%;height:100%;object-fit:cover;"
        />
        <.fit_text
          rect={@rect}
          align={@align}
          valign={@valign}
          color={@front_color}
          font="Fredoka"
          weight="700"
          min_font={@text_min_font}
          max_font={@text_max_font}
          inset={@text_inset}
          backing={@text_backing}
        >
          <.role_content role={:cover} content={%{title: @title, author: @author}} />
        </.fit_text>
        <.debug_box :if={@debug_rect} rect={@debug_rect} />
      </div>
    </div>
    """
  end

  # A fixed-size, absolutely positioned text box. The `.fit-inner` child is scaled
  # to fit by the render document's fit-script. `font`/`weight`/`italic` set the
  # default run style; cover title/author override per-line with em sizes.
  attr :rect, :map, required: true
  attr :align, :atom, required: true
  attr :color, :string, required: true
  attr :font, :string, required: true
  attr :weight, :string, required: true
  attr :italic, :boolean, default: false
  attr :min_font, :integer, default: 8
  attr :max_font, :integer, default: 400
  attr :inset, :integer, default: 0
  attr :backing, :map, default: nil
  attr :candidate_id, :string, default: nil

  attr :valign, :atom,
    default: :middle,
    doc: ":top | :middle | :bottom — vertical anchor in the box"

  slot :inner_block, required: true

  def fit_text(assigns) do
    ~H"""
    <div
      class="fit-text"
      data-candidate-id={@candidate_id}
      data-min-font={@min_font}
      data-max-font={@max_font}
      data-inset={@inset}
      style={"position:absolute;left:#{@rect.x}px;top:#{@rect.y}px;width:#{@rect.w}px;height:#{@rect.h}px;overflow:hidden;#{backing_css(@backing)}"}
    >
      <div
        class="fit-safe"
        style={"position:absolute;left:#{@inset}px;right:#{@inset}px;top:#{@inset}px;bottom:#{@inset}px;display:flex;flex-direction:column;justify-content:#{valign_css(@valign)};overflow:hidden;"}
      >
        <div
          class="fit-inner"
          style={"width:100%;text-align:#{@align};color:#{@color};line-height:1.2;font-family:'#{@font}';font-weight:#{@weight};#{if @italic, do: "font-style:italic;"}"}
        >
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  attr :candidates, :list, required: true
  attr :content, :map, required: true
  attr :role, :atom, required: true

  @doc false
  def quality_sheet(assigns) do
    ~H"""
    <div style="position:relative;width:1px;height:1px;overflow:visible;background:#000;">
      <.fit_text
        :for={candidate <- @candidates}
        rect={%{x: 0, y: 0, w: candidate.rect.w, h: candidate.rect.h}}
        align={candidate.align}
        valign={candidate.valign}
        color="#FAFAFA"
        font={if(@role == :cover, do: "Fredoka", else: "Nunito")}
        weight="700"
        min_font={candidate.min_font}
        max_font={candidate.max_font}
        inset={candidate.inset}
        candidate_id={candidate.id}
      >
        <.role_content role={@role} content={@content} />
      </.fit_text>
    </div>
    """
  end

  attr :candidate, :map, required: true
  attr :content, :map, required: true
  attr :role, :atom, required: true

  @doc false
  def quality_mask(assigns) do
    ~H"""
    <div style={"position:relative;width:#{@candidate.rect.w}px;height:#{@candidate.rect.h}px;overflow:hidden;background:#000;"}>
      <.fit_text
        rect={%{x: 0, y: 0, w: @candidate.rect.w, h: @candidate.rect.h}}
        align={@candidate.align}
        valign={@candidate.valign}
        color="#FFF"
        font={if(@role == :cover, do: "Fredoka", else: "Nunito")}
        weight="700"
        min_font={@candidate.min_font}
        max_font={@candidate.max_font}
        inset={@candidate.inset}
        candidate_id={@candidate.id}
      >
        <.role_content role={@role} content={@content} />
      </.fit_text>
    </div>
    """
  end

  # The one definition of what a role actually renders inside its `.fit-text`
  # box. The browser fit measurement, the scored glyph mask, and the final page
  # must render identical markup or the contrast gates would validate a layout
  # the print page never produces.
  attr :role, :atom, required: true
  attr :content, :map, required: true

  defp role_content(%{role: :cover} = assigns) do
    ~H"""
    <div style="font-family:'Fredoka';font-weight:700;font-size:1em;">{@content.title}</div>
    <div style="font-family:'Nunito';font-weight:700;font-size:0.5em;margin-top:0.18em;">
      by {@content.author}
    </div>
    """
  end

  defp role_content(assigns) do
    ~H"""
    {@content.text}
    """
  end

  # Debug overlay: the raw AI bounding box (cyan dashed), drawn in the same
  # coordinate space as its sibling text box so it can be compared against the
  # final (red, post-floor/clamp) `.fit-text` outline. Rendered only when a
  # `debug_rect` is supplied by the pipeline (dev only).
  defp valign_css(:top), do: "flex-start"
  defp valign_css(:bottom), do: "flex-end"
  defp valign_css(_), do: "center"

  defp backing_css(nil), do: ""

  defp backing_css(%{type: :backing, color: color, opacity: opacity}) do
    [red, green, blue] = Luminance.rgb(color)
    "background:rgba(#{red},#{green},#{blue},#{opacity});border-radius:24px;"
  end

  attr :rect, :map, required: true

  def debug_box(assigns) do
    ~H"""
    <div style={"position:absolute;left:#{@rect.x}px;top:#{@rect.y}px;width:#{@rect.w}px;height:#{@rect.h}px;outline:6px dashed #00BFFF;pointer-events:none;"}>
      <span style="position:absolute;top:0;left:0;background:#00BFFF;color:#000;font:700 28px sans-serif;padding:2px 10px;">
        AI
      </span>
    </div>
    """
  end
end
