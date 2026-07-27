defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{
    AgentRunner,
    Config,
    ExecutionLedger,
    FailureSemantics,
    StatusDashboard,
    Tracker,
    Workflow,
    WorkflowStore,
    Workspace
  }

  alias SymphonyElixir.Linear.Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @default_max_retry_attempts 3
  @default_max_retry_backoff_ms 300_000
  @workflow_refresh_timeout_ms 100
  @terminal_retry_min_delay_ms 1_000
  @terminal_retry_max_delay_ms 60_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :owner_pid,
      :workspace_root,
      :poll_interval_ms,
      :max_concurrent_agents,
      :max_issue_tokens,
      :max_retry_attempts,
      :max_retry_backoff_ms,
      :max_concurrent_agents_by_state,
      :tracker_required_labels,
      :active_state_set,
      :terminal_states,
      :terminal_state_set,
      :tracker_adapter,
      :worker_ssh_hosts,
      :worker_max_concurrent_agents_per_host,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :terminal_workspace_cleanup,
      :execution_ledger_healthy,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      effects: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]

    @type t :: %__MODULE__{}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :owner_pid, self()), name: name)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    case ExecutionLedger.load(config.workspace.root) do
      {:ok, loaded_state} ->
        durable_state = recover_ambiguous_effects(loaded_state)
        retry_attempts = restore_retry_timers(durable_state.retrying)

        state =
          %State{
            owner_pid: Keyword.fetch!(opts, :owner_pid),
            next_poll_due_at_ms: now_ms,
            poll_check_in_progress: false,
            tick_timer_ref: nil,
            tick_token: nil,
            terminal_workspace_cleanup: nil,
            execution_ledger_healthy: true,
            claimed: MapSet.new(Map.keys(durable_state.blocked) ++ Map.keys(retry_attempts)),
            blocked: durable_state.blocked,
            retry_attempts: retry_attempts,
            effects: durable_state.effects,
            codex_totals: @empty_codex_totals,
            codex_rate_limits: nil
          }
          |> cache_runtime_settings(config)

        state =
          state
          |> persist_execution_state()
          |> start_terminal_workspace_cleanup()
          |> schedule_tick(0)

        {:ok, state}

      {:error, reason} ->
        Logger.error("Refusing to start with unreadable durable execution state: #{inspect(reason)}")
        {:stop, {:durable_execution_state_unavailable, reason}}
    end
  end

  @impl true
  def handle_info({:EXIT, owner_pid, reason}, %{owner_pid: owner_pid} = state) do
    {:stop, reason, state}
  end

  def handle_info({:EXIT, pid, _reason}, state) when is_pid(pid) do
    # Owned tasks are linked to this process so they cannot outlive an
    # orchestrator crash. Their monitors remain authoritative for lifecycle
    # state, retry, and accounting.
    {:noreply, state}
  end

  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = execute_poll_cycle(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {ref, cleanup_result},
        %{terminal_workspace_cleanup: %Task{ref: ref}} = state
      ) do
    Process.demonitor(ref, [:flush])

    state =
      cleanup_result
      |> apply_terminal_workspace_cleanup_result(state)
      |> Map.put(:terminal_workspace_cleanup, nil)

    Logger.info("Startup terminal workspace cleanup finished")
    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{terminal_workspace_cleanup: %Task{pid: pid, ref: ref}} = state
      ) do
    Logger.info("Startup terminal workspace cleanup finished: reason=#{inspect(reason)}")
    {:noreply, %{state | terminal_workspace_cleanup: nil}}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        state = maybe_complete_dispatch_effect(state, running_entry, reason)
        session_id = running_entry_session_id(running_entry)

        state = handle_agent_down(reason, state, issue_id, running_entry, session_id)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)
        append_codex_token_ledger(running_entry, updated_running_entry, update, token_delta)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)
          |> maybe_log_token_telemetry_threshold(issue_id, updated_running_entry)

        notify_dashboard()

        if Map.has_key?(state.running, issue_id) do
          {:noreply, %{state | running: Map.put(state.running, issue_id, updated_running_entry)}}
        else
          {:noreply, state}
        end
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} ->
          handle_retry_issue_with_fallback(state, issue_id, attempt, metadata)

        :missing ->
          {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, %State{} = state) do
    case state.terminal_workspace_cleanup do
      %Task{pid: pid, ref: ref} ->
        Logger.info("Stopping startup terminal workspace cleanup because orchestrator is terminating: reason=#{inspect(reason)}")
        stop_running_task(pid, ref)

      _ ->
        :ok
    end

    Enum.each(state.running, fn {issue_id, running_entry} ->
      Logger.info("Stopping tracked agent task because orchestrator is terminating: issue_id=#{issue_id} reason=#{inspect(reason)}")

      stop_running_task(
        Map.get(running_entry, :pid),
        Map.get(running_entry, :ref)
      )
    end)

    :ok
  end

  defp handle_agent_down(:normal, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)
    else
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

      state
      |> complete_issue(issue_id)
      |> schedule_issue_retry(issue_id, 1, %{
        identifier: running_entry.identifier,
        issue_url: running_entry.issue.url,
        issue: running_entry.issue,
        delay_type: :continuation,
        failure_class: nil,
        transition: :retrying,
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path)
      })
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)
    else
      retry_agent_down(state, issue_id, running_entry, session_id, reason)
    end
  end

  defp block_input_required_agent_down(state, issue_id, running_entry, session_id, reason) do
    error = blocker_error(running_entry, "agent exited: #{inspect(reason)}")
    failure_class = input_required_failure_class(running_entry)

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id} failure_class=#{failure_class}: #{error}")

    transition_agent_failure(
      state,
      issue_id,
      running_entry,
      failure_class,
      error
    )
  end

  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    classification = FailureSemantics.classify(reason)

    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} failure_class=#{classification.class} retryable=#{classification.retryable}")

    transition_agent_failure(
      state,
      issue_id,
      running_entry,
      classification.class,
      "agent exited with #{classification.class}"
    )
  end

  defp input_required_failure_class(running_entry) do
    approval? =
      Map.get(running_entry, :last_codex_event) == :approval_required or
        input_required_completion_outcome(Map.get(running_entry, :completion)) ==
          :approval_required

    if approval?, do: :approval_required, else: :operator_decision_required
  end

  @doc false
  @spec transition_failure_for_test(State.t() | map(), Issue.t(), atom(), pos_integer(), String.t()) ::
          State.t() | map()
  def transition_failure_for_test(
        %State{} = state,
        %Issue{} = issue,
        failure_class,
        failed_attempt,
        error
      )
      when is_integer(failed_attempt) and failed_attempt > 0 and is_binary(error) do
    running_entry = %{
      identifier: issue.identifier,
      issue: issue,
      retry_attempt: failed_attempt,
      worker_host: nil,
      workspace_path: nil,
      session_id: nil
    }

    transition_agent_failure(state, issue.id, running_entry, failure_class, error)
  end

  @doc false
  @spec recover_ambiguous_effects_for_test(map()) :: map()
  def recover_ambiguous_effects_for_test(durable_state) when is_map(durable_state) do
    recover_ambiguous_effects(durable_state)
  end

  defp transition_agent_failure(
         %State{} = state,
         issue_id,
         running_entry,
         failure_class,
         error
       )
       when is_binary(issue_id) and is_map(running_entry) and is_binary(error) do
    classification = FailureSemantics.classify({:classified_failure, failure_class, error})
    failed_attempt = normalize_retry_attempt(Map.get(running_entry, :retry_attempt))
    max_attempts = retry_attempt_ceiling(state)

    cond do
      classification.retryable and failed_attempt < max_attempts ->
        schedule_issue_retry(state, issue_id, failed_attempt + 1, %{
          identifier: Map.get(running_entry, :identifier, issue_id),
          issue_url: get_in(running_entry, [:issue, Access.key(:url)]),
          issue: Map.get(running_entry, :issue),
          error: error,
          failure_class: classification.class,
          transition: :retrying,
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path)
        })

      classification.retryable ->
        terminal_failure_state(
          state,
          issue_id,
          running_entry,
          classification.class,
          :held,
          failed_attempt,
          error,
          true
        )

      true ->
        terminal_failure_state(
          state,
          issue_id,
          running_entry,
          classification.class,
          classification.terminal_state,
          failed_attempt,
          error,
          false
        )
    end
  end

  defp terminal_failure_state(
         %State{} = state,
         issue_id,
         entry,
         failure_class,
         terminal_state,
         attempt,
         error,
         retry_exhausted
       ) do
    blocked_entry =
      %{
        issue_id: issue_id,
        identifier: Map.get(entry, :identifier, issue_id),
        issue_url: get_in(entry, [:issue, Access.key(:url)]),
        issue: Map.get(entry, :issue),
        worker_host: Map.get(entry, :worker_host),
        workspace_path: Map.get(entry, :workspace_path),
        session_id: running_entry_session_id(entry),
        error: error,
        failure_class: failure_class,
        terminal_state: terminal_state,
        transition: :terminal,
        attempt: attempt,
        retry_exhausted: retry_exhausted,
        idempotency_key: Map.get(entry, :idempotency_key),
        blocked_at: DateTime.utc_now(),
        last_codex_message: Map.get(entry, :last_codex_message),
        last_codex_event: Map.get(entry, :last_codex_event),
        last_codex_timestamp: Map.get(entry, :last_codex_timestamp),
        block_kind: Map.get(entry, :block_kind)
      }
      |> schedule_terminal_retry()

    %{
      state
      | running: Map.delete(state.running, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
    |> persist_execution_state()
  end

  defp retry_attempt_ceiling(%State{max_retry_attempts: attempts})
       when is_integer(attempts) and attempts > 0,
       do: attempts

  defp retry_attempt_ceiling(_state), do: @default_max_retry_attempts

  defp maybe_dispatch(%State{} = state) do
    state =
      state
      |> reconcile_running_issues()
      |> reconcile_blocked_issues()

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues(),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(state),
            terminal_state_set(state)
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  defp reconcile_blocked_issues(%State{} = state) do
    blocked_ids = Map.keys(state.blocked)

    if blocked_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(blocked_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_blocked_issue_states(
            state,
            active_state_set(state),
            terminal_state_set(state)
          )
          |> reconcile_missing_blocked_issue_ids(blocked_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh blocked issue states: #{inspect(reason)}; keeping blocked issues")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    state = load_runtime_config(state)
    reconcile_running_issue_states(issues, state, active_state_set(state), terminal_state_set(state))
  end

  @doc false
  @spec reconcile_blocked_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_blocked_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    state = load_runtime_config(state)
    requested_issue_ids = Map.keys(state.blocked)

    issues
    |> reconcile_blocked_issue_states(
      state,
      active_state_set(state),
      terminal_state_set(state)
    )
    |> reconcile_missing_blocked_issue_ids(requested_issue_ids, issues)
  end

  @doc false
  @spec recover_startup_terminal_issues_for_test([Issue.t()], term()) :: term()
  def recover_startup_terminal_issues_for_test(issues, %State{} = state) when is_list(issues) do
    recover_startup_terminal_issues(issues, state)
  end

  @doc false
  @spec handle_retry_issue_lookup_for_test(Issue.t(), term(), String.t(), non_neg_integer(), map()) ::
          term()
  def handle_retry_issue_lookup_for_test(%Issue{} = issue, %State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    state = load_runtime_config(state)
    {:noreply, updated_state} = handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)
    updated_state
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    state = load_runtime_config(state)
    should_dispatch_issue?(issue, state, active_state_set(state), terminal_state_set(state))
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    state = load_runtime_config(%State{})
    revalidate_issue_for_dispatch(issue, issue_fetcher, state)
  end

  @doc false
  @spec recover_dispatch_revalidation_for_test(
          :missing | {:error, term()},
          State.t(),
          Issue.t(),
          pos_integer(),
          map()
        ) :: State.t()
  def recover_dispatch_revalidation_for_test(result, %State{} = state, %Issue{} = issue, attempt, metadata)
      when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    case result do
      :missing -> handle_skipped_dispatch(state, issue, :missing, attempt, metadata)
      {:error, _reason} -> handle_dispatch_refresh_failure(state, issue, attempt, metadata)
    end
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    state = load_runtime_config(state)
    select_worker_host(state, preferred_worker_host)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; verifying terminal acceptance")

        terminate_terminal_running_issue(state, issue)

      !issue_routable?(issue, state) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      ambiguous_effect_for_issue?(state, issue.id) ->
        Logger.warning("Ambiguous dispatch effect remains unresolved: #{issue_context(issue)}; preserving terminal hold across reconciliation")
        refresh_blocked_issue_state(state, issue)

      terminal_issue_state?(issue.state, terminal_states) ->
        reconcile_terminal_blocked_issue(issue, state)

      !issue_routable?(issue, state) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")
        release_issue_claim(state, issue.id)

      active_issue_state?(issue.state, active_states) ->
        reconcile_active_blocked_issue(issue, state)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, issue.id)
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_active_blocked_issue(%Issue{} = issue, %State{} = state) do
    case get_in(state.blocked, [issue.id, :block_kind]) do
      :before_terminal ->
        Logger.info("Terminal-blocked issue returned to an active state: #{issue_context(issue)} state=#{issue.state}; releasing claim and preserving workspace for redispatch")
        release_issue_claim(state, issue.id)

      _other ->
        refresh_blocked_issue_state(state, issue)
    end
  end

  defp reconcile_terminal_blocked_issue(%Issue{} = issue, %State{} = state) do
    blocked_entry = Map.get(state.blocked, issue.id, %{})

    case Map.get(blocked_entry, :block_kind) do
      :before_terminal ->
        if terminal_retry_due?(blocked_entry) do
          Logger.info("Retrying terminal acceptance: #{issue_context(issue)} state=#{issue.state} attempt=#{Map.get(blocked_entry, :terminal_retry_attempt, 0) + 1}")
          verify_terminal_blocked_issue(issue, state, blocked_entry)
        else
          Logger.info("Terminal acceptance remains blocked: #{issue_context(issue)} state=#{issue.state}; preserving claim and workspace until bounded retry")
          refresh_blocked_issue_state(state, issue)
        end

      _other ->
        verify_terminal_blocked_issue(issue, state, blocked_entry)
    end
  end

  defp verify_terminal_blocked_issue(%Issue{} = issue, %State{} = state, blocked_entry) do
    case cleanup_terminal_issue_workspace(
           issue,
           Map.get(blocked_entry, :worker_host),
           Map.get(blocked_entry, :workspace_path)
         ) do
      :ok ->
        Logger.info("Blocked issue passed terminal acceptance: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, issue.id)

      {:error, reason} ->
        error = terminal_acceptance_error(reason)
        Logger.warning("Blocked issue failed terminal acceptance: #{issue_context(issue)} state=#{issue.state} error=#{error}; preserving claim and workspace")

        preserve_terminal_block(state, issue, blocked_entry, error)
    end
  end

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      cond do
        MapSet.member?(visible_issue_ids, issue_id) ->
          state_acc

        get_in(state_acc.blocked, [issue_id, :block_kind]) == :before_terminal ->
          Logger.warning("Terminal-blocked issue omitted from state refresh: issue_id=#{issue_id}; preserving claim and workspace until an authoritative terminal snapshot is available")
          state_acc

        FailureSemantics.valid_class?(get_in(state_acc.blocked, [issue_id, :failure_class])) ->
          Logger.warning("Classified terminal issue omitted from state refresh: issue_id=#{issue_id}; preserving durable terminal state")

          state_acc

        true ->
          Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")
          release_issue_claim(state_acc, issue_id)
      end
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{issue: _} = blocked_entry ->
        %{state | blocked: Map.put(state.blocked, issue.id, %{blocked_entry | issue: issue})}
        |> persist_execution_state()

      _ ->
        state
    end
  end

  defp terminate_terminal_running_issue(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      nil ->
        release_issue_claim(state, issue.id)

      running_entry ->
        state = record_session_completion_totals(state, running_entry)
        state = complete_dispatch_effect(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)
        stop_running_task(Map.get(running_entry, :pid), Map.get(running_entry, :ref))

        case cleanup_terminal_issue_workspace(
               issue,
               worker_host,
               Map.get(running_entry, :workspace_path)
             ) do
          :ok ->
            state
            |> Map.put(:running, Map.delete(state.running, issue.id))
            |> release_issue_claim(issue.id)

          {:error, reason} ->
            error = terminal_acceptance_error(reason)
            Logger.warning("Terminal acceptance failed for #{issue_context(issue)} error=#{error}; preserving claim and workspace")

            terminal_entry =
              running_entry
              |> Map.put(:issue, issue)
              |> Map.put(:block_kind, :before_terminal)

            block_issue_from_entry(
              state,
              issue.id,
              terminal_entry,
              error
            )
        end
    end
  end

  defp preserve_terminal_block(%State{} = state, %Issue{} = issue, blocked_entry, error)
       when is_map(blocked_entry) do
    updated_entry =
      blocked_entry
      |> Map.put(:issue_id, issue.id)
      |> Map.put(:identifier, issue.identifier)
      |> Map.put(:issue, issue)
      |> Map.put(:error, error)
      |> Map.put(:block_kind, :before_terminal)
      |> schedule_terminal_retry()

    %{
      state
      | claimed: MapSet.put(state.claimed, issue.id),
        blocked: Map.put(state.blocked, issue.id, updated_entry)
    }
    |> persist_execution_state()
  end

  defp terminal_acceptance_error(reason) do
    "before_terminal acceptance failed: #{terminal_acceptance_error_code(reason)}"
  end

  defp terminal_acceptance_error_code({:workspace_hook_failed, "before_terminal", status})
       when is_integer(status),
       do: "hook_failed_status_#{status}"

  defp terminal_acceptance_error_code({:workspace_hook_failed, _hook_name, _status}),
    do: "hook_failed"

  defp terminal_acceptance_error_code({:workspace_hook_timeout, _hook_name, _timeout_ms}),
    do: "hook_timeout"

  defp terminal_acceptance_error_code({:workspace_hook_execution_failed, _hook_name, _reason}),
    do: "hook_execution_failed"

  defp terminal_acceptance_error_code({:remote_workspace_probe_failed, _reason}),
    do: "remote_workspace_probe_failed"

  defp terminal_acceptance_error_code({type, _rest}) when is_atom(type), do: Atom.to_string(type)
  defp terminal_acceptance_error_code({type, _left, _right}) when is_atom(type), do: Atom.to_string(type)
  defp terminal_acceptance_error_code(type) when is_atom(type), do: Atom.to_string(type)
  defp terminal_acceptance_error_code(_reason), do: "unknown_error"

  defp terminal_retry_due?(blocked_entry) when is_map(blocked_entry) do
    case Map.get(blocked_entry, :terminal_retry_at_ms) do
      retry_at_ms when is_integer(retry_at_ms) ->
        System.monotonic_time(:millisecond) >= retry_at_ms

      _missing ->
        true
    end
  end

  defp schedule_terminal_retry(blocked_entry) when is_map(blocked_entry) do
    if Map.get(blocked_entry, :block_kind) == :before_terminal do
      attempt =
        case Map.get(blocked_entry, :terminal_retry_attempt, 0) do
          value when is_integer(value) and value >= 0 -> value + 1
          _invalid -> 1
        end

      Map.merge(blocked_entry, %{
        terminal_retry_attempt: attempt,
        terminal_retry_at_ms: System.monotonic_time(:millisecond) + terminal_retry_delay_ms(attempt)
      })
    else
      blocked_entry
    end
  end

  defp terminal_retry_delay_ms(attempt) when is_integer(attempt) and attempt > 0 do
    base_delay_ms =
      Config.settings!().polling.interval_ms
      |> max(@terminal_retry_min_delay_ms)
      |> min(@terminal_retry_max_delay_ms)

    shift = (attempt - 1) |> max(0) |> min(6)
    min(base_delay_ms <<< shift, @terminal_retry_max_delay_ms)
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        stop_running_task(pid, ref)

        if ambiguous_effect_for_issue?(state, issue_id) do
          terminal_failure_state(
            state,
            issue_id,
            running_entry,
            :operator_decision_required,
            :held,
            normalize_retry_attempt(Map.get(running_entry, :retry_attempt)),
            "running dispatch stopped before final receipt",
            false
          )
        else
          %{
            state
            | running: Map.delete(state.running, issue_id),
              claimed: MapSet.delete(state.claimed, issue_id),
              blocked: Map.delete(state.blocked, issue_id),
              retry_attempts: Map.delete(state.retry_attempts, issue_id)
          }
        end

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          maybe_restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp maybe_restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    if Map.has_key?(state.blocked, issue_id) do
      state
    else
      restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      if input_required_blocker?(running_entry) do
        error = blocker_error(running_entry, "stalled for #{elapsed_ms}ms after Codex requested operator input")

        Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")

        state
        |> record_session_completion_totals(running_entry)
        |> stop_and_block_issue(issue_id, running_entry, error)
      else
        Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

        state =
          state
          |> complete_dispatch_effect(running_entry)
          |> terminate_running_issue(issue_id, false)

        transition_agent_failure(
          state,
          issue_id,
          running_entry,
          :transient_transport,
          "worker stalled without codex activity"
        )
      end
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp input_required_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      codex_message_method(Map.get(running_entry, :last_codex_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_blocker?(_running_entry), do: false

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) when is_map(running_entry) do
    codex_event_blocker_error(Map.get(running_entry, :last_codex_event)) ||
      completion_blocker_error(Map.get(running_entry, :completion)) ||
      codex_message_blocker_error(Map.get(running_entry, :last_codex_message)) ||
      fallback
  end

  defp blocker_error(_running_entry, fallback), do: fallback

  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
  defp codex_event_blocker_error(_event), do: nil

  defp completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] -> "codex turn requires operator input"
      :approval_required -> "codex turn requires approval"
      nil -> nil
    end
  end

  defp codex_message_blocker_error(message) do
    if codex_message_method(message) == "mcpServer/elicitation/request" do
      "codex MCP elicitation requires operator input"
    end
  end

  defp codex_message_method(%{message: %{"method" => method}}) when is_binary(method), do: method
  defp codex_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp codex_message_method(%{"method" => method}) when is_binary(method), do: method
  defp codex_message_method(%{method: method}) when is_binary(method), do: method
  defp codex_message_method(_message), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :kill)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp stop_running_task(pid, ref) do
    if is_pid(pid) do
      terminate_task(pid)
    end

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp stop_and_block_issue(%State{} = state, issue_id, running_entry, error) do
    stop_running_task(Map.get(running_entry, :pid), Map.get(running_entry, :ref))

    transition_agent_failure(
      state,
      issue_id,
      running_entry,
      input_required_failure_class(running_entry),
      error
    )
  end

  defp block_issue_from_entry(%State{} = state, issue_id, running_entry, error) do
    terminal_failure_state(
      state,
      issue_id,
      running_entry,
      :operator_decision_required,
      :held,
      normalize_retry_attempt(Map.get(running_entry, :retry_attempt)),
      error,
      false
    )
  end

  defp choose_issues(issues, state) do
    active_states = active_state_set(state)
    terminal_states = terminal_state_set(state)

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, blocked: blocked} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, state, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      !Map.has_key?(blocked, issue.id) and
      !ambiguous_effect_for_issue?(state, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, state) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(
         %Issue{state: issue_state},
         %State{running: running, max_concurrent_agents_by_state: state_limits} = state
       )
       when is_binary(issue_state) and is_map(running) and is_map(state_limits) do
    limit = Map.get(state_limits, normalize_issue_state(issue_state), state.max_concurrent_agents)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _state), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         %State{} = state,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable?(issue, state) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp issue_routable?(%Issue{} = issue, %State{tracker_required_labels: required_labels})
       when is_list(required_labels) do
    Issue.routable?(issue, required_labels)
  end

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set(%State{terminal_state_set: %MapSet{} = terminal_states}),
    do: terminal_states

  defp terminal_state_set(%State{}),
    do: Config.settings!().tracker.terminal_states |> normalize_state_set()

  defp active_state_set(%State{active_state_set: %MapSet{} = active_states}), do: active_states

  defp active_state_set(%State{}),
    do: Config.settings!().tracker.active_states |> normalize_state_set()

  defp dispatch_issue(
         %State{} = state,
         issue,
         attempt \\ nil,
         preferred_worker_host \\ nil,
         retry_metadata \\ nil
       ) do
    tracker_adapter = state.tracker_adapter
    issue_fetcher = fn issue_ids -> tracker_adapter.fetch_issue_states_by_ids(issue_ids) end

    case revalidate_issue_for_dispatch(issue, issue_fetcher, state) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        handle_skipped_dispatch(state, issue, :missing, attempt, retry_metadata)

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        handle_skipped_dispatch(state, issue, refreshed_issue, attempt, retry_metadata)

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        handle_dispatch_refresh_failure(state, issue, attempt, retry_metadata)
    end
  end

  defp handle_skipped_dispatch(state, _issue, _result, _attempt, retry_metadata)
       when not is_map(retry_metadata),
       do: state

  defp handle_skipped_dispatch(state, issue, :missing, _attempt, _retry_metadata),
    do: release_issue_claim(state, issue.id)

  defp handle_skipped_dispatch(state, _issue, %Issue{} = refreshed_issue, attempt, retry_metadata) do
    {:noreply, state} =
      handle_retry_issue_lookup(
        refreshed_issue,
        state,
        refreshed_issue.id,
        normalize_retry_attempt(attempt),
        retry_metadata
      )

    state
  end

  defp handle_dispatch_refresh_failure(state, _issue, _attempt, retry_metadata)
       when not is_map(retry_metadata),
       do: state

  defp handle_dispatch_refresh_failure(state, issue, attempt, retry_metadata) do
    schedule_issue_retry(
      state,
      issue.id,
      normalize_retry_attempt(attempt) + 1,
      Map.merge(retry_metadata, %{
        identifier: issue.identifier,
        issue_url: issue.url,
        issue: issue,
        error: "dispatch issue refresh failed",
        failure_class: :transient_transport,
        delay_type: :backoff
      })
    )
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    failure_attempt = normalize_retry_attempt(attempt)
    dispatch_sequence = next_dispatch_sequence(state, issue.id)

    case reserve_dispatch_effect(state, issue, dispatch_sequence) do
      {:ok, reserved_state, prepared_effect} ->
        start_reserved_agent(
          reserved_state,
          prepared_effect,
          issue,
          failure_attempt,
          recipient,
          worker_host
        )

      {:duplicate, duplicate_effect} ->
        terminal_failure_state(
          state,
          issue.id,
          %{
            identifier: issue.identifier,
            issue: issue,
            retry_attempt: failure_attempt,
            idempotency_key: duplicate_effect.idempotency_key,
            worker_host: worker_host
          },
          :operator_decision_required,
          :held,
          failure_attempt,
          "dispatch idempotency key already exists",
          false
        )

      {:error, failed_state, _reason} ->
        terminal_failure_state(
          failed_state,
          issue.id,
          %{
            identifier: issue.identifier,
            issue: issue,
            retry_attempt: failure_attempt,
            worker_host: worker_host
          },
          :unknown_fail_closed,
          :permanent,
          failure_attempt,
          "unable to durably reserve dispatch",
          false
        )
    end
  end

  defp start_reserved_agent(
         state,
         prepared_effect,
         issue,
         failure_attempt,
         recipient,
         worker_host
       ) do
    case start_owned_task(fn ->
           AgentRunner.run(
             issue,
             recipient,
             attempt: failure_attempt,
             worker_host: worker_host
           )
         end) do
      {:ok, %Task{pid: pid, ref: ref}} ->
        Logger.info(
          "Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{failure_attempt} idempotency_key=#{prepared_effect.idempotency_key} worker_host=#{worker_host || "local"}"
        )

        state = mark_dispatch_effect_started(state, prepared_effect.idempotency_key)

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: failure_attempt,
            dispatch_sequence: prepared_effect.attempt,
            idempotency_key: prepared_effect.idempotency_key,
            transition: :running,
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }
        |> persist_execution_state()

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}")

        state = discard_dispatch_effect(state, prepared_effect.idempotency_key)

        transition_agent_failure(
          state,
          issue.id,
          %{
            identifier: issue.identifier,
            issue: issue,
            retry_attempt: failure_attempt,
            worker_host: worker_host
          },
          :transient_transport,
          "failed to spawn agent: #{inspect(reason)}"
        )
    end
  end

  @doc false
  @spec start_owned_task_for_test((-> term())) :: {:ok, Task.t()} | {:error, term()}
  def start_owned_task_for_test(fun) when is_function(fun, 0), do: start_owned_task(fun)

  defp start_owned_task(fun) when is_function(fun, 0) do
    {:ok, Task.Supervisor.async(SymphonyElixir.TaskSupervisor, fun)}
  rescue
    exception in RuntimeError -> {:error, {:task_start_failed, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:task_start_failed, reason}}
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, %State{} = state)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    terminal_states = terminal_state_set(state)

    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, state, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _state), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = retry_attempt(attempt, previous_retry)
    failure_class = Map.get(metadata, :failure_class, Map.get(previous_retry, :failure_class))

    if retry_ceiling_exceeded?(state, failure_class, next_attempt) do
      terminal_failure_state(
        state,
        issue_id,
        Map.merge(previous_retry, metadata),
        failure_class,
        :held,
        retry_attempt_ceiling(state),
        Map.get(metadata, :error) || "retry ceiling exhausted",
        true
      )
    else
      delay_ms = retry_delay(state, next_attempt, metadata)
      old_timer = Map.get(previous_retry, :timer_ref)
      retry_token = make_ref()
      due_at_ms = System.monotonic_time(:millisecond) + delay_ms
      due_at = DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)
      identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
      issue_url = pick_retry_issue_url(previous_retry, metadata)
      error = pick_retry_error(previous_retry, metadata)
      worker_host = pick_retry_worker_host(previous_retry, metadata)
      workspace_path = pick_retry_workspace_path(previous_retry, metadata)

      cancel_retry_timer(old_timer)
      timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)
      error_suffix = retry_error_suffix(error)

      Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt}) failure_class=#{failure_class || "continuation"}#{error_suffix}")

      %{
        state
        | retry_attempts:
            Map.put(state.retry_attempts, issue_id, %{
              attempt: next_attempt,
              timer_ref: timer_ref,
              retry_token: retry_token,
              due_at_ms: due_at_ms,
              due_at: due_at,
              identifier: identifier,
              issue_url: issue_url,
              issue: Map.get(metadata, :issue) || Map.get(previous_retry, :issue),
              error: error,
              failure_class: failure_class,
              transition: :retrying,
              delay_type: Map.get(metadata, :delay_type),
              worker_host: worker_host,
              workspace_path: workspace_path
            })
      }
      |> persist_execution_state()
    end
  end

  defp retry_attempt(attempt, _previous_retry) when is_integer(attempt), do: attempt
  defp retry_attempt(_attempt, previous_retry), do: previous_retry.attempt + 1

  defp retry_ceiling_exceeded?(state, failure_class, next_attempt) do
    failure_class in [:transient_capacity, :transient_transport] and
      next_attempt > retry_attempt_ceiling(state)
  end

  defp cancel_retry_timer(timer_ref) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
  end

  defp cancel_retry_timer(_timer_ref), do: :ok

  defp retry_error_suffix(error) when is_binary(error), do: " error=#{error}"
  defp retry_error_suffix(_error), do: ""

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          issue_url: Map.get(retry_entry, :issue_url),
          issue: Map.get(retry_entry, :issue),
          error: Map.get(retry_entry, :error),
          failure_class: Map.get(retry_entry, :failure_class),
          transition: Map.get(retry_entry, :transition),
          delay_type: Map.get(retry_entry, :delay_type),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path)
        }

        popped_state =
          %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}
          |> persist_execution_state()

        {:ok, attempt, metadata, popped_state}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue_with_fallback(%State{} = state, issue_id, attempt, metadata) do
    handle_retry_issue(state, issue_id, attempt, metadata)
  catch
    :exit, {reason, {GenServer, :call, [WorkflowStore, :current | _]}} = call_exit ->
      Logger.warning("Retry lookup unavailable; preserving one retry for issue_id=#{issue_id}: #{inspect(call_exit)}")

      {:noreply,
       schedule_issue_retry(
         state,
         issue_id,
         attempt + 1,
         Map.merge(metadata, %{error: "retry lookup unavailable: #{inspect(reason)}"})
       )}
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case fetch_retry_issue_states(state, [issue_id]) do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry issue refresh failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{
             error: "retry issue refresh failed",
             failure_class: :transient_transport
           })
         )}
    end
  end

  defp fetch_retry_issue_states(%State{tracker_adapter: adapter}, issue_ids)
       when is_atom(adapter) and not is_nil(adapter) do
    adapter.fetch_issue_states_by_ids(issue_ids)
  end

  defp fetch_retry_issue_states(%State{}, issue_ids) do
    Tracker.fetch_issue_states_by_ids(issue_ids)
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set(state)

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        case cleanup_terminal_issue_workspace(
               issue,
               metadata[:worker_host],
               metadata[:workspace_path]
             ) do
          :ok ->
            Logger.info("Issue passed terminal acceptance: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removed associated workspace")
            {:noreply, release_issue_claim(state, issue_id)}

          {:error, reason} ->
            error = terminal_acceptance_error(reason)
            Logger.warning("Issue failed terminal acceptance: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state} error=#{error}; preserving claim and workspace")

            terminal_entry =
              metadata
              |> Map.put(:identifier, issue.identifier)
              |> Map.put(:issue, issue)
              |> Map.put(:block_kind, :before_terminal)

            {:noreply,
             block_issue_from_entry(
               state,
               issue_id,
               terminal_entry,
               error
             )}
        end

      retry_candidate_issue?(issue, state, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_terminal_issue_workspace(%Issue{} = issue, worker_host, workspace_path)
       when is_binary(workspace_path) do
    Workspace.remove_terminal_issue_workspace(workspace_path, issue, worker_host)
  end

  defp cleanup_terminal_issue_workspace(%Issue{} = issue, worker_host, _workspace_path) do
    Workspace.remove_terminal_issue_workspaces(issue, worker_host)
  end

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup(adapter, terminal_states)
       when is_atom(adapter) and is_list(terminal_states) do
    case adapter.fetch_issues_by_states(terminal_states) do
      {:ok, issues} ->
        {:ok, Enum.map(issues, &cleanup_startup_terminal_workspace_result/1)}

      {:error, reason} ->
        {:error, {:terminal_issue_fetch_failed, reason}}
    end
  end

  defp start_terminal_workspace_cleanup(%State{tracker_adapter: adapter, terminal_states: terminal_states} = state)
       when is_atom(adapter) and not is_nil(adapter) and is_list(terminal_states) do
    case start_owned_task(fn -> run_terminal_workspace_cleanup(adapter, terminal_states) end) do
      {:ok, %Task{} = task} ->
        %{state | terminal_workspace_cleanup: task}

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to start cleanup task: #{inspect(reason)}")
        state
    end
  end

  defp start_terminal_workspace_cleanup(%State{} = state) do
    Logger.warning("Skipping startup terminal workspace cleanup; cached tracker configuration is unavailable")
    state
  end

  defp apply_terminal_workspace_cleanup_result({:ok, results}, %State{} = state)
       when is_list(results) do
    Enum.reduce(results, state, &apply_startup_terminal_workspace_result/2)
  end

  defp apply_terminal_workspace_cleanup_result({:error, reason}, %State{} = state) do
    Logger.warning("Skipping startup terminal workspace cleanup: #{inspect(reason)}")
    state
  end

  defp apply_terminal_workspace_cleanup_result(other, %State{} = state) do
    Logger.warning("Skipping invalid startup terminal workspace cleanup result: #{inspect(other)}")
    state
  end

  defp recover_startup_terminal_issues(issues, %State{} = state) when is_list(issues) do
    Enum.reduce(issues, state, &cleanup_startup_terminal_workspace/2)
  end

  defp cleanup_startup_terminal_workspace_result(%Issue{} = issue) do
    {issue, cleanup_terminal_issue_workspace(issue, nil, nil)}
  end

  defp cleanup_startup_terminal_workspace_result(issue), do: {issue, :ignored}

  defp apply_startup_terminal_workspace_result(
         {%Issue{id: issue_id}, :ok},
         %State{} = state
       ) do
    case Map.get(state.blocked, issue_id) do
      %{block_kind: :before_terminal} -> release_issue_claim(state, issue_id)
      _ -> state
    end
  end

  defp apply_startup_terminal_workspace_result(
         {%Issue{} = issue, {:error, reason}},
         %State{} = state
       ) do
    cleanup_startup_terminal_workspace_failure(issue, reason, state)
  end

  defp apply_startup_terminal_workspace_result(_result, %State{} = state), do: state

  defp cleanup_startup_terminal_workspace(%Issue{} = issue, %State{} = state) do
    case cleanup_terminal_issue_workspace(issue, nil, nil) do
      :ok ->
        state

      {:error, reason} ->
        cleanup_startup_terminal_workspace_failure(issue, reason, state)
    end
  end

  defp cleanup_startup_terminal_workspace(_issue, state), do: state

  defp cleanup_startup_terminal_workspace_failure(%Issue{} = issue, reason, %State{} = state) do
    error = terminal_acceptance_error(reason)
    Logger.warning("Startup terminal acceptance failed for #{issue_context(issue)} error=#{error}; reconstructing claim and terminal block")

    startup_entry = %{
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: nil,
      block_kind: :before_terminal
    }

    block_issue_from_entry(
      state,
      issue.id,
      startup_entry,
      error
    )
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, state, terminal_state_set(state)) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host], metadata)}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           issue: issue,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
    |> persist_execution_state()
  end

  defp retry_delay(%State{} = state, attempt, metadata)
       when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(state, attempt)
    end
  end

  defp failure_retry_delay(%State{max_retry_backoff_ms: max_retry_backoff_ms}, attempt)
       when is_integer(max_retry_backoff_ms) and max_retry_backoff_ms > 0 do
    max_delay_power = min(max(attempt - 2, 0), 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), max_retry_backoff_ms)
  end

  defp failure_retry_delay(%State{}, attempt) do
    max_delay_power = min(max(attempt - 2, 0), 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), @default_max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 1

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_issue_url(previous_retry, metadata) do
    metadata[:issue_url] || Map.get(previous_retry, :issue_url)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case state.worker_ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case state.worker_max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(state.max_concurrent_agents - map_size(state.running), 0)
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          issue_url: metadata.issue.url,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          codex_app_server_pid: Map.get(metadata, :codex_app_server_pid),
          codex_input_tokens: Map.get(metadata, :codex_input_tokens, 0),
          codex_output_tokens: Map.get(metadata, :codex_output_tokens, 0),
          codex_total_tokens: Map.get(metadata, :codex_total_tokens, 0),
          codex_cached_input_tokens: Map.get(metadata, :codex_cached_input_tokens, 0),
          codex_billable_tokens: billable_token_count(metadata),
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event),
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
        |> maybe_put_snapshot_field(:transition, Map.get(metadata, :transition))
        |> maybe_put_snapshot_field(:attempt, Map.get(metadata, :retry_attempt))
        |> maybe_put_snapshot_field(:idempotency_key, Map.get(metadata, :idempotency_key))
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          issue_url: Map.get(retry, :issue_url),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
        |> maybe_put_snapshot_field(:failure_class, Map.get(retry, :failure_class))
        |> maybe_put_snapshot_field(:transition, Map.get(retry, :transition))
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          issue_url: blocked_issue_url(metadata),
          state: blocked_issue_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          error: Map.get(metadata, :error),
          blocked_at: Map.get(metadata, :blocked_at),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event)
        }
        |> maybe_put_snapshot_field(:failure_class, Map.get(metadata, :failure_class))
        |> maybe_put_snapshot_field(:terminal_state, Map.get(metadata, :terminal_state))
        |> maybe_put_snapshot_field(:transition, Map.get(metadata, :transition))
        |> maybe_put_snapshot_field(:attempt, Map.get(metadata, :attempt))
        |> maybe_put_snapshot_field(:retry_exhausted, Map.get(metadata, :retry_exhausted))
        |> maybe_put_snapshot_field(:idempotency_key, Map.get(metadata, :idempotency_key))
      end)

    held = Enum.filter(blocked, &(Map.get(&1, :terminal_state) == :held))
    permanent = Enum.filter(blocked, &(Map.get(&1, :terminal_state) == :permanent))

    snapshot =
      %{
        running: running,
        retrying: retrying,
        blocked: blocked,
        codex_totals: state.codex_totals,
        rate_limits: Map.get(state, :codex_rate_limits),
        polling: %{
          checking?: state.poll_check_in_progress == true,
          next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
          poll_interval_ms: state.poll_interval_ms
        }
      }
      |> maybe_put_terminal_snapshot_lists(held, permanent)

    {:reply, snapshot, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp blocked_issue_url(%{issue: %Issue{url: url}}), do: url
  defp blocked_issue_url(_metadata), do: nil

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_cached_input_tokens = Map.get(running_entry, :codex_cached_input_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    last_reported_cached_input = Map.get(running_entry, :codex_last_reported_cached_input_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_cached_input_tokens: codex_cached_input_tokens + token_delta.cached_input_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        codex_last_reported_cached_input_tokens: max(last_reported_cached_input, token_delta.cached_input_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp execute_poll_cycle(%State{} = state) do
    with_workflow_store_fallback(state, fn ->
      state
      |> load_runtime_config()
      |> maybe_dispatch()
    end)
  end

  defp refresh_runtime_config(%State{} = state) do
    with_workflow_store_fallback(state, fn -> load_runtime_config(state) end)
  end

  defp load_runtime_config(%State{} = state) do
    config = Config.settings!(@workflow_refresh_timeout_ms)
    cache_runtime_settings(state, config)
  end

  defp cache_runtime_settings(%State{} = state, config) do
    %{
      state
      | workspace_root: config.workspace.root,
        poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents,
        max_issue_tokens: config.agent.max_issue_tokens || 0,
        max_retry_attempts: config.agent.max_retry_attempts,
        max_retry_backoff_ms: config.agent.max_retry_backoff_ms,
        max_concurrent_agents_by_state: config.agent.max_concurrent_agents_by_state || %{},
        tracker_required_labels: config.tracker.required_labels || [],
        active_state_set: normalize_state_set(config.tracker.active_states),
        terminal_states: config.tracker.terminal_states,
        terminal_state_set: normalize_state_set(config.tracker.terminal_states),
        tracker_adapter: tracker_adapter(config.tracker.kind),
        worker_ssh_hosts: config.worker.ssh_hosts || [],
        worker_max_concurrent_agents_per_host: config.worker.max_concurrent_agents_per_host
    }
  end

  defp normalize_state_set(state_names) when is_list(state_names) do
    state_names
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp tracker_adapter("memory"), do: SymphonyElixir.Tracker.Memory
  defp tracker_adapter(_kind), do: SymphonyElixir.Linear.Adapter

  defp with_workflow_store_fallback(%State{} = state, operation) when is_function(operation, 0) do
    operation.()
  catch
    :exit, {reason, {GenServer, :call, [WorkflowStore, :current | _]}} = call_exit
    when reason in [:timeout, :noproc] ->
      Logger.warning("Workflow config refresh unavailable; retaining last valid settings: #{inspect(call_exit)}")

      state
  end

  defp retry_candidate_issue?(%Issue{} = issue, %State{} = state, terminal_states) do
    candidate_issue?(issue, state, active_state_set(state), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp maybe_log_token_telemetry_threshold(%State{} = state, issue_id, running_entry) when is_map(running_entry) do
    max_issue_tokens = state.max_issue_tokens || 0
    guard_tokens = billable_token_count(running_entry)

    if max_issue_tokens > 0 and guard_tokens >= max_issue_tokens do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)
      total_tokens = Map.get(running_entry, :codex_total_tokens, 0) || 0
      cached_input_tokens = Map.get(running_entry, :codex_cached_input_tokens, 0) || 0

      Logger.warning(
        "Token telemetry threshold exceeded; continuing issue: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id}; billable_tokens=#{guard_tokens} total_tokens=#{total_tokens} cached_input_tokens=#{cached_input_tokens} max_issue_tokens=#{max_issue_tokens}"
      )
    end

    state
  end

  defp maybe_log_token_telemetry_threshold(state, _issue_id, _running_entry), do: state

  defp billable_token_count(running_entry) when is_map(running_entry) do
    total_tokens = Map.get(running_entry, :codex_total_tokens, 0) || 0
    cached_input_tokens = Map.get(running_entry, :codex_cached_input_tokens, 0) || 0

    max(total_tokens - cached_input_tokens, 0)
  end

  defp billable_token_count(_running_entry), do: 0

  defp append_codex_token_ledger(_running_entry, _updated_running_entry, _update, %{
         input_tokens: input,
         output_tokens: output,
         total_tokens: total
       })
       when input <= 0 and output <= 0 and total <= 0,
       do: :ok

  defp append_codex_token_ledger(running_entry, updated_running_entry, update, token_delta)
       when is_map(token_delta) do
    payload = %{
      schema_version: "symphony.token_delta.v1",
      recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      timestamp: update[:timestamp] |> ledger_timestamp(),
      issue_id: issue_id_for_token_ledger(running_entry),
      issue_identifier: issue_identifier_for_token_ledger(running_entry),
      session_id: Map.get(updated_running_entry, :session_id),
      event: update[:event],
      input_tokens: token_delta.input_tokens,
      output_tokens: token_delta.output_tokens,
      total_tokens: token_delta.total_tokens,
      cached_input_tokens: token_delta.cached_input_tokens,
      billable_tokens: billable_token_count(updated_running_entry),
      reported_input_tokens: token_delta.input_reported,
      reported_output_tokens: token_delta.output_reported,
      reported_total_tokens: token_delta.total_reported,
      reported_cached_input_tokens: token_delta.cached_input_reported,
      turn_count: Map.get(updated_running_entry, :turn_count)
    }

    write_codex_token_ledger(payload)
  end

  defp append_codex_token_ledger(_running_entry, _updated_running_entry, _update, _token_delta), do: :ok

  defp write_codex_token_ledger(payload) when is_map(payload) do
    path = codex_token_ledger_path()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, encoded} <- Jason.encode(payload),
         :ok <- File.write(path, encoded <> "\n", [:append]) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Unable to append Codex token ledger #{path}: #{inspect(reason)}")
        :ok
    end
  end

  defp codex_token_ledger_path do
    case System.get_env("SYMPHONY_TOKEN_LEDGER_PATH") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default_codex_token_ledger_path()
          trimmed -> Path.expand(trimmed)
        end

      _ ->
        default_codex_token_ledger_path()
    end
  end

  defp default_codex_token_ledger_path do
    workflow_path = Path.expand(Workflow.workflow_file_path())
    path_parts = Path.split(workflow_path)

    case Enum.find_index(path_parts, &(&1 == ".codex")) do
      nil ->
        Path.expand(Path.join([Path.dirname(workflow_path), "runs", "symphony-token-ledger", "token-usage.jsonl"]))

      codex_index ->
        repo_root_parts = Enum.take(path_parts, codex_index)
        Path.join(repo_root_parts ++ [".codex", "runs", "symphony-token-ledger", "token-usage.jsonl"])
    end
  end

  defp ledger_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp ledger_timestamp(timestamp) when is_binary(timestamp), do: timestamp
  defp ledger_timestamp(_timestamp), do: nil

  defp issue_id_for_token_ledger(%{issue: %Issue{id: id}}), do: id
  defp issue_id_for_token_ledger(%{issue_id: id}) when is_binary(id), do: id
  defp issue_id_for_token_ledger(_running_entry), do: nil

  defp issue_identifier_for_token_ledger(%{issue: %Issue{identifier: identifier}}), do: identifier
  defp issue_identifier_for_token_ledger(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier_for_token_ledger(_running_entry), do: nil

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      ),
      compute_token_delta(
        running_entry,
        :cached_input,
        usage,
        :codex_last_reported_cached_input_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total, cached_input] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        cached_input_tokens: cached_input.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported,
        cached_input_reported: cached_input.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp get_token_usage(usage, :cached_input),
    do:
      payload_get(usage, [
        "cached_input_tokens",
        :cached_input_tokens,
        "cachedInputTokens",
        :cachedInputTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil

  defp maybe_put_snapshot_field(payload, _key, nil), do: payload
  defp maybe_put_snapshot_field(payload, key, value), do: Map.put(payload, key, value)

  defp maybe_put_terminal_snapshot_lists(snapshot, [], []), do: snapshot

  defp maybe_put_terminal_snapshot_lists(snapshot, held, permanent) do
    snapshot
    |> Map.put(:held, held)
    |> Map.put(:permanent, permanent)
  end

  defp next_dispatch_sequence(%State{} = state, issue_id) do
    state.effects
    |> Map.values()
    |> Enum.filter(&(Map.get(&1, :issue_id) == issue_id))
    |> Enum.map(&Map.get(&1, :attempt, 0))
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp ambiguous_effect_for_issue?(%State{effects: effects}, issue_id)
       when is_map(effects) and is_binary(issue_id) do
    Enum.any?(effects, fn {_key, effect} ->
      Map.get(effect, :issue_id) == issue_id and
        Map.get(effect, :status) in [:prepared, :started]
    end)
  end

  defp ambiguous_effect_for_issue?(_state, _issue_id), do: false

  defp reserve_dispatch_effect(%State{} = state, %Issue{} = issue, sequence) do
    case ExecutionLedger.reserve_effect(state.effects, issue, sequence) do
      {:ok, effects, prepared_effect} ->
        reserved_state = %{state | effects: effects}

        case persist_execution_state_result(reserved_state) do
          {:ok, persisted_state} -> {:ok, persisted_state, prepared_effect}
          {:error, failed_state, reason} -> {:error, failed_state, reason}
        end

      {:duplicate, duplicate_effect} ->
        {:duplicate, duplicate_effect}
    end
  end

  defp mark_dispatch_effect_started(%State{} = state, idempotency_key) do
    case ExecutionLedger.mark_effect_started(state.effects, idempotency_key) do
      {:ok, effects} ->
        %{state | effects: effects}
        |> persist_execution_state()

      {:error, :missing_effect} ->
        Logger.error("Dispatch effect receipt missing idempotency_key=#{idempotency_key}; durable state is fail-closed")

        %{state | execution_ledger_healthy: false}
    end
  end

  defp complete_dispatch_effect(%State{} = state, running_entry) when is_map(running_entry) do
    case Map.get(running_entry, :idempotency_key) do
      idempotency_key when is_binary(idempotency_key) ->
        case ExecutionLedger.mark_effect_completed(state.effects, idempotency_key) do
          {:ok, effects} ->
            %{state | effects: effects}

          {:error, :missing_effect} ->
            Logger.error("Completed dispatch has no durable effect idempotency_key=#{idempotency_key}")

            %{state | execution_ledger_healthy: false}
        end

      _missing ->
        state
    end
  end

  defp complete_dispatch_effect(state, _running_entry), do: state

  defp maybe_complete_dispatch_effect(state, running_entry, reason) do
    if dispatch_receipt_reason?(reason) do
      complete_dispatch_effect(state, running_entry)
    else
      state
    end
  end

  defp dispatch_receipt_reason?(:normal), do: true

  defp dispatch_receipt_reason?({:shutdown, {:classified_failure, failure_class, _reason}}) do
    FailureSemantics.valid_class?(failure_class)
  end

  defp dispatch_receipt_reason?({:classified_failure, failure_class, _reason}) do
    FailureSemantics.valid_class?(failure_class)
  end

  defp dispatch_receipt_reason?(_reason), do: false

  defp discard_dispatch_effect(%State{} = state, idempotency_key) do
    %{state | effects: Map.delete(state.effects, idempotency_key)}
    |> persist_execution_state()
  end

  defp restore_retry_timers(retrying) when is_map(retrying) do
    now_ms = System.monotonic_time(:millisecond)

    Map.new(retrying, fn {issue_id, retry_entry} ->
      delay_ms = max(0, Map.get(retry_entry, :due_at_ms, now_ms) - now_ms)
      retry_token = make_ref()
      timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

      {issue_id,
       retry_entry
       |> Map.put(:retry_token, retry_token)
       |> Map.put(:timer_ref, timer_ref)}
    end)
  end

  defp recover_ambiguous_effects(%{
         blocked: blocked,
         retrying: retrying,
         effects: effects
       })
       when is_map(blocked) and is_map(retrying) and is_map(effects) do
    recovered_blocked =
      Enum.reduce(effects, blocked, fn {_key, effect}, acc ->
        if Map.get(effect, :status) in [:prepared, :started] do
          issue_id = Map.get(effect, :issue_id)
          issue = Map.get(effect, :issue)

          Map.put(acc, issue_id, %{
            issue_id: issue_id,
            identifier: Map.get(effect, :identifier) || issue_id,
            issue_url: if(match?(%Issue{}, issue), do: issue.url, else: nil),
            issue: issue,
            error: "dispatch effect has no final receipt after restart",
            failure_class: :operator_decision_required,
            terminal_state: :held,
            transition: :terminal,
            attempt: Map.get(effect, :attempt, 1),
            retry_exhausted: false,
            idempotency_key: Map.get(effect, :idempotency_key),
            blocked_at: DateTime.utc_now()
          })
        else
          acc
        end
      end)

    ambiguous_issue_ids =
      effects
      |> Enum.filter(fn {_key, effect} ->
        Map.get(effect, :status) in [:prepared, :started]
      end)
      |> Enum.map(fn {_key, effect} -> Map.get(effect, :issue_id) end)
      |> MapSet.new()

    recovered_retrying =
      Map.reject(retrying, fn {issue_id, _entry} ->
        MapSet.member?(ambiguous_issue_ids, issue_id)
      end)

    %{
      blocked: recovered_blocked,
      retrying: recovered_retrying,
      effects: effects
    }
  end

  defp recover_ambiguous_effects(_state),
    do: %{blocked: %{}, retrying: %{}, effects: %{}}

  defp persist_execution_state(%State{} = state) do
    case persist_execution_state_result(state) do
      {:ok, persisted_state} -> persisted_state
      {:error, failed_state, _reason} -> failed_state
    end
  end

  defp persist_execution_state_result(%State{execution_ledger_healthy: nil} = state),
    do: {:ok, state}

  defp persist_execution_state_result(%State{} = state) do
    case ExecutionLedger.persist(
           execution_ledger_root(state),
           state.blocked,
           state.retry_attempts,
           state.effects
         ) do
      :ok ->
        {:ok, %{state | execution_ledger_healthy: true}}

      {:error, reason} ->
        Logger.error("Unable to persist durable execution state: #{inspect(reason)}")
        {:error, %{state | execution_ledger_healthy: false}, reason}
    end
  end

  defp execution_ledger_root(%State{workspace_root: root}) when is_binary(root) and root != "",
    do: root

  defp execution_ledger_root(_state), do: Config.settings!().workspace.root
end
