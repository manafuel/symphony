defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH, Tracker}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @type worker_host :: String.t() | nil
  @type terminal_verification_reason ::
          :hook_failed
          | :hook_task_exit
          | :hook_timeout
          | :issue_identity_changed_after_hook
          | :issue_missing_after_hook
          | :issue_refresh_failed_after_hook
          | :issue_snapshot_incomplete
          | :issue_state_changed_after_hook
          | :issue_updated_after_hook
          | :terminal_workspace_missing
          | {:hook_exit, integer() | :unknown}

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec issue_workspace_path(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def issue_workspace_path(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)
    safe_id = safe_identifier(issue_context.issue_identifier)
    workspace_path_for_issue(safe_id, worker_host)
  end

  @spec existing_issue_workspace(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | :missing | {:error, terminal_verification_reason()}
  def existing_issue_workspace(issue_or_identifier, worker_host \\ nil)

  def existing_issue_workspace(issue_or_identifier, nil) do
    case issue_workspace_path(issue_or_identifier, nil) do
      {:ok, workspace} -> if File.dir?(workspace), do: {:ok, workspace}, else: :missing
      {:error, _reason} -> {:error, :terminal_workspace_missing}
    end
  end

  def existing_issue_workspace(issue_or_identifier, worker_host) when is_binary(worker_host) do
    with {:ok, workspace} <- issue_workspace_path(issue_or_identifier, worker_host) do
      script =
        [
          remote_shell_assign("workspace", workspace),
          "test -d \"$workspace\""
        ]
        |> Enum.join("\n")

      case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
        {:ok, {_output, 0}} -> {:ok, workspace}
        {:ok, {_output, 1}} -> :missing
        {:ok, {_output, _status}} -> {:error, :hook_failed}
        {:error, reason} -> {:error, sanitize_terminal_verification_reason(reason)}
      end
    else
      {:error, _reason} -> {:error, :terminal_workspace_missing}
    end
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_before_terminal_hook(Path.t() | nil, map() | String.t() | nil, worker_host()) ::
          :ok | {:error, terminal_verification_reason()}
  def run_before_terminal_hook(workspace, issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_terminal do
      nil ->
        :ok

      command ->
        case workspace do
          path when is_binary(path) and path != "" ->
            command
            |> run_hook(path, issue_context, "before_terminal", worker_host)
            |> sanitize_terminal_verification_result()

          _ ->
            {:error, :terminal_workspace_missing}
        end
    end
  end

  @spec verify_before_terminal(
          Path.t() | nil,
          map() | String.t() | nil,
          worker_host(),
          ([String.t()] -> term())
        ) :: :ok | {:error, terminal_verification_reason()}
  def verify_before_terminal(
        workspace,
        issue_or_identifier,
        worker_host \\ nil,
        issue_state_fetcher \\ &Tracker.fetch_issue_states_by_ids/1
      )

  def verify_before_terminal(workspace, issue, worker_host, issue_state_fetcher)
      when is_map(issue) and is_function(issue_state_fetcher, 1) do
    case Config.settings!().hooks.before_terminal do
      nil ->
        :ok

      _command ->
        with :ok <- validate_terminal_snapshot(issue),
             :ok <- run_before_terminal_hook(workspace, issue, worker_host),
             :ok <- refetch_terminal_snapshot(issue, issue_state_fetcher) do
          :ok
        else
          {:error, reason} -> {:error, sanitize_terminal_verification_reason(reason)}
          _other -> {:error, :hook_failed}
        end
    end
  end

  def verify_before_terminal(_workspace, _issue, _worker_host, _issue_state_fetcher),
    do: {:error, :issue_snapshot_incomplete}

  @spec confirm_terminal_snapshot(map(), ([String.t()] -> term())) ::
          :ok | {:error, terminal_verification_reason()}
  def confirm_terminal_snapshot(
        issue,
        issue_state_fetcher \\ &Tracker.fetch_issue_states_by_ids/1
      )

  def confirm_terminal_snapshot(issue, issue_state_fetcher)
      when is_map(issue) and is_function(issue_state_fetcher, 1) do
    with :ok <- validate_terminal_snapshot(issue),
         :ok <- refetch_terminal_snapshot(issue, issue_state_fetcher),
         do: :ok
  end

  def confirm_terminal_snapshot(_issue, _issue_state_fetcher),
    do: {:error, :issue_snapshot_incomplete}

  @spec run_before_terminal_hook_for_issue(map() | String.t() | nil, worker_host()) ::
          :ok | {:error, terminal_verification_reason()}
  def run_before_terminal_hook_for_issue(issue_or_identifier, worker_host \\ nil) do
    case issue_workspace_path(issue_or_identifier, worker_host) do
      {:ok, workspace} -> run_before_terminal_hook(workspace, issue_or_identifier, worker_host)
      {:error, _reason} -> {:error, :terminal_workspace_missing}
    end
  end

  @spec sanitize_terminal_verification_reason(term()) :: terminal_verification_reason()
  def sanitize_terminal_verification_reason({:workspace_hook_failed, "before_terminal", status}) do
    {:hook_exit, if(is_integer(status), do: status, else: :unknown)}
  end

  def sanitize_terminal_verification_reason({
        :workspace_hook_failed,
        "before_terminal",
        status,
        _output
      }) do
    {:hook_exit, if(is_integer(status), do: status, else: :unknown)}
  end

  def sanitize_terminal_verification_reason({:workspace_hook_timeout, _hook_name, _timeout_ms}),
    do: :hook_timeout

  def sanitize_terminal_verification_reason({:workspace_hook_task_exit, _hook_name}),
    do: :hook_task_exit

  def sanitize_terminal_verification_reason(reason)
      when reason in [
             :hook_failed,
             :hook_task_exit,
             :hook_timeout,
             :issue_identity_changed_after_hook,
             :issue_missing_after_hook,
             :issue_refresh_failed_after_hook,
             :issue_snapshot_incomplete,
             :issue_state_changed_after_hook,
             :issue_updated_after_hook,
             :terminal_workspace_missing
           ],
      do: reason

  def sanitize_terminal_verification_reason(_reason), do: :hook_failed

  defp sanitize_terminal_verification_result(:ok), do: :ok

  defp sanitize_terminal_verification_result({:error, reason}),
    do: {:error, sanitize_terminal_verification_reason(reason)}

  defp sanitize_terminal_verification_result(_result), do: {:error, :hook_failed}

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    case run_with_timeout(
           fn ->
             System.cmd("sh", ["-lc", command],
               cd: workspace,
               stderr_to_stdout: true,
               env: hook_environment(issue_context)
             )
           end,
           timeout_ms
         ) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:exit, _reason} ->
        {:error, {:workspace_hook_task_exit, hook_name}}

      :timeout ->
        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    exports =
      issue_context
      |> hook_environment()
      |> Enum.map_join("\n", fn {name, value} -> "export #{name}=#{shell_escape(value)}" end)

    remote_command =
      [
        remote_shell_assign("workspace", workspace),
        "cd \"$workspace\" && (",
        exports,
        command,
        ")"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, remote_command, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({_output, status}, workspace, issue_context, "before_terminal") do
    Logger.warning("Workspace hook failed hook=before_terminal #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=omitted")

    {:error, {:workspace_hook_failed, "before_terminal", status}}
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    case run_with_timeout(
           fn -> SSH.run(worker_host, script, stderr_to_stdout: true) end,
           timeout_ms
         ) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        {:error, {:workspace_hook_task_exit, "remote_command"}}

      :timeout ->
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp run_with_timeout(fun, timeout_ms)
       when is_function(fun, 0) and is_integer(timeout_ms) and timeout_ms > 0 do
    caller = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(caller, {result_ref, fun.()})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, result}

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        {:exit, :task_failed}
    after
      timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          100 -> Process.demonitor(monitor_ref, [:flush])
        end

        receive do
          {^result_ref, _late_result} -> :ok
        after
          0 -> :ok
        end

        :timeout
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier} = issue) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      issue_title: Map.get(issue, :title) || "",
      issue_description: Map.get(issue, :description) || "",
      issue_labels: issue_labels(Map.get(issue, :labels)),
      issue_state: Map.get(issue, :state) || "",
      issue_updated_at: issue_updated_at(Map.get(issue, :updated_at))
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      issue_title: "",
      issue_description: "",
      issue_labels: "",
      issue_state: "",
      issue_updated_at: ""
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      issue_title: "",
      issue_description: "",
      issue_labels: "",
      issue_state: "",
      issue_updated_at: ""
    }
  end

  defp hook_environment(issue_context) do
    [
      {"SYMPHONY_ISSUE_ID", to_string(issue_context.issue_id || "")},
      {"SYMPHONY_ISSUE_IDENTIFIER", to_string(issue_context.issue_identifier || "issue")},
      {"SYMPHONY_ISSUE_TITLE", to_string(issue_context.issue_title || "")},
      {"SYMPHONY_ISSUE_DESCRIPTION", to_string(issue_context.issue_description || "")},
      {"SYMPHONY_ISSUE_LABELS", to_string(issue_context.issue_labels || "")},
      {"SYMPHONY_ISSUE_STATE", to_string(issue_context.issue_state || "")},
      {"SYMPHONY_ISSUE_UPDATED_AT", to_string(issue_context.issue_updated_at || "")}
    ]
  end

  defp issue_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(&to_string/1)
    |> Enum.join(",")
  end

  defp issue_labels(_labels), do: ""

  defp issue_updated_at(%DateTime{} = updated_at), do: DateTime.to_iso8601(updated_at)
  defp issue_updated_at(updated_at) when is_binary(updated_at), do: updated_at
  defp issue_updated_at(_updated_at), do: ""

  defp validate_terminal_snapshot(%{
         id: issue_id,
         state: issue_state,
         updated_at: %DateTime{}
       })
       when is_binary(issue_id) and issue_id != "" and is_binary(issue_state) and issue_state != "",
       do: :ok

  defp validate_terminal_snapshot(_issue), do: {:error, :issue_snapshot_incomplete}

  defp refetch_terminal_snapshot(%{id: issue_id} = issue, issue_state_fetcher) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [refreshed_issue]} when is_map(refreshed_issue) ->
        compare_terminal_snapshots(issue, refreshed_issue)

      {:ok, []} ->
        {:error, :issue_missing_after_hook}

      {:ok, _issues} ->
        {:error, :issue_identity_changed_after_hook}

      {:error, _reason} ->
        {:error, :issue_refresh_failed_after_hook}

      _other ->
        {:error, :issue_refresh_failed_after_hook}
    end
  rescue
    _error -> {:error, :issue_refresh_failed_after_hook}
  catch
    _kind, _reason -> {:error, :issue_refresh_failed_after_hook}
  end

  defp compare_terminal_snapshots(
         %{id: issue_id, state: issue_state, updated_at: %DateTime{} = updated_at},
         %{
           id: refreshed_id,
           state: refreshed_state,
           updated_at: %DateTime{} = refreshed_updated_at
         }
       ) do
    cond do
      refreshed_id !== issue_id ->
        {:error, :issue_identity_changed_after_hook}

      DateTime.compare(refreshed_updated_at, updated_at) != :eq ->
        {:error, :issue_updated_after_hook}

      refreshed_state !== issue_state ->
        {:error, :issue_state_changed_after_hook}

      true ->
        :ok
    end
  end

  defp compare_terminal_snapshots(_issue, _refreshed_issue),
    do: {:error, :issue_snapshot_incomplete}

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
