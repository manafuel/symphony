defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.PathSafety

  @linear_graphql_tool "linear_graphql"
  @local_shell_tool "local_shell"
  @write_run_artifact_tool "write_run_artifact"
  @default_shell_timeout_ms 120_000
  @max_shell_timeout_ms 300_000
  @max_shell_output_chars 120_000
  @max_run_artifact_bytes 1_000_000
  @credential_env_name_pattern ~r/(?:^|_)(?:api_key|access_key|secret_key|private_key|service_role_key|key|token|secret|password|passwd|passphrase|authorization|bearer|credential|credentials|database_url|postgres_url|redis_url|mongodb_uri|connection_string)(?:$|_)/i
  @common_credential_patterns [
    ~r/BEGIN (?:RSA |OPENSSH |EC |DSA )?PRIVATE KEY/,
    ~r/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
    ~r/\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9_]{8,}\b/,
    ~r/\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b/,
    ~r/\bgh[pousr]_[A-Za-z0-9_]{20,}\b/,
    ~r/\bgithub_pat_[A-Za-z0-9_]{20,}\b/,
    ~r/\bxox[baprs]-[A-Za-z0-9-]{20,}\b/,
    ~r/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/,
    ~r/\bAIza[0-9A-Za-z_-]{20,}\b/,
    ~r/\bauthorization\s*:\s*(?:bearer|basic)\s+(?!REDACTED\b|<redacted>|example\b|placeholder\b|null\b|\$\{|\$env:|%[A-Za-z_][A-Za-z0-9_]*%)[A-Za-z0-9._~+\/=:-]{8,}/i,
    ~r/\b(?:https?|postgres(?:ql)?|redis|mongodb(?:\+srv)?)\:\/\/[^\/\s:@]+:[^\/\s@]+@/i,
    ~r/\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|passphrase|private[_-]?key|service[_-]?role[_-]?key)\b\s*[:=]\s*["']?(?!REDACTED\b|<redacted>|example\b|placeholder\b|null\b|true\b|false\b|\$\{|\$env:|%[A-Za-z_][A-Za-z0-9_]*%)[^\s"']{8,}/i
  ]
  @hidden_stdio_launcher_name "codex-hidden-stdio-launcher.exe"
  @blocked_product_coordination_checkouts ~w(bob one replicator)
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @write_run_artifact_description """
  Write bounded text evidence under the current Symphony issue workspace runs directory.
  """
  @write_run_artifact_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["path", "content"],
    "properties" => %{
      "path" => %{
        "type" => "string",
        "description" => "Relative output path under the current issue workspace runs/ directory."
      },
      "content" => %{
        "type" => "string",
        "description" => "UTF-8 text content to write. Exact inherited credential values and recognized credential forms are rejected; submit redacted or presence-only evidence."
      },
      "overwrite" => %{
        "type" => ["boolean", "null"],
        "description" => "Whether to replace an existing artifact. Defaults to true."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    if mutation_tools_disabled?(tool, opts) do
      failure_response(mutation_tools_disabled_payload(tool))
    else
      execute_allowed_tool(tool, arguments, opts)
    end
  end

  @spec tool_specs(keyword()) :: [map()]
  def tool_specs(opts \\ []) do
    if Keyword.get(opts, :allow_mutation_tools) == false do
      []
    else
      [
        %{
          "name" => @linear_graphql_tool,
          "description" => @linear_graphql_description,
          "inputSchema" => @linear_graphql_input_schema
        },
        %{
          "name" => @write_run_artifact_tool,
          "description" => @write_run_artifact_description,
          "inputSchema" => @write_run_artifact_input_schema
        }
      ]
    end
  end

  defp mutation_tools_disabled_payload(tool) do
    %{"error" => %{"message" => "`#{tool}` is disabled for read-only routed sessions."}}
  end

  defp mutation_tools_disabled?(tool, opts) do
    tool in [@linear_graphql_tool, @write_run_artifact_tool] and
      Keyword.get(opts, :allow_mutation_tools) == false
  end

  defp execute_allowed_tool(@linear_graphql_tool, arguments, opts),
    do: execute_linear_graphql(arguments, opts)

  defp execute_allowed_tool(@write_run_artifact_tool, arguments, opts),
    do: execute_write_run_artifact(arguments, opts)

  defp execute_allowed_tool(@local_shell_tool, arguments, opts) do
    if Keyword.get(opts, :allow_local_shell) == true do
      execute_local_shell(arguments, opts)
    else
      failure_response(local_shell_error_payload(:local_shell_disabled))
    end
  end

  defp execute_allowed_tool(other, _arguments, _opts) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(other)}.",
        "supportedTools" => supported_tool_names()
      }
    })
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp execute_local_shell(arguments, opts) do
    with {:ok, command, workdir, timeout_ms} <- normalize_local_shell_arguments(arguments, opts),
         :ok <- validate_local_shell_command(command),
         {:ok, output, exit_code} <- run_local_shell_command(command, workdir, timeout_ms) do
      local_shell_response(exit_code == 0, %{
        "command" => command,
        "workdir" => workdir,
        "exit_code" => exit_code,
        "stdout" => truncate_shell_output(output)
      })
    else
      {:error, reason} ->
        failure_response(local_shell_error_payload(reason))
    end
  end

  defp normalize_local_shell_arguments(arguments, opts) when is_map(arguments) do
    workspace = Keyword.get(opts, :workspace) || File.cwd!()

    with {:ok, command} <- normalize_local_shell_command(arguments),
         {:ok, workdir} <- normalize_local_shell_workdir(arguments, workspace),
         {:ok, timeout_ms} <- normalize_local_shell_timeout(arguments),
         :ok <- validate_local_shell_workdir(workdir, workspace) do
      {:ok, command, workdir, timeout_ms}
    end
  end

  defp normalize_local_shell_arguments(_arguments, _opts), do: {:error, :invalid_local_shell_arguments}

  defp execute_write_run_artifact(arguments, opts) do
    workspace = Keyword.get(opts, :workspace) || File.cwd!()

    with {:ok, path, content, overwrite?} <- normalize_write_run_artifact_arguments(arguments),
         {:ok, artifact_path, runs_root} <- normalize_write_run_artifact_path(path, workspace),
         :ok <- validate_write_run_artifact_path(artifact_path, runs_root),
         :ok <- validate_write_run_artifact_content(content),
         {:ok, written_path, existed?} <-
           write_run_artifact_file(artifact_path, runs_root, content, overwrite?) do
      dynamic_tool_response(
        true,
        encode_payload(%{
          "path" => written_path,
          "bytes" => byte_size(content),
          "overwritten" => existed?
        })
      )
    else
      {:error, reason} ->
        failure_response(write_run_artifact_error_payload(reason))
    end
  end

  defp normalize_write_run_artifact_arguments(arguments) when is_map(arguments) do
    path = get_argument(arguments, "path")
    content = get_argument(arguments, "content")
    overwrite = get_argument(arguments, "overwrite")

    cond do
      not is_binary(path) or String.trim(path) == "" ->
        {:error, :missing_run_artifact_path}

      not is_binary(content) ->
        {:error, :invalid_run_artifact_content}

      not (is_nil(overwrite) or is_boolean(overwrite)) ->
        {:error, :invalid_run_artifact_overwrite}

      true ->
        {:ok, String.trim(path), content, if(is_nil(overwrite), do: true, else: overwrite)}
    end
  end

  defp normalize_write_run_artifact_arguments(_arguments), do: {:error, :invalid_run_artifact_arguments}

  defp get_argument(arguments, key) do
    atom_key =
      case key do
        "path" -> :path
        "content" -> :content
        "overwrite" -> :overwrite
      end

    cond do
      Map.has_key?(arguments, key) -> Map.get(arguments, key)
      Map.has_key?(arguments, atom_key) -> Map.get(arguments, atom_key)
      true -> nil
    end
  end

  defp normalize_write_run_artifact_path(path, workspace) do
    if Path.type(path) == :relative do
      expanded_workspace = Path.expand(workspace)
      runs_root = Path.expand(Path.join(expanded_workspace, "runs"))
      artifact_path = Path.expand(path, expanded_workspace)

      with :ok <- validate_write_run_artifact_path(artifact_path, runs_root),
           {:ok, canonical_workspace} <- canonicalize_write_run_artifact_path(expanded_workspace),
           expected_runs_root = Path.expand(Path.join(canonical_workspace, "runs")),
           {:ok, canonical_runs_root} <- canonicalize_write_run_artifact_path(runs_root),
           :ok <- validate_write_run_artifact_runs_root(canonical_runs_root, expected_runs_root),
           {:ok, canonical_artifact_path} <- canonicalize_write_run_artifact_path(artifact_path),
           :ok <- validate_write_run_artifact_path(canonical_artifact_path, canonical_runs_root) do
        {:ok, canonical_artifact_path, canonical_runs_root}
      end
    else
      {:error, {:run_artifact_path_must_be_relative, path}}
    end
  end

  defp canonicalize_write_run_artifact_path(path) do
    case PathSafety.canonicalize(path) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, reason} ->
        {:error, {:run_artifact_path_unreadable, path, reason}}
    end
  end

  defp validate_write_run_artifact_runs_root(canonical_runs_root, expected_runs_root) do
    if same_path?(canonical_runs_root, expected_runs_root) do
      :ok
    else
      {:error, {:run_artifact_runs_root_reparse, canonical_runs_root}}
    end
  end

  defp validate_write_run_artifact_path(artifact_path, runs_root) do
    cond do
      not path_descendant?(artifact_path, runs_root) ->
        {:error, {:run_artifact_path_outside_issue_runs, artifact_path}}

      File.dir?(artifact_path) ->
        {:error, {:run_artifact_path_is_directory, artifact_path}}

      true ->
        :ok
    end
  end

  defp path_descendant?(path, root) do
    normalized_path = normalize_path_for_compare(path)
    normalized_root = normalize_path_for_compare(root)

    String.starts_with?(normalized_path, normalized_root <> "/")
  end

  defp same_path?(left, right),
    do: normalize_path_for_compare(left) == normalize_path_for_compare(right)

  defp validate_write_run_artifact_content(content) do
    cond do
      byte_size(content) > @max_run_artifact_bytes ->
        {:error, {:run_artifact_content_too_large, byte_size(content)}}

      not String.valid?(content) ->
        {:error, :invalid_run_artifact_content}

      contains_inherited_credential?(content) or contains_common_credential_shape?(content) ->
        {:error, :unsafe_run_artifact_content}

      true ->
        :ok
    end
  end

  defp contains_inherited_credential?(content) do
    System.get_env()
    |> Enum.filter(fn {name, value} ->
      Regex.match?(@credential_env_name_pattern, name) and is_binary(value) and
        String.trim(value) != ""
    end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> Enum.any?(&String.contains?(content, &1))
  end

  defp contains_common_credential_shape?(content) do
    Enum.any?(@common_credential_patterns, &Regex.match?(&1, content))
  end

  defp write_run_artifact_file(path, runs_root, content, overwrite?) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, current_runs_root} <- canonicalize_write_run_artifact_path(runs_root),
         :ok <- validate_write_run_artifact_runs_root(current_runs_root, runs_root),
         {:ok, safe_path} <- canonicalize_write_run_artifact_path(path),
         :ok <- validate_write_run_artifact_path(safe_path, current_runs_root),
         existed? = File.exists?(safe_path),
         :ok <- write_run_artifact_contents(safe_path, content, overwrite?) do
      {:ok, safe_path, existed?}
    else
      {:error, {:run_artifact_path_unreadable, _path, _reason} = reason} -> {:error, reason}
      {:error, {:run_artifact_runs_root_reparse, _path} = reason} -> {:error, reason}
      {:error, {:run_artifact_path_outside_issue_runs, _path} = reason} -> {:error, reason}
      {:error, {:run_artifact_path_is_directory, _path} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:run_artifact_write_failed, reason}}
    end
  end

  defp write_run_artifact_contents(path, content, true), do: File.write(path, content)

  defp write_run_artifact_contents(path, content, false) do
    File.write(path, content, [:exclusive])
  end

  defp normalize_local_shell_command(arguments) do
    case Map.get(arguments, "command") || Map.get(arguments, :command) do
      command when is_binary(command) ->
        case String.trim(command) do
          "" -> {:error, :missing_local_shell_command}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_local_shell_command}
    end
  end

  defp normalize_local_shell_workdir(arguments, workspace) do
    raw_workdir = Map.get(arguments, "workdir") || Map.get(arguments, :workdir)

    workdir =
      case raw_workdir do
        nil ->
          workspace

        workdir when is_binary(workdir) ->
          case String.trim(workdir) do
            "" -> workspace
            trimmed -> normalize_local_shell_workdir_path(trimmed, workspace)
          end

        _ ->
          workspace
      end

    {:ok, Path.expand(workdir)}
  end

  defp normalize_local_shell_workdir_path(path, workspace) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(workspace, path)
    end
  end

  defp normalize_local_shell_timeout(arguments) do
    raw_timeout = Map.get(arguments, "timeout_ms") || Map.get(arguments, :timeout_ms)

    cond do
      is_nil(raw_timeout) ->
        {:ok, @default_shell_timeout_ms}

      is_integer(raw_timeout) and raw_timeout > 0 and raw_timeout <= @max_shell_timeout_ms ->
        {:ok, raw_timeout}

      is_integer(raw_timeout) and raw_timeout > @max_shell_timeout_ms ->
        {:ok, @max_shell_timeout_ms}

      true ->
        {:error, :invalid_local_shell_timeout}
    end
  end

  defp validate_local_shell_workdir(workdir, workspace) do
    cond do
      not File.dir?(workdir) ->
        {:error, {:invalid_local_shell_workdir, workdir}}

      not allowed_local_shell_workdir?(workdir, workspace) ->
        {:error, {:local_shell_workdir_outside_allowed_roots, workdir}}

      product_coordination_checkout_workdir?(workdir, workspace) ->
        {:error, {:local_shell_product_coordination_checkout_blocked, workdir}}

      true ->
        :ok
    end
  end

  defp allowed_local_shell_workdir?(workdir, workspace) do
    allowed_local_shell_roots(workspace)
    |> Enum.any?(&path_within?(workdir, &1))
  end

  defp allowed_local_shell_roots(workspace) do
    workspace = Path.expand(workspace)

    case manafuel_root_for_workspace(workspace) do
      nil ->
        [workspace]

      root ->
        [
          workspace,
          Path.join(root, "development"),
          Path.join(root, "worktrees")
        ]
    end
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp product_coordination_checkout_workdir?(workdir, workspace) do
    case manafuel_root_for_workspace(workspace) do
      nil ->
        false

      root ->
        development_root = Path.join(root, "development")
        normalized_workdir = normalize_path_for_compare(workdir)
        normalized_root = normalize_path_for_compare(development_root)
        root_prefix = normalized_root <> "/"

        if String.starts_with?(normalized_workdir, root_prefix) do
          first_segment =
            normalized_workdir
            |> String.replace_prefix(root_prefix, "")
            |> String.split("/", parts: 2)
            |> List.first()

          first_segment in @blocked_product_coordination_checkouts
        else
          false
        end
    end
  end

  defp manafuel_root_for_workspace(workspace) do
    workspace
    |> ancestor_paths()
    |> Enum.find(&(Path.basename(&1) == "manafuel"))
  end

  defp ancestor_paths(path) do
    path
    |> Path.expand()
    |> do_ancestor_paths([])
  end

  defp do_ancestor_paths(path, acc) do
    parent = Path.dirname(path)

    if parent == path do
      Enum.reverse([path | acc])
    else
      do_ancestor_paths(parent, [path | acc])
    end
  end

  defp path_within?(path, root) do
    normalized_path = normalize_path_for_compare(path)
    normalized_root = normalize_path_for_compare(root)

    normalized_path == normalized_root or String.starts_with?(normalized_path, normalized_root <> "/")
  end

  defp normalize_path_for_compare(path) do
    path
    |> Path.expand()
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
    |> String.downcase()
  end

  defp validate_local_shell_command(command) do
    blocked_reason =
      cond do
        String.contains?(command, ["\r", "\n"]) ->
          "multi-line shell commands are not allowed"

        Regex.match?(~r/(^|[^0-9])>{1,2}|[12]>{1,2}/, command) ->
          "shell redirection is not allowed"

        Regex.match?(~r/(\|\||&&|;|\|)/, command) ->
          "multi-command orchestration is not allowed"

        Regex.match?(~r/(?i)\b(powershell|pwsh)(\.exe)?\b.*\s-command\b/, command) ->
          "inline PowerShell is not allowed; use checked-in scripts with -File"

        Regex.match?(
          ~r/(?i)\b(remove-item|rm|del|erase|rmdir|rd|set-content|new-item|out-file|add-content|xcopy|robocopy)\b/,
          command
        ) ->
          "destructive or generated filesystem shell commands are not allowed"

        true ->
          nil
      end

    case blocked_reason do
      nil -> :ok
      reason -> {:error, {:unsafe_local_shell_command, reason}}
    end
  end

  defp run_local_shell_command(command, workdir, timeout_ms) do
    task =
      Task.async(fn ->
        {executable, args} = local_shell_executable(command, workdir)
        System.cmd(executable, args, cd: workdir, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_code}} ->
        {:ok, normalize_shell_output(output), exit_code}

      nil ->
        {:error, {:local_shell_timeout, timeout_ms}}

      {:exit, reason} ->
        {:error, {:local_shell_execution_failed, reason}}
    end
  rescue
    error -> {:error, {:local_shell_execution_failed, Exception.message(error)}}
  end

  defp local_shell_executable(command, workdir) do
    if match?({:win32, _}, :os.type()) do
      power_shell_args = windows_power_shell_args(command)

      case hidden_stdio_launcher_executable(workdir) do
        nil -> {windows_power_shell_executable(), power_shell_args}
        launcher -> {launcher, ["--", "powershell.exe" | power_shell_args]}
      end
    else
      {"/bin/sh", ["-lc", command]}
    end
  end

  defp windows_power_shell_executable do
    System.find_executable("powershell.exe") || "C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  end

  defp windows_power_shell_args(command) do
    [
      "-NoLogo",
      "-NoProfile",
      "-NonInteractive",
      "-WindowStyle",
      "Hidden",
      "-ExecutionPolicy",
      "Bypass",
      "-Command",
      command
    ]
  end

  @doc false
  @spec hidden_stdio_launcher_executable(Path.t()) :: Path.t() | nil
  def hidden_stdio_launcher_executable(workdir) do
    workdir
    |> hidden_stdio_launcher_candidates()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.find(&File.regular?/1)
  end

  defp hidden_stdio_launcher_candidates(workdir) do
    trusted_env_hidden_stdio_launcher_candidates() ++ trusted_control_hidden_stdio_launcher_candidates(workdir)
  end

  defp trusted_env_hidden_stdio_launcher_candidates do
    case System.get_env("CODEX_HIDDEN_STDIO_LAUNCHER") do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> absolute_launcher_candidate()

      _ ->
        []
    end
  end

  defp absolute_launcher_candidate(""), do: []

  defp absolute_launcher_candidate(path) do
    if Path.type(path) == :absolute, do: [path], else: []
  end

  defp trusted_control_hidden_stdio_launcher_candidates(workdir) do
    [workdir, File.cwd!()]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&manafuel_root_for_workspace/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.join([&1, "development", ".codex", "bin", @hidden_stdio_launcher_name]))
  end

  defp normalize_shell_output(output) when is_binary(output) do
    if String.valid?(output) do
      output
    else
      inspect(output)
    end
  end

  defp truncate_shell_output(output) when is_binary(output) do
    if String.length(output) > @max_shell_output_chars do
      String.slice(output, 0, @max_shell_output_chars) <>
        "\n[truncated after #{@max_shell_output_chars} characters]"
    else
      output
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp local_shell_response(success, payload) do
    dynamic_tool_response(success, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp local_shell_error_payload(:invalid_local_shell_arguments) do
    %{
      "error" => %{
        "message" => "`local_shell` expects an object with `command`, optional `workdir`, and optional `timeout_ms`."
      }
    }
  end

  defp local_shell_error_payload(:local_shell_disabled) do
    %{
      "error" => %{
        "message" => "`local_shell` is disabled for issue agents; use hosted sandboxed `shell_command`."
      }
    }
  end

  defp local_shell_error_payload(:missing_local_shell_command) do
    %{
      "error" => %{
        "message" => "`local_shell` requires a non-empty `command` string."
      }
    }
  end

  defp local_shell_error_payload(:invalid_local_shell_timeout) do
    %{
      "error" => %{
        "message" => "`local_shell.timeout_ms` must be a positive integer."
      }
    }
  end

  defp local_shell_error_payload({:invalid_local_shell_workdir, workdir}) do
    %{
      "error" => %{
        "message" => "`local_shell.workdir` must be an existing directory.",
        "workdir" => workdir
      }
    }
  end

  defp local_shell_error_payload({:local_shell_workdir_outside_allowed_roots, workdir}) do
    %{
      "error" => %{
        "message" => "`local_shell.workdir` must be under the issue workspace, MANAfuel worktrees root, or MANAfuel control root.",
        "workdir" => workdir
      }
    }
  end

  defp local_shell_error_payload({:local_shell_product_coordination_checkout_blocked, workdir}) do
    %{
      "error" => %{
        "message" => "`local_shell` must use product worktrees under manafuel.worktree_root, not stale product coordination checkouts under development.",
        "workdir" => workdir
      }
    }
  end

  defp local_shell_error_payload({:unsafe_local_shell_command, reason}) do
    %{
      "error" => %{
        "message" => "`local_shell.command` was blocked by the MANAfuel command guard.",
        "reason" => reason
      }
    }
  end

  defp local_shell_error_payload({:local_shell_timeout, timeout_ms}) do
    %{
      "error" => %{
        "message" => "`local_shell.command` timed out.",
        "timeout_ms" => timeout_ms
      }
    }
  end

  defp local_shell_error_payload({:local_shell_execution_failed, reason}) do
    %{
      "error" => %{
        "message" => "`local_shell.command` failed before returning a process exit code.",
        "reason" => inspect(reason)
      }
    }
  end

  defp write_run_artifact_error_payload(:invalid_run_artifact_arguments) do
    %{
      "error" => %{
        "message" => "`write_run_artifact` expects an object with `path`, `content`, and optional `overwrite`."
      }
    }
  end

  defp write_run_artifact_error_payload(:missing_run_artifact_path) do
    %{
      "error" => %{
        "message" => "`write_run_artifact.path` is required."
      }
    }
  end

  defp write_run_artifact_error_payload(:invalid_run_artifact_content) do
    %{
      "error" => %{
        "message" => "`write_run_artifact.content` must be valid UTF-8 text."
      }
    }
  end

  defp write_run_artifact_error_payload(:invalid_run_artifact_overwrite) do
    %{
      "error" => %{
        "message" => "`write_run_artifact.overwrite` must be a boolean when provided."
      }
    }
  end

  defp write_run_artifact_error_payload({:run_artifact_path_must_be_relative, artifact_path}) do
    %{
      "error" => %{
        "message" => "`write_run_artifact.path` must be relative to the issue workspace.",
        "path" => artifact_path
      }
    }
  end

  defp write_run_artifact_error_payload({:run_artifact_path_outside_issue_runs, artifact_path}) do
    %{
      "error" => %{
        "message" => "`write_run_artifact.path` must stay under the issue workspace `runs` directory.",
        "path" => artifact_path
      }
    }
  end

  defp write_run_artifact_error_payload({:run_artifact_runs_root_reparse, artifact_path}) do
    %{
      "error" => %{
        "message" => "The issue workspace `runs` directory must not be a reparse escape.",
        "path" => artifact_path
      }
    }
  end

  defp write_run_artifact_error_payload({:run_artifact_path_unreadable, artifact_path, reason}) do
    %{
      "error" => %{
        "message" => "`write_run_artifact.path` could not be canonicalized safely.",
        "path" => artifact_path,
        "reason" => inspect(reason)
      }
    }
  end

  defp write_run_artifact_error_payload({:run_artifact_path_is_directory, artifact_path}) do
    %{
      "error" => %{
        "message" => "`write_run_artifact.path` must be a file path, not a directory.",
        "path" => artifact_path
      }
    }
  end

  defp write_run_artifact_error_payload({:run_artifact_content_too_large, bytes}) do
    %{
      "error" => %{
        "message" => "`write_run_artifact.content` exceeds the maximum artifact size.",
        "bytes" => bytes,
        "maxBytes" => @max_run_artifact_bytes
      }
    }
  end

  defp write_run_artifact_error_payload(:unsafe_run_artifact_content) do
    %{
      "error" => %{
        "code" => "unsafe_run_artifact_content",
        "message" => "`write_run_artifact.content` contains credential material and was rejected; use redacted or presence-only evidence."
      }
    }
  end

  defp write_run_artifact_error_payload({:run_artifact_write_failed, reason}) do
    %{
      "error" => %{
        "message" => "`write_run_artifact` failed to write the artifact.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
