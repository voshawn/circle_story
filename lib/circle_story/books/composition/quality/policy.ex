defmodule CircleStory.Books.Composition.Quality.Policy do
  @moduledoc """
  Explicit, replaceable policy for deterministic text composition.

  The 112px outer inset and current canvas dimensions preserve the established
  geometry. They are not printer-certified trim or binding specifications.
  """

  alias CircleStory.Books.Composition.Layout

  @contract_version "composition-quality-v1"

  @default_weights %{
    readability: 4.0,
    font_size: 1.5,
    compactness: 1.2,
    seed_proximity: 1.0,
    whitespace_balance: 0.8,
    edge_quietness: 0.5
  }

  @enforce_keys [
    :role,
    :contract_version,
    :dimensions,
    :outer_inset,
    :fold_inset,
    :internal_inset,
    :min_font,
    :preferred_font,
    :font_caps,
    :growth_step,
    :growth_steps,
    :map_cell_size,
    :candidate_transforms,
    :alignments,
    :valignments,
    :finalist_limit,
    :hard_contrast,
    :target_contrast,
    :max_low_contrast_fraction,
    :tile_size_ratio,
    :tile_stride_ratio,
    :min_tile_samples,
    :edge_threshold,
    :max_unsafe_strip_fraction,
    :max_edge_strip_fraction,
    :max_saliency_strip_fraction,
    :backing_opacities,
    :soft_weights
  ]

  defstruct @enforce_keys

  @type role :: :inner | :cover
  @type t :: %__MODULE__{}

  @doc "Stable contract identifier persisted with composition provenance."
  @spec contract_version() :: String.t()
  def contract_version, do: @contract_version

  @doc "Build the role-aware default policy, with explicit test/calibration overrides."
  @spec new(role(), keyword()) :: t()
  def new(role, overrides \\ []) when role in [:inner, :cover] do
    defaults = defaults(role)

    defaults
    |> Map.merge(Map.new(overrides))
    |> then(&struct!(__MODULE__, &1))
  end

  @doc "Hard page/fold bounds for the semantic side selected by the seed rect."
  @spec bounds_for_seed(t(), map()) :: map()
  def bounds_for_seed(%__MODULE__{role: :cover} = policy, _seed) do
    {width, height} = policy.dimensions
    inset = policy.outer_inset
    %{x: inset, y: inset, w: width - 2 * inset, h: height - 2 * inset}
  end

  def bounds_for_seed(%__MODULE__{role: :inner} = policy, seed) do
    {width, height} = policy.dimensions
    inset = policy.outer_inset
    fold = div(width, 2)
    seed_center = seed.x + seed.w / 2

    {left, right} =
      if seed_center < fold do
        {inset, fold - policy.fold_inset}
      else
        {fold + policy.fold_inset, width - inset}
      end

    %{x: left, y: inset, w: max(right - left, 1), h: height - 2 * inset}
  end

  # Gates and thresholds are shared by construction: a role states only what it
  # genuinely differs on, so a newly added gate applies to both roles.
  defp defaults(role), do: Map.merge(shared_defaults(), role_defaults(role))

  defp shared_defaults do
    %{
      contract_version: @contract_version,
      outer_inset: Layout.safe_inset(),
      # No authoritative binding number exists yet. A zero rect-level fold inset
      # preserves current geometry; the internal glyph inset still keeps ink away.
      fold_inset: 0,
      internal_inset: 48,
      min_font: 24,
      growth_steps: 3,
      map_cell_size: 32,
      candidate_transforms: [:seed, :grow, :translate, :wrap],
      alignments: [:seed, :center, :left, :right],
      valignments: [:seed, :middle, :top, :bottom],
      finalist_limit: 10,
      hard_contrast: 3.0,
      target_contrast: 4.5,
      max_low_contrast_fraction: 0.05,
      tile_size_ratio: 1.5,
      tile_stride_ratio: 0.5,
      min_tile_samples: 48,
      edge_threshold: 0.08,
      max_unsafe_strip_fraction: 0.35,
      max_edge_strip_fraction: 0.5,
      max_saliency_strip_fraction: 0.6,
      backing_opacities: [0.44, 0.6, 0.78],
      soft_weights: @default_weights
    }
  end

  defp role_defaults(:inner) do
    %{
      role: :inner,
      dimensions: Layout.inner_dims(),
      preferred_font: 64,
      font_caps: [64, 56, 48],
      growth_step: 64
    }
  end

  defp role_defaults(:cover) do
    front = Layout.front_region_local()

    %{
      role: :cover,
      dimensions: {front.w, front.h},
      preferred_font: 360,
      font_caps: [360, 300, 240],
      growth_step: 80
    }
  end
end
