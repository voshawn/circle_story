defmodule CircleStory.Books.Composition.Quality.Attempts do
  @moduledoc """
  Scan evidence for one kind of attempt: untreated ink, or treated backing.

  Untreated and treated attempts answer different questions — why plain ink was
  refused, and what the bounded backing search then cost — so their counts and
  rejection reasons are summarized separately and never merged.
  """

  alias CircleStory.Books.Composition.Quality.{Candidate, Diagnostics}

  @enforce_keys [:kind]
  defstruct @enforce_keys ++ [scanned: 0, passed: 0, rejected: 0, rejection_reasons: %{}]

  @type kind :: :untreated | :treated
  @type t :: %__MODULE__{
          kind: kind(),
          scanned: non_neg_integer(),
          passed: non_neg_integer(),
          rejected: non_neg_integer(),
          rejection_reasons: %{optional(term()) => pos_integer()}
        }

  @doc "Summarize every scored variant of one attempt kind."
  @spec summarize(kind(), [Candidate.t()]) :: t()
  def summarize(kind, variants) when kind in [:untreated, :treated] do
    {passing, rejected} = Enum.split_with(variants, &(&1.hard_rejections == []))

    %__MODULE__{
      kind: kind,
      scanned: length(variants),
      passed: length(passing),
      rejected: length(rejected),
      rejection_reasons: rejected |> Enum.flat_map(& &1.hard_rejections) |> Enum.frequencies()
    }
  end

  @doc "JSON-safe provenance for the placement sidecar and the development UI."
  @spec provenance(t()) :: map()
  def provenance(%__MODULE__{} = attempts) do
    %{
      scanned: attempts.scanned,
      passed: attempts.passed,
      rejected: attempts.rejected,
      rejection_reasons: Diagnostics.class_frequencies(attempts.rejection_reasons)
    }
  end

  @doc "Decode persisted attempt evidence; reasons stay strings once serialized."
  @spec decode(kind(), term()) :: map()
  def decode(kind, %{} = attempts) do
    %{
      kind: kind,
      scanned: attempts["scanned"] || 0,
      passed: attempts["passed"] || 0,
      rejected: attempts["rejected"] || 0,
      rejection_reasons: decode_reasons(attempts["rejection_reasons"])
    }
  end

  def decode(kind, _attempts),
    do: %{kind: kind, scanned: 0, passed: 0, rejected: 0, rejection_reasons: %{}}

  defp decode_reasons(%{} = reasons) do
    Map.new(reasons, fn {reason, count} -> {to_string(reason), count} end)
  end

  defp decode_reasons(_reasons), do: %{}
end
