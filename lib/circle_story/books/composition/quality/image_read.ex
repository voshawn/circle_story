defmodule CircleStory.Books.Composition.Quality.ImageRead do
  @moduledoc """
  The single boundary between raising libvips reads and deterministic steps.

  Vix's `!` operations raise on a decode, colorspace, or cast fault, while every
  `Quality` step and `Composition.compose_spread/2` itself are specced
  `{:ok, _} | {:error, _}`. A libvips fault is therefore turned into the bounded
  `{:image_binary_failed, module}` reason that `Diagnostics` already classes,
  instead of an exception escaping the contract. Only the exception module is
  carried: a libvips message can quote whatever path or pixel data it was raised
  over and has no bounded size.
  """

  @doc "Run a libvips read, converting a raise into a bounded image-fault result."
  @spec guard((-> result)) :: result | {:error, {:image_binary_failed, module()}} when result: var
  def guard(read) when is_function(read, 0) do
    read.()
  rescue
    error -> {:error, {:image_binary_failed, error.__struct__}}
  end
end
