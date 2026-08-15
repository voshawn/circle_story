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
    document = LazyHTML.from_fragment(html)

    assert Enum.any?(LazyHTML.query(document, ".fit-text")),
           "expected the rendered page to publish text in a .fit-text box"

    refute_fills(document, ".fit-text")
  end

  @doc """
  Assert no element matching `selector`, or nested inside it, paints a fill.

  Used for pages whose text sits over art alone, where a backing rectangle has
  nowhere legitimate to hide - including as a sibling behind the text box.
  """
  @spec assert_no_fill_anywhere(String.t(), String.t()) :: :ok
  def assert_no_fill_anywhere(html, selector \\ "*") do
    html |> LazyHTML.from_fragment() |> refute_fills(selector)
  end

  defp refute_fills(document, selector) do
    scope = scoped_elements(document, selector)
    refute_inline_fills(scope)
    refute_stylesheet_fills(document, scope)
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

  defp refute_stylesheet_fills(document, scope) do
    for style <- LazyHTML.query(document, "style"),
        {selector, declarations} <- rules(LazyHTML.text(style)),
        {property, value} <- declarations,
        property in @fill_properties,
        stylesheet_rule_reaches_scope?(selector, scope) do
      flunk("stylesheet rule #{selector} paints #{property}:#{value} behind composed text")
    end
  end

  defp scoped_elements(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.flat_map(fn root -> [root | Enum.to_list(LazyHTML.query(root, "*"))] end)
  end

  # Membership is decided by matching the selector against each scoped node in
  # place, so the node keeps its ancestors and two structurally identical
  # elements in different parts of the page stay distinguishable.
  defp stylesheet_rule_reaches_scope?(selector, scope) do
    Enum.any?(scope, &selector_matches?(&1, selector))
  end

  defp selector_matches?(element, selector) do
    element |> LazyHTML.filter(selector) |> Enum.any?()
  rescue
    # A selector this parser cannot evaluate is treated as reaching the scope:
    # an unreadable rule must not be a way to paint behind the text unnoticed.
    ArgumentError -> true
  end

  defp describe(element) do
    classes = element |> LazyHTML.attribute("class") |> List.first() || "element"
    "<#{classes}>"
  end

  # Blocks are read with brace tracking rather than a naive split, so a rule
  # nested inside an at-rule (`@media print { .fit-text { background:#fff } }`)
  # is still parsed as a selector with declarations. An at-rule's own
  # declarations describe the page or a font, not an element in scope, so only
  # its nested rules are collected.
  defp rules(css), do: css |> strip_comments() |> parse_rules("", [])

  defp strip_comments(css), do: String.replace(css, ~r|/\*.*?\*/|s, " ")

  defp parse_rules("", _prelude, rules), do: Enum.reverse(rules)

  defp parse_rules(<<"{", rest::binary>>, prelude, rules) do
    {body, remainder} = take_block(rest, 0, "")
    parse_rules(remainder, "", collect_rule(String.trim(prelude), body, rules))
  end

  defp parse_rules(<<"}", rest::binary>>, _prelude, rules), do: parse_rules(rest, "", rules)

  defp parse_rules(<<character::utf8, rest::binary>>, prelude, rules),
    do: parse_rules(rest, prelude <> <<character::utf8>>, rules)

  defp take_block("", _depth, body), do: {body, ""}
  defp take_block(<<"}", rest::binary>>, 0, body), do: {body, rest}

  defp take_block(<<"}", rest::binary>>, depth, body),
    do: take_block(rest, depth - 1, body <> "}")

  defp take_block(<<"{", rest::binary>>, depth, body),
    do: take_block(rest, depth + 1, body <> "{")

  defp take_block(<<character::utf8, rest::binary>>, depth, body),
    do: take_block(rest, depth, body <> <<character::utf8>>)

  defp collect_rule(selector, body, rules) do
    cond do
      String.contains?(body, "{") -> Enum.reverse(parse_rules(body, "", [])) ++ rules
      String.starts_with?(selector, "@") -> rules
      selector == "" -> rules
      true -> [{selector, declarations(body)} | rules]
    end
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
