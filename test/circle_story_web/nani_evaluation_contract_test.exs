defmodule CircleStoryWeb.NaniEvaluationContractTest do
  use ExUnit.Case, async: false

  alias CircleStory.Books.CharacterSelector
  alias CircleStory.Books.Templates.NanisMagicThread
  alias CircleStory.CharacterSelectorProviderFake
  alias CircleStoryWeb.NaniEvaluationLive

  setup do
    previous_provider =
      Application.get_env(:circle_story, :character_selector_provider)

    Application.put_env(
      :circle_story,
      :character_selector_provider,
      CharacterSelectorProviderFake
    )

    dir =
      Path.join(
        System.tmp_dir!(),
        "circle_story_nani_contract_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    on_exit(fn ->
      Application.put_env(:circle_story, :character_selector_provider, previous_provider)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  test "mount reconstruction and reconnect reconstruction never select or call a model", %{
    dir: dir
  } do
    File.write!(Path.join(dir, "nani.jpg"), "source discovery only checks the file")

    first = NaniEvaluationLive.reconstruct(source_dir: dir)
    second = NaniEvaluationLive.reconstruct(source_dir: dir)

    assert first.book.title == "Nani's Magic Thread"
    assert second.book.title == first.book.title

    assert Enum.find(first.book.characters, &(&1.name == "Nani")).source_image_path ==
             Path.join(dir, "nani.jpg")

    assert length(first.characters) == 5
    assert length(first.pages) == 11
    refute_receive {:character_selector_called, _, _}
  end

  test "a same-basename composed overwrite changes the URLs used for rendering", %{dir: dir} do
    generated_dir = Path.join(:code.priv_dir(:circle_story), "generated_images")
    print_ready_dir = Path.join(:code.priv_dir(:circle_story), "print_ready")
    basename = "inner_9_99#{System.unique_integer([:positive])}.png"
    raw = Path.join(generated_dir, basename)
    composed = Path.join(print_ready_dir, basename)

    File.mkdir_p!(generated_dir)
    File.mkdir_p!(print_ready_dir)
    File.write!(raw, "synthetic raw fixture")
    File.write!(composed, "first composed fixture")
    File.touch!(composed, 1_700_000_000)

    on_exit(fn ->
      File.rm(raw)
      File.rm(composed)
    end)

    first = NaniEvaluationLive.reconstruct(source_dir: dir)
    first_page = Enum.find(first.pages, &(&1.page == 9))
    first_stat = File.stat!(composed, time: :posix)
    first_version = "#{first_stat.mtime}-#{first_stat.size}"

    assert URI.decode_query(URI.parse(first_page.composed.full_url).query) == %{
             "v" => first_version
           }

    assert URI.decode_query(URI.parse(first_page.composed.thumbnail_url).query) == %{
             "v" => first_version,
             "variant" => "thumbnail"
           }

    File.write!(composed, "replacement composed fixture with different bytes")
    File.touch!(composed, 1_700_000_000)

    second = NaniEvaluationLive.reconstruct(source_dir: dir)
    second_page = Enum.find(second.pages, &(&1.page == 9))

    assert second_page.composed.basename == first_page.composed.basename
    assert second_page.composed.modified_at == first_page.composed.modified_at
    refute second_page.composed.full_url == first_page.composed.full_url
    refute second_page.composed.thumbnail_url == first_page.composed.thumbnail_url
    assert second_page.raw.thumbnail_url == first_page.raw.thumbnail_url
  end

  test "cold batch planning counts the exact calls driven by its sequential stages", %{dir: dir} do
    cache_dir = Path.join(dir, "empty-selection-cache")
    book = NanisMagicThread.book()

    plan =
      NaniEvaluationLive.plan_batch(book,
        provider: CharacterSelectorProviderFake,
        cache_dir: cache_dir
      )

    assert plan.total_calls == 35
    assert plan.image_calls == 15
    assert Enum.map(Enum.take(plan.stages, 5), & &1.kind) == List.duplicate(:portrait, 5)
    assert Enum.all?(Enum.drop(plan.stages, 5), &(&1.kind == :generate_page))

    parent = self()

    runner = fn stage, current_book ->
      send(parent, {:invoked_stage, stage})
      {:ok, current_book, %{fake: true}}
    end

    assert {:ok, result} =
             NaniEvaluationLive.execute_plan(plan, book, stage_runner: runner)

    invoked = collect_invoked(length(plan.stages))
    invoked_call_count = Enum.sum(for stage <- invoked, call <- stage.calls, do: call.count)

    assert invoked_call_count == plan.total_calls
    assert length(result.completed_item_keys) == length(plan.stages)
  end

  test "a current selector cache makes the page confirmation count honest", %{dir: dir} do
    book = NanisMagicThread.book()
    spread = book.cover
    cache_dir = Path.join(dir, "selection-cache")

    send(self(), {:character_selector_response, {:ok, ["Nani", "Ornella"]}})

    CharacterSelector.for_spread(spread, book.characters,
      provider: CharacterSelectorProviderFake,
      cache_dir: cache_dir
    )

    assert_receive {:character_selector_called, ^spread, _names}

    assert {:ok, plan} =
             NaniEvaluationLive.plan_action(book, :generate_page, :cover,
               provider: CharacterSelectorProviderFake,
               cache_dir: cache_dir
             )

    assert plan.total_calls == 2

    assert Enum.map(plan.calls, & &1.type) |> Enum.sort() ==
             ["Image generation", "Text placement"]

    refute_receive {:character_selector_called, _, _}
  end

  defp collect_invoked(count) do
    Enum.map(1..count, fn _index ->
      assert_receive {:invoked_stage, stage}
      stage
    end)
  end
end
