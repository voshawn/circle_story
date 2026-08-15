defmodule CircleStoryWeb.NaniEvaluationLive do
  @moduledoc """
  Development-only evaluation surface for the fixed Nani image pipeline.

  Mounting and rebuilding this LiveView only inspect code and local files. Model
  calls are reachable exclusively through confirmed async actions.
  """

  use CircleStoryWeb, :live_view

  alias CircleStory.Books.{Book, CharacterSelector, Composition, Generator, PromptBuilder}

  alias CircleStory.Books.Actions.{GeminiImage, PlaceText}

  alias CircleStory.Books.CharacterSelector.Gemini, as: SelectorGemini
  alias CircleStory.Books.Composition.ImageOps
  alias CircleStory.Books.Composition.Quality.{Attempts, Diagnostics, Result}
  alias CircleStory.Books.Templates.NanisMagicThread

  @source_extensions ~w(.png .jpg .jpeg .webp)
  @pipeline_task :nani_pipeline
  @threshold_pass_outcome Result.threshold_pass_outcome()
  @fallback_outcome Result.fallback_outcome()

  @impl true
  def mount(_params, _session, socket) do
    evaluation = reconstruct()

    {:ok,
     socket
     |> assign(:page_title, "Nani pipeline lab")
     |> assign(:book, evaluation.book)
     |> assign(:stats, evaluation.stats)
     |> assign(:batch_plan, evaluation.batch_plan)
     |> assign(:batch_review?, false)
     |> assign(:batch_error, nil)
     |> assign(:batch_form, to_form(%{"confirmation" => ""}, as: :batch))
     |> assign(:pending, nil)
     |> assign(:active, nil)
     |> assign(:ignore_pipeline_exit?, false)
     |> assign(:errors, %{})
     |> assign(:notice, nil)
     |> assign(:session_items, MapSet.new())
     |> assign(:credential_available?, credential_available?())
     |> stream(:characters, evaluation.characters,
       dom_id: fn character -> "character-#{character.id}" end
     )
     |> stream(:pages, evaluation.pages, dom_id: fn page -> "page-#{page.id}" end)}
  end

  @doc false
  @spec reconstruct(keyword()) :: map()
  def reconstruct(opts \\ []) do
    book = load_book(opts)
    characters = Enum.map(book.characters, &character_card/1)
    pages = page_cards(book)

    %{
      book: book,
      characters: characters,
      pages: pages,
      batch_plan: plan_batch(book),
      stats: %{
        references: Enum.count(characters, & &1.reference),
        raw_art: Enum.count(pages, & &1.raw),
        composed: Enum.count(pages, & &1.composed)
      }
    }
  end

  @doc false
  @spec load_book(keyword()) :: Book.t()
  def load_book(opts \\ []) do
    source_dir =
      Keyword.get_lazy(opts, :source_dir, fn ->
        Path.join(:code.priv_dir(:circle_story), "source_images")
      end)

    NanisMagicThread.book()
    |> attach_source_photos(source_dir)
    |> attach_saved_references()
  end

  @doc false
  @spec plan_action(Book.t(), :portrait | :generate_page | :replace_text, term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def plan_action(book, action, target, selector_opts \\ [])

  def plan_action(%Book{} = book, :portrait, name, _selector_opts) when is_binary(name) do
    if Enum.any?(book.characters, &(&1.name == name)) do
      calls = [call("Image generation", GeminiImage.model())]
      stage = stage(:portrait, "character:#{source_basename(name)}", name, name, calls)
      {:ok, plan(:portrait, name, name, [stage])}
    else
      {:error, :unknown_character}
    end
  end

  def plan_action(%Book{} = book, :generate_page, page, selector_opts) do
    with {:ok, spread, key, label} <- page_target(book, page) do
      selector_calls =
        if CharacterSelector.cache_status(spread, book.characters, selector_opts) == :model do
          []
        else
          [call("Character selection", SelectorGemini.model())]
        end

      calls =
        selector_calls ++
          [
            call("Image generation", GeminiImage.model()),
            call("Text placement", PlaceText.model())
          ]

      stage = stage(:generate_page, key, label, page, calls)
      {:ok, plan(:generate_page, page, label, [stage])}
    end
  end

  def plan_action(%Book{} = book, :replace_text, page, _selector_opts) do
    with {:ok, _spread, key, label} <- page_target(book, page),
         {:ok, _raw} <- latest_raw(page) do
      calls = [call("Text placement", PlaceText.model())]
      stage = stage(:replace_text, key, label, page, calls)
      {:ok, plan(:replace_text, page, label, [stage])}
    end
  end

  def plan_action(_book, _action, _target, _selector_opts), do: {:error, :invalid_action}

  @doc false
  @spec plan_batch(Book.t(), keyword()) :: map()
  def plan_batch(book, selector_opts \\ [])

  def plan_batch(%Book{} = book, selector_opts) do
    portrait_stages =
      Enum.map(book.characters, fn character ->
        {:ok, portrait} = plan_action(book, :portrait, character.name, selector_opts)
        List.first(portrait.stages)
      end)

    page_stages =
      Enum.map([:cover | Enum.to_list(1..9)], fn page ->
        {:ok, page_plan} = plan_action(book, :generate_page, page, selector_opts)
        List.first(page_plan.stages)
      end)

    plan(:batch, :batch, "the whole Nani book", portrait_stages ++ page_stages)
  end

  @doc false
  @spec execute_plan(map(), Book.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def execute_plan(plan, %Book{} = book, opts \\ []) do
    runner = Keyword.get(opts, :stage_runner, &run_stage/2)
    notify = Keyword.get(opts, :notify, fn _event -> :ok end)

    plan.stages
    |> Enum.reduce_while({book, []}, fn stage, {current_book, completed} ->
      notify.({:started, stage})

      case safely_run_stage(runner, stage, current_book) do
        {:ok, updated_book, result} ->
          notify.({:completed, stage, result})
          {:cont, {updated_book, [stage.item_key | completed]}}

        {:error, reason} ->
          {:halt,
           {:error, %{stage: stage, reason: reason, completed_item_keys: Enum.reverse(completed)}}}
      end
    end)
    |> case do
      {:error, failure} ->
        {:error, failure}

      {updated_book, completed} ->
        {:ok, %{book: updated_book, completed_item_keys: Enum.reverse(completed)}}
    end
  end

  @impl true
  def handle_event("prepare-paid", %{"action" => action, "item" => item}, socket) do
    with false <- busy?(socket),
         {:ok, plan} <- event_plan(socket.assigns.book, action, item) do
      {:noreply, socket |> assign(pending: plan, notice: nil) |> refresh_evaluation()}
    else
      true -> {:noreply, assign(socket, :notice, "Finish or cancel the current action first.")}
      {:error, reason} -> {:noreply, assign(socket, :notice, format_error(reason))}
    end
  end

  def handle_event("cancel-confirmation", _params, socket) do
    {:noreply,
     socket
     |> assign(pending: nil, notice: "Confirmation cancelled. No model calls made.")
     |> refresh_evaluation()}
  end

  def handle_event("confirm-paid", _params, socket) do
    case {busy?(socket), socket.assigns.pending} do
      {true, _pending} ->
        {:noreply, assign(socket, :notice, "Finish or cancel the current action first.")}

      {false, nil} ->
        {:noreply, assign(socket, :notice, "That confirmation is no longer active.")}

      {false, pending} ->
        with {:ok, current_plan} <-
               plan_action(socket.assigns.book, pending.action, pending.target) do
          cond do
            not equivalent_plan?(pending, current_plan) ->
              {:noreply,
               assign(socket,
                 pending: current_plan,
                 notice:
                   "Cache state changed. Review the updated call count before confirming again."
               )}

            not credential_available?() ->
              {:noreply,
               assign(socket,
                 credential_available?: false,
                 notice: "GOOGLE_API_KEY is missing. No model call was attempted."
               )}

            true ->
              {:noreply, start_execution(socket, current_plan)}
          end
        else
          {:error, reason} ->
            {:noreply, assign(socket, pending: nil, notice: format_error(reason))}
        end
    end
  end

  def handle_event("review-batch", _params, socket) do
    if busy?(socket) do
      {:noreply, assign(socket, :notice, "Finish or cancel the current action first.")}
    else
      {:noreply,
       socket
       |> assign(
         batch_review?: true,
         batch_error: nil,
         batch_form: to_form(%{"confirmation" => ""}, as: :batch),
         pending: nil,
         notice: nil
       )
       |> refresh_evaluation()}
    end
  end

  def handle_event("validate-batch", %{"batch" => params}, socket) do
    {:noreply,
     assign(socket,
       batch_form: to_form(params, as: :batch),
       batch_error: nil
     )}
  end

  def handle_event("cancel-batch-confirmation", _params, socket) do
    {:noreply,
     assign(socket,
       batch_review?: false,
       batch_error: nil,
       batch_form: to_form(%{"confirmation" => ""}, as: :batch),
       notice: "Whole-book confirmation cancelled. No model calls made."
     )}
  end

  def handle_event("start-batch", %{"batch" => %{"confirmation" => phrase}}, socket) do
    current_plan = plan_batch(socket.assigns.book)

    cond do
      not socket.assigns.batch_review? ->
        {:noreply, assign(socket, :batch_error, "Review the whole-book plan first.")}

      busy?(socket) ->
        {:noreply, assign(socket, :batch_error, "Finish or cancel the current action first.")}

      phrase != "GENERATE" ->
        {:noreply, assign(socket, :batch_error, "Type GENERATE exactly to continue.")}

      not equivalent_plan?(socket.assigns.batch_plan, current_plan) ->
        {:noreply,
         assign(socket,
           batch_plan: current_plan,
           batch_error: "Cache state changed. Review the updated call count and submit again."
         )}

      not credential_available?() ->
        {:noreply,
         assign(socket,
           credential_available?: false,
           batch_error: "GOOGLE_API_KEY is missing. No model call was attempted."
         )}

      true ->
        {:noreply, start_execution(socket, current_plan)}
    end
  end

  def handle_event("run-free", %{"action" => action, "item" => item}, socket) do
    with false <- busy?(socket),
         {:ok, plan} <- free_plan(socket.assigns.book, action, item) do
      {:noreply, start_execution(socket, plan)}
    else
      true -> {:noreply, assign(socket, :notice, "Finish or cancel the current action first.")}
      {:error, reason} -> {:noreply, assign(socket, :notice, format_error(reason))}
    end
  end

  def handle_event("cancel-active", _params, socket) do
    case socket.assigns.active do
      nil ->
        {:noreply, socket}

      active ->
        socket = cancel_async(socket, @pipeline_task)
        key = active.current_item_key || active.plan.item_key

        {:noreply,
         socket
         |> assign(:active, nil)
         |> assign(:ignore_pipeline_exit?, true)
         |> assign(:pending, nil)
         |> assign(:notice, "Action cancelled. Completed files were preserved on disk.")
         |> assign(
           :errors,
           Map.put(socket.assigns.errors, key, error_entry("Cancelled by operator."))
         )
         |> refresh_evaluation()}
    end
  end

  @impl true
  def handle_info({:nani_pipeline, run_ref, {:started, stage}}, socket) do
    updated =
      update_active(socket, run_ref, fn active ->
        %{active | current_item_key: stage.item_key, current_label: stage.item_label}
      end)

    if updated.assigns.active && updated.assigns.active.run_ref == run_ref do
      {:noreply, refresh_evaluation(updated)}
    else
      {:noreply, updated}
    end
  end

  def handle_info({:nani_pipeline, run_ref, {:completed, stage, _result}}, socket) do
    socket =
      update_active(socket, run_ref, fn active ->
        %{active | completed: active.completed + 1}
      end)

    if socket.assigns.active && socket.assigns.active.run_ref == run_ref do
      {:noreply,
       socket
       |> assign(:session_items, MapSet.put(socket.assigns.session_items, stage.item_key))
       |> assign(:errors, Map.delete(socket.assigns.errors, stage.item_key))
       |> refresh_evaluation()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(@pipeline_task, {:ok, {:ok, _result}}, socket) do
    {:noreply,
     socket
     |> assign(:active, nil)
     |> assign(:pending, nil)
     |> assign(:batch_review?, false)
     |> assign(:notice, "Action complete. Artifacts were refreshed from disk.")
     |> refresh_evaluation()}
  end

  def handle_async(@pipeline_task, {:ok, {:error, failure}}, socket) do
    entry = error_entry(failure.reason)

    {:noreply,
     socket
     |> assign(:active, nil)
     |> assign(:pending, nil)
     |> assign(:notice, "Action stopped. Previous and completed artifacts remain on disk.")
     |> assign(:errors, Map.put(socket.assigns.errors, failure.stage.item_key, entry))
     |> refresh_evaluation()}
  end

  def handle_async(
        @pipeline_task,
        {:exit, _reason},
        %{assigns: %{ignore_pipeline_exit?: true}} = socket
      ) do
    {:noreply, assign(socket, :ignore_pipeline_exit?, false)}
  end

  def handle_async(@pipeline_task, {:exit, reason}, socket) do
    key =
      case socket.assigns.active do
        nil -> "batch"
        active -> active.current_item_key || active.plan.item_key
      end

    {:noreply,
     socket
     |> assign(:active, nil)
     |> assign(:pending, nil)
     |> assign(:notice, "The async action exited. Existing files were retained.")
     |> assign(:errors, Map.put(socket.assigns.errors, key, error_entry(reason)))
     |> refresh_evaluation()}
  end

  defp attach_source_photos(%Book{} = book, source_dir) do
    characters =
      Enum.map(book.characters, fn character ->
        source =
          @source_extensions
          |> Enum.map(&Path.join(source_dir, source_basename(character.name) <> &1))
          |> Enum.find(&File.regular?/1)

        %{character | source_image_path: source}
      end)

    %{book | characters: characters}
  end

  defp attach_saved_references(%Book{} = book) do
    Enum.reduce(book.characters, book, fn character, current_book ->
      case Generator.attach_character_reference(current_book, character.name) do
        {:ok, updated_book} -> updated_book
        {:error, :no_reference_image} -> current_book
      end
    end)
  end

  defp source_basename(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp character_card(character) do
    %{
      id: source_basename(character.name),
      key: "character:#{source_basename(character.name)}",
      name: character.name,
      prompt: String.trim(character.image_prompt),
      system_prompt: PromptBuilder.system_prompt(:character),
      user_prompt: PromptBuilder.character_message(character),
      source_photo?: is_binary(character.source_image_path),
      reference: artifact(character.reference_image_path, "generated")
    }
  end

  defp page_cards(book) do
    [page_card(book, :cover)] ++
      Enum.map(1..9, &page_card(book, &1)) ++ [dedication_card(book)]
  end

  defp page_card(book, page) do
    {:ok, spread, key, label} = page_target(book, page)
    raw_path = latest_raw_path(page)
    composed_path = composed_path(raw_path)
    {system_prompt, user_prompt} = Generator.inspect_prompt(book, page)
    selected = CharacterSelector.for_preview(spread, book.characters)
    selection_source = CharacterSelector.cache_status(spread, book.characters)
    placement = placement(raw_path)

    %{
      id: page_id(page),
      key: key,
      kind: :art,
      page: page,
      label: label,
      story_text: Map.get(spread, :text) || Map.get(spread, :tagline),
      raw: artifact(raw_path, "generated"),
      composed: artifact(composed_path, "print-ready"),
      placement: placement,
      selection_source: selection_source,
      selected_names: Enum.map(selected, & &1.name),
      system_prompt: system_prompt,
      user_prompt: user_prompt,
      can_replace?: is_binary(raw_path),
      can_recompose?:
        match?(%{source: source} when source in [:model, :fallback, :unknown], placement)
    }
  end

  defp dedication_card(book) do
    path = Path.join([:code.priv_dir(:circle_story), "print_ready", "dedication.png"])

    %{
      id: "dedication",
      key: "page:dedication",
      kind: :dedication,
      page: :dedication,
      label: "Dedication",
      story_text: book.dedication.text,
      raw: nil,
      composed: artifact(if(File.regular?(path), do: path), "print-ready"),
      placement: %{source: :not_applicable},
      selection_source: :not_applicable,
      selected_names: [],
      system_prompt: nil,
      user_prompt: nil,
      can_replace?: false,
      can_recompose?: true
    }
  end

  defp artifact(nil, _root), do: nil

  defp artifact(path, root) do
    if File.regular?(path) do
      basename = Path.basename(path)
      base_url = "/dev/books/nani/artifacts/#{root}/#{URI.encode(basename)}"
      stat = File.stat!(path, time: :posix)
      # Place Text and Recompose overwrite the artifact in place, so the basename
      # alone never changes and the browser keeps showing its cached copy. Version
      # both URLs off the stat we already read so a rewrite moves the `img` src.
      version = "#{stat.mtime}-#{stat.size}"

      %{
        basename: basename,
        full_url: base_url <> "?v=#{version}",
        thumbnail_url: base_url <> "?variant=thumbnail&v=#{version}",
        generated_at: filename_timestamp(basename),
        modified_at: format_timestamp(stat.mtime)
      }
    end
  end

  defp filename_timestamp(basename) do
    case Regex.run(~r/_(\d+)\.png$/, basename, capture: :all_but_first) do
      [unix] -> unix |> String.to_integer() |> format_timestamp()
      _ -> "Not encoded in filename"
    end
  end

  defp format_timestamp(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
      {:error, _} -> "Invalid timestamp"
    end
  end

  defp latest_raw_path(:cover), do: ok_path(ImageOps.latest_raw("cover_front_"))
  defp latest_raw_path(position), do: ok_path(ImageOps.latest_raw("inner_#{position}_"))

  defp latest_raw(page) do
    case latest_raw_path(page) do
      nil -> {:error, :no_raw_art}
      path -> {:ok, path}
    end
  end

  defp ok_path({:ok, path}), do: path
  defp ok_path({:error, _reason}), do: nil

  defp composed_path(nil), do: nil

  defp composed_path(raw) do
    path = Path.join([:code.priv_dir(:circle_story), "print_ready", Path.basename(raw)])
    if File.regular?(path), do: path
  end

  defp placement(nil), do: %{source: :missing}

  defp placement(raw) do
    case Composition.cached_placement(raw) do
      {:ok, box} -> box
      {:error, _reason} -> %{source: :missing}
    end
  end

  defp page_target(book, :cover),
    do: {:ok, book.cover, "page:cover", "Front & back cover"}

  defp page_target(book, position) when position in 1..9 do
    case Enum.find(book.spreads, &(&1.position == position)) do
      nil -> {:error, :unknown_page}
      spread -> {:ok, spread, "page:spread-#{position}", "Spread #{position}"}
    end
  end

  defp page_target(_book, _page), do: {:error, :unknown_page}

  defp page_id(:cover), do: "cover"
  defp page_id(position), do: "spread-#{position}"

  defp call(type, model), do: %{type: type, model: model, count: 1}

  defp stage(kind, item_key, item_label, target, calls) do
    %{kind: kind, item_key: item_key, item_label: item_label, target: target, calls: calls}
  end

  defp plan(action, target, label, stages) do
    calls = stages |> Enum.flat_map(& &1.calls) |> summarize_calls()

    %{
      action: action,
      target: target,
      item_key: if(action == :batch, do: "batch", else: List.first(stages).item_key),
      label: label,
      stages: stages,
      calls: calls,
      total_calls: Enum.sum(Enum.map(calls, & &1.count)),
      image_calls:
        stages
        |> Enum.flat_map(& &1.calls)
        |> Enum.count(&(&1.type == "Image generation"))
    }
  end

  defp summarize_calls(calls) do
    calls
    |> Enum.group_by(&{&1.type, &1.model})
    |> Enum.map(fn {{type, model}, grouped} ->
      %{type: type, model: model, count: Enum.sum(Enum.map(grouped, & &1.count))}
    end)
    |> Enum.sort_by(& &1.type)
  end

  defp event_plan(book, "portrait", item), do: plan_action(book, :portrait, item)

  defp event_plan(book, "generate-page", item) do
    with {:ok, page} <- parse_page(item), do: plan_action(book, :generate_page, page)
  end

  defp event_plan(book, "replace-text", item) do
    with {:ok, page} <- parse_page(item), do: plan_action(book, :replace_text, page)
  end

  defp event_plan(_book, _action, _item), do: {:error, :invalid_action}

  defp free_plan(_book, "recompose", "dedication") do
    stage = stage(:compose_dedication, "page:dedication", "Dedication", :dedication, [])
    {:ok, plan(:compose, :dedication, "Dedication", [stage])}
  end

  defp free_plan(book, "recompose", item) do
    with {:ok, page} <- parse_page(item),
         {:ok, _spread, key, label} <- page_target(book, page),
         {:ok, raw} <- latest_raw(page),
         {:ok, _placement} <- Composition.cached_placement(raw) do
      stage = stage(:compose, key, label, page, [])
      {:ok, plan(:compose, page, label, [stage])}
    end
  end

  defp free_plan(_book, _action, _item), do: {:error, :invalid_action}

  defp parse_page("cover"), do: {:ok, :cover}

  defp parse_page(value) do
    case Integer.parse(value) do
      {position, ""} when position in 1..9 -> {:ok, position}
      _ -> {:error, :unknown_page}
    end
  end

  defp start_execution(socket, plan) do
    owner = self()
    run_ref = make_ref()
    book = socket.assigns.book
    first_stage = List.first(plan.stages)

    notifier = fn event -> send(owner, {:nani_pipeline, run_ref, event}) end

    socket
    |> assign(:pending, nil)
    |> assign(:ignore_pipeline_exit?, false)
    |> assign(:batch_review?, false)
    |> assign(:batch_error, nil)
    |> assign(:notice, nil)
    |> assign(:active, %{
      run_ref: run_ref,
      plan: plan,
      completed: 0,
      current_item_key: first_stage.item_key,
      current_label: first_stage.item_label
    })
    |> refresh_evaluation()
    |> start_async(@pipeline_task, fn -> execute_plan(plan, book, notify: notifier) end)
  end

  defp run_stage(%{kind: :portrait, target: name}, book) do
    case Generator.generate_character_reference(book, name) do
      {:ok, updated_book} -> {:ok, updated_book, %{type: :portrait}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_stage(%{kind: :generate_page, target: :cover}, book) do
    normalize_pipeline_result(Generator.generate_cover(book), book)
  end

  defp run_stage(%{kind: :generate_page, target: position}, book) do
    normalize_pipeline_result(Generator.generate_spread(book, position), book)
  end

  defp run_stage(%{kind: :replace_text, target: :cover}, book) do
    with {:ok, raw} <- latest_raw(:cover) do
      updated = %{book | cover: %{book.cover | generated_image_path: raw}}
      normalize_pipeline_result(Composition.compose_cover(updated, force_bbox: true), book)
    end
  end

  defp run_stage(%{kind: :replace_text, target: position}, book) do
    with {:ok, raw} <- latest_raw(position),
         {:ok, spread, _key, _label} <- page_target(book, position) do
      updated = %{spread | generated_image_path: raw}
      normalize_pipeline_result(Composition.compose_spread(updated, force_bbox: true), book)
    end
  end

  defp run_stage(%{kind: :compose, target: :cover}, book) do
    with {:ok, raw} <- latest_raw(:cover) do
      updated = %{book | cover: %{book.cover | generated_image_path: raw}}

      normalize_pipeline_result(
        Composition.compose_cover(updated, cached_bbox_only: true),
        book
      )
    end
  end

  defp run_stage(%{kind: :compose, target: position}, book) do
    with {:ok, raw} <- latest_raw(position),
         {:ok, spread, _key, _label} <- page_target(book, position) do
      updated = %{spread | generated_image_path: raw}

      normalize_pipeline_result(
        Composition.compose_spread(updated, cached_bbox_only: true),
        book
      )
    end
  end

  defp run_stage(%{kind: :compose_dedication}, book) do
    normalize_pipeline_result(Generator.compose_dedication(book), book)
  end

  defp normalize_pipeline_result({:ok, result}, book), do: {:ok, book, result}
  defp normalize_pipeline_result({:error, reason}, _book), do: {:error, reason}

  defp safely_run_stage(runner, stage, book) do
    runner.(stage, book)
  rescue
    exception in ChromicPDF.Browser.ExecutionError ->
      message = Exception.message(exception)

      if String.contains?(String.downcase(message), "timeout") do
        {:error, {:chromic_pdf_timeout, message}}
      else
        {:error, {:chromic_pdf_failure, message}}
      end

    exception ->
      {:error, {:exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  defp equivalent_plan?(left, right) do
    Map.take(left, [:action, :target, :calls, :total_calls]) ==
      Map.take(right, [:action, :target, :calls, :total_calls])
  end

  defp credential_available? do
    case System.get_env("GOOGLE_API_KEY") do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp busy?(socket), do: not is_nil(socket.assigns.active)

  defp update_active(socket, run_ref, fun) do
    case socket.assigns.active do
      %{run_ref: ^run_ref} = active -> assign(socket, :active, fun.(active))
      _ -> socket
    end
  end

  defp refresh_evaluation(socket) do
    evaluation = reconstruct()

    socket
    |> assign(:book, evaluation.book)
    |> assign(:stats, evaluation.stats)
    |> assign(:batch_plan, evaluation.batch_plan)
    |> assign(:credential_available?, credential_available?())
    |> stream(:characters, evaluation.characters, reset: true)
    |> stream(:pages, evaluation.pages, reset: true)
  end

  attr :id, :string, required: true
  attr :quality, :map, required: true

  @doc """
  Persisted, content-free deterministic composition evidence for one page.

  Transparent black/white attempts are reported together. A below-threshold
  fallback is explicit and retains the glyph-mask contrast evidence that ranked
  it without exposing story text, renderer payloads, paths, or source art. Only
  a recorded threshold pass reads as one; anything else is flagged for review.
  """
  def composition_quality(assigns) do
    assigns =
      assigns
      |> assign(:attempts, Map.get(assigns.quality, :attempts) || %{})
      |> assign(
        :preferred?,
        Map.get(assigns.quality, :selection_outcome) == @threshold_pass_outcome
      )

    ~H"""
    <div
      id={@id}
      class={[
        "mt-2 rounded-xl border p-3",
        if(@preferred?,
          do: "border-emerald-200 bg-emerald-50 text-emerald-950",
          else: "border-amber-300 bg-amber-50 text-amber-950"
        )
      ]}
    >
      <p class={["font-semibold"]}>
        Deterministic composition · {format_quality_ink(@quality.ink)}
      </p>
      <p class={["font-semibold", not @preferred? && "text-amber-800"]}>
        {format_quality_outcome(@quality.selection_outcome)}
      </p>
      <p>
        Final {format_quality_rect(@quality.final_rect)} · {@quality.align}/{@quality.valign} · {@quality.adjustment}
      </p>
      <p>
        Font {format_quality_metric(@quality.font_size)}px · {@quality.line_count} lines · {@quality.candidate_count} candidates · {format_quality_metric(
          @quality.duration_ms
        )}ms
      </p>
      <p>
        Glyphs {format_quality_rect(@quality.glyph_bounds)}
      </p>
      <p>
        Worst tile p10 {format_quality_metric(@quality.metrics.worst_tile_p10)}:1 ·
        below 3:1 {format_quality_percent(@quality.metrics.worst_tile_low_contrast_fraction)} ·
        worst line p05 {format_quality_metric(@quality.metrics.worst_line_p05)}:1 ·
        edge {format_quality_percent(@quality.metrics.edge_density)}
      </p>
      <p :if={not @preferred?}>
        Selected threshold misses: {format_readability_rejections(
          Map.get(@quality, :readability_rejections, [])
        )}
      </p>
      <p>
        Transparent black/white attempts: {format_quality_attempts(Map.get(@attempts, :transparent))}
      </p>
      <p :if={Map.get(@quality, :mask_render_errors, []) != []}>
        Mask render failures: {format_mask_render_errors(@quality.mask_render_errors)}
      </p>
      <p class={[
        "break-all text-[0.65rem]",
        if(@preferred?, do: "text-emerald-800/75", else: "text-amber-800/75")
      ]}>
        {@quality.contract_version} · {@quality.candidate_id} · {format_quality_count(
          Map.get(@quality, :scored_count)
        )} scans · {@quality.rejected_count} variants missed preferred gates
      </p>
    </div>
    """
  end

  @doc false
  @spec format_error(term()) :: String.t()
  def format_error({:chromic_pdf_timeout, _message}) do
    "ChromicPDF timed out while composing this page. Prior art and pages were retained."
  end

  def format_error({:chromic_pdf_failure, message}), do: "ChromicPDF failed: #{message}"
  def format_error(:no_raw_art), do: "No raw art exists for this item yet."
  def format_error(:no_cached_bounding_box), do: "No cached text placement exists yet."
  def format_error(:unknown_page), do: "Unknown Nani page."
  def format_error(:unknown_character), do: "Unknown Nani character."
  def format_error(:invalid_action), do: "That action is not available."

  def format_error({:composition_overflow, %{minimum_font: font}}) do
    "Story text cannot fit without clipping at the #{font}px minimum. Revise or split the page upstream."
  end

  # A browser that returned no usable measurement is a local rendering fault, so
  # it must never be reported as page content the author has to rewrite.
  def format_error({:composition_measurement_failed, _details}) do
    "The local browser returned no usable text measurement, so nothing was composed. " <>
      "Check Chrome and retry; the page content was not the problem."
  end

  # Every finalist mask failing is the same class of local fault. The operator
  # copy is fixed; the bounded fault classes behind it travel as separate
  # evidence through `error_evidence/1` rather than inside this sentence.
  def format_error({:composition_mask_render_failed, _errors}) do
    "Text readability verification could not run because the local renderer failed. " <>
      "No composed page was published. Retry composition; if the problem continues, " <>
      "inspect the local Chrome renderer."
  end

  def format_error({:composition_quality_failed, details}) do
    "No geometry-safe transparent black/white text candidate could be published " <>
      "(#{format_quality_attempts(Map.get(details, :transparent))}). " <>
      "Existing output was retained."
  end

  def format_error({:exception, message}), do: message
  def format_error(reason) when is_binary(reason), do: reason

  # An unrecognized reason is still a third-party term: a libvips message or a
  # renderer exit can quote the page document it failed over, so the catch-all
  # names the bounded fault class instead of inspecting the raw payload.
  def format_error(reason), do: "Unexpected failure: #{Diagnostics.reason_class(reason)}."

  @doc """
  Bounded evidence for a failure, kept out of the operator message.

  Mask faults arrive as opaque renderer terms that can embed the page document,
  so only the sanitized class names and their counts are ever surfaced. Overflow
  instead carries the browser's own fit geometry, which `evidence_label/1`
  labels as a fit detail rather than a renderer fault.
  """
  @spec error_evidence(term()) :: String.t() | nil
  def error_evidence({:composition_mask_render_failed, errors}),
    do: format_mask_render_classes(errors)

  # The scan reasons already travel inside `format_error/1`, so the evidence line
  # carries only the renderer faults that message cannot state.
  def error_evidence({:composition_quality_failed, details}),
    do: details |> Map.get(:mask_render_errors, []) |> format_mask_render_classes()

  def error_evidence({:composition_overflow, details}),
    do: details |> Map.get(:closest_fit) |> format_fit_evidence()

  def error_evidence(
        {:composition_measurement_failed, %{reason: :no_usable_measurement} = details}
      ),
      do: details |> Map.get(:rejection_reasons, %{}) |> format_reason_classes()

  def error_evidence({:composition_measurement_failed, reason}),
    do: Diagnostics.reason_class(reason)

  def error_evidence(_reason), do: nil

  @doc false
  @spec error_entry(term()) :: %{
          message: String.t(),
          evidence: String.t() | nil,
          evidence_label: String.t() | nil
        }
  def error_entry(reason) do
    case error_evidence(reason) do
      nil ->
        %{message: format_error(reason), evidence: nil, evidence_label: nil}

      evidence ->
        %{
          message: format_error(reason),
          evidence: evidence,
          evidence_label: evidence_label(reason)
        }
    end
  end

  # Overflow evidence is the browser's own fit geometry for content that did not
  # fit; the renderer classes are local faults. Anything else stays neutral so a
  # new reason can never be labelled as a cause it did not have.
  defp evidence_label({:composition_overflow, _details}), do: "Fit details"
  defp evidence_label({:composition_mask_render_failed, _errors}), do: "Renderer diagnostics"
  defp evidence_label({:composition_quality_failed, _details}), do: "Composition diagnostics"
  defp evidence_label({:composition_measurement_failed, _details}), do: "Renderer diagnostics"
  defp evidence_label(_reason), do: "Details"

  defp format_mask_render_classes([_ | _] = errors) do
    errors
    |> Enum.map(fn {_candidate_id, reason} -> Diagnostics.reason_class(reason) end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {class, count} -> {-count, class} end)
    |> Enum.map_join(", ", fn {class, count} -> "#{class} ×#{count}" end)
  end

  defp format_mask_render_classes(_errors), do: nil

  defp format_reason_classes(reasons) when is_map(reasons) and reasons != %{} do
    reasons
    |> Diagnostics.class_frequencies()
    |> Enum.sort_by(fn {class, count} -> {-count, class} end)
    |> Enum.map_join(", ", fn {class, count} -> "#{class} ×#{count}" end)
  end

  defp format_reason_classes(_reasons), do: nil

  # Only the browser's own numbers: the box the candidate had, the box its text
  # wanted, and the derived deltas. No story text is ever surfaced here.
  defp format_fit_evidence(%{overflow_width: width, overflow_height: height} = fit) do
    "closest fit #{fit.candidate_id} at #{format_quality_metric(fit.font_size)}px " <>
      "overran by #{width}×#{height}px " <>
      "(text #{fit.scroll_width}×#{fit.scroll_height}px in " <>
      "#{fit.available_width}×#{fit.available_height}px)"
  end

  defp format_fit_evidence(_fit), do: nil

  defp error_for(errors, key), do: Map.get(errors, key)
  defp active_for?(nil, _key), do: false
  defp active_for?(active, key), do: active.current_item_key == key
  defp pending_for?(nil, _key), do: false
  defp pending_for?(pending, key), do: pending.item_key == key
  defp current_session?(session_items, key), do: MapSet.member?(session_items, key)

  defp page_param(:cover), do: "cover"
  defp page_param(page), do: to_string(page)

  defp selection_label(:model), do: "cached model selection"
  defp selection_label(:fallback), do: "cached include-all fallback"
  defp selection_label(:unknown), do: "preview include-all · no current model cache"
  defp selection_label(:not_applicable), do: "not applicable"

  defp placement_label(:model), do: "model placement"
  defp placement_label(:fallback), do: "fallback placement"
  defp placement_label(:unknown), do: "unknown · legacy cache"
  defp placement_label(:missing), do: "no placement cache"
  defp placement_label(:not_applicable), do: "not applicable"

  defp format_quality_rect(%{x: x, y: y, w: width, h: height}),
    do: "x=#{x}, y=#{y}, #{width}×#{height}px"

  defp format_quality_rect(_), do: "unknown rect"

  defp format_quality_metric(value) when is_number(value),
    do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp format_quality_metric(_), do: "—"

  defp format_quality_percent(value) when is_number(value),
    do: :erlang.float_to_binary(value * 100.0, decimals: 1) <> "%"

  defp format_quality_percent(_), do: "—"

  defp format_quality_count(value) when is_integer(value), do: Integer.to_string(value)
  defp format_quality_count(_), do: "—"

  defp format_quality_ink(ink) when ink in [:white, "white"], do: "transparent white text"
  defp format_quality_ink(ink) when ink in [:black, "black"], do: "transparent black text"
  defp format_quality_ink(_ink), do: "transparent text · ink not recorded"

  defp format_quality_outcome(@fallback_outcome),
    do: "Below preferred readability thresholds · best geometry-safe transparent result published"

  defp format_quality_outcome(@threshold_pass_outcome), do: "Preferred readability thresholds met"

  defp format_quality_outcome(_outcome),
    do: "Selection outcome not recorded · treat as below preferred readability thresholds"

  defp format_readability_rejections([]), do: "none recorded"
  defp format_readability_rejections(reasons), do: Enum.join(reasons, ", ")

  # Live attempt evidence still carries the raw rejection terms it collected, so
  # it is reduced to the same bounded classes the sidecar persists before display.
  defp format_quality_attempts(%Attempts{} = attempts),
    do: attempts |> Attempts.provenance() |> format_quality_attempts()

  defp format_quality_attempts(%{scanned: 0}), do: "none scanned"

  defp format_quality_attempts(%{scanned: scanned, passed: passed} = attempts) do
    "#{passed}/#{scanned} met thresholds" <>
      format_rejection_reasons(Map.get(attempts, :rejection_reasons, %{}))
  end

  defp format_quality_attempts(_), do: "no recorded evidence"

  defp format_rejection_reasons(reasons) when reasons == %{}, do: ""

  defp format_rejection_reasons(reasons) when is_map(reasons) do
    detail =
      reasons
      |> Enum.sort_by(fn {reason, count} -> {-count, to_string(reason)} end)
      |> Enum.map_join(", ", fn {reason, count} -> "#{reason} ×#{count}" end)

    " · rejected: #{detail}"
  end

  defp format_rejection_reasons(_), do: ""

  defp format_mask_render_errors(errors) do
    Enum.map_join(errors, ", ", fn error -> "#{error.candidate_id} (#{error.reason})" end)
  end

  defp origin_label(session_items, key) do
    if current_session?(session_items, key),
      do: "created or refreshed this session",
      else: "loaded from disk"
  end
end
