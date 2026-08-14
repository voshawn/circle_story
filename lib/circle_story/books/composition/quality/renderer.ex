defmodule CircleStory.Books.Composition.Quality.Renderer do
  @moduledoc "Boundary for browser text fitting and finalist glyph-mask rendering."

  alias CircleStory.Books.Composition.Quality.Candidate

  @callback measure([Candidate.t()], map(), :inner | :cover) ::
              {:ok, %{String.t() => map()}} | {:error, term()}

  @callback mask(Candidate.t(), map(), :inner | :cover) ::
              {:ok, Vix.Vips.Image.t()} | {:error, term()}
end
