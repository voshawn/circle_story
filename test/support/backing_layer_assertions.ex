defmodule CircleStory.BackingLayerAssertions do
  @moduledoc """
  Assertions for the print policy that composed text is transparent black or
  white over the art, with no rectangular backing layer behind it.

  The rendered page HTML is the byte contract ChromicPDF screenshots, so these
  parse it into elements and CSS declarations rather than matching one spelling
  of one fill.
  """

  import ExUnit.Assertions

  @fill_properties ~w(
    background
    background-color
    background-image
    box-shadow
    backdrop-filter
  )

  @doc """
  Assert the published text box and everything inside it paints no fill.

  Fails when the `.fit-text` box, any descendant, or a stylesheet rule targeting
  those elements declares a background, shadow, or backdrop of its own.
  """
  @spec assert_transparent_text_box(String.t()) :: :ok
  def assert_transparent_text_box(html) do
    boxes = query(html, ".fit-text")

    assert Enum.any?(boxes),
           "expected the rendered page to publish text in a .fit-text box"

    scope = scoped_elements(html, ".fit-text")
    refute_inline_fills(scope)
    refute_stylesheet_fills(html, scope)
    :ok
  end

  @doc """
  Assert no element matching `selector`, or nested inside it, paints a fill.

  Used for pages whose text sits over art alone, where a backing rectangle has
  nowhere legitimate to hide - including as a sibling behind the text box.
  """
  @spec assert_no_fill_anywhere(String.t(), String.t()) :: :ok
  def assert_no_fill_anywhere(html, selector \\ "*") do
    scope = scoped_elements(html, selector)
    refute_inline_fills(scope)
    refute_stylesheet_fills(html, scope)
    :ok
  end

  defp refute_inline_fills(elements) do
    for element <- elements,
        style <- LazyHTML.attribute(element, "style"),
        {property, value} <- declarations(style) do
      refute property in @fill_properties,
             "#{describe(element)} paints #{property}:#{value} behind composed text"
    end
  end

  defp refute_stylesheet_fills(html, scope) do
    document = LazyHTML.from_fragment(html)

    for style <- LazyHTML.query(document, "style"),
        {selector, declarations} <- rules(LazyHTML.text(style)),
        {property, value} <- declarations,
        property in @fill_properties,
        stylesheet_rule_reaches_scope?(document, selector, scope) do
      flunk("stylesheet rule #{selector} paints #{property}:#{value} behind composed text")
    end
  end

  defp scoped_elements(html, selector) do
    document = LazyHTML.from_fragment(html)

    document
    |> LazyHTML.query(selector)
    |> Enum.flat_map(fn root -> [root | Enum.to_list(LazyHTML.query(root, "*"))] end)
    |> Enum.uniq()
  end

  defp stylesheet_rule_reaches_scope?(document, selector, scope) do
    scope_html = MapSet.new(scope, &LazyHTML.to_html/1)

    selector
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.any?(fn individual_selector ->
      Enum.any?(LazyHTML.query(document, individual_selector), fn element ->
        MapSet.member?(scope_html, LazyHTML.to_html(element))
      end)
    end)
  end

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp describe(element) do
    classes = element |> LazyHTML.attribute("class") |> List.first() || "element"
    "<#{classes}>"
  end

  defp rules(css) do
    css
    |> String.split("}")
    |> Enum.flat_map(fn block ->
      case String.split(block, "{", parts: 2) do
        [selector, body] -> [{String.trim(selector), declarations(body)}]
        _ -> []
      end
    end)
  end

  defp declarations(css) do
    css
    |> String.split(";")
    |> Enum.flat_map(fn declaration ->
      case String.split(declaration, ":", parts: 2) do
        [property, value] ->
          [{property |> String.trim() |> String.downcase(), String.trim(value)}]

        _ ->
          []
      end
    end)
  end
end
