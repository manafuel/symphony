defmodule SymphonyElixir.ProducerV6.Execution do
  @moduledoc """
  Production adapter between the orchestrator and the immutable producer-v6 DAG.

  The public entries retain the small map shape expected by the existing
  orchestrator while every mutation is committed by `ProducerReceipts`. No v5
  persistence function is reachable from this module.
  """

  alias SymphonyElixir.{ProducerReceipts, Rfc8785Jcs}
  alias SymphonyElixir.ProducerV6.Broker
  alias SymphonyElixir.ProducerV6.RuntimeBinding.Live

  @deadline_seconds 7_200

  @spec reserve(map(), map(), map(), pos_integer(), pos_integer()) ::
          {:ok, map(), map()} | {:duplicate, map()} | {:error, term()}
  def reserve(context, effects, issue, dispatch_sequence, retry_attempt) do
    reserve_with_broker(
      context,
      effects,
      issue,
      dispatch_sequence,
      retry_attempt,
      Broker
    )
  end

  @doc false
  @spec reserve_with_broker(map(), map(), map(), pos_integer(), pos_integer(), module()) ::
          {:ok, map(), map()} | {:duplicate, map()} | {:error, term()}
  def reserve_with_broker(
        %{kind: :producer_v6} = context,
        effects,
        issue,
        dispatch_sequence,
        retry_attempt,
        broker
      )
      when is_map(effects) and is_map(issue) and is_integer(dispatch_sequence) and
             dispatch_sequence > 0 and is_integer(retry_attempt) and retry_attempt > 0 and
             is_atom(broker) do
    with false <- ambiguous_issue?(effects, issue_value(issue, :id)),
         workspace_root when is_binary(workspace_root) <- workspace_root(context),
         deadline = deadline_after(@deadline_seconds),
         {:ok, allocation} <-
           ProducerReceipts.reserve_dispatch_with_broker(
             issue,
             dispatch_sequence,
             retry_attempt,
             workspace_root,
             context,
             deadline,
             broker
           ),
         false <- allocation.replay,
         {:ok, runtime_binding} <- runtime_binding(context, workspace_root, broker),
         prepared_at = producer_now(),
         input = %{
           issue: issue_projection(issue),
           dispatch_allocation: Map.drop(allocation, [:replay]),
           process_epoch_id: process_epoch_id(),
           runtime_binding: runtime_binding,
           producer_claim: nil,
           admission_result: nil,
           state: initial_state(),
           prepared_at_utc: prepared_at,
           previous_transition: nil,
           prior_milestones: [],
           evidence: %{"prepared_at_utc" => prepared_at},
           deadline_at_utc: deadline,
           owner_os_pid: owner_os_pid()
         },
         {:ok, committed} <-
           ProducerReceipts.commit_transition_with_broker(
             workspace_root,
             context,
             input,
             broker
           ) do
      entry = entry_from_document(committed.effect)
      {:ok, Map.put(effects, entry.idempotency_key, entry), entry}
    else
      true -> duplicate_for_issue(effects, issue_value(issue, :id))
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_v6_reservation_invalid}
    end
  end

  def reserve_with_broker(_context, _effects, _issue, _dispatch_sequence, _retry_attempt, _broker),
    do: {:error, :invalid_producer_v6_reservation}

  @spec mark_worker_registered(map(), map(), String.t(), pid() | String.t()) ::
          {:ok, map()} | {:error, term()}
  def mark_worker_registered(context, effects, idempotency_key, worker_pid) do
    transition(
      context,
      effects,
      idempotency_key,
      "worker_registered",
      fn state ->
        worker = %{
          "worker_id" => worker_id(worker_pid),
          "beam_pid" => inspect(worker_pid),
          "registered_at_utc" => producer_now()
        }

        {%{state | "attempt_phase" => "worker_registered", "worker" => worker}, %{"worker" => worker}}
      end
    )
  end

  @spec mark_workspace_ready(map(), map(), String.t(), Path.t()) ::
          {:ok, map()} | {:error, term()}
  def mark_workspace_ready(context, effects, idempotency_key, path) when is_binary(path) do
    transition(
      context,
      effects,
      idempotency_key,
      "workspace_ready",
      fn state ->
        workspace = %{
          "lexical_path" => Path.expand(path),
          "physical_path" => Path.expand(path),
          "created" => File.dir?(path),
          "ready_at_utc" => producer_now()
        }

        {%{state | "attempt_phase" => "workspace_ready", "workspace" => workspace}, %{"workspace" => workspace}}
      end
    )
  end

  @spec mark_claim_ready(map(), map(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def mark_claim_ready(context, effects, idempotency_key, producer_claim)
      when is_map(producer_claim) do
    transition(
      context,
      effects,
      idempotency_key,
      "claim_ready",
      fn state ->
        next = %{
          state
          | "attempt_phase" => "claim_ready",
            "producer_claim" => stringify(producer_claim)
        }

        {next, %{"producer_claim" => stringify(producer_claim)}}
      end
    )
  end

  @spec mark_admission_passed(map(), map(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def mark_admission_passed(context, effects, idempotency_key, admission_result)
      when is_map(admission_result) do
    transition(
      context,
      effects,
      idempotency_key,
      "admission_passed",
      fn state ->
        next = %{
          state
          | "attempt_phase" => "admitted",
            "admission" => stringify(admission_result)
        }

        {next, %{"admission" => stringify(admission_result)}}
      end
    )
  end

  @spec mark_thread_ready(map(), map(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def mark_thread_ready(context, effects, idempotency_key, thread) when is_map(thread) do
    transition(
      context,
      effects,
      idempotency_key,
      "thread_ready",
      fn state ->
        thread = stringify(thread)
        next = %{state | "attempt_phase" => "thread_ready", "thread" => thread}
        {next, %{"thread" => thread}}
      end
    )
  end

  @spec mark_turn_start_intent(map(), map(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def mark_turn_start_intent(context, effects, idempotency_key, intent) when is_map(intent) do
    transition(
      context,
      effects,
      idempotency_key,
      "turn_start_intent",
      fn state ->
        intent = stringify(intent)
        turn_number = intent["turn_number"]

        turn = %{
          "turn_number" => turn_number,
          "client_user_message_id" => intent["client_user_message_id"],
          "prompt_sha256" => intent["prompt_sha256"],
          "intent_at_utc" => intent["intent_at_utc"],
          "turn_id" => nil,
          "user_message_item_id" => nil,
          "started_at_utc" => nil,
          "history_reconciliation" => nil,
          "terminal_status" => nil,
          "terminal_at_utc" => nil,
          "result_sha256" => nil,
          "server_turn_terminal_event" => nil,
          "completion_seal" => nil
        }

        next = %{
          state
          | "attempt_phase" => "executing",
            "turns" => state["turns"] ++ [turn]
        }

        {next, intent}
      end
    )
  end

  @spec mark_turn_started(map(), map(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def mark_turn_started(context, effects, idempotency_key, started) when is_map(started) do
    transition(
      context,
      effects,
      idempotency_key,
      "turn_started",
      fn state ->
        started = stringify(started)
        turn = Map.merge(List.last(state["turns"]), started)
        next = %{state | "attempt_phase" => "executing", "turns" => replace_last(state["turns"], turn)}
        {next, turn_start_evidence(turn)}
      end
    )
  end

  @spec mark_turn_terminal(map(), map(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def mark_turn_terminal(context, effects, idempotency_key, terminal) when is_map(terminal) do
    transition(
      context,
      effects,
      idempotency_key,
      "turn_terminal",
      fn state ->
        terminal = stringify(terminal)
        turn = Map.merge(List.last(state["turns"]), terminal)
        next = %{state | "attempt_phase" => "executing", "turns" => replace_last(state["turns"], turn)}
        {next, turn}
      end
    )
  end

  @spec mark_completed(map(), map(), String.t(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def mark_completed(context, effects, idempotency_key, terminal_tracker, completion_seal)
      when is_map(terminal_tracker) and is_map(completion_seal) do
    transition(
      context,
      effects,
      idempotency_key,
      "completed",
      fn state ->
        completed_at_utc = producer_now()
        terminal_tracker = stringify(terminal_tracker)
        completion_seal = stringify(completion_seal)
        turn = Map.put(List.last(state["turns"]), "completion_seal", completion_seal)
        turns = replace_last(state["turns"], turn)

        next = %{
          state
          | "attempt_phase" => "completed",
            "disposition" => "completed",
            "turns" => turns,
            "completed_at_utc" => completed_at_utc,
            "completion_outcome" => "issue_terminal",
            "terminal_tracker" => terminal_tracker
        }

        evidence = %{
          "completion_outcome" => "issue_terminal",
          "terminal_turn_number" => turn["turn_number"],
          "turn_terminal_at_utc" => turn["terminal_at_utc"],
          "terminal_tracker" => terminal_tracker,
          "completed_at_utc" => completed_at_utc,
          "turn_count" => length(turns),
          "transition_receipt_count_before_completed" => state["milestone_sequence"],
          "previous_receipt_sha256" => nil
        }

        {next, evidence}
      end
    )
  end

  @spec verify_state(Path.t(), map(), map()) :: :ok | {:error, term()}
  def verify_state(workspace_root, context, effects) when is_map(effects) do
    current = Path.join(workspace_root, ".symphony-state\\execution.json")

    with {:ok, identity} <- Broker.inspect(current, workspace_root, context),
         {:ok, bytes} <- File.read(current),
         true <- identity["sha256"] == sha256(bytes),
         {:ok, ledger} <- Rfc8785Jcs.validate_canonical(bytes),
         expected <- effects |> Map.values() |> Enum.map(& &1.document) |> Enum.sort_by(& &1["idempotency_key"]),
         actual when is_list(actual) <- ledger["effects"],
         true <- actual == expected do
      :ok
    else
      false -> {:error, :producer_v6_runtime_state_drift}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_v6_runtime_state_invalid}
    end
  end

  @spec entry_from_document(map()) :: map()
  def entry_from_document(document) when is_map(document) do
    %{
      idempotency_key: document["idempotency_key"],
      issue_id: document["issue_id"],
      identifier: document["identifier"],
      issue: document["issue"],
      attempt: document["dispatch_sequence"],
      retry_attempt: document["retry_attempt"],
      status: status(document),
      prepared_at: parse_datetime(document["prepared_at_utc"]),
      receipt_at: receipt_at(document),
      document: document
    }
  end

  defp transition(context, effects, key, milestone, update) do
    with entry when is_map(entry) <- Map.get(effects, key),
         document when is_map(document) <- entry.document,
         :ok <- expected_predecessor(document["last_milestone"], milestone),
         workspace_root when is_binary(workspace_root) <- workspace_root(context),
         {:ok, allocation_document} <- read_reference(document["dispatch_allocation"], workspace_root),
         {:ok, transition_document} <- read_reference(last_transition(document), workspace_root),
         {:ok, transition_authority} <- transition_authority(document, workspace_root),
         {state, evidence} <- update.(state_from_effect(document)),
         evidence <- bind_predecessor_evidence(evidence, milestone, last_transition(document)),
         sequence = document["milestone_sequence"] + 1,
         state = %{state | "milestone_sequence" => sequence, "last_milestone" => milestone},
         input = %{
           issue: document["issue"],
           dispatch_allocation: %{document: allocation_document, reference: document["dispatch_allocation"]},
           process_epoch_id: transition_authority.process_epoch_id,
           runtime_binding: transition_document["runtime_binding"],
           producer_claim: state["producer_claim"],
           admission_result: state["admission"],
           state: state,
           prepared_at_utc: document["prepared_at_utc"],
           previous_transition: last_transition(document),
           prior_milestones: document["milestones"],
           evidence: evidence,
           deadline_at_utc: transition_authority.deadline_at_utc,
           owner_os_pid: owner_os_pid()
         },
         {:ok, committed} <- ProducerReceipts.commit_transition(workspace_root, context, input) do
      next = entry_from_document(committed.effect)
      {:ok, Map.put(effects, key, next)}
    else
      nil -> {:error, :missing_effect}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_v6_transition_invalid}
    end
  end

  defp runtime_binding(%{runtime_binding: binding}, _root, _broker) when is_map(binding),
    do: {:ok, binding}

  defp runtime_binding(context, root, broker), do: Live.transition_binding(context, root, broker)

  defp workspace_root(%{contract: %{document: contract}}),
    do: get_in(contract, ["constants", "workspace_root_windows"])

  defp initial_state do
    %{
      "attempt_phase" => "reserved",
      "disposition" => "active",
      "milestone_sequence" => 1,
      "last_milestone" => "prepared",
      "worker" => nil,
      "workspace" => nil,
      "producer_claim" => nil,
      "admission" => nil,
      "thread" => nil,
      "turns" => [],
      "completed_at_utc" => nil,
      "completion_outcome" => nil,
      "terminal_tracker" => nil,
      "hold" => nil
    }
  end

  defp state_from_effect(effect) do
    Map.take(
      effect,
      ~w(attempt_phase disposition milestone_sequence last_milestone worker workspace producer_claim admission thread turns completed_at_utc completion_outcome terminal_tracker hold)
    )
  end

  defp issue_projection(issue) do
    %{
      "id" => issue_value(issue, :id),
      "identifier" => issue_value(issue, :identifier),
      "state" => issue_value(issue, :state),
      "url" => issue_value(issue, :url),
      "assigned_to_worker" => issue_value(issue, :assigned_to_worker)
    }
  end

  defp issue_value(issue, key), do: Map.get(issue, key) || Map.get(issue, Atom.to_string(key))

  defp ambiguous_issue?(effects, issue_id) do
    Enum.any?(effects, fn {_key, effect} ->
      effect.issue_id == issue_id and effect.status in [:prepared, :started]
    end)
  end

  defp duplicate_for_issue(effects, issue_id) do
    case Enum.find(effects, fn {_key, effect} -> effect.issue_id == issue_id end) do
      nil -> {:error, :producer_v6_duplicate_resolution_failed}
      {_key, effect} -> {:duplicate, effect}
    end
  end

  defp expected_predecessor("prepared", "worker_registered"), do: :ok
  defp expected_predecessor("worker_registered", "workspace_ready"), do: :ok
  defp expected_predecessor("workspace_ready", "claim_ready"), do: :ok
  defp expected_predecessor("claim_ready", "admission_passed"), do: :ok
  defp expected_predecessor("admission_passed", "thread_ready"), do: :ok
  defp expected_predecessor("thread_ready", "turn_start_intent"), do: :ok
  defp expected_predecessor("turn_terminal", "turn_start_intent"), do: :ok
  defp expected_predecessor("turn_start_intent", "turn_started"), do: :ok
  defp expected_predecessor("turn_started", "turn_terminal"), do: :ok
  defp expected_predecessor("turn_terminal", "completed"), do: :ok
  defp expected_predecessor(_from, _to), do: {:error, :producer_v6_transition_not_allowed}

  defp last_transition(%{"milestones" => milestones}) when is_list(milestones) and milestones != [] do
    milestone = List.last(milestones)

    %{
      "path" => milestone["receipt_path"],
      "physical_path" => milestone["receipt_physical_path"],
      "volume_id" => milestone["receipt_volume_id"],
      "file_id" => milestone["receipt_file_id"],
      "file_type" => milestone["receipt_file_type"],
      "link_count" => milestone["receipt_link_count"],
      "sha256" => milestone["receipt_sha256"],
      "length" => milestone["receipt_length"]
    }
  end

  defp read_reference(reference, workspace_root) when is_map(reference) do
    path = Path.join(workspace_root, String.replace(reference["path"], "/", "\\"))

    with {:ok, bytes} <- File.read(path),
         true <- sha256(bytes) == reference["sha256"],
         {:ok, document} <- Rfc8785Jcs.validate_canonical(bytes) do
      {:ok, document}
    else
      false -> {:error, :producer_v6_reference_digest_drift}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transition_authority(%{"milestones" => milestones}, workspace_root)
       when is_list(milestones) and milestones != [] do
    with milestone when is_map(milestone) <- List.last(milestones),
         intent_reference when is_map(intent_reference) <- milestone["install_intent_core"],
         {:ok, intent} <- read_reference(intent_reference, workspace_root),
         lock_reference when is_map(lock_reference) <- intent["lock"],
         {:ok, lock} <- read_reference(lock_reference, workspace_root),
         locked_process_epoch_id when is_binary(locked_process_epoch_id) <-
           lock["owner_process_epoch_id"],
         locked_owner_os_pid when is_integer(locked_owner_os_pid) <- lock["owner_os_pid"],
         current_process_epoch_id = process_epoch_id(),
         current_owner_os_pid = owner_os_pid(),
         true <- locked_process_epoch_id == current_process_epoch_id,
         true <- locked_owner_os_pid == current_owner_os_pid,
         deadline_at_utc when is_binary(deadline_at_utc) <-
           lock["authority_deadline_at_utc"] do
      {:ok,
       %{
         process_epoch_id: locked_process_epoch_id,
         deadline_at_utc: deadline_at_utc
       }}
    else
      false -> {:error, :producer_v6_process_authority_drift}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_v6_transition_authority_invalid}
    end
  end

  defp transition_authority(_document, _workspace_root),
    do: {:error, :producer_v6_transition_authority_invalid}

  defp bind_predecessor_evidence(evidence, "completed", predecessor)
       when is_map(evidence) and is_map(predecessor) do
    Map.put(evidence, "previous_receipt_sha256", predecessor["sha256"])
  end

  defp bind_predecessor_evidence(evidence, _milestone, _predecessor), do: evidence

  defp turn_start_evidence(turn) do
    Map.take(
      turn,
      ~w(client_user_message_id prompt_sha256 intent_at_utc turn_id user_message_item_id started_at_utc)
    )
  end

  defp replace_last([], _value), do: []
  defp replace_last(values, value), do: List.replace_at(values, -1, value)

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp status(%{"last_milestone" => "completed"}), do: :completed
  defp status(%{"last_milestone" => "prepared"}), do: :prepared
  defp status(_document), do: :started

  defp receipt_at(%{"milestones" => milestones}) when is_list(milestones) and milestones != [] do
    milestones |> List.last() |> Map.get("at_utc") |> parse_datetime()
  end

  defp receipt_at(_document), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp worker_id(pid), do: :crypto.hash(:sha256, inspect(pid)) |> Base.encode16(case: :lower)
  defp owner_os_pid, do: System.pid() |> String.to_integer()

  defp process_epoch_id do
    key = {__MODULE__, :process_epoch_id}

    case :persistent_term.get(key, nil) do
      nil ->
        value = "sympe-" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end

  defp producer_now,
    do: DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.%3fZ")

  defp deadline_after(seconds) do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.%3fZ")
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
