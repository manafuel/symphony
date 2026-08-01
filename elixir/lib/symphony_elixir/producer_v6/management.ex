defmodule SymphonyElixir.ProducerV6.Management do
  @moduledoc """
  Reconciles completed producer-v6 executions from the recurring Symphony
  management cycle and publishes a causally later immutable state projection.
  """

  alias SymphonyElixir.{ProducerV6.Broker, Rfc8785Jcs}

  @receipt_schema "manafuel.symphony_natural_management_receipt.v1"
  @projection_schema "manafuel.symphony_management_state_projection.v1"
  @state_schema "manafuel.symphony_management_observation_state.v1"
  @reference_keys ~w(path physical_path volume_id file_id file_type link_count sha256 length)

  @spec observe(map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def observe(context), do: observe_with_broker(context, Broker)

  @doc false
  @spec observe_with_broker(map(), module()) :: {:ok, non_neg_integer()} | {:error, term()}
  def observe_with_broker(%{kind: :producer_v6} = context, broker) when is_atom(broker) do
    workspace_root = workspace_root(context)
    cycle_sequence = next_cycle_sequence()

    with true <- is_binary(workspace_root),
         {:ok, executions} <-
           cas_documents("execution_binding", "execution_binding", workspace_root, context, broker),
         {:ok, receipts} <-
           cas_documents(
             "natural_management_receipt",
             "natural_management_receipt",
             workspace_root,
             context,
             broker
           ),
         {:ok, projections} <-
           cas_documents(
             "management_state_projection",
             "management_state_projection",
             workspace_root,
             context,
             broker
           ) do
      Enum.reduce_while(executions, {:ok, 0}, fn execution, {:ok, published} ->
        reconcile_execution(
          execution,
          receipts,
          projections,
          cycle_sequence,
          workspace_root,
          context,
          broker,
          published
        )
      end)
    else
      false -> {:error, :producer_management_workspace_invalid}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_management_observation_invalid}
    end
  end

  def observe_with_broker(_context, _broker),
    do: {:error, :invalid_producer_management_context}

  defp reconcile_execution(
         execution,
         receipts,
         projections,
         cycle_sequence,
         workspace_root,
         context,
         broker,
         published
       ) do
    case reconcile(
           execution,
           receipts,
           projections,
           cycle_sequence,
           workspace_root,
           context,
           broker
         ) do
      {:ok, :already_observed} -> {:cont, {:ok, published}}
      {:ok, :not_later_yet} -> {:cont, {:ok, published}}
      {:ok, :published} -> {:cont, {:ok, published + 1}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp reconcile(
         execution,
         receipts,
         projections,
         cycle_sequence,
         workspace_root,
         context,
         broker
       ) do
    digest = execution.reference["sha256"]
    matching_receipts = Enum.filter(receipts, &(&1.document["execution_binding_sha256"] == digest))
    matching_projections = Enum.filter(projections, &(&1.document["execution_binding_sha256"] == digest))

    case {matching_receipts, matching_projections} do
      {[receipt], [projection]} ->
        if projection.document["natural_management_receipt_sha256"] ==
             receipt.reference["sha256"] and
             exact_reference?(
               projection.document["natural_management_receipt"],
               receipt.reference
             ) do
          {:ok, :already_observed}
        else
          {:error, :producer_management_existing_projection_drift}
        end

      {[], []} ->
        publish_management(
          execution,
          cycle_sequence,
          workspace_root,
          context,
          broker
        )

      _ ->
        {:error, :producer_management_receipt_projection_cardinality}
    end
  end

  defp publish_management(execution, cycle_sequence, workspace_root, context, broker) do
    binding = execution.document
    reference = execution.reference

    observed_at_utc = now()

    management_process_epoch_id =
      process_epoch_id(reference, cycle_sequence, observed_at_utc)

    with "PASS" <- binding["decision"],
         "issue_terminal" <- binding["completion_outcome"],
         tracker when is_map(tracker) <- binding["terminal_tracker"],
         task_down when is_binary(task_down) <- binding["task_down_observed_at_utc"],
         deadline when is_binary(deadline) <- tracker["deadline_at_utc"],
         {:ok, observed} <- parse_time(observed_at_utc),
         {:ok, task_down_at} <- parse_time(task_down),
         {:ok, deadline_at} <- parse_time(deadline),
         :lt <- DateTime.compare(task_down_at, observed),
         :lt <- DateTime.compare(observed, deadline_at),
         ceo_reference when is_map(ceo_reference) <- binding["ceo_prioritization_receipt"],
         {:ok, ceo} <-
           read_reference(
             ceo_reference,
             workspace_root,
             context,
             broker,
             "ceo_prioritization_receipt"
           ),
         ceo_process_epoch_id when is_binary(ceo_process_epoch_id) <- ceo["process_epoch_id"],
         {:ok, tracker_sha256} <- canonical_sha256(tracker),
         before = state_document(reference, "BEFORE_RECONCILIATION", observed_at_utc),
         after_state = state_document(reference, "AFTER_RECONCILIATION", observed_at_utc),
         {:ok, before_reference} <-
           broker.publish_cas(
             before,
             "milestone_evidence",
             workspace_root,
             context,
             deadline
           ),
         {:ok, after_reference} <-
           broker.publish_cas(
             after_state,
             "milestone_evidence",
             workspace_root,
             context,
             deadline
           ),
         true <- before_reference["sha256"] != after_reference["sha256"],
         receipt =
           receipt_document(binding, %{
             execution_reference: reference,
             ceo_reference: ceo_reference,
             tracker: tracker,
             tracker_sha256: tracker_sha256,
             before_reference: before_reference,
             after_reference: after_reference,
             cycle_sequence: cycle_sequence,
             management_process_epoch_id: management_process_epoch_id,
             observed_at_utc: observed_at_utc
           }),
         :ok <- exact_projection(context, "natural_management_receipt", receipt),
         {:ok, receipt_reference} <-
           broker.publish_cas(
             receipt,
             "natural_management_receipt",
             workspace_root,
             context,
             deadline
           ),
         projection =
           projection_document(binding, %{
             execution_reference: reference,
             ceo_reference: ceo_reference,
             ceo_process_epoch_id: ceo_process_epoch_id,
             tracker: tracker,
             tracker_sha256: tracker_sha256,
             receipt_reference: receipt_reference,
             management_process_epoch_id: management_process_epoch_id,
             observed_at_utc: observed_at_utc
           }),
         :ok <- exact_projection(context, "management_state_projection", projection),
         {:ok, _projection_reference} <-
           broker.publish_cas(
             projection,
             "management_state_projection",
             workspace_root,
             context,
             deadline
           ) do
      {:ok, :published}
    else
      :eq -> {:ok, :not_later_yet}
      :gt -> {:error, :producer_management_chronology_invalid}
      false -> {:error, :producer_management_state_did_not_advance}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_management_evidence_invalid}
    end
  end

  defp receipt_document(binding, attrs) do
    %{
      "schema_version" => @receipt_schema,
      "publisher_kind" => "SYMPHONY_RECURRING",
      "publisher_process_epoch_id" => attrs.management_process_epoch_id,
      "publisher_cycle_sequence" => attrs.cycle_sequence,
      "ceo_prioritization_receipt" => attrs.ceo_reference,
      "ceo_prioritization_receipt_sha256" => attrs.ceo_reference["sha256"],
      "execution_binding" => attrs.execution_reference,
      "execution_binding_sha256" => attrs.execution_reference["sha256"],
      "source_ledger_schema_version" => "symphony.execution_ledger.v6",
      "issue" => %{
        "id" => get_in(binding, ["effect_identity", "issue_id"]),
        "identifier" => get_in(binding, ["effect_identity", "identifier"])
      },
      "claim_session_id" => get_in(binding, ["effect_identity", "claim_session_id"]),
      "idempotency_key" => get_in(binding, ["effect_identity", "idempotency_key"]),
      "completion_outcome" => binding["completion_outcome"],
      "terminal_tracker" => attrs.tracker,
      "terminal_tracker_sha256" => attrs.tracker_sha256,
      "done_state_id" => get_in(attrs.tracker, ["state", "id"]),
      "done_state_type" => get_in(attrs.tracker, ["state", "type"]),
      "final_worker_marker" => get_in(attrs.tracker, ["final_worker_comment", "marker"]),
      "final_worker_comment_author_id" => get_in(attrs.tracker, ["final_worker_comment", "author_id"]),
      "done_history_id" => get_in(attrs.tracker, ["done_transition", "history_id"]),
      "done_history_actor_id" => get_in(attrs.tracker, ["done_transition", "actor_id"]),
      "completed_at_utc" => binding["completed_at_utc"],
      "task_down_observed_at_utc" => binding["task_down_observed_at_utc"],
      "management_state_before" => attrs.before_reference,
      "management_state_after" => attrs.after_reference,
      "management_action" => "ISSUE_TERMINAL_STATE_RECONCILED",
      "observed_at_utc" => attrs.observed_at_utc,
      "decision" => "PASS"
    }
  end

  defp projection_document(binding, attrs) do
    %{
      "schema_version" => @projection_schema,
      "issue" => %{
        "id" => get_in(binding, ["effect_identity", "issue_id"]),
        "identifier" => get_in(binding, ["effect_identity", "identifier"])
      },
      "claim_session_id" => get_in(binding, ["effect_identity", "claim_session_id"]),
      "idempotency_key" => get_in(binding, ["effect_identity", "idempotency_key"]),
      "execution_binding" => attrs.execution_reference,
      "execution_binding_sha256" => attrs.execution_reference["sha256"],
      "source_ledger_schema_version" => "symphony.execution_ledger.v6",
      "ceo_prioritization_receipt" => attrs.ceo_reference,
      "ceo_prioritization_receipt_sha256" => attrs.ceo_reference["sha256"],
      "ceo_originator_process_epoch_id" => attrs.ceo_process_epoch_id,
      "terminal_tracker" => attrs.tracker,
      "terminal_tracker_sha256" => attrs.tracker_sha256,
      "natural_management_receipt" => attrs.receipt_reference,
      "natural_management_receipt_sha256" => attrs.receipt_reference["sha256"],
      "management_process_epoch_id" => attrs.management_process_epoch_id,
      "task_down_observed_at_utc" => binding["task_down_observed_at_utc"],
      "management_observed_at_utc" => attrs.observed_at_utc,
      "causal_order" => "V6_ISSUE_TERMINAL_THEN_NATURAL_MANAGEMENT",
      "decision" => "PASS"
    }
  end

  defp state_document(execution_reference, phase, observed_at_utc) do
    %{
      "schema_version" => @state_schema,
      "execution_binding_sha256" => execution_reference["sha256"],
      "phase" => phase,
      "observed_at_utc" => observed_at_utc,
      "decision" => "PASS"
    }
  end

  defp cas_documents(root_name, projection, workspace_root, context, broker) do
    relative = get_in(context, [:contract, :document, "path_roots", root_name])
    maximum_bytes = get_in(context, [:contract, :document, "cas_limits", root_name])
    max_effects = get_in(context, [:contract, :document, "bounds", "max_effects"])

    with true <- is_binary(relative) and String.starts_with?(relative, ".symphony-state/"),
         true <- is_integer(maximum_bytes) and maximum_bytes > 0,
         true <- is_integer(max_effects) and max_effects > 0,
         root = filesystem_path(workspace_root, relative),
         paths = Path.wildcard(Path.join(root, "**/*.json"), match_dot: true) |> Enum.sort(),
         true <- length(paths) <= max_effects do
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
      false -> {:error, {:producer_management_cas_contract_invalid, root_name}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:producer_management_cas_invalid, root_name}}
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
      false -> {:halt, {:error, {:producer_management_cas_drift, root_name}}}
      {:error, reason} -> {:halt, {:error, reason}}
      _ -> {:halt, {:error, {:producer_management_cas_invalid, root_name}}}
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
      false -> {:error, {:producer_management_reference_drift, projection}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:producer_management_reference_invalid, projection}}
    end
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
      false -> {:error, :producer_management_immutable_reference_invalid}
      _ -> {:error, :producer_management_immutable_reference_invalid}
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

  defp exact_projection(%{contract: %{document: contract}}, name, document)
       when is_map(document) do
    expected = get_in(contract, ["ordered_fields", name])

    if is_list(expected) and Enum.sort(Map.keys(document)) == Enum.sort(expected),
      do: :ok,
      else: {:error, {:producer_management_projection_mismatch, name}}
  end

  defp exact_projection(_context, name, _document),
    do: {:error, {:producer_management_projection_mismatch, name}}

  defp canonical_sha256(document) do
    case Rfc8785Jcs.encode(document) do
      {:ok, bytes} -> {:ok, sha256(bytes)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> {:error, :producer_management_datetime_invalid}
    end
  end

  defp parse_time(_value), do: {:error, :producer_management_datetime_invalid}

  defp process_epoch_id(reference, cycle_sequence, observed_at_utc) do
    material =
      Enum.join(
        [reference["sha256"], Integer.to_string(cycle_sequence), observed_at_utc],
        ":"
      )

    "symmp-" <> String.slice(sha256(material), 0, 32)
  end

  defp next_cycle_sequence do
    key = {__MODULE__, :cycle_sequence}
    next = :persistent_term.get(key, 0) + 1
    :persistent_term.put(key, next)
    next
  end

  defp workspace_root(%{contract: %{document: contract}}),
    do: get_in(contract, ["constants", "workspace_root_windows"])

  defp filesystem_path(root, relative),
    do: Path.join(String.replace(root, "\\", "/"), String.replace(relative, "\\", "/"))

  defp now, do: DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.%3fZ")
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
