defmodule CircleStory.Books.Generator do
  @moduledoc """
  Generate and compose print-ready book pages.

  ## IEx workflow

      book = CircleStory.Books.Templates.NanisMagicThread.book()

      # One AI reference portrait per character, so the same face recurs across
      # spreads. Do this first: spreads only get conditioned on the characters
      # whose reference is already attached to the book you pass in.
      {:ok, book} = CircleStory.Books.Generator.generate_character_reference(book, "Ornella")

      # ...or, in a fresh session, re-attach the newest saved portrait instead of
      # paying to regenerate it ({:error, :no_reference_image} if none is saved)
      {:ok, book} = CircleStory.Books.Generator.attach_character_reference(book, "Ornella")

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
    Character,
    CharacterSelector,
    Composition,
    CoverSpread,
    DedicationSpread,
    InnerSpread,
    PromptBuilder
  }

  alias CircleStory.Books.Actions.GenerateCharacterReference
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

  @doc "Generate an AI reference portrait for one character; returns the updated book."
  @spec generate_character_reference(Book.t(), String.t()) :: {:ok, Book.t()} | {:error, term()}
  def generate_character_reference(%Book{} = book, name) do
    with {:ok, character} <- fetch_character(book, name),
         {:ok, %{image_path: path}} <-
           GenerateCharacterReference.run(%{character: character}, %{}) do
      {:ok, put_character_reference(book, name, path)}
    end
  end

  @doc """
  Re-attach the newest saved reference for one character without regenerating.

  Returns `{:error, :no_reference_image}` when nothing is saved for that
  character: an unchanged `{:ok, book}` would be indistinguishable from a real
  attach, and the caller would go on to pay for a spread with no conditioning.
  """
  @spec attach_character_reference(Book.t(), String.t()) :: {:ok, Book.t()} | {:error, term()}
  def attach_character_reference(%Book{} = book, name) do
    with {:ok, _character} <- fetch_character(book, name) do
      case ImageOps.latest_raw(GenerateCharacterReference.reference_prefix(name)) do
        {:ok, path} -> {:ok, put_character_reference(book, name, path)}
        {:error, :no_raw_art} -> {:error, :no_reference_image}
      end
    end
  end

  @doc """
  Returns `{system_prompt, user_message}` for the given page without an API call.

  A cached render selection is reused when it matches the selector provider's
  current selection version. Otherwise the preview conservatively includes all
  configured characters, still without a model call.
  """
  @spec inspect_prompt(Book.t(), :cover | 1..9, keyword()) :: {String.t(), String.t()}
  def inspect_prompt(book, page, selector_opts \\ [])

  def inspect_prompt(%Book{} = book, :cover, selector_opts) do
    selected = CharacterSelector.for_preview(book.cover, book.characters, selector_opts)
    {PromptBuilder.system_prompt(:cover), PromptBuilder.user_message(book.cover, selected)}
  end

  def inspect_prompt(%Book{} = book, position, selector_opts) when is_integer(position) do
    spread = Enum.find(book.spreads, &(&1.position == position))
    selected = CharacterSelector.for_preview(spread, book.characters, selector_opts)
    {PromptBuilder.system_prompt(:inner), PromptBuilder.user_message(spread, selected)}
  end

  defp fetch_spread(%Book{spreads: spreads}, position) do
    case Enum.find(spreads, &(&1.position == position)) do
      nil -> {:error, "no spread at position #{position}"}
      %InnerSpread{} = spread -> {:ok, spread}
    end
  end

  defp fetch_character(%Book{characters: characters}, name) do
    case Enum.find(characters, &(&1.name == name)) do
      nil -> {:error, "no character named #{name}"}
      %Character{} = character -> {:ok, character}
    end
  end

  defp put_character_reference(%Book{characters: characters} = book, name, path) do
    characters =
      Enum.map(characters, fn
        %Character{name: ^name} = c -> %{c | reference_image_path: path}
        c -> c
      end)

    %{book | characters: characters}
  end

  defp put_cover_raw(%Book{cover: %CoverSpread{} = cover} = book, raw) do
    %{book | cover: %{cover | generated_image_path: raw}}
  end
end
