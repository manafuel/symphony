defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @type worker_host :: String.t() | nil

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

  @spec remove_terminal_issue_workspaces(map()) :: :ok | {:error, term()}
  def remove_terminal_issue_workspaces(issue), do: remove_terminal_issue_workspaces(issue, nil)

  @spec remove_terminal_issue_workspaces(map(), worker_host()) :: :ok | {:error, term()}
  def remove_terminal_issue_workspaces(issue, worker_host)
      when is_map(issue) and is_binary(worker_host) do
    issue_context = issue_context(issue)
    safe_id = safe_identifier(issue_context.issue_identifier)

    with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host) do
      remove_terminal_issue_workspace(workspace, issue, worker_host)
    end
  end

  def remove_terminal_issue_workspaces(issue, nil) when is_map(issue) do
    issue_context = issue_context(issue)
    safe_id = safe_identifier(issue_context.issue_identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        remove_terminal_issue_workspace_for_safe_id(safe_id, issue, nil)

      worker_hosts ->
        Enum.reduce_while(worker_hosts, :ok, fn worker_host, :ok ->
          reduce_terminal_workspace_cleanup(worker_host, safe_id, issue)
        end)
    end
  end

  def remove_terminal_issue_workspaces(_issue, _worker_host) do
    {:error, :invalid_terminal_issue}
  end

  defp remove_terminal_issue_workspace_for_safe_id(safe_id, issue, worker_host) do
    with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host) do
      remove_terminal_issue_workspace(workspace, issue, worker_host)
    end
  end

  defp reduce_terminal_workspace_cleanup(worker_host, safe_id, issue) do
    case remove_terminal_issue_workspace_for_safe_id(safe_id, issue, worker_host) do
      :ok ->
        {:cont, :ok}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  @spec remove_terminal_issue_workspace(Path.t(), map()) :: :ok | {:error, term()}
  def remove_terminal_issue_workspace(workspace, issue),
    do: remove_terminal_issue_workspace(workspace, issue, nil)

  @spec remove_terminal_issue_workspace(Path.t(), map(), worker_host()) :: :ok | {:error, term()}
  def remove_terminal_issue_workspace(workspace, issue, worker_host)
      when is_binary(workspace) and is_map(issue) do
    maybe_remove_terminal_workspace(workspace, issue_context(issue), worker_host)
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

  defp maybe_remove_terminal_workspace(workspace, issue_context, worker_host) do
    with :ok <- validate_terminal_workspace_path(workspace, worker_host) do
      workspace
      |> maybe_run_before_terminal_hook(issue_context, worker_host)
      |> remove_terminal_workspace_after_hook(workspace, worker_host)
    end
  end

  defp remove_terminal_workspace_after_hook(:missing, _workspace, _worker_host), do: :ok

  defp remove_terminal_workspace_after_hook(:ok, workspace, worker_host) do
    case remove(workspace, worker_host) do
      {:ok, _removed_paths} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  defp remove_terminal_workspace_after_hook(
         {:error, _reason} = error,
         _workspace,
         _worker_host
       ),
       do: error

  defp validate_terminal_workspace_path(workspace, nil) do
    if File.exists?(workspace), do: validate_workspace_path(workspace, nil), else: :ok
  end

  defp validate_terminal_workspace_path(workspace, worker_host)
       when is_binary(worker_host) do
    validate_workspace_path(workspace, worker_host)
  end

  defp maybe_run_before_terminal_hook(workspace, issue_context, nil) do
    case Config.settings!().hooks.before_terminal do
      nil ->
        :ok

      command ->
        if File.dir?(workspace) do
          run_hook(command, workspace, issue_context, "before_terminal", nil)
        else
          :missing
        end
    end
  end

  defp maybe_run_before_terminal_hook(workspace, issue_context, worker_host)
       when is_binary(worker_host) do
    case Config.settings!().hooks.before_terminal do
      nil ->
        :ok

      command ->
        run_remote_before_terminal_hook(command, workspace, issue_context, worker_host)
    end
  end

  defp run_remote_before_terminal_hook(command, workspace, issue_context, worker_host) do
    case probe_remote_terminal_workspace(workspace, worker_host) do
      :present ->
        run_hook(command, workspace, issue_context, "before_terminal", worker_host)

      :missing ->
        :missing

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec classify_remote_terminal_workspace_probe_for_test(term()) ::
          :present | :missing | {:error, term()}
  def classify_remote_terminal_workspace_probe_for_test(result) do
    classify_remote_terminal_workspace_probe(result)
  end

  defp probe_remote_terminal_workspace(workspace, worker_host) do
    script =
      [
        remote_shell_assign("workspace", workspace),
        "test -d \"$workspace\""
      ]
      |> Enum.join("\n")

    worker_host
    |> run_remote_command(script, Config.settings!().hooks.timeout_ms)
    |> classify_remote_terminal_workspace_probe()
  end

  defp classify_remote_terminal_workspace_probe(result) do
    case result do
      {:ok, {_output, 0}} ->
        :present

      {:ok, {_output, 1}} ->
        :missing

      {:ok, {_output, status}} ->
        {:error, {:remote_workspace_probe_failed, status}}

      {:error, reason} ->
        {:error, {:remote_workspace_probe_failed, terminal_probe_error_code(reason)}}
    end
  end

  defp terminal_probe_error_code({type, _rest}) when is_atom(type), do: type
  defp terminal_probe_error_code({type, _left, _right}) when is_atom(type), do: type
  defp terminal_probe_error_code(type) when is_atom(type), do: type
  defp terminal_probe_error_code(_reason), do: :unknown

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
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

    task =
      Task.async(fn ->
        {shell, args} = local_shell_command(command)
        System.cmd(shell, args, cd: workspace, stderr_to_stdout: true, env: hook_environment(issue_context))
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}

      {:exit, reason} ->
        {:error, {:workspace_hook_execution_failed, hook_name, reason}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    script =
      [
        "cd #{shell_escape(workspace)}",
        hook_environment_exports(issue_context),
        command
      ]
      |> List.flatten()
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp local_shell_command(command) do
    case :os.type() do
      {:win32, _name} ->
        git_bash =
          case System.find_executable("git.exe") do
            nil -> nil
            git -> git |> Path.dirname() |> Path.join("../bin/bash.exe") |> Path.expand()
          end

        if is_binary(git_bash) and File.regular?(git_bash) do
          {git_bash, ["-lc", command]}
        else
          shell = System.find_executable("powershell.exe") || "powershell.exe"

          wrapped_command = """
          & {
          #{command}
          }
          if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
          if (-not $?) { exit 1 }
          """

          {shell,
           [
             "-NoLogo",
             "-NoProfile",
             "-NonInteractive",
             "-ExecutionPolicy",
             "Bypass",
             "-Command",
             wrapped_command
           ]}
        end

      _ ->
        {"sh", ["-lc", command]}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    output_bytes = output |> IO.iodata_to_binary() |> byte_size()

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output_bytes=#{output_bytes} output_redacted=true")

    {:error, {:workspace_hook_failed, hook_name, status}}
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
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(issue) when is_map(issue) do
    identifier = hook_string(issue_value(issue, :identifier))

    %{
      issue_id: hook_string(issue_value(issue, :id)),
      issue_identifier: if(identifier == "", do: "issue", else: identifier),
      issue_title: hook_string(issue_value(issue, :title)),
      issue_description: hook_string(issue_value(issue, :description)),
      issue_labels: hook_labels(issue_value(issue, :labels)),
      issue_state: hook_string(issue_value(issue, :state)),
      issue_updated_at: hook_datetime(issue_value(issue, :updated_at))
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      issue_title: "",
      issue_description: "",
      issue_labels: [],
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
      issue_labels: [],
      issue_state: "",
      issue_updated_at: ""
    }
  end

  defp issue_value(issue, key) when is_map(issue) and is_atom(key) do
    Map.get(issue, key) || Map.get(issue, Atom.to_string(key))
  end

  defp hook_labels(labels) when is_list(labels) do
    Enum.flat_map(labels, fn
      label when is_binary(label) -> [label]
      %{name: name} when is_binary(name) -> [name]
      %{"name" => name} when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp hook_labels(_labels), do: []

  defp hook_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp hook_datetime(value), do: hook_string(value)

  defp hook_string(nil), do: ""
  defp hook_string(value) when is_binary(value), do: value
  defp hook_string(value), do: to_string(value)

  defp hook_environment(issue_context) do
    labels = Map.get(issue_context, :issue_labels, [])

    [
      {"SYMPHONY_ISSUE_ID", hook_string(Map.get(issue_context, :issue_id))},
      {"SYMPHONY_ISSUE_IDENTIFIER", hook_string(Map.get(issue_context, :issue_identifier))},
      {"SYMPHONY_ISSUE_TITLE", hook_string(Map.get(issue_context, :issue_title))},
      {"SYMPHONY_ISSUE_DESCRIPTION", hook_string(Map.get(issue_context, :issue_description))},
      {"SYMPHONY_ISSUE_LABELS", Enum.join(labels, ",")},
      {"SYMPHONY_ISSUE_STATE", hook_string(Map.get(issue_context, :issue_state))},
      {"SYMPHONY_ISSUE_UPDATED_AT", hook_string(Map.get(issue_context, :issue_updated_at))}
    ]
  end

  defp hook_environment_exports(issue_context) do
    Enum.map(hook_environment(issue_context), fn {name, value} ->
      "export #{name}=#{shell_escape(value)}"
    end)
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier}"
  end
end
