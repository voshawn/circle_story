defmodule CircleStory.Books.Composition.Quality.Diagnostics do
  @moduledoc """
  Bounded, content-free classes for renderer and image-library diagnostics.

  Faults arrive as opaque third-party terms: a ChromicPDF exit reason carries
  the whole `GenServer.call/3` argument list, which includes the page document,
  and an exception message can quote whatever it was raised over. Neither may be
  persisted into the placement sidecar or rendered in the development UI, and
  neither has a bounded size. Every reason is therefore reduced here to a class
  named only by the atom tags that identify the fault; any other payload
  contributes its type and nothing else.
  """

  @max_segments 4
  @max_length 96

  @doc "Bounded class name for one diagnostic reason, carrying no payload text."
  @spec reason_class(term()) :: String.t()
  def reason_class(reason) do
    case tags(reason, @max_segments) do
      [] -> type_name(reason)
      tags -> tags |> Enum.join(":") |> String.slice(0, @max_length)
    end
  end

  @doc """
  Re-key a raw reason frequency map onto bounded classes, summing collisions.

  Classing is deliberately many-to-one — two libvips faults with different
  payloads share the `image_binary_failed` class — so counts are added rather
  than overwritten and the totals still reconcile with `rejected`.
  """
  @spec class_frequencies(%{optional(term()) => non_neg_integer()}) :: %{
          optional(String.t()) => non_neg_integer()
        }
  def class_frequencies(frequencies) do
    Enum.reduce(frequencies, %{}, fn {reason, count}, classes ->
      Map.update(classes, reason_class(reason), count, &(&1 + count))
    end)
  end

  defp tags(_reason, budget) when budget <= 0, do: []
  defp tags(reason, _budget) when is_atom(reason), do: [atom_label(reason)]

  # Only tuples are walked. Lists and maps are payloads — a renderer exit's
  # argument list is exactly where the document hides — so they never contribute.
  defp tags(reason, budget) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.reduce([], fn element, taken ->
      taken ++ tags(element, budget - length(taken))
    end)
  end

  defp tags(_reason, _budget), do: []

  defp type_name(reason) when is_binary(reason), do: "string"
  defp type_name(reason) when is_bitstring(reason), do: "bitstring"
  defp type_name(reason) when is_integer(reason), do: "integer"
  defp type_name(reason) when is_float(reason), do: "float"
  defp type_name(reason) when is_list(reason), do: "list"
  defp type_name(reason) when is_tuple(reason), do: "tuple"
  defp type_name(%module{}), do: atom_label(module)
  defp type_name(reason) when is_map(reason), do: "map"
  defp type_name(reason) when is_pid(reason), do: "pid"
  defp type_name(reason) when is_reference(reason), do: "reference"
  defp type_name(reason) when is_port(reason), do: "port"
  defp type_name(reason) when is_function(reason), do: "function"
  defp type_name(_reason), do: "unknown"

  defp atom_label(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> module -> module
      name -> name
    end
  end
end
