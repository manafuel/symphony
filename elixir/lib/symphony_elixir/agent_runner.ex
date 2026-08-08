defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger

  alias SymphonyElixir.{
    AgentMemory,
    Config,
    FailureSemantics,
    Linear.Issue,
    PromptBuilder,
    Tracker,
    Workspace
  }

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.ProducerV6.Lifecycle

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @doc false
  @spec build_turn_prompt_for_test(Issue.t(), keyword(), pos_integer(), pos_integer()) ::
          String.t()
  def build_turn_prompt_for_test(%Issue{} = issue, opts, turn_number, max_turns) do
    build_turn_prompt(issue, opts, turn_number, max_turns)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        classification = FailureSemantics.classify(reason)

        Logger.error("Agent run failed for #{issue_context(issue)} failure_class=#{classification.class} retryable=#{classification.retryable}")

        exit(FailureSemantics.exit_reason(reason))
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        producer_v6 = Keyword.get(opts, :producer_v6, false)

        try do
          if producer_v6 do
            with :ok <-
                   producer_checkpoint(
                     codex_update_recipient,
                     issue,
                     :workspace_ready,
                     %{worker_host: worker_host, workspace_path: workspace},
                     true
                   ),
                 {:ok, hook_receipt_bytes} <-
                   Workspace.run_before_run_hook_with_receipt(workspace, issue, worker_host),
                 :ok <-
                   producer_checkpoint(
                     codex_update_recipient,
                     issue,
                     :admission_passed,
                     %{hook_receipt_bytes: hook_receipt_bytes},
                     true
                   ) do
              run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
            end
          else
            send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

            with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
              run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
            end
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue, producer_v6) do
    fn message ->
      maybe_checkpoint_session_started(recipient, issue, message, producer_v6)
      send_codex_update(recipient, issue, message)
    end
  end

  defp maybe_checkpoint_session_started(recipient, issue, %{event: :session_started} = message, true) do
    case producer_checkpoint(recipient, issue, :turn_started, message, true) do
      :ok -> :ok
      {:error, reason} -> exit({:producer_checkpoint_failed, reason})
    end
  end

  defp maybe_checkpoint_session_started(_recipient, _issue, _message, _producer_v6), do: :ok

  defp producer_checkpoint(_recipient, _issue, _kind, _payload, false), do: :ok

  defp producer_checkpoint(recipient, %Issue{id: issue_id}, kind, payload, true)
       when is_pid(recipient) and is_binary(issue_id) and is_atom(kind) and is_map(payload) do
    GenServer.call(recipient, {:producer_checkpoint, issue_id, kind, payload}, :infinity)
  catch
    :exit, reason -> {:error, {:producer_checkpoint_call_failed, reason}}
  end

  defp producer_checkpoint(_recipient, _issue, _kind, _payload, true),
    do: {:error, :producer_checkpoint_recipient_invalid}

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    producer_v6 = Keyword.get(opts, :producer_v6, false)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host),
         {:ok, closeout} <-
           producer_thread_checkpoint(
             codex_update_recipient,
             issue,
             %{thread_id: session.thread_id, metadata: session.metadata},
             producer_v6
           ) do
      run_context = %{
        app_session: session,
        workspace: workspace,
        codex_update_recipient: codex_update_recipient,
        opts: opts,
        issue_state_fetcher: issue_state_fetcher,
        max_turns: max_turns,
        closeout: closeout
      }

      try do
        do_run_codex_turns(run_context, issue, 1)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(context, issue, turn_number) do
    prompt =
      issue
      |> build_turn_prompt(context.opts, turn_number, context.max_turns)
      |> append_producer_closeout(context.closeout)

    producer_v6 = Keyword.get(context.opts, :producer_v6, false)
    intent = Lifecycle.turn_intent(turn_number, prompt)

    with :ok <-
           producer_checkpoint(
             context.codex_update_recipient,
             issue,
             :turn_start_intent,
             intent,
             producer_v6
           ),
         {:ok, turn_session} <-
           AppServer.run_turn(
             context.app_session,
             prompt,
             issue,
             on_message: codex_message_handler(context.codex_update_recipient, issue, producer_v6),
             client_user_message_id: if(producer_v6, do: intent["client_user_message_id"]),
             capture_history: producer_v6
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{context.workspace} turn=#{turn_number}/#{context.max_turns}")

      issue
      |> continue_with_issue?(context.issue_state_fetcher)
      |> handle_turn_completion(context, issue, turn_session, turn_number, producer_v6)
    end
  end

  defp handle_turn_completion(
         {:continue, refreshed_issue},
         context,
         issue,
         turn_session,
         turn_number,
         producer_v6
       )
       when turn_number < context.max_turns do
    with :ok <-
           commit_turn_terminal(
             context.codex_update_recipient,
             issue,
             turn_session,
             context.closeout,
             false,
             producer_v6
           ) do
      Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{context.max_turns}")
      do_run_codex_turns(context, refreshed_issue, turn_number + 1)
    end
  end

  defp handle_turn_completion(
         {:continue, refreshed_issue},
         context,
         issue,
         turn_session,
         _turn_number,
         producer_v6
       ) do
    with :ok <-
           commit_turn_terminal(
             context.codex_update_recipient,
             issue,
             turn_session,
             context.closeout,
             false,
             producer_v6
           ) do
      Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")
      :ok
    end
  end

  defp handle_turn_completion(
         {:done, _refreshed_issue},
         context,
         issue,
         turn_session,
         _turn_number,
         producer_v6
       ) do
    commit_turn_terminal(
      context.codex_update_recipient,
      issue,
      turn_session,
      context.closeout,
      true,
      producer_v6
    )
  end

  defp handle_turn_completion(
         {:error, reason},
         _context,
         _issue,
         _turn_session,
         _turn_number,
         _producer_v6
       ),
       do: {:error, reason}

  defp producer_thread_checkpoint(recipient, issue, payload, true) do
    case producer_checkpoint(recipient, issue, :thread_ready, payload, true) do
      {:ok, closeout} when is_map(closeout) or is_nil(closeout) -> {:ok, closeout}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_closeout_directive_missing}
    end
  end

  defp producer_thread_checkpoint(recipient, issue, payload, false) do
    with :ok <- producer_checkpoint(recipient, issue, :thread_ready, payload, false) do
      {:ok, nil}
    end
  end

  defp commit_turn_terminal(recipient, issue, turn_session, nil, _final, true) do
    producer_checkpoint(recipient, issue, :turn_terminal, turn_session, true)
  end

  defp commit_turn_terminal(recipient, issue, turn_session, closeout, final, true) do
    kind = if(final, do: :turn_terminal_final, else: :turn_terminal)
    payload = if(final, do: Map.put(turn_session, :producer_closeout, closeout), else: turn_session)
    producer_checkpoint(recipient, issue, kind, payload, true)
  end

  defp commit_turn_terminal(recipient, issue, turn_session, _closeout, _final, false) do
    producer_checkpoint(recipient, issue, :turn_terminal, turn_session, false)
  end

  defp append_producer_closeout(prompt, nil), do: prompt

  defp append_producer_closeout(prompt, %{terminal_marker: marker}) when is_binary(marker) do
    prompt <>
      "\n\n## Producer-v6 closeout custody\n\n" <>
      "Before moving this issue to Done, post exactly one dedicated Linear comment whose entire body is the following byte-for-byte text (no Markdown fence, prefix, suffix, whitespace, or newline):\n\n" <>
      marker <>
      "\n\nThis machine marker is additional to the normal human-readable `<!-- symphony:final:... -->` evidence comment. Do not claim completion unless both comments exist and the state transition to Done succeeds.\n"
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    recaller = Keyword.get(opts, :agentmemory_recaller, &AgentMemory.recall/1)
    prompt_builder = Keyword.get(opts, :prompt_builder, &PromptBuilder.build_prompt/2)

    memory_context = recall_context(recaller, issue)
    prompt = prompt_builder.(issue, opts)
    AgentMemory.append_context(prompt, memory_context)
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp recall_context(recaller, issue) do
    case recaller.(issue) do
      {:ok, context} when is_binary(context) and context != "" -> context
      _ -> nil
    end
  rescue
    _exception ->
      Logger.warning("AgentMemory first-turn recall raised unexpectedly; continuing without memory context")

      nil
  catch
    _kind, _reason ->
      Logger.warning("AgentMemory first-turn recall exited unexpectedly; continuing without memory context")

      nil
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
