defmodule CircleStory.Books.Generator do
  @moduledoc """
  Convenience functions for generating and inspecting book spread images.

  ## IEx workflow

      book = CircleStory.Books.Templates.NanisMagicThread.book()

      # Inspect the prompt before generating
      {sys, user} = CircleStory.Books.Generator.inspect_prompt(book, :cover)
      IO.puts(user)

      # Generate a single page
      {:ok, %{image_path: path}} = CircleStory.Books.Generator.generate_cover(book)
      {:ok, %{image_path: path}} = CircleStory.Books.Generator.generate_spread(book, 1)
  """

  alias CircleStory.Books.{Book, PromptBuilder}
  alias CircleStory.Books.Actions.GenerateSpreadImage

  @spec generate_cover(Book.t()) :: {:ok, map()} | {:error, term()}
  def generate_cover(%Book{} = book) do
    GenerateSpreadImage.run(
      %{spread: book.cover, characters: book.characters, spread_type: :cover},
      %{}
    )
  end

  @spec generate_spread(Book.t(), 1..9) :: {:ok, map()} | {:error, term()}
  def generate_spread(%Book{} = book, position) when position in 1..9 do
    case Enum.find(book.spreads, &(&1.position == position)) do
      nil ->
        {:error, "no spread at position #{position}"}

      spread ->
        GenerateSpreadImage.run(
          %{spread: spread, characters: book.characters, spread_type: :inner},
          %{}
        )
    end
  end

  @doc """
  Returns `{system_prompt, user_message}` for the given page without making an API call.

  Pass `:cover` for the cover, or an integer 1–9 for inner spreads.
  """
  @spec inspect_prompt(Book.t(), :cover | 1..9) :: {String.t(), String.t()}
  def inspect_prompt(%Book{} = book, :cover) do
    {PromptBuilder.system_prompt(:cover), PromptBuilder.user_message(book.cover, book.characters)}
  end

  def inspect_prompt(%Book{} = book, position) when is_integer(position) do
    spread = Enum.find(book.spreads, &(&1.position == position))
    {PromptBuilder.system_prompt(:inner), PromptBuilder.user_message(spread, book.characters)}
  end
end
