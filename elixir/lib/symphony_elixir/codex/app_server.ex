defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Config, PathSafety, SSH}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @max_dynamic_tool_output_chars 8_000
  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."
  @issue_product_repositories ~w(development one replicator bob)
  @manafuel_developer_instructions """
  MANAfuel Symphony runs use the Windows Codex app-server stdio client. Use hosted sandboxed `shell_command` for all local command work. Use `write_run_artifact` only for bounded non-secret evidence under the current issue workspace `runs/` directory when an existing checked-in script does not generate the artifact. Keep shell calls simple: one read, search, status, test, git, or existing script invocation. Do not send inline PowerShell scripts, loops, here-strings, direct PowerShell read/navigation cmdlets or aliases (Get-ChildItem, Get-Content, Select-Object, Set-Location, dir, ls, cat, type, cd, pwd), filesystem generation, shell redirection file writes, inline JSON payloads, or multi-step orchestration. Use native executables, existing checked-in scripts with short file/path arguments, `write_run_artifact` for issue-local run evidence, or apply_patch for repository edits. Issue at most one hosted `shell_command` tool call per assistant turn, and do not move a ticket to Human Review solely because the current turn's hosted shell budget is exhausted.

  The harness has already applied packaged MANAfuel skill orientation through WORKFLOW.md and the injected issue runtime context. Do not use hosted shell_command to read packaged SKILL.md files from the user plugin cache, including .codex/plugins/cache/**/skills/*/SKILL.md and manafuel-codex:* skill files. Use the provided WORKFLOW.md contract, issue context, and repository files instead. Task-specific source files, tests, status commands, and existing scripts may still be read or executed when needed.

  The current cwd is a scratch Symphony issue workspace. Before reading or editing product repository files, create or select an issue-local normal clone inside this workspace, based on current `origin/main`, and run product file reads from that clone. Do not use a linked Git worktree or a shared coordination checkout as the ticket implementation repository. Do not run broad repository discovery from the scratch workspace, including `rg --files`, `git status`, or `git worktree list`; inspect only the issue-local clone.
  """

  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host) do
      metadata = port_metadata(port, worker_host)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host),
           {:ok, thread_id} <- do_start_session(port, expanded_workspace, session_policies) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           # `never` suppresses prompts; it is not authorization to cross a
           # sandbox or human-in-the-loop boundary.
           auto_approve_requests: false,
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           workspace: expanded_workspace,
           worker_host: worker_host
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments, workspace: workspace)
      end)

    case start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        case await_turn_completion(port, on_message, tool_executor, auto_approve_requests, workspace) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil) do
    with {:ok, executable, args} <- local_port_command(),
         {:ok, port_executable, port_args} <- local_port_spawn_command(executable, args, workspace) do
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(port_executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: Enum.map(port_args, &String.to_charlist/1),
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_port(workspace, worker_host) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp remote_launch_command(workspace) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      "exec #{Config.settings!().codex.command}"
    ]
    |> Enum.join(" && ")
  end

  defp local_port_command do
    command = Config.settings!().codex.command

    case :os.type() do
      {:win32, _} -> windows_port_command(command)
      _ -> bash_port_command(command)
    end
  end

  defp bash_port_command(command) do
    case System.find_executable("bash") do
      nil -> {:error, :bash_not_found}
      executable -> {:ok, executable, ["-lc", command]}
    end
  end

  defp windows_port_command(command) do
    case command_tokens(command) do
      [] ->
        {:error, :empty_codex_command}

      [executable | args] ->
        case resolve_windows_executable(executable) do
          nil -> {:error, {:windows_executable_not_found, executable}}
          resolved -> {:ok, resolved, args}
        end
    end
  end

  defp resolve_windows_executable(executable) do
    cond do
      File.exists?(executable) ->
        executable

      String.match?(executable, ~r{^[A-Za-z]:[\\/]}) ->
        nil

      true ->
        System.find_executable(executable)
    end
  end

  @doc false
  @spec local_port_spawn_command_for_test(String.t(), [String.t()], Path.t()) ::
          {:ok, String.t(), [String.t()]} | {:error, term()}
  def local_port_spawn_command_for_test(executable, args, workspace) do
    local_port_spawn_command(executable, args, workspace)
  end

  defp local_port_spawn_command(executable, args, workspace) do
    with {:ok, port_executable, port_args} <- local_port_base_spawn_command(executable, args) do
      windows_hidden_stdio_spawn_command(port_executable, port_args, workspace)
    end
  end

  defp local_port_base_spawn_command(executable, args) do
    cond do
      windows_batch_script?(executable) ->
        {:ok, windows_cmd_executable(), ["/d", "/c", executable | args]}

      windows_extensionless_script?(executable) ->
        case git_bash_executable() do
          nil -> {:error, {:git_bash_not_found, executable}}
          bash -> {:ok, bash, [executable | args]}
        end

      true ->
        {:ok, executable, args}
    end
  end

  defp windows_hidden_stdio_spawn_command(executable, args, workspace) do
    cond do
      not match?({:win32, _}, :os.type()) ->
        {:ok, executable, args}

      hidden_stdio_launcher_disabled?() ->
        {:ok, executable, args}

      hidden_stdio_launcher_executable?(executable) ->
        {:ok, executable, args}

      true ->
        case DynamicTool.hidden_stdio_launcher_executable(workspace) do
          nil -> {:ok, executable, args}
          launcher -> {:ok, launcher, hidden_stdio_launcher_args(workspace, executable, args)}
        end
    end
  end

  defp hidden_stdio_launcher_args(workspace, executable, args) do
    cwd_args =
      if is_binary(workspace) and String.trim(workspace) != "" do
        ["--cwd", workspace]
      else
        []
      end

    cwd_args ++ ["--", executable | args]
  end

  defp hidden_stdio_launcher_disabled? do
    case System.get_env("SYMPHONY_DISABLE_CODEX_HIDDEN_STDIO_LAUNCHER") do
      value when is_binary(value) ->
        String.downcase(String.trim(value)) in ["1", "true", "yes"]

      _ ->
        false
    end
  end

  defp hidden_stdio_launcher_executable?(path) when is_binary(path) do
    path
    |> Path.basename()
    |> String.downcase()
    |> Kernel.==("codex-hidden-stdio-launcher.exe")
  end

  defp hidden_stdio_launcher_executable?(_path), do: false

  defp windows_batch_script?(path) when is_binary(path) do
    match?({:win32, _}, :os.type()) and String.downcase(Path.extname(path)) in [".cmd", ".bat"]
  end

  defp windows_extensionless_script?(path) when is_binary(path) do
    match?({:win32, _}, :os.type()) and File.regular?(path) and Path.extname(path) == ""
  end

  defp git_bash_executable do
    [
      "C:/Program Files/Git/bin/bash.exe",
      "C:/Program Files/Git/usr/bin/bash.exe",
      System.find_executable("bash")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&windows_system_bash?/1)
    |> Enum.find(&File.exists?/1)
  end

  defp windows_system_bash?(path) when is_binary(path) do
    path
    |> String.replace("\\", "/")
    |> String.downcase()
    |> String.contains?("/windows/system32/bash.exe")
  end

  defp windows_cmd_executable do
    System.find_executable("cmd.exe") || "C:/Windows/System32/cmd.exe"
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp do_start_session(port, workspace, session_policies) do
    case send_initialize(port) do
      :ok -> start_thread(port, workspace, session_policies)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec thread_start_payload(String.t(), %{approval_policy: term(), thread_sandbox: term()}) :: map()
  def thread_start_payload(workspace, %{approval_policy: approval_policy, thread_sandbox: thread_sandbox}) do
    %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "developerInstructions" => @manafuel_developer_instructions,
        "dynamicTools" => DynamicTool.tool_specs()
      }
    }
  end

  defp start_thread(port, workspace, session_policies) do
    send_message(port, thread_start_payload(workspace, session_policies))

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests, workspace) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests,
      workspace
    )
  end

  defp receive_loop(
         port,
         on_message,
         timeout_ms,
         pending_line,
         tool_executor,
         auto_approve_requests,
         workspace
       ) do
    receive_loop(
      port,
      on_message,
      timeout_ms,
      pending_line,
      tool_executor,
      auto_approve_requests,
      workspace,
      :turn
    )
  end

  defp receive_loop(
         port,
         on_message,
         timeout_ms,
         pending_line,
         tool_executor,
         auto_approve_requests,
         workspace,
         timeout_context
       ) do
    receive_timeout_ms = receive_timeout_ms(timeout_ms, timeout_context)

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)

        handle_incoming(
          port,
          on_message,
          complete_line,
          timeout_ms,
          tool_executor,
          auto_approve_requests,
          workspace,
          timeout_context
        )

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests,
          workspace,
          timeout_context
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      receive_timeout_ms ->
        timeout_error(timeout_context, receive_timeout_ms)
    end
  end

  defp receive_timeout_ms(turn_timeout_ms, :command_execution) do
    command_timeout_ms(turn_timeout_ms)
  end

  defp receive_timeout_ms(turn_timeout_ms, _timeout_context), do: turn_timeout_ms

  defp command_timeout_ms(turn_timeout_ms) do
    case Config.settings!().codex.stall_timeout_ms do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        min(timeout_ms, turn_timeout_ms)

      _ ->
        turn_timeout_ms
    end
  end

  defp timeout_error(:command_execution, timeout_ms),
    do: {:error, {:command_execution_timeout, timeout_ms}}

  defp timeout_error(_timeout_context, _timeout_ms), do: {:error, :turn_timeout}

  defp handle_incoming(
         port,
         on_message,
         data,
         timeout_ms,
         tool_executor,
         auto_approve_requests,
         workspace,
         timeout_context
       ) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        next_timeout_context = next_timeout_context(payload, timeout_context)

        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          timeout_ms,
          tool_executor,
          auto_approve_requests,
          workspace,
          next_timeout_context
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(
          port,
          on_message,
          timeout_ms,
          "",
          tool_executor,
          auto_approve_requests,
          workspace,
          timeout_context
        )

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(
          port,
          on_message,
          timeout_ms,
          "",
          tool_executor,
          auto_approve_requests,
          workspace,
          timeout_context
        )
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         auto_approve_requests,
         workspace,
         timeout_context
       ) do
    metadata = metadata_from_message(port, payload)

    case maybe_block_unsafe_command(payload, workspace) do
      {:block, reason} ->
        emit_message(
          on_message,
          :unsafe_command_blocked,
          %{payload: payload, raw: payload_string, reason: reason},
          metadata
        )

        {:error, {:unsafe_command_blocked, reason, payload}}

      :ok ->
        case maybe_handle_approval_request(
               port,
               method,
               payload,
               payload_string,
               on_message,
               metadata,
               tool_executor,
               auto_approve_requests
             ) do
          :input_required ->
            emit_message(
              on_message,
              :turn_input_required,
              %{payload: payload, raw: payload_string},
              metadata
            )

            {:error, {:turn_input_required, payload}}

          :approved ->
            receive_loop(
              port,
              on_message,
              timeout_ms,
              "",
              tool_executor,
              auto_approve_requests,
              workspace,
              timeout_context
            )

          :approval_required ->
            emit_message(
              on_message,
              :approval_required,
              %{payload: payload, raw: payload_string},
              metadata
            )

            {:error, {:approval_required, payload}}

          :unhandled ->
            if needs_input?(method, payload) do
              emit_message(
                on_message,
                :turn_input_required,
                %{payload: payload, raw: payload_string},
                metadata
              )

              {:error, {:turn_input_required, payload}}
            else
              emit_message(
                on_message,
                :notification,
                %{
                  payload: payload,
                  raw: payload_string
                },
                metadata
              )

              Logger.debug("Codex notification: #{inspect(method)}")

              receive_loop(
                port,
                on_message,
                timeout_ms,
                "",
                tool_executor,
                auto_approve_requests,
                workspace,
                timeout_context
              )
            end
        end
    end
  end

  defp next_timeout_context(payload, current_context) do
    cond do
      command_execution_completed_message?(payload) -> :turn
      command_execution_activity_message?(payload) -> :command_execution
      true -> current_context
    end
  end

  defp command_execution_activity_message?(%{"method" => "item/commandExecution/requestApproval", "params" => params})
       when is_map(params),
       do: true

  defp command_execution_activity_message?(%{"method" => method})
       when method in ["item/commandExecution/outputDelta", "item/commandExecution/output"] do
    true
  end

  defp command_execution_activity_message?(%{
         "method" => "item/started",
         "params" => %{"item" => %{"type" => "commandExecution"}}
       }),
       do: true

  defp command_execution_activity_message?(_payload), do: false

  defp command_execution_completed_message?(%{
         "method" => method,
         "params" => %{"item" => %{"type" => "commandExecution"}}
       })
       when method in ["item/completed", "item/failed"],
       do: true

  defp command_execution_completed_message?(_payload), do: false

  defp maybe_block_unsafe_command(payload, workspace) do
    payload
    |> command_execution_contexts()
    |> Enum.find_value(:ok, fn context ->
      case unsafe_command_reason(context, workspace) do
        nil -> false
        reason -> {:block, reason}
      end
    end)
  end

  @doc false
  @spec unsafe_command_block_reason_for_test(map()) :: String.t() | nil
  def unsafe_command_block_reason_for_test(payload) do
    unsafe_command_block_reason_for_test(payload, nil)
  end

  @doc false
  @spec unsafe_command_block_reason_for_test(map(), Path.t() | nil) :: String.t() | nil
  def unsafe_command_block_reason_for_test(payload, workspace) do
    case maybe_block_unsafe_command(payload, workspace) do
      {:block, reason} -> reason
      :ok -> nil
    end
  end

  @doc false
  @spec normalize_dynamic_tool_result_for_test(map()) :: map()
  def normalize_dynamic_tool_result_for_test(result) do
    normalize_dynamic_tool_result(result)
  end

  defp command_execution_contexts(%{"method" => "item/commandExecution/requestApproval", "params" => params})
       when is_map(params) do
    [
      %{
        command: Map.get(params, "command"),
        cwd: Map.get(params, "cwd"),
        command_actions: []
      }
    ]
  end

  defp command_execution_contexts(%{"params" => %{"item" => %{"type" => "commandExecution"} = item}}) do
    [
      %{
        command: Map.get(item, "command"),
        cwd: Map.get(item, "cwd"),
        command_actions: command_action_strings(Map.get(item, "commandActions"))
      }
    ]
  end

  defp command_execution_contexts(_payload), do: []

  defp command_action_strings(actions) when is_list(actions) do
    actions
    |> Enum.flat_map(fn
      %{"command" => command} when is_binary(command) -> [command]
      _ -> []
    end)
  end

  defp command_action_strings(_actions), do: []

  defp unsafe_command_reason(
         %{command: command, cwd: cwd, command_actions: command_actions},
         workspace
       ) do
    [command, cwd | command_actions]
    |> Enum.find_value(fn value ->
      case unsafe_absolute_command_reason(value) do
        nil -> false
        reason -> reason
      end
    end) ||
      unsafe_legacy_harness_poller_reason(command) ||
      Enum.find_value(command_actions, fn action -> unsafe_legacy_harness_poller_reason(action) end) ||
      unsafe_inline_shell_payload_reason(command) ||
      Enum.find_value(command_actions, fn action -> unsafe_inline_shell_payload_reason(action) end) ||
      unsafe_hosted_shell_generation_reason(command) ||
      Enum.find_value(command_actions, fn action -> unsafe_hosted_shell_generation_reason(action) end) ||
      unsafe_relative_command_reason(command, cwd) ||
      Enum.find_value(command_actions, fn action -> unsafe_relative_command_reason(action, cwd) end) ||
      unsafe_direct_powershell_cmdlet_reason(command) ||
      Enum.find_value(command_actions, fn action -> unsafe_direct_powershell_cmdlet_reason(action) end) ||
      unsafe_repository_discovery_reason([command | command_actions], cwd, workspace)
  end

  defp unsafe_command_reason(_context, _workspace), do: nil

  defp unsafe_absolute_command_reason(command) when is_binary(command) do
    normalized = String.downcase(String.replace(command, "\\", "/"))

    cond do
      Regex.match?(~r{/\.codex/plugins/cache/.*/skills/.*/skill\.md}, normalized) ->
        "packaged skill file read through hosted shell_command"

      Regex.match?(~r{/development/(one|replicator|bob)(?:/|$)}, normalized) ->
        "product coordination-checkout path used instead of a named product worktree"

      Regex.match?(~r{/development/tools/discord-iac(?:/|$)}, normalized) ->
        "product coordination-checkout path used instead of a named product worktree"

      true ->
        nil
    end
  end

  defp unsafe_absolute_command_reason(_command), do: nil

  defp unsafe_legacy_harness_poller_reason(command) when is_binary(command) do
    normalized =
      command
      |> String.replace("\\", "/")
      |> String.downcase()

    if String.contains?(normalized, "codex-kanban-linear-poll.ps1") do
      "legacy kanban poller invoked from hosted child session"
    else
      nil
    end
  end

  defp unsafe_legacy_harness_poller_reason(_command), do: nil

  defp unsafe_inline_shell_payload_reason(command) when is_binary(command) do
    normalized =
      command
      |> String.trim()
      |> String.downcase()

    inline_ticket_text =
      Regex.match?(~r/(^|\s)--ticket-text(?:\s|=)/, normalized)

    inline_json_literal =
      Regex.match?(~r/(^|\s)--(?:ticket-text|input|payload|json)(?:\s|=)['"]?\s*[\{\[]/, normalized)

    hosted_script =
      Regex.match?(~r/(^|\s)(?:\.[\\\/]|scripts[\\\/]|[\w:][^\s]*[\\\/])?[^\s'"]+\.ps1\b/, normalized) ||
        Regex.match?(~r/\b(?:powershell|pwsh)(?:\.exe)?\b/, normalized)

    if hosted_script && (inline_ticket_text || inline_json_literal) do
      "inline structured payload passed through hosted shell_command"
    else
      nil
    end
  end

  defp unsafe_inline_shell_payload_reason(_command), do: nil

  defp unsafe_direct_powershell_cmdlet_reason(command) when is_binary(command) do
    normalized =
      command
      |> String.trim()
      |> String.downcase()

    powershell_invocation =
      Regex.match?(
        ~r/\b(?:powershell|pwsh)(?:\.exe)?\b/,
        normalized
      )

    command_without_quoted_strings =
      if powershell_invocation do
        Regex.replace(~r/'[^']*'/, normalized, "")
      else
        Regex.replace(~r/'[^']*'|"[^"]*"/, normalized, "")
      end

    direct_cmdlet =
      Regex.match?(
        ~r/(^|[;&|\r\n])\s*(?:get-childitem|get-content|select-object|set-location|get-location|gci|gc|dir|ls|cat|type|cd|pwd)\b/,
        command_without_quoted_strings
      )

    wrapped_cmdlet =
      powershell_invocation &&
        (Regex.match?(
           ~r/\s-(?:command|c)\s+['"]?(?:&\s*)?(?:\{\s*)?(?:get-childitem|get-content|select-object|set-location|get-location|gci|gc|dir|ls|cat|type|cd|pwd)\b/,
           normalized
         ) ||
           single_quoted_powershell_cmdlet?(normalized))

    if direct_cmdlet || wrapped_cmdlet do
      "direct PowerShell cmdlet used through hosted shell_command"
    else
      nil
    end
  end

  defp unsafe_direct_powershell_cmdlet_reason(_command), do: nil

  defp single_quoted_powershell_cmdlet?(normalized) when is_binary(normalized) do
    ~r/\s-(?:command|c)\s+'([^']*)'/
    |> Regex.scan(normalized, capture: :all_but_first)
    |> List.flatten()
    |> Enum.any?(fn script ->
      Regex.match?(
        ~r/(^|[;&|\r\n])\s*(?:get-childitem|get-content|select-object|set-location|get-location|gci|gc|dir|ls|cat|type|cd|pwd)\b/,
        script
      )
    end)
  end

  defp single_quoted_powershell_cmdlet?(_normalized), do: false

  defp unsafe_hosted_shell_generation_reason(command) when is_binary(command) do
    normalized =
      command
      |> String.trim()
      |> String.downcase()

    powershell_invocation =
      Regex.match?(
        ~r/\b(?:powershell|pwsh)(?:\.exe)?\b/,
        normalized
      )

    command_without_quoted_strings =
      if powershell_invocation do
        Regex.replace(~r/'[^']*'/, normalized, "")
      else
        Regex.replace(~r/'[^']*'|"[^"]*"/, normalized, "")
      end

    direct_generation =
      Regex.match?(
        ~r/(^|[;&|{(\r\n])\s*(?:new-item|set-content|add-content|out-file|mkdir|md|ni|sc|ac)\b/,
        command_without_quoted_strings
      )

    generation_token =
      Regex.match?(
        ~r/(^|[;&|{(\r\n])\s*(?:new-item|set-content|add-content|out-file|mkdir|md|ni|sc|ac)\b/,
        command_without_quoted_strings
      ) ||
        Regex.match?(
          ~r/\s-(?:command|c)\s+['"]?(?:&\s*)?(?:\{\s*)?(?:new-item|set-content|add-content|out-file|mkdir|md|ni|sc|ac)\b/,
          command_without_quoted_strings
        ) ||
        single_quoted_powershell_generation?(normalized)

    redirection_source = command_without_quoted_strings

    redirection_generation =
      Regex.match?(~r/(^|[\s;&|{(\r\n])(?:\d+)?>{1,2}(?!&)\s*\S/, redirection_source)

    wrapped_generation = powershell_invocation && generation_token

    if direct_generation || wrapped_generation || redirection_generation do
      "PowerShell filesystem-generation command used through hosted shell_command"
    else
      nil
    end
  end

  defp unsafe_hosted_shell_generation_reason(_command), do: nil

  defp unsafe_repository_discovery_reason(commands, cwd, workspace)
       when is_list(commands) and is_binary(cwd) do
    candidates =
      commands
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(fn command ->
        command
        |> String.trim()
        |> String.replace("\\", "/")
        |> String.downcase()
        |> shell_command_candidates()
      end)
      |> Enum.uniq()

    cond do
      Enum.any?(candidates, &git_worktree_list_command?/1) ->
        "scratch Symphony workspace git worktree discovery is not allowed"

      not Enum.any?(candidates, &repository_discovery_command?/1) ->
        nil

      raw_parent_path_segment?(cwd) or
          Enum.any?(candidates, fn candidate ->
            repository_scope_override_command?(candidate) and
                not allowed_issue_local_git_directory_scope?(candidate, cwd, workspace)
          end) ->
        "scratch Symphony workspace repository discovery cannot override the issue-local clone scope"

      all_repository_discovery_candidates_issue_local_scoped?(candidates, cwd, workspace) ->
        nil

      valid_issue_local_normal_clone_cwd?(cwd, workspace) ->
        nil

      true ->
        "scratch Symphony workspace repository discovery requires a valid issue-local normal clone under products/<repo>"
    end
  end

  defp unsafe_repository_discovery_reason(_commands, _cwd, _workspace), do: nil

  defp shell_command_candidates(command) when is_binary(command) do
    [command]
    |> expand_shell_command_candidates(MapSet.new(), [])
    |> Enum.map(fn candidate ->
      raw = trim_shell_command_edges(candidate)
      %{raw: raw, argv: split_shell_argv(raw), compound?: compound_shell_command?(raw)}
    end)
    |> Enum.uniq()
  end

  defp expand_shell_command_candidates([], _seen, candidates), do: Enum.reverse(candidates)

  defp expand_shell_command_candidates([candidate | rest], seen, candidates) do
    normalized = trim_shell_command_edges(candidate)

    if normalized == "" or MapSet.member?(seen, normalized) do
      expand_shell_command_candidates(rest, seen, candidates)
    else
      expansions =
        wrapped_shell_command_candidates(normalized) ++
          nested_shell_command_candidates(normalized) ++ shell_command_segments(normalized)

      expand_shell_command_candidates(
        rest ++ expansions,
        MapSet.put(seen, normalized),
        [normalized | candidates]
      )
    end
  end

  defp split_shell_argv(command) do
    OptionParser.split(command)
  rescue
    RuntimeError -> nil
  end

  defp wrapped_shell_command_candidates(command) do
    cmd_wrapped =
      case cmd_inner_candidate(command) do
        nil -> []
        inner -> [normalize_cmd_inner_candidate(inner)]
      end

    powershell_wrapped =
      case Regex.run(~r/\b(?:powershell|pwsh)(?:\.exe)?\b.*\s-(?:command|c)\s+(.+)$/, command, capture: :all_but_first) do
        [inner] -> [inner]
        _ -> []
      end

    parsed_wrapped =
      command
      |> split_shell_argv()
      |> wrapped_shell_argv_candidate()

    cmd_wrapped ++ powershell_wrapped ++ parsed_wrapped
  end

  defp nested_shell_command_candidates(command) do
    command = Regex.replace(~r/'[^']*'/, command, "")

    ~r/\$\(([^()]*)\)/
    |> Regex.scan(command, capture: :all_but_first)
    |> List.flatten()
  end

  defp wrapped_shell_argv_candidate([executable | arguments]) do
    executable_name =
      executable
      |> String.replace("\\", "/")
      |> Path.basename()

    marker =
      case executable_name do
        name when name in ["powershell", "powershell.exe", "pwsh", "pwsh.exe"] -> ["-command", "-c"]
        _other -> nil
      end

    case split_after_wrapper_marker(arguments, marker) do
      [] -> []
      inner_argv -> [Enum.join(inner_argv, " ")]
    end
  end

  defp wrapped_shell_argv_candidate(_argv), do: []

  defp split_after_wrapper_marker(_arguments, nil), do: []

  defp split_after_wrapper_marker(arguments, markers) do
    markers = List.wrap(markers)

    case Enum.split_while(arguments, &(&1 not in markers)) do
      {_options, [_marker | inner_argv]} -> inner_argv
      _marker_missing -> []
    end
  end

  defp cmd_inner_candidate(command) do
    case Regex.run(
           ~r/^(?:(?:"[^"]*[\\\/])|(?:'[^']*[\\\/])|(?:[^\s"']*[\\\/])|["'])?cmd(?:\.exe)?["']?(\s+.+)$/is,
           command,
           capture: :all_but_first
         ) do
      [arguments] -> extract_cmd_execution_inner(String.trim_leading(arguments))
      _not_cmd_wrapper -> nil
    end
  end

  defp extract_cmd_execution_inner(arguments) do
    case Regex.run(~r/^(?:"\/[ckr]"|'\/[ckr]')\s+(.+)$/is, arguments, capture: :all_but_first) do
      [inner] -> inner
      _not_exact_quoted_marker -> extract_cmd_quoted_attached_inner(arguments)
    end
  end

  defp extract_cmd_quoted_attached_inner(arguments) do
    case Regex.run(~r/^"\/[ckr]([^"]+)"(.*)$/is, arguments, capture: :all_but_first) do
      [attached, remainder] -> attached <> remainder
      _not_double_quoted_marker -> extract_cmd_single_quoted_attached_inner(arguments)
    end
  end

  defp extract_cmd_single_quoted_attached_inner(arguments) do
    case Regex.run(~r/^'\/[ckr]([^']+)'(.*)$/is, arguments, capture: :all_but_first) do
      [attached, remainder] -> attached <> remainder
      _not_single_quoted_marker -> extract_cmd_unquoted_inner(arguments)
    end
  end

  defp extract_cmd_unquoted_inner(arguments) do
    case Regex.run(~r/^\/[ckr](.+)$/is, arguments, capture: :all_but_first) do
      [inner] -> String.trim_leading(inner)
      _not_execution_marker -> skip_cmd_switch(arguments)
    end
  end

  defp skip_cmd_switch(arguments) do
    case Regex.run(
           ~r/^(?:"\/[^"]+"|'\/[^']+'|\/\S+)\s+(.+)$/s,
           arguments,
           capture: :all_but_first
         ) do
      [rest] -> extract_cmd_execution_inner(String.trim_leading(rest))
      _not_switch -> nil
    end
  end

  defp normalize_cmd_inner_candidate(command) do
    command
    |> String.trim()
    |> trim_cmd_outer_command_quotes()
    |> String.graphemes()
    |> escape_cmd_carets_for_analysis(false, [])
    |> Enum.reverse()
    |> Enum.join()
  end

  defp trim_cmd_outer_command_quotes(<<"\"", rest::binary>> = command) do
    if String.ends_with?(rest, "\"") do
      binary_part(rest, 0, byte_size(rest) - 1)
    else
      command
    end
  end

  defp trim_cmd_outer_command_quotes(command), do: command

  defp escape_cmd_carets_for_analysis([], _quoted, normalized), do: normalized

  defp escape_cmd_carets_for_analysis(["^", escaped | rest], false, normalized) do
    quoted_fragment =
      if escaped == "\"" do
        ["'", escaped, "'"]
      else
        ["\"", escaped, "\""]
      end

    escape_cmd_carets_for_analysis(rest, false, Enum.reverse(quoted_fragment) ++ normalized)
  end

  defp escape_cmd_carets_for_analysis(["\"" | rest], quoted, normalized) do
    escape_cmd_carets_for_analysis(rest, not quoted, ["\"" | normalized])
  end

  defp escape_cmd_carets_for_analysis([character | rest], quoted, normalized) do
    escape_cmd_carets_for_analysis(rest, quoted, [character | normalized])
  end

  defp trim_shell_command_edges(command) do
    Enum.reduce(1..3, command, fn _pass, candidate ->
      candidate
      |> String.trim()
      |> trim_enclosing_shell_quotes()
      |> String.trim()
      |> String.trim_leading("&")
      |> String.trim()
      |> String.trim_leading("{")
      |> String.trim_trailing("}")
      |> String.trim()
      |> trim_enclosing_shell_quotes()
      |> String.trim()
    end)
  end

  defp trim_enclosing_shell_quotes(<<quote, rest::binary>> = command) when quote in [?", ?'] do
    case :binary.match(rest, <<quote>>) do
      {closing_index, 1} when closing_index == byte_size(rest) - 1 ->
        binary_part(rest, 0, closing_index)

      _not_one_enclosing_pair ->
        command
    end
  end

  defp trim_enclosing_shell_quotes(command), do: command

  defp compound_shell_command?(command) do
    case shell_command_segments(command) do
      [_single] -> false
      _multiple_or_empty -> true
    end
  end

  defp shell_command_segments(command) when is_binary(command) do
    command
    |> String.graphemes()
    |> split_shell_command_segments(nil, false, [], [])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_shell_command_segments([], _quote, _escaped, current, segments) do
    Enum.reverse([current |> Enum.reverse() |> Enum.join() | segments])
  end

  defp split_shell_command_segments([character | rest], quote, true, current, segments) do
    split_shell_command_segments(rest, quote, false, [character | current], segments)
  end

  defp split_shell_command_segments([character | rest], quote, false, current, segments)
       when character in ["\\", "`"] do
    split_shell_command_segments(rest, quote, true, [character | current], segments)
  end

  defp split_shell_command_segments([character | rest], nil, false, current, segments)
       when character in ["'", "\""] do
    split_shell_command_segments(rest, character, false, [character | current], segments)
  end

  defp split_shell_command_segments([character | rest], character, false, current, segments)
       when character in ["'", "\""] do
    split_shell_command_segments(rest, nil, false, [character | current], segments)
  end

  defp split_shell_command_segments([character | rest], nil, false, current, segments)
       when character in [";", "&", "|", "\r", "\n"] do
    segment = current |> Enum.reverse() |> Enum.join()
    split_shell_command_segments(rest, nil, false, [], [segment | segments])
  end

  defp split_shell_command_segments([character | rest], quote, false, current, segments) do
    split_shell_command_segments(rest, quote, false, [character | current], segments)
  end

  defp repository_discovery_command?(%{raw: raw, argv: argv, compound?: compound?}) do
    case repository_cli_argv(argv) do
      {:git, arguments} -> git_repository_discovery_argv?(arguments)
      {:rg, arguments} -> elem(rg_files_analysis(arguments), 0)
      :not_repository_cli when is_nil(argv) or compound? -> broad_repository_discovery_command?(raw)
      :not_repository_cli -> false
    end
  end

  defp repository_discovery_command?(_command), do: false

  defp git_worktree_list_command?(%{raw: raw, argv: argv, compound?: compound?}) do
    case repository_cli_argv(argv) do
      {:git, arguments} -> git_worktree_list_argv?(arguments)
      {:rg, _arguments} -> false
      :not_repository_cli when is_nil(argv) or compound? -> git_worktree_list_command?(raw)
      :not_repository_cli -> false
    end
  end

  defp git_worktree_list_command?(command) when is_binary(command) do
    command = shell_command_without_quoted_contents(command)

    Regex.match?(
      ~r/(?:^|[;&|\r\n])\s*(?:&\s*)?(?:[^\s;&|]*[\\\/])?git(?:\.exe)?\s+[^\r\n;&|]*?\bworktree\s+list(?:\s|$)/,
      command
    )
  end

  defp repository_scope_override_command?(%{raw: raw, argv: argv, compound?: compound?} = candidate) do
    scope_raw = if compound?, do: shell_command_without_quoted_contents(raw), else: raw

    repository_discovery_command?(candidate) and
      (raw_parent_path_segment?(scope_raw) or
         git_scope_override_command?(scope_raw) or
         git_scope_override_argv?(argv) or
         Regex.match?(~r/(?:--git-dir|--work-tree)(?:=|\s)/, scope_raw) or
         Regex.match?(~r/\bgit_[a-z0-9_]+\s*=/, scope_raw) or
         rg_files_positional_path?(scope_raw) or
         rg_files_positional_path_argv?(argv))
  end

  defp repository_scope_override_command?(_command), do: false

  defp allowed_issue_local_git_directory_scope?(
         %{argv: argv, compound?: false},
         cwd,
         workspace
       )
       when is_binary(cwd) and is_binary(workspace) do
    with {:git, arguments} <- repository_cli_argv(argv),
         {:ok, target} <- git_directory_scope_target(arguments),
         {"status", _command_arguments} <- git_command_and_arguments(arguments),
         false <- raw_parent_path_segment?(target),
         :relative <- Path.type(target),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, canonical_cwd} <- PathSafety.canonicalize(cwd),
         true <- canonical_cwd == canonical_workspace,
         {:ok, canonical_target} <-
           target
           |> Path.expand(canonical_cwd)
           |> PathSafety.canonicalize(),
         {:ok, clone_root} <-
           issue_local_clone_root(canonical_target, canonical_workspace),
         true <- canonical_target == clone_root,
         true <- valid_issue_local_normal_clone_cwd?(canonical_target, canonical_workspace) do
      true
    else
      _reason -> false
    end
  end

  defp allowed_issue_local_git_directory_scope?(_candidate, _cwd, _workspace), do: false

  defp all_repository_discovery_candidates_issue_local_scoped?(candidates, cwd, workspace) do
    discovery_candidates = Enum.filter(candidates, &repository_discovery_command?/1)

    discovery_candidates != [] and
      Enum.all?(discovery_candidates, fn candidate ->
        allowed_issue_local_git_directory_scope?(candidate, cwd, workspace)
      end)
  end

  defp git_directory_scope_target(arguments) when is_list(arguments),
    do: git_directory_scope_target(arguments, nil)

  defp git_directory_scope_target(["-c", target | rest], nil)
       when is_binary(target) and target != "" do
    if String.contains?(target, "=") do
      {:error, :unsafe_git_directory_scope}
    else
      git_directory_scope_target(rest, target)
    end
  end

  defp git_directory_scope_target(["status" | command_arguments], target)
       when is_binary(target) do
    if Enum.any?(command_arguments, &git_status_scope_override_argument?/1) do
      {:error, :unsafe_git_directory_scope}
    else
      {:ok, target}
    end
  end

  defp git_directory_scope_target([option | rest], target) do
    if git_global_flag?(option) do
      git_directory_scope_target(rest, target)
    else
      {:error, :unsafe_git_directory_scope}
    end
  end

  defp git_directory_scope_target(_arguments, _target),
    do: {:error, :unsafe_git_directory_scope}

  defp git_status_scope_override_argument?(argument) do
    argument in [
      "-c",
      "--git-dir",
      "--work-tree",
      "--config-env",
      "--namespace",
      "--super-prefix",
      "--exec-path"
    ] or
      Enum.any?(
        [
          "-c",
          "--git-dir=",
          "--work-tree=",
          "--config-env=",
          "--namespace=",
          "--super-prefix=",
          "--exec-path="
        ],
        &String.starts_with?(argument, &1)
      )
  end

  defp raw_parent_path_segment?(path) when is_binary(path) do
    Regex.match?(~r{(?:^|[\\/])\.\.(?:[\\/]|$)}, path) or
      Regex.match?(~r{(?:^|[\s"'=])\.\.(?:[\\/]|[\s"']|$)}, path)
  end

  defp raw_parent_path_segment?(_path), do: false

  defp git_scope_override_command?(command) do
    Regex.match?(~r/\bgit(?:\.exe)?\b[^\r\n;&|]*?\s-c(?:\S*)?(?=\s|$)/, command)
  end

  defp git_scope_override_argv?(argv) do
    case repository_cli_argv(argv) do
      {:git, arguments} ->
        Enum.any?(arguments, fn argument ->
          argument == "-c" or String.starts_with?(argument, "-c") or
            argument in ["--git-dir", "--work-tree", "--config-env"] or
            String.starts_with?(argument, "--git-dir=") or
            String.starts_with?(argument, "--work-tree=") or
            String.starts_with?(argument, "--config-env=")
        end)

      _not_git ->
        false
    end
  end

  defp rg_files_positional_path?(command) do
    case Regex.run(
           ~r/\brg(?:\.exe)?\b([^\r\n;&|]*)/,
           command,
           capture: :all_but_first
         ) do
      [arguments] ->
        case split_shell_argv(arguments) do
          nil -> false
          argv -> match?({true, true}, rg_files_analysis(argv))
        end

      _no_rg_files ->
        false
    end
  end

  defp rg_files_positional_path_argv?(argv) do
    case repository_cli_argv(argv) do
      {:rg, arguments} ->
        match?({true, true}, rg_files_analysis(arguments))

      _not_rg ->
        false
    end
  end

  defp git_repository_discovery_argv?(arguments) do
    case git_command_and_arguments(arguments) do
      {"status", _command_arguments} -> true
      {"worktree", ["list" | _command_arguments]} -> true
      _other_command -> false
    end
  end

  defp git_worktree_list_argv?(arguments) do
    match?({"worktree", ["list" | _command_arguments]}, git_command_and_arguments(arguments))
  end

  defp git_command_and_arguments([option, _value | rest])
       when option in ["-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"] do
    git_command_and_arguments(rest)
  end

  defp git_command_and_arguments([option | rest]) do
    cond do
      git_global_flag?(option) ->
        git_command_and_arguments(rest)

      git_inline_global_option?(option) ->
        git_command_and_arguments(rest)

      String.starts_with?(option, "-") ->
        git_command_and_arguments(rest)

      true ->
        {option, rest}
    end
  end

  defp git_command_and_arguments([]), do: :no_git_command

  defp git_global_flag?(option) do
    option in [
      "-p",
      "--paginate",
      "--no-pager",
      "--no-replace-objects",
      "--bare",
      "--literal-pathspecs",
      "--glob-pathspecs",
      "--noglob-pathspecs",
      "--icase-pathspecs"
    ]
  end

  defp git_inline_global_option?(option) do
    Enum.any?(
      [
        "-c",
        "--git-dir=",
        "--work-tree=",
        "--namespace=",
        "--super-prefix=",
        "--config-env=",
        "--exec-path="
      ],
      &String.starts_with?(option, &1)
    )
  end

  defp rg_files_analysis(arguments), do: rg_files_analysis(arguments, false, false)

  defp rg_files_analysis([], files_seen, positional_seen), do: {files_seen, positional_seen}

  defp rg_files_analysis([argument | rest], files_seen, positional_seen) do
    cond do
      rg_option_takes_value?(argument) ->
        rg_files_analysis(Enum.drop(rest, 1), files_seen, positional_seen)

      argument == "--" ->
        {files_seen, positional_seen or rest != []}

      argument == "--files" ->
        rg_files_analysis(rest, true, positional_seen)

      String.starts_with?(argument, "-") ->
        rg_files_analysis(rest, files_seen, positional_seen)

      true ->
        rg_files_analysis(rest, files_seen, true)
    end
  end

  defp rg_option_takes_value?(option) do
    option in [
      "-e",
      "--regexp",
      "-f",
      "--file",
      "-g",
      "--glob",
      "--iglob",
      "-t",
      "--type",
      "-t-not",
      "--type-not",
      "--encoding",
      "--engine",
      "--max-depth",
      "--max-count",
      "--max-filesize",
      "--path-separator",
      "--replace",
      "--sort",
      "--sortr",
      "--threads"
    ]
  end

  defp repository_cli_argv([executable | arguments]) do
    executable_name =
      executable
      |> String.replace("\\", "/")
      |> Path.basename()

    case executable_name do
      name when name in ["git", "git.exe"] -> {:git, arguments}
      name when name in ["rg", "rg.exe"] -> {:rg, arguments}
      _other -> :not_repository_cli
    end
  end

  defp repository_cli_argv(_argv), do: :not_repository_cli

  defp shell_command_without_quoted_contents(command) do
    command = Regex.replace(~r/'[^']*'/, command, "")
    Regex.replace(~r/"(?:\\.|[^"])*"/, command, "")
  end

  defp valid_issue_local_normal_clone_cwd?(cwd, workspace)
       when is_binary(cwd) and is_binary(workspace) do
    with false <- raw_parent_path_segment?(cwd),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, canonical_cwd} <- PathSafety.canonicalize(cwd),
         {:ok, clone_root} <- issue_local_clone_root(canonical_cwd, canonical_workspace),
         git_dir = Path.join(clone_root, ".git"),
         true <- File.dir?(git_dir),
         {:ok, canonical_git_dir} <- PathSafety.canonicalize(git_dir),
         true <- canonical_git_dir == git_dir,
         true <- File.regular?(Path.join(git_dir, "HEAD")),
         true <- File.regular?(Path.join(git_dir, "config")) do
      true
    else
      _reason -> false
    end
  end

  defp valid_issue_local_normal_clone_cwd?(_cwd, _workspace), do: false

  defp issue_local_clone_root(cwd, workspace) do
    relative = Path.relative_to(cwd, workspace)

    case Path.split(relative) do
      ["products", repo | _rest] when repo in @issue_product_repositories ->
        {:ok, Path.join([workspace, "products", repo])}

      _segments ->
        {:error, :not_issue_product_clone}
    end
  end

  defp broad_repository_discovery_command?(command) when is_binary(command) do
    command = shell_command_without_quoted_contents(command)

    Regex.match?(
      ~r/(?:^|[;&|\r\n])\s*(?:&\s*)?(?:[^\s;&|]*[\\\/])?rg(?:\.exe)?\s+[^\r\n;&|]*?--files(?:\s|$)/,
      command
    ) ||
      git_worktree_list_command?(command) ||
      Regex.match?(
        ~r/(?:^|[;&|\r\n])\s*(?:&\s*)?(?:[^\s;&|]*[\\\/])?git(?:\.exe)?\s+[^\r\n;&|]*?\bstatus(?:\s|$)/,
        command
      )
  end

  defp single_quoted_powershell_generation?(normalized) when is_binary(normalized) do
    ~r/\s-(?:command|c)\s+'([^']*)'/
    |> Regex.scan(normalized, capture: :all_but_first)
    |> List.flatten()
    |> Enum.any?(fn script ->
      Regex.match?(
        ~r/(^|[;&|{(\r\n])\s*(?:new-item|set-content|add-content|out-file|mkdir|md|ni|sc|ac)\b/,
        script
      ) ||
        Regex.match?(~r/(^|[\s;&|{(\r\n])(?:\d+)?>{1,2}(?!&)\s*\S/, script)
    end)
  end

  defp single_quoted_powershell_generation?(_normalized), do: false

  defp unsafe_relative_command_reason(command, cwd) when is_binary(command) and is_binary(cwd) do
    normalized_command = String.downcase(String.replace(command, "\\", "/"))
    normalized_cwd = String.downcase(String.replace(cwd, "\\", "/"))

    cond do
      Regex.match?(~r{/development/?$}, normalized_cwd) and product_relative_path?(normalized_command) ->
        "product coordination-checkout path used instead of a named product worktree"

      Regex.match?(~r{/development/tools/?$}, normalized_cwd) and
          discord_iac_relative_path?(normalized_command) ->
        "product coordination-checkout path used instead of a named product worktree"

      String.contains?(normalized_cwd, "/.codex/plugins/cache/") and
          plugin_skill_relative_path?(normalized_command) ->
        "packaged skill file read through hosted shell_command"

      true ->
        nil
    end
  end

  defp unsafe_relative_command_reason(_command, _cwd), do: nil

  defp product_relative_path?(command) when is_binary(command) do
    Regex.match?(~r{(^|[\s"'=])(?:\./)?(one|replicator|bob)(?:/|[\s"']|$)}, command) or
      discord_iac_relative_path?(command) or
      Regex.match?(~r{(^|[\s"'=])(?:\./)?tools/discord-iac(?:/|[\s"']|$)}, command)
  end

  defp discord_iac_relative_path?(command) when is_binary(command) do
    Regex.match?(~r{(^|[\s"'=])(?:\./)?discord-iac(?:/|[\s"']|$)}, command)
  end

  defp plugin_skill_relative_path?(command) when is_binary(command) do
    Regex.match?(~r{(^|[\s"'=])(?:\./)?skills/[^ \t\r\n"']*/skill\.md(?:[\s"']|$)}, command) or
      Regex.match?(~r{(^|[\s"'=])(?:\./)?[^ \t\r\n"'/]+/skill\.md(?:[\s"']|$)}, command) or
      Regex.match?(~r{(^|[\s"'=])(?:\./)?skill\.md(?:[\s"']|$)}, command)
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         "mcpServer/elicitation/request",
         %{"id" => _id, "params" => params} = _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    if mcp_tool_call_approval_elicitation?(params), do: :approval_required, else: :input_required
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp mcp_tool_call_approval_elicitation?(%{
         "_meta" => %{"codex_approval_kind" => "mcp_tool_call"},
         "mode" => "form",
         "requestedSchema" => schema
       })
       when is_map(schema) do
    empty_object_schema?(schema)
  end

  defp mcp_tool_call_approval_elicitation?(_params), do: false

  defp empty_object_schema?(%{"type" => "object"} = schema) do
    empty_schema_properties?(Map.get(schema, "properties")) and
      empty_schema_required?(Map.get(schema, "required"))
  end

  defp empty_object_schema?(_schema), do: false

  defp empty_schema_properties?(properties) when is_map(properties), do: map_size(properties) == 0
  defp empty_schema_properties?(nil), do: true
  defp empty_schema_properties?(_properties), do: false

  defp empty_schema_required?(required) when is_list(required), do: Enum.empty?(required)
  defp empty_schema_required?(nil), do: true
  defp empty_schema_required?(_required), do: false

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end
      |> truncate_dynamic_tool_output()

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> truncate_dynamic_tool_content_items(existing_items)
        _ -> dynamic_tool_content_items(output)
      end

    %{
      "success" => success,
      "output" => output,
      "contentItems" => content_items
    }
  end

  defp normalize_dynamic_tool_result(result) do
    output = result |> inspect() |> truncate_dynamic_tool_output()

    %{
      "success" => false,
      "output" => output,
      "contentItems" => dynamic_tool_content_items(output)
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp truncate_dynamic_tool_content_items(items) when is_list(items) do
    Enum.map(items, fn
      %{"text" => text} = item when is_binary(text) ->
        Map.put(item, "text", truncate_dynamic_tool_output(text))

      item ->
        item
    end)
  end

  defp truncate_dynamic_tool_output(output) when is_binary(output) do
    if String.length(output) > @max_dynamic_tool_output_chars do
      String.slice(output, 0, @max_dynamic_tool_output_chars) <>
        "\n[dynamic tool output truncated after #{@max_dynamic_tool_output_chars} characters]"
    else
      output
    end
  end

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _auto_approve_requests
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         _auto_approve_requests
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, _answers, _decision} ->
        :approval_required

      :error ->
        reply_with_non_interactive_tool_input_answer(
          port,
          id,
          params,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp reply_with_non_interactive_tool_input_answer(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata
       ) do
    case tool_request_user_input_unavailable_answers(params) do
      {:ok, answers} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, raw: payload_string, answer: @non_interactive_tool_input_answer},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp tool_request_user_input_unavailable_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_question_id(question) do
          {:ok, question_id} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map}
      _ -> :error
    end
  end

  defp tool_request_user_input_unavailable_answers(_params), do: :error

  defp tool_request_user_input_question_id(%{"id" => question_id}) when is_binary(question_id),
    do: {:ok, question_id}

  defp tool_request_user_input_question_id(_question), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    case tool_request_user_input_approval_option_label(options) do
      nil -> :error
      answer_label -> {:ok, question_id, answer_label}
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        catch
          :exit, :epipe ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp command_tokens(command) when is_binary(command) do
    ~r/"([^"]*)"|'([^']*)'|(\S+)/
    |> Regex.scan(String.trim(command), capture: :all_but_first)
    |> Enum.map(fn captures ->
      Enum.find(captures, "", &(&1 != ""))
    end)
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
