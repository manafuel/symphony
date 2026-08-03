defmodule SymphonyElixir.ProducerReceipts do
  @moduledoc """
  Producer-v6 immutable receipt and dual-ledger transaction writer.

  Each transition is committed in the reviewed order: evidence, transition,
  lock receipt, install-intent core, target effect/ledger, install plan,
  durable PREVIOUS then CURRENT broker installation, broker-result receipt,
  and install-result receipt. No v5 writer or absent-to-present recovery path is
  available here.
  """

  alias SymphonyElixir.{ProducerV6.Broker, ProducerV6.Format, Rfc8785Jcs}

  @transition_schema "manafuel.symphony_producer_transition_receipt.v1"
  @intent_schema "manafuel.symphony_ledger_install_intent_core.v1"
  @plan_schema "manafuel.symphony_ledger_install_plan.v1"
  @result_schema "manafuel.symphony_ledger_install_result.v1"
  @ledger_schema "symphony.execution_ledger.v6"
  @effect_schema "symphony.execution_effect.v6"
  @milestones ~w(prepared worker_registered workspace_ready claim_ready admission_passed thread_ready turn_start_intent turn_started turn_terminal completed held)
  @input_keys ~w(issue dispatch_allocation process_epoch_id runtime_binding producer_claim admission_result state prepared_at_utc previous_transition prior_milestones evidence deadline_at_utc owner_os_pid)a

  @type authority :: map()

  @spec reserve_dispatch(map(), pos_integer(), pos_integer(), Path.t(), authority(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def reserve_dispatch(issue, dispatch_sequence, retry_attempt, workspace_root, authority, deadline)
      when is_map(issue) do
    reserve_dispatch_with_broker(
      issue,
      dispatch_sequence,
      retry_attempt,
      workspace_root,
      authority,
      deadline,
      Broker
    )
  end

  @doc false
  @spec reserve_dispatch_with_broker(
          map(),
          pos_integer(),
          pos_integer(),
          Path.t(),
          map(),
          String.t(),
          module()
        ) ::
          {:ok, map()} | {:error, term()}
  def reserve_dispatch_with_broker(
        issue,
        dispatch_sequence,
        retry_attempt,
        workspace_root,
        authority,
        deadline,
        broker
      )
      when is_map(issue) and is_atom(broker) do
    issue_identity = %{"id" => issue_value(issue, "id"), "identifier" => issue_value(issue, "identifier")}

    with :ok <- validate_issue(issue_identity),
         {:ok, result} <-
           broker.allocate_dispatch(
             issue_identity,
             dispatch_sequence,
             retry_attempt,
             now(),
             workspace_root,
             authority,
             deadline
           ),
         allocation when is_map(allocation) <- result.allocation,
         reference when is_map(reference) <- result.reference,
         replay when is_boolean(replay) <- result.replay do
      {:ok, %{document: allocation, reference: reference, replay: replay}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :dispatch_allocation_result_invalid}
    end
  end

  @spec commit_transition(Path.t(), authority(), map()) :: {:ok, map()} | {:error, term()}
  def commit_transition(workspace_root, authority, input),
    do: commit_transition_with_broker(workspace_root, authority, input, Broker)

  @doc false
  @spec commit_transition_with_broker(Path.t(), map(), map(), module()) ::
          {:ok, map()} | {:error, term()}
  def commit_transition_with_broker(workspace_root, authority, input, broker)
      when is_binary(workspace_root) and is_map(authority) and is_map(input) and
             is_atom(broker) do
    with :ok <- exact_atom_keys(input, @input_keys),
         :ok <- validate_input(input),
         {:ok, lock} <-
           broker.acquire_lock(
             input.process_epoch_id,
             input.owner_os_pid,
             input.deadline_at_utc,
             workspace_root,
             authority
           ) do
      case commit_under_lock(workspace_root, authority, input, lock, broker) do
        {:ok, result} ->
          release_committed_lock(result, lock, input, workspace_root, authority, broker)

        {:error, reason} ->
          {:error, {:producer_transition_commit_blocked_lock_retained, reason, lock.reference}}
      end
    end
  end

  def commit_transition_with_broker(_workspace_root, _authority, _input, _broker),
    do: {:error, :invalid_producer_transition_input}

  defp release_committed_lock(result, lock, input, workspace_root, authority, broker) do
    case broker.release_lock(lock.reference, input.deadline_at_utc, workspace_root, authority) do
      :ok -> {:ok, result}
      {:error, reason} -> {:error, {:ledger_lock_release_failed_after_commit, reason}}
    end
  end

  defp commit_under_lock(workspace_root, authority, input, lock, broker) do
    issue = issue_projection(input.issue)
    allocation = input.dispatch_allocation
    allocation_document = allocation.document
    allocation_reference = allocation.reference
    sequence = input.state["milestone_sequence"]
    milestone_name = input.state["last_milestone"]

    dispatch = %{
      "dispatch_sequence" => allocation_document["dispatch_sequence"],
      "retry_attempt" => allocation_document["retry_attempt"],
      "allocation" => allocation_reference
    }

    with {:ok, before} <-
           read_ledger_before(workspace_root, authority, input.deadline_at_utc, broker),
         {:ok, evidence_reference} <-
           broker.publish_cas(
             input.evidence,
             "milestone_evidence",
             workspace_root,
             authority,
             input.deadline_at_utc
           ),
         transition =
           transition_document(
             input,
             issue,
             dispatch,
             sequence,
             milestone_name,
             evidence_reference,
             before.fingerprints
           ),
         :ok <- exact_projection(transition, authority, "transition_receipt"),
         {:ok, transition_reference} <-
           broker.publish_cas(
             transition,
             "transition",
             workspace_root,
             authority,
             input.deadline_at_utc
           ),
         {:ok, lock_receipt_reference} <-
           broker.publish_cas(
             lock.lock,
             "ledger_write_lock_receipt",
             workspace_root,
             authority,
             input.deadline_at_utc
           ),
         generation_id = random_hex(16),
         intent =
           intent_document(input, %{
             issue: issue,
             dispatch: dispatch,
             sequence: sequence,
             name: milestone_name,
             transition: transition_reference,
             before: before.fingerprints,
             generation: generation_id,
             lock: lock_receipt_reference
           }),
         :ok <- exact_projection(intent, authority, "ledger_install_intent_core"),
         {:ok, intent_reference} <-
           broker.publish_cas(
             intent,
             "ledger_install_intent_core",
             workspace_root,
             authority,
             input.deadline_at_utc
           ),
         milestone =
           effect_milestone(
             sequence,
             milestone_name,
             transition["milestone"],
             intent_reference,
             transition_reference,
             input.previous_transition
           ),
         effect = effect_document(input, allocation_document, allocation_reference, milestone),
         :ok <- exact_projection(effect, authority, "effect"),
         {:ok, effect_bytes} <- Rfc8785Jcs.encode(effect),
         effect_sha256 = sha256(effect_bytes),
         {:ok, ledger} <- target_ledger(before.ledger, effect, generation_id),
         :ok <- exact_projection(ledger, authority, "ledger"),
         {:ok, ledger_bytes} <- Rfc8785Jcs.encode(ledger),
         ledger_sha256 = sha256(ledger_bytes),
         {:ok, target_ledger_reference} <-
           broker.publish_cas(
             ledger,
             "ledger_snapshot",
             workspace_root,
             authority,
             input.deadline_at_utc
           ),
         expected_after = expected_after(generation_id, ledger_sha256, byte_size(ledger_bytes)),
         plan =
           plan_document(input, %{
             issue: issue,
             dispatch: dispatch,
             sequence: sequence,
             intent: intent_reference,
             effect_sha: effect_sha256,
             before_cas: before.cas,
             after_pair: expected_after,
             lock: lock_receipt_reference
           }),
         :ok <- exact_projection(plan, authority, "ledger_install_plan"),
         {:ok, plan_reference} <-
           broker.publish_cas(
             plan,
             "ledger_install_plan",
             workspace_root,
             authority,
             input.deadline_at_utc
           ),
         {:ok, broker_receipt} <-
           install_pair(
             workspace_root,
             authority,
             input.deadline_at_utc,
             lock.reference,
             before,
             target_ledger_reference,
             broker
           ),
         {:ok, broker_reference} <-
           broker.publish_cas_at(
             broker_receipt,
             ".symphony-state/file-transaction-broker-results/sha256",
             1_048_576,
             workspace_root,
             authority,
             input.deadline_at_utc
           ),
         {:ok, installed_after, destination_results} <-
           installed_after(broker_receipt, generation_id, ledger_sha256, byte_size(ledger_bytes)),
         result =
           result_document(input, %{
             issue: issue,
             dispatch: dispatch,
             sequence: sequence,
             intent: intent_reference,
             plan: plan_reference,
             effect_sha: effect_sha256,
             broker: broker_reference,
             outcomes: destination_results,
             after_pair: installed_after
           }),
         :ok <- exact_projection(result, authority, "ledger_install_result"),
         {:ok, result_reference} <-
           broker.publish_cas(
             result,
             "ledger_install_result",
             workspace_root,
             authority,
             input.deadline_at_utc
           ) do
      {:ok,
       %{
         effect: effect,
         ledger: ledger,
         transition: %{document: transition, reference: transition_reference},
         install_intent_core: %{document: intent, reference: intent_reference},
         install_plan: %{document: plan, reference: plan_reference},
         broker_result: %{document: broker_receipt, reference: broker_reference},
         install_result: %{document: result, reference: result_reference},
         current: installed_after["current"],
         previous: installed_after["previous"]
       }}
    end
  end

  defp read_ledger_before(workspace_root, authority, deadline, broker) do
    current_path = Path.join(workspace_root, ".symphony-state\\execution.json")
    previous_path = Path.join(workspace_root, ".symphony-state\\execution.previous.json")

    case {File.exists?(current_path), File.exists?(previous_path)} do
      {false, false} ->
        {:ok,
         %{
           fingerprints: %{"current" => nil, "previous" => nil},
           cas: %{"current" => nil, "previous" => nil},
           identities: %{"current" => nil, "previous" => nil},
           ledger: empty_ledger()
         }}

      {true, true} ->
        with {:ok, current_identity} <- broker.inspect(current_path, workspace_root, authority),
             {:ok, previous_identity} <- broker.inspect(previous_path, workspace_root, authority),
             :ok <- equal_distinct_identities(current_identity, previous_identity),
             {:ok, current_bytes} <- File.read(current_path),
             {:ok, previous_bytes} <- File.read(previous_path),
             true <- current_bytes == previous_bytes,
             true <- sha256(current_bytes) == current_identity["sha256"],
             {:ok, ledger} <- Rfc8785Jcs.validate_canonical(current_bytes),
             :ok <- ledger_root(ledger),
             {:ok, archive_reference} <-
               broker.publish_cas(
                 ledger,
                 "ledger_snapshot",
                 workspace_root,
                 authority,
                 deadline
               ) do
          {:ok,
           %{
             fingerprints: %{
               "current" => fingerprint("CURRENT", ".symphony-state/execution.json", current_identity, ledger),
               "previous" =>
                 fingerprint(
                   "PREVIOUS",
                   ".symphony-state/execution.previous.json",
                   previous_identity,
                   ledger
                 )
             },
             cas: %{"current" => archive_reference, "previous" => archive_reference},
             identities: %{"current" => current_identity, "previous" => previous_identity},
             ledger: ledger
           }}
        else
          false -> {:error, :ledger_before_pair_bytes_or_identity_mismatch}
          {:error, reason} -> {:error, reason}
        end

      _split ->
        {:error, :one_file_split_requires_recovery_journal}
    end
  end

  defp transition_document(input, issue, dispatch, sequence, milestone_name, evidence, before) do
    %{
      "schema_version" => @transition_schema,
      "claim_session_id" => input.dispatch_allocation.document["claim_session_id"],
      "idempotency_key" => input.dispatch_allocation.document["idempotency_key"],
      "issue" => issue,
      "dispatch" => dispatch,
      "effect_binding" => %{
        "effect_schema_version" => @effect_schema,
        "source_ledger_schema_version" => @ledger_schema
      },
      "milestone" => %{
        "sequence" => sequence,
        "name" => milestone_name,
        "turn_number" => turn_number(input.evidence),
        "at_utc" => now(),
        "evidence" => evidence,
        "evidence_sha256" => evidence["sha256"]
      },
      "previous_transition" => previous_reference(input.previous_transition),
      "ledger_before" => before,
      "runtime_binding" => input.runtime_binding,
      "producer_claim" => input.producer_claim,
      "admission_result" => input.admission_result,
      "state" => input.state
    }
  end

  defp intent_document(input, attrs) do
    %{
      "schema_version" => @intent_schema,
      "claim_session_id" => input.dispatch_allocation.document["claim_session_id"],
      "idempotency_key" => input.dispatch_allocation.document["idempotency_key"],
      "issue" => attrs.issue,
      "dispatch" => attrs.dispatch,
      "transaction_id" => random_hex(16),
      "process_epoch_id" => input.process_epoch_id,
      "milestone_sequence" => attrs.sequence,
      "milestone_name" => attrs.name,
      "transition_receipt" => attrs.transition,
      "ledger_before" => attrs.before,
      "target_generation_id" => attrs.generation,
      "target_transition_head_sha256" => attrs.transition["sha256"],
      "lock" => attrs.lock,
      "created_at_utc" => now(),
      "decision" => "PREPARED"
    }
  end

  defp effect_milestone(sequence, name, transition_milestone, intent, transition, previous) do
    %{
      "sequence" => sequence,
      "name" => name,
      "turn_number" => transition_milestone["turn_number"],
      "at_utc" => transition_milestone["at_utc"],
      "evidence_sha256" => transition_milestone["evidence_sha256"],
      "install_intent_core" => intent,
      "receipt_path" => transition["path"],
      "receipt_physical_path" => transition["physical_path"],
      "receipt_volume_id" => transition["volume_id"],
      "receipt_file_id" => transition["file_id"],
      "receipt_file_type" => transition["file_type"],
      "receipt_link_count" => transition["link_count"],
      "receipt_sha256" => transition["sha256"],
      "receipt_length" => transition["length"],
      "previous_receipt_sha256" => if(is_map(previous), do: previous["sha256"], else: nil)
    }
  end

  defp effect_document(input, allocation, allocation_reference, milestone) do
    state = input.state

    %{
      "effect_schema_version" => @effect_schema,
      "source_ledger_schema_version" => @ledger_schema,
      "idempotency_key" => allocation["idempotency_key"],
      "claim_session_id" => allocation["claim_session_id"],
      "issue_id" => issue_value(input.issue, "id"),
      "identifier" => issue_value(input.issue, "identifier"),
      "issue" => stringify(input.issue),
      "dispatch_sequence" => allocation["dispatch_sequence"],
      "retry_attempt" => allocation["retry_attempt"],
      "dispatch_allocation" => allocation_reference,
      "attempt_phase" => state["attempt_phase"],
      "disposition" => state["disposition"],
      "milestone_sequence" => state["milestone_sequence"],
      "last_milestone" => state["last_milestone"],
      "prepared_at_utc" => input.prepared_at_utc,
      "worker" => state["worker"],
      "workspace" => state["workspace"],
      "producer_claim" => state["producer_claim"],
      "admission" => state["admission"],
      "thread" => state["thread"],
      "turns" => state["turns"],
      "completed_at_utc" => state["completed_at_utc"],
      "completion_outcome" => state["completion_outcome"],
      "terminal_tracker" => state["terminal_tracker"],
      "hold" => state["hold"],
      "milestones" => input.prior_milestones ++ [milestone]
    }
  end

  defp plan_document(input, attrs) do
    %{
      "schema_version" => @plan_schema,
      "claim_session_id" => input.dispatch_allocation.document["claim_session_id"],
      "idempotency_key" => input.dispatch_allocation.document["idempotency_key"],
      "issue" => attrs.issue,
      "dispatch" => attrs.dispatch,
      "milestone_sequence" => attrs.sequence,
      "install_intent_core" => attrs.intent,
      "target_effect_sha256" => attrs.effect_sha,
      "ledger_before_cas" => attrs.before_cas,
      "ledger_after" => attrs.after_pair,
      "installation_mode" => "DURABLE_SEQUENTIAL_PAIR",
      "installation_order" => ["PREVIOUS", "CURRENT"],
      "destination_commit_contract" => [
        "exclusive_same_directory_temp",
        "write_exact_target_bytes",
        "flush_file",
        "no_reparse_replace",
        "flush_parent_directory",
        "handle_reopen_identity_and_bytes"
      ],
      "split_recovery" => "BLOCK_WITH_IMMUTABLE_JOURNAL_NO_RESTART_INSTALL",
      "lock" => attrs.lock,
      "prepared_at_utc" => now(),
      "decision" => "READY_TO_INSTALL"
    }
  end

  defp result_document(input, attrs) do
    %{
      "schema_version" => @result_schema,
      "claim_session_id" => input.dispatch_allocation.document["claim_session_id"],
      "idempotency_key" => input.dispatch_allocation.document["idempotency_key"],
      "issue" => attrs.issue,
      "dispatch" => attrs.dispatch,
      "milestone_sequence" => attrs.sequence,
      "install_intent_core" => attrs.intent,
      "install_plan" => attrs.plan,
      "target_effect_sha256" => attrs.effect_sha,
      "broker_result" => attrs.broker,
      "destination_results" => attrs.outcomes,
      "ledger_after" => attrs.after_pair,
      "installed_at_utc" => List.last(attrs.outcomes)["completed_at_utc"],
      "decision" => "PASS"
    }
  end

  defp install_pair(workspace_root, authority, deadline, lock, before, target, broker) do
    parameters = %{
      "lock" => absolute_reference(lock, workspace_root),
      "target_ledger_path" => absolute_path(target, workspace_root),
      "maximum_bytes" => 20_000,
      "expected_previous" => broker_expected(before.identities["previous"], workspace_root),
      "expected_current" => broker_expected(before.identities["current"], workspace_root),
      "previous_path" => Broker.reference_wire_path(workspace_root, ".symphony-state/execution.previous.json"),
      "current_path" => Broker.reference_wire_path(workspace_root, ".symphony-state/execution.json")
    }

    broker.invoke_receipt(
      "InstallDualLedgerAndReadback",
      parameters,
      workspace_root,
      authority,
      deadline
    )
  end

  defp installed_after(%{"result" => %{"destination_results" => [previous, current]}}, generation, sha, length) do
    with {:ok, previous_fingerprint} <- installed_fingerprint(previous, generation, sha, length),
         {:ok, current_fingerprint} <- installed_fingerprint(current, generation, sha, length),
         false <- previous_fingerprint["file_id"] == current_fingerprint["file_id"] do
      outcomes = [Map.drop(previous, ["reference"]), Map.drop(current, ["reference"])]
      {:ok, %{"current" => current_fingerprint, "previous" => previous_fingerprint}, outcomes}
    else
      _ -> {:error, :installed_ledger_pair_result_invalid}
    end
  end

  defp installed_after(_receipt, _generation, _sha, _length),
    do: {:error, :installed_ledger_pair_result_invalid}

  defp installed_fingerprint(%{"reference" => identity, "role" => role}, generation, sha, length) do
    path = if role == "CURRENT", do: ".symphony-state/execution.json", else: ".symphony-state/execution.previous.json"

    with true <- role in ["CURRENT", "PREVIOUS"],
         true <- identity["sha256"] == sha and identity["length"] == length,
         "regular" <- identity["file_type"],
         1 <- identity["link_count"] do
      {:ok, fingerprint(role, path, identity, %{"generation_id" => generation})}
    else
      _ -> {:error, :installed_ledger_fingerprint_invalid}
    end
  end

  defp target_ledger(ledger, effect, generation_id) do
    effects = ledger["effects"] || []
    key = effect["idempotency_key"]

    existing = Enum.find(effects, &(&1["idempotency_key"] == key))

    if is_nil(existing) or existing["milestone_sequence"] < effect["milestone_sequence"] do
      target_effects =
        effects
        |> Enum.reject(&(&1["idempotency_key"] == key))
        |> Kernel.++([effect])
        |> Enum.sort_by(& &1["idempotency_key"])

      {:ok,
       %{
         "schema_version" => @ledger_schema,
         "generation_id" => generation_id,
         "generated_at" => now(),
         "blocked" => ledger["blocked"] || [],
         "retrying" => ledger["retrying"] || [],
         "effects" => target_effects
       }}
    else
      {:error, :duplicate_or_nonmonotonic_transition}
    end
  end

  defp empty_ledger, do: %{"schema_version" => @ledger_schema, "blocked" => [], "retrying" => [], "effects" => []}

  defp ledger_root(%{
         "schema_version" => @ledger_schema,
         "generation_id" => generation,
         "generated_at" => generated_at,
         "blocked" => blocked,
         "retrying" => retrying,
         "effects" => effects
       })
       when is_binary(generation) and is_binary(generated_at) and is_list(blocked) and
              is_list(retrying) and is_list(effects),
       do: :ok

  defp ledger_root(_ledger), do: {:error, :ledger_before_schema_invalid}

  defp expected_after(generation_id, sha, length) do
    %{
      "current" => %{
        "role" => "CURRENT",
        "path" => ".symphony-state/execution.json",
        "generation_id" => generation_id,
        "sha256" => sha,
        "length" => length
      },
      "previous" => %{
        "role" => "PREVIOUS",
        "path" => ".symphony-state/execution.previous.json",
        "generation_id" => generation_id,
        "sha256" => sha,
        "length" => length
      }
    }
  end

  defp fingerprint(role, path, identity, ledger) do
    %{
      "role" => role,
      "path" => path,
      "physical_path" => identity["physical_path"],
      "volume_id" => identity["volume_id"],
      "file_id" => identity["file_id"],
      "file_type" => identity["file_type"],
      "link_count" => identity["link_count"],
      "generation_id" => ledger["generation_id"],
      "sha256" => identity["sha256"],
      "length" => identity["length"]
    }
  end

  defp equal_distinct_identities(current, previous) do
    if current["sha256"] == previous["sha256"] and current["length"] == previous["length"] and
         current["link_count"] == 1 and previous["link_count"] == 1 and
         current["file_type"] == "regular" and previous["file_type"] == "regular" and
         {current["volume_id"], current["file_id"]} != {previous["volume_id"], previous["file_id"]},
       do: :ok,
       else: {:error, :ledger_before_pair_identity_invalid}
  end

  defp validate_input(input) do
    allocation = input.dispatch_allocation
    state = input.state

    with true <- is_map(allocation) and is_map(allocation.document) and is_map(allocation.reference),
         :ok <- validate_issue(issue_projection(input.issue)),
         true <- is_binary(input.process_epoch_id) and input.process_epoch_id != "",
         true <- is_integer(input.owner_os_pid) and input.owner_os_pid > 0,
         true <- is_map(input.runtime_binding),
         true <- is_map(state),
         sequence when is_integer(sequence) and sequence > 0 <- state["milestone_sequence"],
         milestone when milestone in @milestones <- state["last_milestone"],
         true <- length(input.prior_milestones) + 1 == sequence,
         true <- is_map(input.evidence),
         :ok <- producer_datetime(input.prepared_at_utc),
         :ok <- producer_datetime(input.deadline_at_utc) do
      :ok
    else
      _ -> {:error, :producer_transition_input_invalid}
    end
  end

  defp validate_issue(%{"id" => id, "identifier" => identifier})
       when is_binary(id) and id != "" and is_binary(identifier) and identifier != "",
       do: :ok

  defp validate_issue(_issue), do: {:error, :producer_issue_identity_invalid}

  defp exact_projection(document, %{contract: %{document: contract}}, projection) do
    expected = get_in(contract, ["ordered_fields", projection])

    if is_list(expected) and Enum.sort(Map.keys(document)) == Enum.sort(expected),
      do: :ok,
      else: {:error, {:producer_projection_mismatch, projection}}
  end

  defp exact_projection(_document, _authority, projection),
    do: {:error, {:producer_projection_mismatch, projection}}

  defp exact_atom_keys(map, expected) do
    if Enum.sort(Map.keys(map)) == Enum.sort(expected),
      do: :ok,
      else: {:error, :producer_transition_input_property_set_mismatch}
  end

  defp issue_projection(issue),
    do: %{"id" => issue_value(issue, "id"), "identifier" => issue_value(issue, "identifier")}

  defp issue_value(issue, key), do: Map.get(issue, key) || Map.get(issue, String.to_atom(key))

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp previous_reference(nil), do: null_reference()
  defp previous_reference(reference) when is_map(reference), do: reference

  defp null_reference do
    %{
      "path" => nil,
      "physical_path" => nil,
      "volume_id" => nil,
      "file_id" => nil,
      "file_type" => nil,
      "link_count" => nil,
      "sha256" => nil,
      "length" => nil
    }
  end

  defp turn_number(evidence), do: Map.get(evidence, "turn_number") || Map.get(evidence, :turn_number)

  defp broker_expected(nil, _workspace_root), do: nil

  defp broker_expected(identity, workspace_root) do
    identity
    |> Map.take(~w(path physical_path volume_id file_id file_type link_count sha256 length))
    |> Map.update!("path", &Broker.reference_wire_path(workspace_root, &1))
  end

  defp absolute_reference(reference, workspace_root) do
    reference
    |> Map.put("path", absolute_path(reference, workspace_root))
  end

  defp absolute_path(reference, workspace_root) do
    Broker.reference_wire_path(workspace_root, reference["path"])
  end

  defp producer_datetime(value) when is_binary(value) do
    if Format.producer_datetime?(value),
      do: :ok,
      else: {:error, :producer_datetime_not_canonical}
  end

  defp producer_datetime(_value), do: {:error, :producer_datetime_invalid}

  defp now, do: DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.%3fZ")
  defp random_hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
