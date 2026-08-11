defmodule CircleStory.Books.Composition.Quality.Context do
  @moduledoc "Explicit immutable state passed through deterministic composition steps."

  alias CircleStory.Books.Composition.Quality.Policy

  @enforce_keys [:image, :content, :placement, :seed_rect, :policy, :renderer]
  defstruct @enforce_keys ++
              [
                :bounds,
                :safety_map,
                :safe_canvas,
                :selected,
                candidates: [],
                measured: [],
                finalists: [],
                untreated: [],
                treated: [],
                evaluated: [],
                evidence: %{}
              ]

  @type t :: %__MODULE__{
          image: Vix.Vips.Image.t(),
          content: map(),
          placement: map(),
          seed_rect: map(),
          policy: Policy.t(),
          renderer: module(),
          bounds: map() | nil,
          safety_map: struct() | nil,
          safe_canvas: map() | nil,
          candidates: list(),
          measured: list(),
          finalists: list(),
          untreated: list(),
          treated: list(),
          evaluated: list(),
          selected: struct() | nil,
          evidence: map()
        }
end
