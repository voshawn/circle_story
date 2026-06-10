defmodule CircleStory.Books.Generator do
  @moduledoc """
  Generate and compose print-ready book pages.

  ## IEx workflow

      book = CircleStory.Books.Templates.NanisMagicThread.book()

      # Full path: generate art + bounding box + render component -> print-ready PNG
      {:ok, %{image_path: path}} = CircleStory.Books.Generator.generate_cover(book)
      {:ok, %{image_path: path}} = CircleStory.Books.Generator.generate_spread(book, 1)

      # Cheap re-render from cached raw art + cached bbox (no model calls)
      {:ok, %{image_path: path}} = CircleStory.Books.Generator.compose_cover(book)
      {:ok, %{image_path: path}} = CircleStory.Books.Generator.compose_spread(book, 1)
      {:ok, %{image_path: path}} = CircleStory.Books.Generator.compose_dedication(book)
  """

  alias CircleStory.Books.{
    Book,
    Composition,
    CoverSpread,
    DedicationSpread,
    InnerSpread,
    PromptBuilder
  }

  alias CircleStory.Books.Actions.GenerateSpreadImage
  alias CircleStory.Books.Composition.ImageOps

  @spec generate_cover(Book.t()) :: {:ok, map()} | {:error, term()}
  def generate_cover(%Book{} = book) do
    with {:ok, %{image_path: raw}} <-
           GenerateSpreadImage.run(
             %{spread: book.cover, characters: book.characters, spread_type: :cover},
             %{}
           ) do
      book |> put_cover_raw(raw) |> Composition.compose_cover(force_bbox: true)
    end
  end

  @spec compose_cover(Book.t()) :: {:ok, map()} | {:error, term()}
  def compose_cover(%Book{} = book) do
    with {:ok, raw} <- ImageOps.latest_raw("cover_front_") do
      book |> put_cover_raw(raw) |> Composition.compose_cover()
    end
  end

  @spec generate_spread(Book.t(), 1..9) :: {:ok, map()} | {:error, term()}
  def generate_spread(%Book{} = book, position) when position in 1..9 do
    with {:ok, spread} <- fetch_spread(book, position),
         {:ok, %{image_path: raw}} <-
           GenerateSpreadImage.run(
             %{spread: spread, characters: book.characters, spread_type: :inner},
             %{}
           ) do
      Composition.compose_spread(%{spread | generated_image_path: raw}, force_bbox: true)
    end
  end

  @spec compose_spread(Book.t(), 1..9) :: {:ok, map()} | {:error, term()}
  def compose_spread(%Book{} = book, position) when position in 1..9 do
    with {:ok, spread} <- fetch_spread(book, position),
         {:ok, raw} <- ImageOps.latest_raw("inner_#{position}_") do
      Composition.compose_spread(%{spread | generated_image_path: raw})
    end
  end

  @spec compose_dedication(Book.t()) :: {:ok, map()} | {:error, term()}
  def compose_dedication(%Book{dedication: %DedicationSpread{} = dedication}),
    do: Composition.compose_dedication(dedication)

  def compose_dedication(%Book{dedication: nil}), do: {:error, :no_dedication}

  @doc "Returns `{system_prompt, user_message}` for the given page without an API call."
  @spec inspect_prompt(Book.t(), :cover | 1..9) :: {String.t(), String.t()}
  def inspect_prompt(%Book{} = book, :cover) do
    {PromptBuilder.system_prompt(:cover), PromptBuilder.user_message(book.cover, book.characters)}
  end

  def inspect_prompt(%Book{} = book, position) when is_integer(position) do
    spread = Enum.find(book.spreads, &(&1.position == position))
    {PromptBuilder.system_prompt(:inner), PromptBuilder.user_message(spread, book.characters)}
  end

  defp fetch_spread(%Book{spreads: spreads}, position) do
    case Enum.find(spreads, &(&1.position == position)) do
      nil -> {:error, "no spread at position #{position}"}
      %InnerSpread{} = spread -> {:ok, spread}
    end
  end

  defp put_cover_raw(%Book{cover: %CoverSpread{} = cover} = book, raw) do
    %{book | cover: %{cover | generated_image_path: raw}}
  end
end
