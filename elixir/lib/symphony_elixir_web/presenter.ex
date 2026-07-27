defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        payload = %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, []))
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

        held = Enum.map(Map.get(snapshot, :held, []), &terminal_entry_payload/1)
        permanent = Enum.map(Map.get(snapshot, :permanent, []), &terminal_entry_payload/1)

        maybe_put_terminal_collections(payload, held, permanent)

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked),
        host: workspace_host(running, retry, blocked)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: optional_payload(running, &running_issue_payload/1),
      retry: optional_payload(retry, &retry_issue_payload/1),
      blocked: optional_payload(blocked, &blocked_issue_payload/1),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload(recent_event_entry(running, blocked)),
      last_error: last_error(blocked, retry),
      tracked: %{}
    }
    |> maybe_put(:failure_class, encode_atom(entry_attribute(blocked, :failure_class)))
    |> maybe_put(:terminal_state, encode_atom(entry_attribute(blocked, :terminal_state)))
  end

  defp optional_payload(nil, _builder), do: nil
  defp optional_payload(entry, builder), do: builder.(entry)

  defp recent_event_entry(running, _blocked) when not is_nil(running), do: running
  defp recent_event_entry(nil, blocked), do: blocked

  defp last_error(%{error: error}, _retry), do: error
  defp last_error(nil, %{error: error}), do: error
  defp last_error(_blocked, _retry), do: nil

  defp entry_attribute(nil, _key), do: nil
  defp entry_attribute(entry, key), do: Map.get(entry, key)

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _blocked) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _blocked) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, %{terminal_state: :held}), do: "held"
  defp issue_status(nil, nil, %{terminal_state: :permanent}), do: "permanent"
  defp issue_status(nil, nil, _blocked), do: "blocked"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
    |> maybe_put(:transition, encode_atom(Map.get(entry, :transition)))
    |> maybe_put(:attempt, Map.get(entry, :attempt))
    |> maybe_put(:idempotency_key, Map.get(entry, :idempotency_key))
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
    |> maybe_put(:failure_class, encode_atom(Map.get(entry, :failure_class)))
    |> maybe_put(:transition, encode_atom(Map.get(entry, :transition)))
  end

  defp blocked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: Map.get(entry, :state),
      error: Map.get(entry, :error),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: Map.get(entry, :session_id),
      blocked_at: iso8601(Map.get(entry, :blocked_at)),
      last_event: Map.get(entry, :last_codex_event),
      last_message: summarize_message(Map.get(entry, :last_codex_message)),
      last_event_at: iso8601(Map.get(entry, :last_codex_timestamp))
    }
    |> maybe_put(:failure_class, encode_atom(Map.get(entry, :failure_class)))
    |> maybe_put(:terminal_state, encode_atom(Map.get(entry, :terminal_state)))
    |> maybe_put(:transition, encode_atom(Map.get(entry, :transition)))
    |> maybe_put(:attempt, Map.get(entry, :attempt))
    |> maybe_put(:retry_exhausted, Map.get(entry, :retry_exhausted))
    |> maybe_put(:idempotency_key, Map.get(entry, :idempotency_key))
  end

  defp terminal_entry_payload(entry) do
    entry
    |> blocked_entry_payload()
    |> Map.put(:status, encode_atom(Map.get(entry, :terminal_state)))
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
    |> maybe_put(:failure_class, encode_atom(Map.get(retry, :failure_class)))
    |> maybe_put(:transition, encode_atom(Map.get(retry, :transition)))
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: Map.get(blocked, :session_id),
      state: Map.get(blocked, :state),
      error: Map.get(blocked, :error),
      blocked_at: iso8601(Map.get(blocked, :blocked_at)),
      last_event: Map.get(blocked, :last_codex_event),
      last_message: summarize_message(Map.get(blocked, :last_codex_message)),
      last_event_at: iso8601(Map.get(blocked, :last_codex_timestamp))
    }
    |> maybe_put(:failure_class, encode_atom(Map.get(blocked, :failure_class)))
    |> maybe_put(:terminal_state, encode_atom(Map.get(blocked, :terminal_state)))
    |> maybe_put(:transition, encode_atom(Map.get(blocked, :transition)))
    |> maybe_put(:attempt, Map.get(blocked, :attempt))
    |> maybe_put(:retry_exhausted, Map.get(blocked, :retry_exhausted))
    |> maybe_put(:idempotency_key, Map.get(blocked, :idempotency_key))
  end

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    [
      %{
        at: iso8601(Map.get(entry, :last_codex_timestamp)),
        event: Map.get(entry, :last_codex_event),
        message: summarize_message(Map.get(entry, :last_codex_message))
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)

  defp maybe_put_terminal_collections(payload, [], []), do: payload

  defp maybe_put_terminal_collections(payload, held, permanent) do
    counts =
      payload.counts
      |> Map.put(:held, length(held))
      |> Map.put(:permanent, length(permanent))

    payload
    |> Map.put(:counts, counts)
    |> Map.put(:held, held)
    |> Map.put(:permanent, permanent)
  end

  defp encode_atom(nil), do: nil
  defp encode_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_atom(value) when is_binary(value), do: value
  defp encode_atom(_value), do: nil
end
