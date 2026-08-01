defmodule SymphonyElixir.ProducerV6.ExecutionBinding do
  @moduledoc """
  Publishes the immutable producer-v6 execution binding only after the worker
  task has terminated and the completed dual-ledger generation has been
  reopened, physically identified, and independently archived.
  """

  alias SymphonyElixir.{ProducerV6.Broker, Rfc8785Jcs}

  @schema "manafuel.symphony_producer_execution_binding.v1"
  @reference_keys ~w(path physical_path volume_id file_id file_type link_count sha256 length)

  @spec publish(map(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def publish(context, effect, task_down_observed_at_utc) do
    publish_with_broker(context, effect, task_down_observed_at_utc, Broker)
  end

  @doc false
  @spec publish_with_broker(map(), map(), String.t(), module()) ::
          {:ok, map()} | {:error, term()}
  def publish_with_broker(
        %{kind: :producer_v6} = context,
        %{document: document},
        task_down_observed_at_utc,
        broker
      )
      when is_map(document) and is_binary(task_down_observed_at_utc) and is_atom(broker) do
    workspace_root = workspace_root(context)

    with :ok <- completed_effect(document),
         true <- is_binary(workspace_root),
         {:ok, _task_down} <- parse_time(task_down_observed_at_utc),
         {:ok, deadline_at_utc} <- authority_deadline(document, workspace_root, context, broker),
         {:ok, contract_manifest} <- contract_manifest(context, workspace_root, broker),
         {:ok, ledgers} <-
           completed_ledger_pair(
             document,
             workspace_root,
             context,
             deadline_at_utc,
             broker
           ),
         {:ok, chain} <- transition_chain(document, workspace_root, context, broker),
         {:ok, claim} <-
           read_reference(
             document["producer_claim"],
             workspace_root,
             context,
             broker,
             "claim_receipt"
           ),
         {:ok, final_transition} <- last_document(chain.transitions),
         {:ok, turn_terminal} <- terminal_turn(document),
         {:ok, turn_terminal_at_utc} <- turn_terminal_milestone_time(document),
         runtime_binding_sha256 when is_binary(runtime_binding_sha256) <-
           get_in(final_transition, ["runtime_binding", "runtime_binding_sha256"]),
         ceo_prioritization_receipt when is_map(ceo_prioritization_receipt) <-
           claim["ceo_prioritization_receipt"],
         completion_seal when is_map(completion_seal) <- turn_terminal["completion_seal"],
         server_event when is_map(server_event) <- turn_terminal["server_turn_terminal_event"],
         {:ok, effect_sha256} <- canonical_sha256(document),
         :ok <- chronology(document["completed_at_utc"], task_down_observed_at_utc),
         binding = %{
           "schema_version" => @schema,
           "contract_manifest" => contract_manifest,
           "runtime_binding_sha256" => runtime_binding_sha256,
           "current_ledger" => ledgers.current,
           "previous_ledger" => ledgers.previous,
           "effect_identity" => effect_identity(document, effect_sha256),
           "dispatch_allocation" => document["dispatch_allocation"],
           "ceo_prioritization_receipt" => ceo_prioritization_receipt,
           "producer_claim" => document["producer_claim"],
           "admission_result" => document["admission"],
           "transition_receipts" => chain.transition_receipts,
           "ledger_install_plans" => chain.ledger_install_plans,
           "ledger_install_results" => chain.ledger_install_results,
           "transition_chain_head" => List.last(chain.transition_receipts),
           "transition_receipt_count" => length(chain.transition_receipts),
           "ledger_install_plan_count" => length(chain.ledger_install_plans),
           "ledger_install_result_count" => length(chain.ledger_install_results),
           "final_milestone_sequence" => document["milestone_sequence"],
           "terminal_turn_number" => turn_terminal["turn_number"],
           "server_turn_terminal_event" => server_event,
           "server_turn_terminal_at_utc" => turn_terminal["terminal_at_utc"],
           "turn_terminal_at_utc" => turn_terminal_at_utc,
           "completion_seal" => completion_seal,
           "recovery_journal" => nil,
           "recovered_from_completion_seal" => false,
           "completion_outcome" => "issue_terminal",
           "terminal_tracker" => document["terminal_tracker"],
           "completed_at_utc" => document["completed_at_utc"],
           "task_down_observed_at_utc" => task_down_observed_at_utc,
           "decision" => "PASS"
         },
         :ok <- exact_projection(context, "execution_binding", binding),
         :ok <- exact_projection(context, "execution_effect_identity", binding["effect_identity"]),
         {:ok, reference} <-
           broker.publish_cas(
             binding,
             "execution_binding",
             workspace_root,
             context,
             deadline_at_utc
           ) do
      {:ok, %{document: binding, reference: reference}}
    else
      false -> {:error, :producer_execution_binding_invalid}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_execution_binding_invalid}
    end
  end

  def publish_with_broker(_context, _effect, _task_down_observed_at_utc, _broker),
    do: {:error, :invalid_producer_execution_binding_input}

  @doc false
  @spec build_for_test(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_for_test(context, fields) when is_map(context) and is_map(fields) do
    binding = Map.put(fields, "schema_version", @schema)

    with :ok <- exact_projection(context, "execution_binding", binding),
         :ok <- exact_projection(context, "execution_effect_identity", binding["effect_identity"]) do
      {:ok, binding}
    end
  end

  defp completed_effect(document) do
    requirements = [
      document["effect_schema_version"] == "symphony.execution_effect.v6",
      document["source_ledger_schema_version"] == "symphony.execution_ledger.v6",
      document["attempt_phase"] == "completed",
      document["disposition"] == "completed",
      document["last_milestone"] == "completed",
      document["completion_outcome"] == "issue_terminal",
      is_map(document["terminal_tracker"]),
      is_list(document["milestones"]),
      length(document["milestones"]) == document["milestone_sequence"]
    ]

    if Enum.all?(requirements),
      do: :ok,
      else: {:error, :producer_execution_effect_not_completed}
  end

  defp contract_manifest(
         %{contract: %{path: path, sha256: expected_sha256}} = context,
         workspace_root,
         broker
       ) do
    with {:ok, identity} <- broker.inspect(path, workspace_root, context),
         true <- identity["sha256"] == expected_sha256,
         {:ok, reference} <- immutable_reference(identity, workspace_root) do
      {:ok, reference}
    else
      false -> {:error, :producer_contract_manifest_digest_drift}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_contract_manifest_invalid}
    end
  end

  defp contract_manifest(_context, _workspace_root, _broker),
    do: {:error, :producer_contract_manifest_invalid}

  defp completed_ledger_pair(document, workspace_root, context, deadline, broker) do
    current_path = Path.join(workspace_root, ".symphony-state\\execution.json")
    previous_path = Path.join(workspace_root, ".symphony-state\\execution.previous.json")

    with {:ok, current_identity} <- broker.inspect(current_path, workspace_root, context),
         {:ok, previous_identity} <- broker.inspect(previous_path, workspace_root, context),
         :ok <- distinct_regular_pair(current_identity, previous_identity),
         {:ok, current_bytes} <- File.read(current_path),
         {:ok, previous_bytes} <- File.read(previous_path),
         true <- current_bytes == previous_bytes,
         true <- sha256(current_bytes) == current_identity["sha256"],
         true <- sha256(previous_bytes) == previous_identity["sha256"],
         {:ok, ledger} <- Rfc8785Jcs.validate_canonical(current_bytes),
         :ok <- completed_ledger(ledger, document),
         {:ok, archive} <-
           broker.publish_bytes(
             current_bytes,
             "ledger_snapshot",
             workspace_root,
             context,
             deadline
           ),
         {:ok, current} <-
           ledger_generation(
             "CURRENT",
             ".symphony-state/execution.json",
             current_identity,
             archive,
             ledger["generation_id"],
             context
           ),
         {:ok, previous} <-
           ledger_generation(
             "PREVIOUS",
             ".symphony-state/execution.previous.json",
             previous_identity,
             archive,
             ledger["generation_id"],
             context
           ) do
      {:ok, %{current: current, previous: previous}}
    else
      false -> {:error, :producer_completed_ledger_pair_drift}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_completed_ledger_pair_invalid}
    end
  end

  defp distinct_regular_pair(current, previous) do
    if Enum.all?([current, previous], fn identity ->
         identity["file_type"] == "regular" and identity["link_count"] == 1
       end) and current["sha256"] == previous["sha256"] and
         current["length"] == previous["length"] and
         {current["volume_id"], current["file_id"]} !=
           {previous["volume_id"], previous["file_id"]} do
      :ok
    else
      {:error, :producer_completed_ledger_identity_invalid}
    end
  end

  defp completed_ledger(ledger, document) do
    matches =
      case ledger do
        %{
          "schema_version" => "symphony.execution_ledger.v6",
          "generation_id" => generation,
          "blocked" => [],
          "retrying" => [],
          "effects" => effects
        }
        when is_binary(generation) and byte_size(generation) == 32 and is_list(effects) ->
          Enum.filter(effects, &(&1["idempotency_key"] == document["idempotency_key"]))

        _ ->
          []
      end

    if matches == [document],
      do: :ok,
      else: {:error, :producer_completed_effect_missing_from_ledger_pair}
  end

  defp ledger_generation(role, source_path, source, archive, generation_id, context) do
    document = %{
      "role" => role,
      "source_path" => source_path,
      "source_physical_path" => source["physical_path"],
      "source_volume_id" => source["volume_id"],
      "source_file_id" => source["file_id"],
      "source_file_type" => source["file_type"],
      "source_link_count" => source["link_count"],
      "archive_path" => archive["path"],
      "archive_physical_path" => archive["physical_path"],
      "archive_volume_id" => archive["volume_id"],
      "archive_file_id" => archive["file_id"],
      "archive_file_type" => archive["file_type"],
      "archive_link_count" => archive["link_count"],
      "archive_sha256" => archive["sha256"],
      "archive_length" => archive["length"],
      "generation_id" => generation_id
    }

    case exact_projection(context, "execution_ledger_generation", document) do
      :ok -> {:ok, document}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transition_chain(document, workspace_root, context, broker) do
    milestones = document["milestones"]
    count = length(milestones)
    min_count = get_in(context, [:contract, :document, "bounds", "min_completed_receipts"])
    max_count = get_in(context, [:contract, :document, "bounds", "max_completed_receipts"])

    with true <- is_integer(min_count) and is_integer(max_count) and count in min_count..max_count,
         {:ok, plans} <-
           cas_documents("ledger_install_plan", "ledger_install_plan", workspace_root, context, broker),
         {:ok, results} <-
           cas_documents(
             "ledger_install_result",
             "ledger_install_result",
             workspace_root,
             context,
             broker
           ),
         {:ok, chain} <-
           collect_chain(milestones, plans, results, document, workspace_root, context, broker) do
      {:ok, chain}
    else
      false -> {:error, :producer_transition_chain_count_invalid}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_transition_chain_invalid}
    end
  end

  defp collect_chain(milestones, plans, results, effect, workspace_root, context, broker) do
    milestones
    |> Enum.with_index(1)
    |> Enum.reduce_while(
      {:ok,
       %{
         transitions: [],
         transition_receipts: [],
         ledger_install_plans: [],
         ledger_install_results: []
       }},
      fn {milestone, sequence}, {:ok, acc} ->
        transition_reference = transition_reference(milestone)
        intent_reference = milestone["install_intent_core"]

        with true <- milestone["sequence"] == sequence,
             true <- is_map(transition_reference) and is_map(intent_reference),
             {:ok, transition} <-
               read_reference(
                 transition_reference,
                 workspace_root,
                 context,
                 broker,
                 "transition_receipt"
               ),
             {:ok, intent} <-
               read_reference(
                 intent_reference,
                 workspace_root,
                 context,
                 broker,
                 "ledger_install_intent_core"
               ),
             true <- exact_reference?(intent["transition_receipt"], transition_reference),
             true <- chain_identity?(transition, effect, milestone, sequence),
             {:ok, plan} <- unique_plan(plans, effect, intent_reference, sequence),
             {:ok, result} <-
               unique_result(results, effect, intent_reference, plan.reference, sequence) do
          next = %{
            transitions: acc.transitions ++ [transition],
            transition_receipts: acc.transition_receipts ++ [transition_reference],
            ledger_install_plans: acc.ledger_install_plans ++ [plan.reference],
            ledger_install_results: acc.ledger_install_results ++ [result.reference]
          }

          {:cont, {:ok, next}}
        else
          false -> {:halt, {:error, {:producer_transition_chain_drift, sequence}}}
          {:error, reason} -> {:halt, {:error, reason}}
          _ -> {:halt, {:error, {:producer_transition_chain_invalid, sequence}}}
        end
      end
    )
  end

  defp chain_identity?(transition, effect, milestone, sequence) do
    transition["claim_session_id"] == effect["claim_session_id"] and
      transition["idempotency_key"] == effect["idempotency_key"] and
      get_in(transition, ["issue", "id"]) == effect["issue_id"] and
      get_in(transition, ["issue", "identifier"]) == effect["identifier"] and
      get_in(transition, ["milestone", "sequence"]) == sequence and
      get_in(transition, ["milestone", "name"]) == milestone["name"] and
      get_in(transition, ["milestone", "evidence_sha256"]) == milestone["evidence_sha256"]
  end

  defp unique_plan(plans, effect, intent, sequence) do
    plans
    |> Enum.filter(fn row ->
      row.document["claim_session_id"] == effect["claim_session_id"] and
        row.document["idempotency_key"] == effect["idempotency_key"] and
        row.document["milestone_sequence"] == sequence and
        row.document["decision"] == "READY_TO_INSTALL" and
        exact_reference?(row.document["install_intent_core"], intent)
    end)
    |> exactly_one(:producer_ledger_install_plan_cardinality)
  end

  defp unique_result(results, effect, intent, plan, sequence) do
    results
    |> Enum.filter(fn row ->
      row.document["claim_session_id"] == effect["claim_session_id"] and
        row.document["idempotency_key"] == effect["idempotency_key"] and
        row.document["milestone_sequence"] == sequence and row.document["decision"] == "PASS" and
        exact_reference?(row.document["install_intent_core"], intent) and
        exact_reference?(row.document["install_plan"], plan)
    end)
    |> exactly_one(:producer_ledger_install_result_cardinality)
  end

  defp exactly_one([row], _reason), do: {:ok, row}
  defp exactly_one(_rows, reason), do: {:error, reason}

  defp cas_documents(root_name, projection, workspace_root, context, broker) do
    relative = get_in(context, [:contract, :document, "path_roots", root_name])
    maximum_bytes = get_in(context, [:contract, :document, "cas_limits", root_name])
    max_effects = get_in(context, [:contract, :document, "bounds", "max_effects"])
    max_receipts = get_in(context, [:contract, :document, "bounds", "max_completed_receipts"])

    with true <- is_binary(relative) and String.starts_with?(relative, ".symphony-state/"),
         true <- is_integer(maximum_bytes) and maximum_bytes > 0,
         true <- is_integer(max_effects) and is_integer(max_receipts),
         root = filesystem_path(workspace_root, relative),
         paths = Path.wildcard(Path.join(root, "**/*.json"), match_dot: true) |> Enum.sort(),
         true <- length(paths) <= max_effects * max_receipts do
      Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, rows} ->
        append_cas_document(
          path,
          rows,
          root_name,
          projection,
          maximum_bytes,
          workspace_root,
          context,
          broker
        )
      end)
    else
      false -> {:error, {:producer_cas_enumeration_contract_invalid, root_name}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:producer_cas_enumeration_invalid, root_name}}
    end
  end

  defp append_cas_document(
         path,
         rows,
         root_name,
         projection,
         maximum_bytes,
         workspace_root,
         context,
         broker
       ) do
    with true <- File.regular?(path),
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= maximum_bytes,
         digest = sha256(bytes),
         true <- Path.basename(path, ".json") == digest,
         {:ok, document} <- Rfc8785Jcs.validate_canonical(bytes),
         :ok <- exact_projection(context, projection, document),
         {:ok, identity} <- broker.inspect(path, workspace_root, context),
         {:ok, reference} <- immutable_reference(identity, workspace_root),
         true <- reference["sha256"] == digest and reference["length"] == byte_size(bytes) do
      {:cont, {:ok, rows ++ [%{document: document, reference: reference}]}}
    else
      false -> {:halt, {:error, {:producer_cas_enumeration_drift, root_name}}}
      {:error, reason} -> {:halt, {:error, reason}}
      _ -> {:halt, {:error, {:producer_cas_enumeration_invalid, root_name}}}
    end
  end

  defp authority_deadline(document, workspace_root, context, broker) do
    with milestone when is_map(milestone) <- List.last(document["milestones"]),
         intent_reference when is_map(intent_reference) <- milestone["install_intent_core"],
         {:ok, intent} <-
           read_reference(
             intent_reference,
             workspace_root,
             context,
             broker,
             "ledger_install_intent_core"
           ),
         lock_reference when is_map(lock_reference) <- intent["lock"],
         {:ok, lock} <-
           read_reference(
             lock_reference,
             workspace_root,
             context,
             broker,
             "ledger_write_lock"
           ),
         deadline when is_binary(deadline) <- lock["authority_deadline_at_utc"],
         {:ok, deadline_at} <- parse_time(deadline),
         true <- DateTime.compare(DateTime.utc_now(), deadline_at) == :lt do
      {:ok, deadline}
    else
      false -> {:error, :producer_execution_binding_deadline_expired}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_execution_binding_deadline_invalid}
    end
  end

  defp read_reference(reference, workspace_root, context, broker, projection)
       when is_map(reference) do
    path = filesystem_path(workspace_root, reference["path"])

    with true <- exact_reference_shape?(reference),
         {:ok, identity} <- broker.inspect(path, workspace_root, context),
         true <- identity_matches_reference?(identity, reference, path),
         {:ok, bytes} <- File.read(path),
         true <- sha256(bytes) == reference["sha256"] and byte_size(bytes) == reference["length"],
         {:ok, document} <- Rfc8785Jcs.validate_canonical(bytes),
         :ok <- exact_projection(context, projection, document) do
      {:ok, document}
    else
      false -> {:error, {:producer_reference_drift, projection}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:producer_reference_invalid, projection}}
    end
  end

  defp read_reference(_reference, _workspace_root, _context, _broker, projection),
    do: {:error, {:producer_reference_invalid, projection}}

  defp terminal_turn(%{"turns" => turns}) when is_list(turns) and turns != [] do
    turn = List.last(turns)

    if is_map(turn) and is_integer(turn["turn_number"]) and turn["terminal_status"] == "completed" and
         is_binary(turn["terminal_at_utc"]),
       do: {:ok, turn},
       else: {:error, :producer_terminal_turn_invalid}
  end

  defp terminal_turn(_document), do: {:error, :producer_terminal_turn_invalid}

  defp turn_terminal_milestone_time(%{"milestones" => milestones}) when is_list(milestones) do
    case Enum.reverse(milestones) do
      [%{"name" => "completed"}, %{"name" => "turn_terminal", "at_utc" => at_utc} | _]
      when is_binary(at_utc) ->
        {:ok, at_utc}

      _ ->
        {:error, :producer_turn_terminal_milestone_missing}
    end
  end

  defp turn_terminal_milestone_time(_document),
    do: {:error, :producer_turn_terminal_milestone_missing}

  defp last_document([]), do: {:error, :producer_transition_chain_empty}
  defp last_document(documents), do: {:ok, List.last(documents)}

  defp effect_identity(document, digest) do
    %{
      "effect_schema_version" => document["effect_schema_version"],
      "idempotency_key" => document["idempotency_key"],
      "claim_session_id" => document["claim_session_id"],
      "issue_id" => document["issue_id"],
      "identifier" => document["identifier"],
      "dispatch_sequence" => document["dispatch_sequence"],
      "retry_attempt" => document["retry_attempt"],
      "dispatch_allocation_sha256" => get_in(document, ["dispatch_allocation", "sha256"]),
      "attempt_phase" => document["attempt_phase"],
      "disposition" => document["disposition"],
      "completion_outcome" => document["completion_outcome"],
      "effect_sha256" => digest
    }
  end

  defp transition_reference(milestone) do
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

  defp immutable_reference(identity, workspace_root) when is_map(identity) do
    absolute_path = identity["path"]

    with true <- is_binary(absolute_path),
         relative =
           absolute_path
           |> Path.relative_to(Path.expand(workspace_root))
           |> String.replace("\\", "/"),
         true <- relative != absolute_path and not String.starts_with?(relative, "../"),
         reference = %{
           "path" => relative,
           "physical_path" => identity["physical_path"],
           "volume_id" => identity["volume_id"],
           "file_id" => identity["file_id"],
           "file_type" => identity["file_type"],
           "link_count" => identity["link_count"],
           "sha256" => identity["sha256"],
           "length" => identity["length"]
         },
         true <- exact_reference_shape?(reference) do
      {:ok, reference}
    else
      false -> {:error, :producer_immutable_reference_invalid}
      _ -> {:error, :producer_immutable_reference_invalid}
    end
  end

  defp exact_reference_shape?(reference) when is_map(reference) do
    Enum.sort(Map.keys(reference)) == Enum.sort(@reference_keys) and
      Enum.all?(~w(path physical_path volume_id file_id file_type sha256), fn key ->
        is_binary(reference[key]) and reference[key] != ""
      end) and reference["file_type"] == "regular" and reference["link_count"] == 1 and
      is_integer(reference["length"]) and reference["length"] > 0
  end

  defp exact_reference_shape?(_reference), do: false

  defp identity_matches_reference?(identity, reference, expected_path) when is_map(identity) do
    Path.expand(identity["path"]) == Path.expand(expected_path) and
      Enum.all?(~w(physical_path volume_id file_id file_type link_count sha256 length), fn key ->
        identity[key] == reference[key]
      end)
  end

  defp identity_matches_reference?(_identity, _reference, _expected_path), do: false

  defp exact_reference?(left, right) when is_map(left) and is_map(right) do
    Enum.all?(@reference_keys, &(left[&1] == right[&1]))
  end

  defp exact_reference?(_left, _right), do: false

  defp chronology(completed_at_utc, task_down_observed_at_utc) do
    with {:ok, completed} <- parse_time(completed_at_utc),
         {:ok, task_down} <- parse_time(task_down_observed_at_utc),
         true <- DateTime.compare(completed, task_down) in [:lt, :eq] do
      :ok
    else
      false -> {:error, :producer_task_down_chronology_invalid}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_task_down_chronology_invalid}
    end
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> {:error, :producer_datetime_invalid}
    end
  end

  defp parse_time(_value), do: {:error, :producer_datetime_invalid}

  defp canonical_sha256(document) do
    case Rfc8785Jcs.encode(document) do
      {:ok, bytes} -> {:ok, sha256(bytes)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exact_projection(%{contract: %{document: contract}}, name, document)
       when is_map(document) do
    expected = get_in(contract, ["ordered_fields", name])

    if is_list(expected) and Enum.sort(Map.keys(document)) == Enum.sort(expected),
      do: :ok,
      else: {:error, {:producer_execution_binding_projection_mismatch, name}}
  end

  defp exact_projection(_context, name, _document),
    do: {:error, {:producer_execution_binding_projection_mismatch, name}}

  defp workspace_root(%{contract: %{document: contract}}),
    do: get_in(contract, ["constants", "workspace_root_windows"])

  defp filesystem_path(root, relative),
    do: Path.join(String.replace(root, "\\", "/"), String.replace(relative, "\\", "/"))

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
