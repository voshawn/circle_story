defmodule CircleStory.Books.Composition.Quality.Attempts do
  @moduledoc """
  Privacy-safe scan evidence for transparent black/white text candidates.

  A variant meets the preferred thresholds only when both its non-negotiable
  geometry/render checks and its readability checks pass. Below-threshold
  variants remain auditable ranking evidence for the transparent fallback.
  """

  alias CircleStory.Books.Composition.Quality.{Candidate, Diagnostics}

  @enforce_keys [:kind]
  defstruct @enforce_keys ++ [scanned: 0, passed: 0, rejected: 0, rejection_reasons: %{}]

  @type kind :: :transparent
  @type t :: %__MODULE__{
          kind: kind(),
          scanned: non_neg_integer(),
          passed: non_neg_integer(),
          rejected: non_neg_integer(),
          rejection_reasons: %{optional(term()) => pos_integer()}
        }

  @doc "Summarize every scored transparent black/white variant."
  @spec summarize(kind(), [Candidate.t()]) :: t()
  def summarize(:transparent, variants) do
    {passing, rejected} = Enum.split_with(variants, &Candidate.preferred?/1)

    %__MODULE__{
      kind: :transparent,
      scanned: length(variants),
      passed: length(passing),
      rejected: length(rejected),
      rejection_reasons: rejected |> Enum.flat_map(&rejections/1) |> Enum.frequencies()
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
  def decode(:transparent, %{} = attempts) do
    %{
      kind: :transparent,
      scanned: attempts["scanned"] || 0,
      passed: attempts["passed"] || 0,
      rejected: attempts["rejected"] || 0,
      rejection_reasons: decode_reasons(attempts["rejection_reasons"])
    }
  end

  def decode(:transparent, _attempts),
    do: %{kind: :transparent, scanned: 0, passed: 0, rejected: 0, rejection_reasons: %{}}

  defp rejections(candidate),
    do: candidate.hard_rejections ++ candidate.readability_rejections

  defp decode_reasons(%{} = reasons) do
    Map.new(reasons, fn {reason, count} -> {to_string(reason), count} end)
  end

  defp decode_reasons(_reasons), do: %{}
end
