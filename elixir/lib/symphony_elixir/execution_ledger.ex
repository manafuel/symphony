defmodule SymphonyElixir.ExecutionLedger do
  @moduledoc """
  Durable retry, terminal-state, and dispatch-effect ownership.

  One current and one previous generation are kept under the configured
  workspace root. A prepared dispatch effect is written before a worker starts;
  after restart, an unreceipted effect is ambiguous and must be held rather than
  executed again.

  Persistence uses a synced temporary file followed by crash-safe generation
  rotation. POSIX hosts sync the parent directory after every directory-entry
  transition. On Windows, Erlang/OTP implements `:file.rename/2` with
  `MOVEFILE_WRITE_THROUGH`; the synced file plus write-through rename is the
  supported metadata durability boundary.
  """

  alias SymphonyElixir.{FailureSemantics, PathSafety}
  alias SymphonyElixir.Linear.Issue

  @schema_version "symphony.execution_ledger.v4"
  @legacy_schema_versions [
    "symphony.execution_ledger.v3",
    "symphony.execution_ledger.v2",
    "symphony.execution_ledger.v1"
  ]
  @ledger_file "execution.json"
  @previous_ledger_file "execution.previous.json"
  @max_text_bytes 2_000

  @type state :: %{blocked: map(), retrying: map(), effects: map()}

  @spec load(Path.t()) :: {:ok, state()} | {:error, term()}
  def load(workspace_root) when is_binary(workspace_root) do
    with {:ok, paths} <- ledger_paths(workspace_root) do
      load_current_or_previous(paths)
    end
  end

  @spec persist(Path.t(), map(), map(), map()) :: :ok | {:error, term()}
  def persist(workspace_root, blocked, retrying, effects)
      when is_binary(workspace_root) and is_map(blocked) and is_map(retrying) and
             is_map(effects) do
    with {:ok, paths} <- ledger_paths(workspace_root),
         :ok <- File.mkdir_p(Path.dirname(paths.current)),
         {:ok, content} <- encode(blocked, retrying, effects) do
      atomic_write(paths, content)
    end
  end

  @spec reserve_effect(map(), Issue.t(), pos_integer()) ::
          {:ok, map(), map()} | {:duplicate, map()}
  def reserve_effect(effects, %Issue{id: issue_id} = issue, attempt)
      when is_map(effects) and is_binary(issue_id) and issue_id != "" and
             is_integer(attempt) and attempt > 0 do
    idempotency_key = idempotency_key(issue_id, attempt)

    case Map.get(effects, idempotency_key) do
      nil ->
        prepared = %{
          idempotency_key: idempotency_key,
          issue_id: issue_id,
          identifier: issue.identifier,
          issue: issue,
          attempt: attempt,
          status: :prepared,
          prepared_at: DateTime.utc_now(),
          receipt_at: nil
        }

        {:ok, Map.put(effects, idempotency_key, prepared), prepared}

      existing ->
        {:duplicate, existing}
    end
  end

  @spec mark_effect_started(map(), String.t()) :: {:ok, map()} | {:error, :missing_effect}
  def mark_effect_started(effects, idempotency_key)
      when is_map(effects) and is_binary(idempotency_key) do
    case Map.get(effects, idempotency_key) do
      nil ->
        {:error, :missing_effect}

      effect ->
        started = %{effect | status: :started, receipt_at: DateTime.utc_now()}
        {:ok, Map.put(effects, idempotency_key, started)}
    end
  end

  @spec mark_effect_completed(map(), String.t()) ::
          {:ok, map()} | {:error, :missing_effect}
  def mark_effect_completed(effects, idempotency_key)
      when is_map(effects) and is_binary(idempotency_key) do
    case Map.get(effects, idempotency_key) do
      nil ->
        {:error, :missing_effect}

      effect ->
        completed = %{effect | status: :completed, receipt_at: DateTime.utc_now()}
        {:ok, Map.put(effects, idempotency_key, completed)}
    end
  end

  @spec idempotency_key(String.t(), pos_integer()) :: String.t()
  def idempotency_key(issue_id, attempt)
      when is_binary(issue_id) and is_integer(attempt) and attempt > 0 do
    :crypto.hash(:sha256, ["symphony.dispatch.v1", 0, issue_id, 0, Integer.to_string(attempt)])
    |> Base.encode16(case: :lower)
  end

  defp ledger_paths(workspace_root) do
    with {:ok, canonical_root} <- PathSafety.canonicalize(workspace_root) do
      state_root = Path.join(canonical_root, ".symphony-state")
      current = Path.join(state_root, @ledger_file)
      previous = Path.join(state_root, @previous_ledger_file)

      with :ok <- validate_ledger_path(canonical_root, state_root),
           :ok <- validate_ledger_path(canonical_root, current),
           :ok <- validate_ledger_path(canonical_root, previous) do
        {:ok, %{current: current, previous: previous}}
      end
    end
  end

  defp validate_ledger_path(canonical_root, path) do
    with {:ok, canonical_path} <- PathSafety.canonicalize(path),
         true <- descendant_path?(canonical_path, canonical_root) do
      :ok
    else
      false -> {:error, {:execution_ledger_outside_workspace, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp descendant_path?(path, root) do
    relative = Path.relative_to(path, root)

    Path.type(relative) == :relative and
      case Path.split(relative) do
        [] -> false
        [".." | _rest] -> false
        _segments -> true
      end
  end

  defp load_current_or_previous(paths) do
    cond do
      File.exists?(paths.current) ->
        load_current_with_previous_fallback(paths)

      File.exists?(paths.previous) ->
        load_file(paths.previous)

      true ->
        {:ok, %{blocked: %{}, retrying: %{}, effects: %{}}}
    end
  end

  defp load_current_with_previous_fallback(paths) do
    case load_file(paths.current) do
      {:ok, _state} = current ->
        current

      {:error, current_reason} = current_error ->
        load_previous_after_current_failure(paths, current_reason, current_error)
    end
  end

  defp load_previous_after_current_failure(paths, current_reason, current_error) do
    if File.exists?(paths.previous) do
      case load_file(paths.previous) do
        {:ok, _state} = previous ->
          previous

        {:error, previous_reason} ->
          {:error, {:invalid_execution_generations, current_reason, previous_reason}}
      end
    else
      current_error
    end
  end

  defp load_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, payload} <- Jason.decode(content),
         {:ok, state} <- decode_payload(payload) do
      {:ok, state}
    else
      {:error, reason} -> {:error, {:invalid_execution_ledger, reason}}
      _ -> {:error, {:invalid_execution_ledger, :schema_mismatch}}
    end
  end

  defp decode_payload(%{
         "schema_version" => @schema_version,
         "blocked" => blocked,
         "retrying" => retrying,
         "effects" => effects
       })
       when is_list(blocked) and is_list(retrying) and is_list(effects) do
    with {:ok, decoded_blocked} <- decode_entries(blocked, &decode_blocked/1),
         {:ok, decoded_retrying} <- decode_entries(retrying, &decode_retry/1),
         {:ok, decoded_effects} <- decode_entries(effects, &decode_effect/1) do
      {:ok,
       %{
         blocked: decoded_blocked,
         retrying: decoded_retrying,
         effects: decoded_effects
       }}
    end
  end

  defp decode_payload(%{
         "schema_version" => version,
         "blocked" => blocked,
         "retrying" => retrying
       })
       when version in @legacy_schema_versions and is_list(blocked) and is_list(retrying) do
    with {:ok, decoded_blocked} <- decode_entries(blocked, &decode_legacy_blocked/1),
         {:ok, decoded_retrying} <- decode_entries(retrying, &decode_legacy_retry/1) do
      {:ok, %{blocked: decoded_blocked, retrying: decoded_retrying, effects: %{}}}
    end
  end

  defp decode_payload(%{
         "schema_version" => "symphony.execution_ledger.v1",
         "blocked" => blocked
       })
       when is_list(blocked) do
    with {:ok, decoded_blocked} <- decode_entries(blocked, &decode_legacy_blocked/1) do
      {:ok, %{blocked: decoded_blocked, retrying: %{}, effects: %{}}}
    end
  end

  defp decode_payload(_payload), do: {:error, :schema_mismatch}

  defp decode_entries(entries, decoder) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
      case decoder.(entry) do
        {:ok, {key, _value}} when is_map_key(acc, key) ->
          {:halt, {:error, {:duplicate_execution_entry, key}}}

        {:ok, {key, value}} ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp decode_blocked(
         %{
           "issue_id" => issue_id,
           "failure_class" => failure_class,
           "terminal_state" => terminal_state,
           "attempt" => attempt,
           "blocked_at" => blocked_at
         } = entry
       )
       when is_binary(issue_id) and issue_id != "" and is_binary(failure_class) and
              is_binary(terminal_state) and is_integer(attempt) and attempt > 0 do
    with {:ok, decoded_class} <- decode_failure_class(failure_class),
         {:ok, decoded_terminal} <- decode_terminal_state(terminal_state),
         {:ok, blocked_datetime} <- decode_datetime(blocked_at),
         {:ok, issue} <- decode_issue(Map.get(entry, "issue"), issue_id) do
      {:ok,
       {issue_id,
        decoded_blocked_entry(
          entry,
          issue,
          issue_id,
          decoded_class,
          decoded_terminal,
          attempt,
          blocked_datetime
        )}}
    end
  end

  defp decode_blocked(_entry), do: {:error, :invalid_blocked_entry}

  defp decoded_blocked_entry(
         entry,
         issue,
         issue_id,
         decoded_class,
         decoded_terminal,
         attempt,
         blocked_datetime
       ) do
    %{
      issue: issue,
      identifier: Map.get(entry, "identifier") || issue.identifier || issue_id,
      issue_url: Map.get(entry, "issue_url") || issue.url,
      error: safe_failure_diagnostic(decoded_class, :terminal),
      worker_host: Map.get(entry, "worker_host"),
      workspace_path: Map.get(entry, "workspace_path"),
      session_id: Map.get(entry, "session_id"),
      failure_class: decoded_class,
      terminal_state: decoded_terminal,
      transition: :terminal,
      attempt: attempt,
      retry_exhausted: Map.get(entry, "retry_exhausted") == true,
      idempotency_key: Map.get(entry, "idempotency_key"),
      block_kind: decode_known_atom(Map.get(entry, "block_kind")),
      blocked_at: blocked_datetime
    }
  end

  defp decode_legacy_blocked(%{"issue_id" => issue_id} = entry)
       when is_binary(issue_id) and issue_id != "" do
    with {:ok, issue} <- decode_issue(Map.get(entry, "issue"), issue_id),
         {:ok, attempt} <- decode_legacy_attempt(Map.fetch(entry, "attempt")),
         {:ok, blocked_at} <-
           decode_datetime(Map.get(entry, "blocked_at") || DateTime.to_iso8601(DateTime.utc_now())) do
      {:ok,
       {issue_id,
        %{
          issue: issue,
          identifier: Map.get(entry, "identifier") || issue.identifier || issue_id,
          issue_url: Map.get(entry, "issue_url") || issue.url,
          error: safe_failure_diagnostic(:unknown_fail_closed, :legacy_terminal),
          worker_host: Map.get(entry, "worker_host"),
          workspace_path: Map.get(entry, "workspace_path"),
          session_id: Map.get(entry, "session_id"),
          failure_class: :unknown_fail_closed,
          terminal_state: :permanent,
          transition: :terminal,
          attempt: attempt,
          retry_exhausted: false,
          idempotency_key: nil,
          block_kind: decode_known_atom(Map.get(entry, "block_kind")),
          blocked_at: blocked_at
        }}}
    end
  end

  defp decode_legacy_blocked(_entry), do: {:error, :invalid_legacy_blocked_entry}

  defp decode_legacy_attempt(:error), do: {:ok, 1}
  defp decode_legacy_attempt({:ok, attempt}) when is_integer(attempt) and attempt > 0, do: {:ok, attempt}
  defp decode_legacy_attempt(_attempt), do: {:error, :invalid_legacy_attempt}

  defp decode_retry(
         %{
           "issue_id" => issue_id,
           "attempt" => attempt,
           "failure_class" => failure_class,
           "due_at" => due_at,
           "delay_type" => delay_type
         } = entry
       )
       when is_binary(issue_id) and issue_id != "" and is_integer(attempt) and attempt > 0 and
              (is_binary(failure_class) or is_nil(failure_class)) and is_binary(delay_type) do
    with {:ok, decoded_class} <- decode_retry_failure_class(failure_class, delay_type),
         {:ok, due_datetime} <- decode_datetime(due_at) do
      now = DateTime.utc_now()
      remaining_ms = max(0, DateTime.diff(due_datetime, now, :millisecond))

      {:ok,
       {issue_id,
        %{
          attempt: attempt,
          identifier: Map.get(entry, "identifier") || issue_id,
          issue_url: Map.get(entry, "issue_url"),
          error: safe_failure_diagnostic(decoded_class, decode_delay_type(delay_type)),
          worker_host: Map.get(entry, "worker_host"),
          workspace_path: Map.get(entry, "workspace_path"),
          failure_class: decoded_class,
          delay_type: decode_delay_type(delay_type),
          transition: :retrying,
          due_at: due_datetime,
          due_at_ms: System.monotonic_time(:millisecond) + remaining_ms
        }}}
    else
      _ -> {:error, {:invalid_retrying_entry, issue_id}}
    end
  end

  defp decode_retry(_entry), do: {:error, :invalid_retrying_entry}

  defp decode_legacy_retry(%{"issue_id" => issue_id, "attempt" => attempt} = entry)
       when is_binary(issue_id) and issue_id != "" and is_integer(attempt) and attempt > 0 do
    due_at = Map.get(entry, "due_at") || DateTime.to_iso8601(DateTime.utc_now())

    decode_retry(
      entry
      |> Map.put("failure_class", "transient_transport")
      |> Map.put("delay_type", "backoff")
      |> Map.put("due_at", due_at)
    )
  end

  defp decode_legacy_retry(_entry), do: {:error, :invalid_legacy_retrying_entry}

  defp decode_effect(
         %{
           "idempotency_key" => key,
           "issue_id" => issue_id,
           "attempt" => attempt,
           "status" => status,
           "prepared_at" => prepared_at
         } = entry
       )
       when is_binary(key) and is_binary(issue_id) and issue_id != "" and
              is_integer(attempt) and attempt > 0 and is_binary(status) do
    with true <- key == idempotency_key(issue_id, attempt),
         {:ok, decoded_status} <- decode_effect_status(status),
         {:ok, prepared_datetime} <- decode_datetime(prepared_at),
         {:ok, receipt_datetime} <- decode_optional_datetime(Map.get(entry, "receipt_at")),
         {:ok, issue} <- decode_issue(Map.get(entry, "issue"), issue_id) do
      {:ok,
       {key,
        %{
          idempotency_key: key,
          issue_id: issue_id,
          identifier: Map.get(entry, "identifier") || issue.identifier || issue_id,
          issue: issue,
          attempt: attempt,
          status: decoded_status,
          prepared_at: prepared_datetime,
          receipt_at: receipt_datetime
        }}}
    else
      _ -> {:error, {:invalid_effect_entry, key}}
    end
  end

  defp decode_effect(_entry), do: {:error, :invalid_effect_entry}

  defp encode(blocked, retrying, effects) do
    Jason.encode(%{
      schema_version: @schema_version,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
      blocked: encode_sorted(blocked, &encode_blocked/2),
      retrying: encode_sorted(retrying, &encode_retry/2),
      effects: encode_sorted(effects, &encode_effect/2)
    })
  end

  defp encode_sorted(entries, encoder) do
    entries
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> encoder.(key, value) end)
  end

  defp encode_blocked(issue_id, entry) do
    %{
      issue_id: bounded_text(issue_id),
      identifier: bounded_text(Map.get(entry, :identifier)),
      issue_url: bounded_text(Map.get(entry, :issue_url)),
      issue: encode_issue(Map.get(entry, :issue), issue_id),
      error:
        safe_failure_diagnostic(
          Map.get(entry, :failure_class),
          Map.get(entry, :block_kind) || :terminal
        ),
      worker_host: bounded_text(Map.get(entry, :worker_host)),
      workspace_path: bounded_text(Map.get(entry, :workspace_path)),
      session_id: bounded_text(Map.get(entry, :session_id)),
      failure_class: encode_failure_class(Map.get(entry, :failure_class)),
      terminal_state: encode_terminal_state(Map.get(entry, :terminal_state)),
      transition: "terminal",
      attempt: positive_integer(Map.get(entry, :attempt)),
      retry_exhausted: Map.get(entry, :retry_exhausted) == true,
      idempotency_key: bounded_text(Map.get(entry, :idempotency_key)),
      block_kind: encode_atom(Map.get(entry, :block_kind)),
      blocked_at: encode_datetime(Map.get(entry, :blocked_at)) || DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp encode_retry(issue_id, entry) do
    due_at =
      encode_datetime(Map.get(entry, :due_at)) ||
        DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

    %{
      issue_id: bounded_text(issue_id),
      identifier: bounded_text(Map.get(entry, :identifier)),
      issue_url: bounded_text(Map.get(entry, :issue_url)),
      error:
        safe_failure_diagnostic(
          Map.get(entry, :failure_class),
          Map.get(entry, :delay_type) || :backoff
        ),
      worker_host: bounded_text(Map.get(entry, :worker_host)),
      workspace_path: bounded_text(Map.get(entry, :workspace_path)),
      attempt: positive_integer(Map.get(entry, :attempt)),
      failure_class: encode_retry_failure_class(Map.get(entry, :failure_class), Map.get(entry, :delay_type)),
      delay_type: encode_delay_type(Map.get(entry, :delay_type)),
      transition: "retrying",
      due_at: due_at
    }
  end

  defp encode_effect(key, entry) do
    issue_id = Map.get(entry, :issue_id)

    %{
      idempotency_key: bounded_text(key),
      issue_id: bounded_text(issue_id),
      identifier: bounded_text(Map.get(entry, :identifier)),
      issue: encode_issue(Map.get(entry, :issue), issue_id),
      attempt: positive_integer(Map.get(entry, :attempt)),
      status: encode_atom(Map.get(entry, :status)),
      prepared_at: encode_datetime(Map.get(entry, :prepared_at)),
      receipt_at: encode_datetime(Map.get(entry, :receipt_at))
    }
  end

  defp encode_issue(%Issue{} = issue, issue_id) do
    %{
      id: bounded_text(issue.id || issue_id),
      identifier: bounded_text(issue.identifier),
      state: bounded_text(issue.state),
      url: bounded_text(issue.url),
      assigned_to_worker: issue.assigned_to_worker
    }
  end

  defp encode_issue(_issue, issue_id), do: %{id: bounded_text(issue_id), assigned_to_worker: true}

  defp decode_issue(issue, issue_id) when is_map(issue) do
    {:ok,
     %Issue{
       id: Map.get(issue, "id") || issue_id,
       identifier: Map.get(issue, "identifier"),
       state: Map.get(issue, "state"),
       url: Map.get(issue, "url"),
       assigned_to_worker: Map.get(issue, "assigned_to_worker") != false
     }}
  end

  defp decode_issue(_issue, issue_id) do
    {:ok, %Issue{id: issue_id, identifier: issue_id, assigned_to_worker: true}}
  end

  defp encode_failure_class(class) do
    if FailureSemantics.valid_class?(class), do: Atom.to_string(class), else: "unknown_fail_closed"
  end

  defp decode_failure_class(value) when is_binary(value) do
    case Enum.find(FailureSemantics.classes(), &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_failure_class}
      class -> {:ok, class}
    end
  end

  defp encode_retry_failure_class(nil, :continuation), do: nil
  defp encode_retry_failure_class(class, _delay_type), do: encode_failure_class(class)

  defp decode_retry_failure_class(nil, "continuation"), do: {:ok, nil}

  defp decode_retry_failure_class(value, "backoff") when is_binary(value) do
    with {:ok, class} <- decode_failure_class(value),
         true <- class in [:transient_capacity, :transient_transport] do
      {:ok, class}
    else
      _ -> {:error, :invalid_retry_failure_class}
    end
  end

  defp decode_retry_failure_class(_value, _delay_type), do: {:error, :invalid_retry_failure_class}

  defp encode_delay_type(:continuation), do: "continuation"
  defp encode_delay_type(_delay_type), do: "backoff"

  defp decode_delay_type("continuation"), do: :continuation
  defp decode_delay_type("backoff"), do: :backoff

  defp encode_terminal_state(:held), do: "held"
  defp encode_terminal_state(:permanent), do: "permanent"
  defp encode_terminal_state(_value), do: "permanent"

  defp decode_terminal_state("held"), do: {:ok, :held}
  defp decode_terminal_state("permanent"), do: {:ok, :permanent}
  defp decode_terminal_state(_value), do: {:error, :invalid_terminal_state}

  defp decode_effect_status("prepared"), do: {:ok, :prepared}
  defp decode_effect_status("started"), do: {:ok, :started}
  defp decode_effect_status("completed"), do: {:ok, :completed}
  defp decode_effect_status(_status), do: {:error, :invalid_effect_status}

  defp safe_failure_diagnostic(class, context) when is_atom(context) do
    class_label =
      if FailureSemantics.valid_class?(class),
        do: Atom.to_string(class),
        else: "continuation"

    "execution_#{context}:#{class_label}"
  end

  defp decode_known_atom("before_terminal"), do: :before_terminal
  defp decode_known_atom(_value), do: nil

  defp encode_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_atom(value) when is_binary(value), do: bounded_text(value)
  defp encode_atom(_value), do: nil

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(_value), do: nil

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp decode_datetime(_value), do: {:error, :invalid_datetime}

  defp decode_optional_datetime(nil), do: {:ok, nil}
  defp decode_optional_datetime(value), do: decode_datetime(value)

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: 1

  defp bounded_text(nil), do: nil

  defp bounded_text(value) when is_binary(value) do
    if byte_size(value) <= @max_text_bytes do
      value
    else
      value
      |> String.graphemes()
      |> Enum.reduce_while("", &append_bounded_grapheme/2)
    end
  end

  defp bounded_text(value) do
    value
    |> inspect(limit: 30, printable_limit: @max_text_bytes, width: 80)
    |> bounded_text()
  end

  defp append_bounded_grapheme(grapheme, acc) do
    if byte_size(acc) + byte_size(grapheme) <= @max_text_bytes - 14,
      do: {:cont, acc <> grapheme},
      else: {:halt, acc <> "...[truncated]"}
  end

  defp atomic_write(paths, content) do
    temporary = "#{paths.current}.tmp-#{System.unique_integer([:positive, :monotonic])}"

    with :ok <- durable_write(temporary, content),
         :ok <- sync_parent_directory(paths.current),
         :ok <- rotate_current_generation(paths),
         :ok <- sync_parent_directory(paths.current),
         :ok <- File.rename(temporary, paths.current),
         :ok <- sync_parent_directory(paths.current) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, {:execution_ledger_write_failed, reason}}
    end
  end

  defp sync_parent_directory(path) do
    case :os.type() do
      {:win32, _name} ->
        # OTP's Windows efile_rename uses MOVEFILE_WRITE_THROUGH. File content
        # and metadata are synced before the rename by durable_write/2.
        :ok

      _other ->
        sync_directory(Path.dirname(path))
    end
  end

  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :directory, :raw]) do
      {:ok, device} ->
        sync_result = :file.sync(device)
        close_result = :file.close(device)
        if sync_result == :ok, do: close_result, else: sync_result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp durable_write(path, content) do
    case :file.open(String.to_charlist(path), [:write, :binary, :raw]) do
      {:ok, device} ->
        result =
          case :file.write(device, content) do
            :ok -> :file.sync(device)
            {:error, reason} -> {:error, reason}
          end

        close_result = :file.close(device)
        if result == :ok, do: close_result, else: result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rotate_current_generation(paths) do
    if File.exists?(paths.current) do
      case load_file(paths.current) do
        {:ok, _state} ->
          rotate_valid_generation(paths)

        {:error, current_reason} ->
          remove_invalid_current(paths, current_reason)
      end
    else
      :ok
    end
  end

  defp rotate_valid_generation(paths) do
    with :ok <- remove_if_present(paths.previous) do
      File.rename(paths.current, paths.previous)
    end
  end

  defp remove_invalid_current(paths, current_reason) do
    case File.exists?(paths.previous) do
      true -> remove_invalid_current_with_previous(paths, current_reason)
      false -> {:error, {:invalid_current_generation, current_reason}}
    end
  end

  defp remove_invalid_current_with_previous(paths, current_reason) do
    case load_file(paths.previous) do
      {:ok, _state} ->
        File.rm(paths.current)

      {:error, previous_reason} ->
        {:error, {:invalid_execution_generations, current_reason, previous_reason}}
    end
  end

  defp remove_if_present(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
