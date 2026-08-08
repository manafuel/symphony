defmodule SymphonyElixir.ProducerV6.Lifecycle do
  @moduledoc """
  Builds producer-v6 claim and admission artifacts from reopened live facts.

  The CEO receipt must be an exact, unique CAS match for the dispatched issue.
  Admission fields come only from the machine receipt emitted by the actual hook.
  """

  alias SymphonyElixir.ProducerV6.{Broker, RuntimeBinding.Live, TerminalTracker}
  alias SymphonyElixir.Rfc8785Jcs

  @hook_receipt_keys ~w(child_exit_code child_invoked child_stdout_sha256 completed_at_utc decision hook_exit_code schema_version)

  @doc false
  @spec validate_hook_receipt_for_test(binary()) :: :ok | {:error, term()}
  def validate_hook_receipt_for_test(bytes) when is_binary(bytes) do
    with {:ok, receipt} <- Rfc8785Jcs.validate_canonical(bytes) do
      validate_hook_receipt(receipt)
    end
  end

  @doc false
  @spec reference_for_test(map(), Path.t()) :: map()
  def reference_for_test(identity, workspace_root)
      when is_map(identity) and is_binary(workspace_root),
      do: reference(identity, workspace_root)

  @spec claim(map(), map(), Path.t()) :: {:ok, map()} | {:error, term()}
  def claim(context, effect, workspace_path)
      when is_map(context) and is_map(effect) and is_binary(workspace_path) do
    workspace_root = workspace_root(context)
    document = effect.document

    with true <- File.dir?(workspace_path),
         {:ok, deadline} <- authority_deadline(document, workspace_root),
         {:ok, runtime_binding} <- Live.full_binding(context, workspace_root, Broker),
         {:ok, admission_contract} <- Live.admission_contract(context),
         {:ok, ceo_reference} <- ceo_reference(context, document, workspace_root),
         {:ok, ledger_binding} <- ledger_binding(context, workspace_root),
         claim = %{
           "schema_version" => "manafuel.symphony_producer_claim_receipt.v1",
           "claim_session_id" => document["claim_session_id"],
           "idempotency_key" => document["idempotency_key"],
           "issue" => issue(document),
           "dispatch" => dispatch(document),
           "ceo_prioritization_receipt" => ceo_reference,
           "ledger_binding" => ledger_binding,
           "workspace" => %{
             "execution_target" => "local",
             "lexical_path" => Path.expand(workspace_path),
             "physical_path" => Path.expand(workspace_path),
             "created" => true
           },
           "runtime_binding" => runtime_binding,
           "admission_contract" => admission_contract,
           "claimed_at_utc" => now()
         },
         :ok <- exact_projection(context, "claim_receipt", claim),
         {:ok, reference} <-
           Broker.publish_cas(claim, "claim", workspace_root, context, deadline) do
      {:ok, reference}
    else
      false -> {:error, :producer_claim_workspace_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec admission(map(), map(), map(), binary()) :: {:ok, map()} | {:error, term()}
  def admission(context, effect, producer_claim, hook_receipt_bytes)
      when is_map(context) and is_map(effect) and is_map(producer_claim) and
             is_binary(hook_receipt_bytes) do
    workspace_root = workspace_root(context)
    document = effect.document

    with {:ok, hook_receipt} <- Rfc8785Jcs.validate_canonical(hook_receipt_bytes),
         :ok <- validate_hook_receipt(hook_receipt),
         {:ok, deadline} <- authority_deadline(document, workspace_root),
         {:ok, claim_document} <- read_reference(producer_claim, workspace_root),
         {:ok, evidence_reference} <-
           Broker.publish_cas(
             hook_receipt,
             "app_server_response",
             workspace_root,
             context,
             deadline
           ),
         admission = %{
           "schema_version" => "manafuel.symphony_admission_result.v1",
           "claim_session_id" => document["claim_session_id"],
           "idempotency_key" => document["idempotency_key"],
           "issue" => issue(document),
           "dispatch" => dispatch(document),
           "producer_claim" => producer_claim,
           "runtime_binding" => claim_document["runtime_binding"],
           "admission_contract" => claim_document["admission_contract"],
           "outcome" => %{
             "decision" => hook_receipt["decision"],
             "reason_code" => "admitted",
             "hook_exit_code" => hook_receipt["hook_exit_code"],
             "child_invoked" => hook_receipt["child_invoked"],
             "child_exit_code" => hook_receipt["child_exit_code"],
             "evidence" => evidence_reference,
             "diagnostic_sha256" => hook_receipt["child_stdout_sha256"]
           },
           "completed_at_utc" => hook_receipt["completed_at_utc"]
         },
         :ok <- exact_projection(context, "admission_result", admission),
         :ok <- exact_projection(context, "admission_outcome", admission["outcome"]),
         {:ok, reference} <-
           Broker.publish_cas(
             admission,
             "admission_result",
             workspace_root,
             context,
             deadline
           ) do
      {:ok, reference}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec thread(map()) :: map()
  def thread(session) when is_map(session) do
    %{
      "id" => session.thread_id,
      "experimental_api" => true,
      "history_mode" => "paginated",
      "legacy_include_turns_used" => false,
      "memory_mode" => "none",
      "memory_disable_ack" => "startup_contract_memory_none",
      "memory_disabled_at_utc" => now(),
      "app_server_os_pid" => session.metadata[:codex_app_server_pid],
      "ready_at_utc" => now()
    }
  end

  @spec turn_intent(pos_integer(), String.t()) :: map()
  def turn_intent(turn_number, prompt)
      when is_integer(turn_number) and turn_number > 0 and is_binary(prompt) do
    intent_at_utc = now()
    prompt_sha256 = sha256(prompt)

    client_user_message_id =
      sha256("symphony.turn.intent.v1\0#{turn_number}\0#{prompt_sha256}\0#{intent_at_utc}")

    %{
      "turn_number" => turn_number,
      "client_user_message_id" => client_user_message_id,
      "prompt_sha256" => prompt_sha256,
      "intent_at_utc" => intent_at_utc
    }
  end

  @spec turn_started(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def turn_started(_context, effect, message)
      when is_map(effect) and is_map(message) do
    document = effect.document
    intent = List.last(document["turns"])
    thread_id = get_in(document, ["thread", "id"])
    turn_id = message[:turn_id]
    client_id = message[:client_user_message_id]
    started_at_utc = now()

    with true <- is_map(intent),
         true <- is_binary(thread_id),
         true <- is_binary(turn_id),
         true <- is_binary(client_id),
         true <- intent["client_user_message_id"] == client_id,
         true <- is_binary(started_at_utc) do
      pagination = %{
        "resource" => "codex_turn_start",
        "method" => "turn/start",
        "history_mode" => "not_requested",
        "requested_page_size" => 0,
        "pages" => [],
        "pagination_complete" => true,
        "stable_ids_unique" => true,
        "match_count" => 1
      }

      reconciliation = %{
        "thread_id" => thread_id,
        "experimental_api" => true,
        "history_mode" => "turn_start_acknowledgement",
        "legacy_include_turns_used" => false,
        "client_user_message_id" => client_id,
        "prompt_sha256" => intent["prompt_sha256"],
        "pagination" => pagination,
        "matched_turn_id" => turn_id,
        "matched_user_message_item_id" => client_id,
        "reconciled_at_utc" => started_at_utc,
        "decision" => "PASS"
      }

      {:ok,
       %{
         "client_user_message_id" => client_id,
         "prompt_sha256" => intent["prompt_sha256"],
         "intent_at_utc" => intent["intent_at_utc"],
         "turn_id" => turn_id,
         "user_message_item_id" => client_id,
         "started_at_utc" => started_at_utc,
         "history_reconciliation" => reconciliation
       }}
    else
      false -> {:error, :producer_turn_start_acknowledgement_invalid}
    end
  end

  @spec turn_terminal(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def turn_terminal(context, effect, turn_session)
      when is_map(context) and is_map(effect) and is_map(turn_session) do
    workspace_root = workspace_root(context)
    document = effect.document
    result = turn_session[:result]

    with true <- is_map(result),
         "completed" <- result[:status],
         payload when is_map(payload) <- result[:payload],
         raw when is_binary(raw) <- result[:raw],
         terminal_at_utc when is_binary(terminal_at_utc) <- result[:terminal_at_utc],
         {:ok, deadline} <- authority_deadline(document, workspace_root),
         {:ok, event_reference} <-
           Broker.publish_bytes(raw, "terminal_event", workspace_root, context, deadline) do
      {:ok,
       %{
         "terminal_status" => "completed",
         "terminal_at_utc" => terminal_at_utc,
         "result_sha256" => sha256(raw),
         "server_turn_terminal_event" => event_reference,
         "completion_seal" => nil
       }}
    else
      false -> {:error, :producer_turn_terminal_invalid}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_turn_terminal_invalid}
    end
  end

  @spec closeout_directive(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def closeout_directive(context, effect, producer_claim)
      when is_map(context) and is_map(effect) and is_map(producer_claim) do
    workspace_root = workspace_root(context)
    document = effect.document

    with {:ok, claim} <- read_reference(producer_claim, workspace_root),
         ceo_reference when is_map(ceo_reference) <- claim["ceo_prioritization_receipt"],
         {:ok, ceo} <- read_reference(ceo_reference, workspace_root),
         cycle when is_integer(cycle) and cycle in 1..2 <- ceo["originator_cycle_index"],
         runtime_sha when is_binary(runtime_sha) <-
           get_in(claim, ["runtime_binding", "runtime_binding_sha256"]),
         {:ok, deadline} <- find_cycle_deadline(context, document, cycle, runtime_sha) do
      {:ok,
       %{
         deadline_at_utc: deadline.deadline_at_utc,
         deadline_sha256: deadline.deadline_sha256,
         deadline_artifact_path: deadline.deadline_artifact_path,
         originator_cycle_index: cycle,
         terminal_marker: TerminalTracker.marker_text(document, deadline)
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_closeout_directive_invalid}
    end
  end

  @spec turn_terminal_final(map(), map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def turn_terminal_final(context, effect, turn_session, deadline)
      when is_map(context) and is_map(effect) and is_map(turn_session) and is_map(deadline) do
    workspace_root = workspace_root(context)
    document = effect.document
    result = turn_session[:result]
    turn = List.last(document["turns"])

    with true <- is_map(result) and is_map(turn),
         "completed" <- result[:status],
         raw when is_binary(raw) <- result[:raw],
         terminal_at_utc when is_binary(terminal_at_utc) <- result[:terminal_at_utc],
         {:ok, event_reference} <-
           Broker.publish_bytes(
             raw,
             "terminal_event",
             workspace_root,
             context,
             deadline.deadline_at_utc
           ),
         server_event = %{reference: event_reference, terminal_at_utc: terminal_at_utc},
         {:ok, tracker} <- TerminalTracker.capture(context, effect, server_event, deadline),
         {:ok, claim} <- read_reference(document["producer_claim"], workspace_root),
         runtime_sha when is_binary(runtime_sha) <-
           get_in(claim, ["runtime_binding", "runtime_binding_sha256"]),
         seal = %{
           "schema_version" => "manafuel.symphony_completion_seal.v1",
           "claim_session_id" => document["claim_session_id"],
           "idempotency_key" => document["idempotency_key"],
           "issue" => issue(document),
           "dispatch" => dispatch(document),
           "runtime_binding_sha256" => runtime_sha,
           "terminal_turn_number" => turn["turn_number"],
           "server_turn_terminal_event" => event_reference,
           "server_turn_terminal_at_utc" => terminal_at_utc,
           "completion_outcome" => "issue_terminal",
           "terminal_tracker" => tracker,
           "predecessor_transition" => last_transition(document),
           "sealed_at_utc" => now(),
           "decision" => "SEALED"
         },
         :ok <- exact_projection(context, "completion_seal", seal),
         {:ok, seal_reference} <-
           Broker.publish_cas(
             seal,
             "completion_seal",
             workspace_root,
             context,
             deadline.deadline_at_utc
           ) do
      {:ok,
       %{
         terminal: %{
           "terminal_status" => "completed",
           "terminal_at_utc" => terminal_at_utc,
           "result_sha256" => sha256(raw),
           "server_turn_terminal_event" => event_reference,
           "completion_seal" => seal_reference
         },
         terminal_tracker: tracker,
         completion_seal: seal_reference
       }}
    else
      false -> {:error, :producer_final_turn_terminal_invalid}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_final_turn_terminal_invalid}
    end
  end

  defp find_cycle_deadline(context, document, cycle, runtime_sha) do
    source_root = get_in(context, [:launch, :document, "source", "git_root"])

    paths =
      if is_binary(source_root) and source_root != "" do
        Path.join([
          String.replace(source_root, "\\", "/"),
          ".codex",
          "runs",
          "symphony-production-activation",
          "**",
          "ordinary-chain-deadlines",
          "cycle-#{cycle}.json"
        ])
        |> Path.wildcard(match_dot: true)
        |> Enum.sort()
      else
        []
      end

    if length(paths) > 1_000 do
      {:error, :producer_cycle_deadline_enumeration_limit}
    else
      matches = Enum.filter(paths, &cycle_deadline_match?(&1, document, cycle, runtime_sha))

      case matches do
        [path] ->
          reopen_cycle_deadline(path, cycle)

        [] ->
          {:error, :producer_cycle_deadline_missing}

        _ ->
          {:error, :producer_cycle_deadline_ambiguous}
      end
    end
  end

  defp cycle_deadline_match?(path, document, cycle, runtime_sha) do
    with {:ok, bytes} <- File.read(path),
         {:ok, deadline} <- Rfc8785Jcs.validate_canonical(bytes),
         true <- deadline["schema_version"] == "manafuel.symphony_cycle_deadline.v1",
         true <- deadline["originator_cycle_index"] == cycle,
         true <- deadline["issue_id"] == document["issue_id"],
         true <- deadline["identifier"] == document["identifier"],
         true <- deadline["runtime_binding_sha256"] == runtime_sha,
         {:ok, expiry, 0} <- DateTime.from_iso8601(deadline["deadline_at_utc"]),
         true <- DateTime.compare(DateTime.utc_now(), expiry) == :lt do
      true
    else
      _ -> false
    end
  end

  defp reopen_cycle_deadline(path, cycle) do
    with {:ok, bytes} <- File.read(path),
         {:ok, deadline} <- Rfc8785Jcs.validate_canonical(bytes) do
      {:ok,
       %{
         deadline_at_utc: deadline["deadline_at_utc"],
         deadline_sha256: sha256(bytes),
         deadline_artifact_path: Path.expand(path),
         originator_cycle_index: cycle
       }}
    end
  end

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

  defp validate_hook_receipt(receipt) when is_map(receipt) do
    with true <- Enum.sort(Map.keys(receipt)) == Enum.sort(@hook_receipt_keys),
         "manafuel.symphony_admission_hook_receipt.v1" <- receipt["schema_version"],
         "PASS" <- receipt["decision"],
         0 <- receipt["hook_exit_code"],
         true <- receipt["child_invoked"],
         0 <- receipt["child_exit_code"],
         digest when is_binary(digest) <- receipt["child_stdout_sha256"],
         true <- byte_size(digest) == 64,
         {:ok, _time, 0} <- DateTime.from_iso8601(receipt["completed_at_utc"]) do
      :ok
    else
      _ -> {:error, :producer_admission_hook_receipt_not_pass}
    end
  end

  defp validate_hook_receipt(_receipt),
    do: {:error, :producer_admission_hook_receipt_invalid}

  defp ledger_binding(context, workspace_root) do
    current = Path.join(workspace_root, ".symphony-state\\execution.json")
    previous = Path.join(workspace_root, ".symphony-state\\execution.previous.json")

    with {:ok, current_identity} <- Broker.inspect(current, workspace_root, context),
         {:ok, previous_identity} <- Broker.inspect(previous, workspace_root, context) do
      {:ok,
       %{
         "current" => reference(current_identity, workspace_root),
         "previous" => reference(previous_identity, workspace_root)
       }}
    end
  end

  defp ceo_reference(context, document, workspace_root) do
    root = Path.join(String.replace(workspace_root, "\\", "/"), ".symphony-state/ceo-prioritization-receipts/sha256")

    with {:ok, paths} <- cas_paths(root),
         candidates <- matching_ceo_candidates(paths, document["issue_id"], document["identifier"]),
         [path] <- candidates,
         {:ok, identity} <- Broker.inspect(path, workspace_root, context) do
      {:ok, reference(identity, workspace_root)}
    else
      [] -> {:error, :producer_ceo_prioritization_receipt_missing}
      [_ | _] -> {:error, :producer_ceo_prioritization_receipt_ambiguous}
      {:error, reason} -> {:error, reason}
    end
  end

  defp matching_ceo_candidates(paths, issue_id, identifier) do
    Enum.filter(paths, fn path ->
      with {:ok, bytes} <- File.read(path),
           {:ok, receipt} <- Rfc8785Jcs.validate_canonical(bytes),
           true <-
             receipt["schema_version"] ==
               "manafuel.symphony_ceo_discovery_prioritization_receipt.v1",
           true <- receipt["decision"] == "PASS",
           true <- receipt["outcome"] == "CREATED",
           created when is_map(created) <- receipt["created_backlog"],
           true <- created["issue_id"] == issue_id,
           true <- created["identifier"] == identifier do
        true
      else
        _ -> false
      end
    end)
  end

  defp regular_files_in_shard(root, shard) do
    shard_path = Path.join(root, shard)

    case File.lstat(shard_path) do
      {:ok, %File.Stat{type: :directory}} -> regular_files(shard_path)
      _ -> []
    end
  end

  defp regular_files(shard_path) do
    case File.ls(shard_path) do
      {:ok, files} ->
        files
        |> Enum.sort()
        |> Enum.map(&Path.join(shard_path, &1))
        |> Enum.filter(&File.regular?/1)

      _ ->
        []
    end
  end

  defp cas_paths(root) do
    case File.ls(root) do
      {:ok, shards} ->
        paths =
          shards
          |> Enum.sort()
          |> Enum.flat_map(&regular_files_in_shard(root, &1))

        {:ok, paths}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authority_deadline(%{"milestones" => milestones}, workspace_root)
       when is_list(milestones) and milestones != [] do
    with milestone when is_map(milestone) <- List.last(milestones),
         intent_reference when is_map(intent_reference) <- milestone["install_intent_core"],
         {:ok, intent} <- read_reference(intent_reference, workspace_root),
         lock_reference when is_map(lock_reference) <- intent["lock"],
         {:ok, lock} <- read_reference(lock_reference, workspace_root),
         deadline when is_binary(deadline) <- lock["authority_deadline_at_utc"] do
      {:ok, deadline}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_lifecycle_authority_invalid}
    end
  end

  defp authority_deadline(_document, _workspace_root),
    do: {:error, :producer_lifecycle_authority_invalid}

  defp read_reference(reference, workspace_root) when is_map(reference) do
    path = Path.join(workspace_root, String.replace(reference["path"], "/", "\\"))

    with {:ok, bytes} <- File.read(path),
         true <- sha256(bytes) == reference["sha256"],
         {:ok, document} <- Rfc8785Jcs.validate_canonical(bytes) do
      {:ok, document}
    else
      false -> {:error, :producer_lifecycle_reference_digest_drift}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reference(identity, workspace_root) do
    wire_root =
      workspace_root
      |> String.replace("\\", "/")
      |> String.trim_trailing("/")

    %{
      "path" =>
        workspace_root
        |> Broker.reference_wire_path(identity["path"])
        |> String.replace_prefix(wire_root <> "/", "")
        |> String.replace("\\", "/"),
      "physical_path" => identity["physical_path"],
      "volume_id" => identity["volume_id"],
      "file_id" => identity["file_id"],
      "file_type" => identity["file_type"],
      "link_count" => identity["link_count"],
      "sha256" => identity["sha256"],
      "length" => identity["length"]
    }
  end

  defp exact_projection(%{contract: %{document: contract}}, name, document) do
    expected = get_in(contract, ["ordered_fields", name])

    if is_list(expected) and Enum.sort(Map.keys(document)) == Enum.sort(expected),
      do: :ok,
      else: {:error, {:producer_lifecycle_projection_mismatch, name}}
  end

  defp issue(document),
    do: %{"id" => document["issue_id"], "identifier" => document["identifier"]}

  defp dispatch(document),
    do: %{
      "dispatch_sequence" => document["dispatch_sequence"],
      "retry_attempt" => document["retry_attempt"],
      "allocation" => document["dispatch_allocation"]
    }

  defp workspace_root(%{contract: %{document: contract}}),
    do: get_in(contract, ["constants", "workspace_root_windows"])

  defp now, do: DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.%3fZ")
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
