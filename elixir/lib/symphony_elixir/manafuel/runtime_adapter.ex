defmodule SymphonyElixir.Manafuel.RuntimeAdapter do
  @moduledoc """
  Static, fail-closed validation for one MANAfuel Codex app-server session.

  This module owns no process, credentials, configuration, or live Codex call.
  A caller supplies a narrow generic transport client, which makes the complete
  protocol testable with deterministic fake transcripts.
  """

  alias SymphonyElixir.PathSafety

  @open_timeout_ms 10_000
  @request_timeout_ms 10_000
  @close_timeout_ms 5_000
  @total_timeout_ms 60_000
  @max_frame_bytes 1_048_576
  @max_noise_frames 256
  @max_pages 100
  @max_entries 10_000

  @worker_manifest %{
    "version" => "manafuel.agent-manifest.v2",
    "agent_id" => "implementation-worker",
    "model" => "gpt-5.6-terra",
    "reasoning_effort" => "medium",
    "sandbox" => %{"mode" => "workspace-write", "network_access" => false},
    "approval_policy" => "never",
    "tool_mode" => "code_mode_only",
    "tools" => ["exec", "wait"],
    "code_mode_nested_tools" => ["shell_command", "apply_patch"],
    "skills" => ["manafuel-control", "implementation-system", "frontend-system", "fullstack-api", "testing"],
    "capabilities" => ["repo-write", "repository.patch", "local-validation.run"],
    "credential_profile" => "none",
    "repository_roots" => [%{"token" => "ASSIGNED_REPOSITORY", "access" => "task-tracked", "allowlist" => "task-tracked-allowlist"}],
    "output_contract" => %{"format" => "json", "schema_path" => "output-contracts/implementation-result.v1.schema.json"},
    "concurrency" => 1,
    "no_auto_subagents" => true
  }

  @repository_artifacts %{
    "development" => %{"authority" => "github", "kind" => "repository", "native_id" => "manafuel/development"},
    "one" => %{"authority" => "github", "kind" => "repository", "native_id" => "manafuel/one"},
    "replicator" => %{"authority" => "github", "kind" => "repository", "native_id" => "manafuel/replicator"}
  }

  @context_keys [
    :repository,
    :workspace_root,
    :codex_home,
    :codex_executable,
    :codex_install_root,
    :expected_sha256,
    :argv,
    :env,
    :skill_roots,
    :instruction_paths,
    :timeouts
  ]
  @client_keys [:open_runtime, :request, :close_runtime]
  @expected_argv ["-c", "skills.bundled.enabled=false", "app-server", "--listen", "stdio://"]
  @skill_names ["manafuel-control", "implementation-system", "frontend-system", "fullstack-api", "testing"]
  @permission_profile_ids [":read-only", ":workspace", ":danger-full-access"]
  @thread_keys [
    "id",
    "extra",
    "sessionId",
    "forkedFromId",
    "parentThreadId",
    "preview",
    "ephemeral",
    "section",
    "sectionEnteredAt",
    "historyMode",
    "modelProvider",
    "createdAt",
    "updatedAt",
    "recencyAt",
    "status",
    "path",
    "cwd",
    "cliVersion",
    "source",
    "canAcceptDirectInput",
    "threadSource",
    "agentNickname",
    "agentRole",
    "gitInfo",
    "name",
    "turns"
  ]
  @allowed_env_keys [
    "APPDATA",
    "CODEX_HOME",
    "ComSpec",
    "HOMEDRIVE",
    "HOMEPATH",
    "LOCALAPPDATA",
    "NUMBER_OF_PROCESSORS",
    "OS",
    "PATH",
    "PATHEXT",
    "PROCESSOR_ARCHITECTURE",
    "ProgramData",
    "ProgramFiles",
    "ProgramFiles(x86)",
    "ProgramW6432",
    "SystemRoot",
    "TEMP",
    "TMP",
    "USERPROFILE",
    "WINDIR"
  ]
  @forbidden_env_key ~r/(?:api|auth|credential|key|password|proxy|secret|token)/i
  @disabled_features [
    "unified_exec",
    "code_mode_buffered_exec",
    "view_image",
    "hooks",
    "deferred_executor",
    "request_permissions_tool",
    "web_search_request",
    "web_search_cached",
    "standalone_web_search",
    "memories",
    "network_proxy",
    "multi_agent",
    "multi_agent_v2",
    "apps",
    "enable_mcp_apps",
    "tool_suggest",
    "recommended_plugins",
    "plugins",
    "executor_capability_discovery",
    "in_app_browser",
    "browser_use",
    "browser_use_full_cdp_access",
    "browser_use_external",
    "computer_use",
    "remote_plugin",
    "plugin_sharing",
    "image_generation",
    "skill_mcp_dependency_install",
    "skill_search",
    "default_mode_request_user_input",
    "guardian_approval",
    "guardianv2",
    "goals",
    "token_budget",
    "rollout_budget",
    "current_time_reminder",
    "tool_call_mcp_elicitation",
    "auth_elicitation",
    "artifact",
    "fast_mode",
    "use_agent_identity",
    "workspace_dependencies"
  ]
  @enabled_features ["shell_tool", "code_mode", "code_mode_host", "code_mode_only"]
  @canonical_uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @sha256 ~r/\A[a-f0-9]{64}\z/

  @type error ::
          :invalid_admission
          | :invalid_runtime_context
          | :unsafe_path
          | :forbidden_launch_environment
          | :runtime_open_failed
          | :runtime_timeout
          | :runtime_protocol_error
          | :runtime_version_mismatch
          | :auth_mismatch
          | :model_mismatch
          | :environment_mismatch
          | :skill_mismatch
          | :extension_mismatch
          | :permission_profile_mismatch
          | :effective_runtime_mismatch
          | :runtime_close_failed

  @type session :: %{
          transport: term(),
          thread_id: String.t(),
          repository: String.t(),
          workspace_root: String.t(),
          effective_runtime: map()
        }

  @type client :: %{
          open_runtime: (String.t(), map(), pos_integer() -> {:ok, term()} | {:error, term()}),
          request: (term(), pos_integer() | :notification, String.t(), map() | :omit, pos_integer() -> term()),
          close_runtime: (term(), pos_integer() -> term())
        }

  @spec open_validated(map(), map(), client()) :: {:ok, session()} | {:error, error()}
  def open_validated(admitted_run, runtime_context, client) do
    deadline_ms = monotonic_ms() + @total_timeout_ms

    with {:ok, admitted} <- validate_admitted_run(admitted_run),
         {:ok, context} <- validate_runtime_context(runtime_context, admitted),
         :ok <- validate_client(client),
         {:ok, transport} <- open_transport(context, client, deadline_ms),
         do: finish_open(transport, context, client, admitted, deadline_ms)
  end

  defp finish_open(transport, context, client, admitted, deadline_ms) do
    case run_protocol(transport, context, client, admitted, deadline_ms) do
      {:ok, session} ->
        {:ok, session}

      {:error, reason} ->
        _ = close_transport(transport, client)
        {:error, reason}
    end
  end

  @spec close(session(), client()) :: :ok | {:error, :runtime_close_failed}
  def close(session, client) do
    if valid_session?(session) and validate_client(client) == :ok do
      close_transport(session.transport, client)
    else
      {:error, :runtime_close_failed}
    end
  end

  defp validate_admitted_run(admitted_run) when is_map(admitted_run) do
    with :ok <- validate_admitted_shape(admitted_run),
         :ok <- validate_admitted_identity(admitted_run),
         :ok <- validate_admitted_repository(admitted_run),
         :ok <- validate_admitted_manifest(admitted_run) do
      {:ok, admitted_run}
    end
  end

  defp validate_admitted_run(_admitted_run), do: {:error, :invalid_admission}

  defp validate_admitted_shape(admitted_run) do
    if exact_keys?(admitted_run, [
         :linear_issue_id,
         :experiment_key,
         :agent_id,
         :repository,
         :repository_artifact,
         :status,
         :manifest
       ]) do
      :ok
    else
      {:error, :invalid_admission}
    end
  end

  defp validate_admitted_identity(admitted_run) do
    valid_issue_id? = is_binary(admitted_run.linear_issue_id) and String.match?(admitted_run.linear_issue_id, @canonical_uuid)
    valid_experiment? = is_binary(admitted_run.experiment_key) and byte_size(admitted_run.experiment_key) > 0

    if valid_issue_id? and valid_experiment? and admitted_run.agent_id === "implementation-worker" do
      :ok
    else
      {:error, :invalid_admission}
    end
  end

  defp validate_admitted_repository(admitted_run) do
    valid_repository? = Map.has_key?(@repository_artifacts, admitted_run.repository)
    valid_artifact? = valid_repository? and admitted_run.repository_artifact === Map.fetch!(@repository_artifacts, admitted_run.repository)

    if valid_artifact? and admitted_run.status in ["proposed", "running"] do
      :ok
    else
      {:error, :invalid_admission}
    end
  end

  defp validate_admitted_manifest(admitted_run) do
    if admitted_run.manifest === @worker_manifest do
      :ok
    else
      {:error, :invalid_admission}
    end
  end

  defp validate_runtime_context(context, admitted) when is_map(context) do
    with true <- exact_keys?(context, @context_keys) or {:error, :invalid_runtime_context},
         true <- context.repository === admitted.repository or {:error, :invalid_runtime_context},
         {:ok, workspace_root} <- safe_directory(context.workspace_root),
         {:ok, codex_home} <- safe_directory(context.codex_home),
         {:ok, install_root} <- safe_directory(context.codex_install_root),
         :ok <- require_true(dedicated_roots?(workspace_root, codex_home), :unsafe_path),
         {:ok, executable} <- safe_regular_file(context.codex_executable),
         :ok <- validate_executable(executable, install_root, context.expected_sha256),
         :ok <- require_true(context.argv === @expected_argv, :invalid_runtime_context),
         :ok <- validate_environment(context.env, codex_home),
         {:ok, skill_roots} <- validate_skill_roots(context.skill_roots, codex_home),
         {:ok, instruction_paths} <- validate_instruction_paths(context.instruction_paths, workspace_root),
         :ok <- validate_timeouts(context.timeouts) do
      {:ok,
       %{
         context
         | workspace_root: workspace_root,
           codex_home: codex_home,
           codex_install_root: install_root,
           codex_executable: executable,
           skill_roots: skill_roots,
           instruction_paths: instruction_paths
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_runtime_context(_context, _admitted), do: {:error, :invalid_runtime_context}

  defp safe_directory(path) when is_binary(path) do
    with {:ok, ^path} <- PathSafety.canonicalize(path),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(path) do
      {:ok, path}
    else
      _other -> {:error, :unsafe_path}
    end
  end

  defp safe_directory(_path), do: {:error, :unsafe_path}

  defp safe_regular_file(path) when is_binary(path) do
    with {:ok, ^path} <- PathSafety.canonicalize(path),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path) do
      {:ok, path}
    else
      _other -> {:error, :unsafe_path}
    end
  end

  defp safe_regular_file(_path), do: {:error, :unsafe_path}

  defp dedicated_roots?(workspace_root, codex_home) do
    workspace_root != codex_home and
      not contained_path?(workspace_root, codex_home) and
      not contained_path?(codex_home, workspace_root)
  end

  defp validate_executable(executable, install_root, expected_sha256) do
    with true <- Path.basename(executable) === "codex.exe" or {:error, :unsafe_path},
         true <- Path.dirname(executable) === install_root or {:error, :unsafe_path},
         true <- (is_binary(expected_sha256) and String.match?(expected_sha256, @sha256)) or {:error, :invalid_runtime_context},
         {:ok, bytes} <- File.read(executable),
         true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) === expected_sha256 or {:error, :unsafe_path} do
      :ok
    else
      {:error, :invalid_runtime_context} = error -> error
      _other -> {:error, :unsafe_path}
    end
  end

  defp validate_environment(environment, codex_home) when is_map(environment) do
    keys = Map.keys(environment)

    if Enum.all?(keys, &is_binary/1) and
         Enum.all?(keys, &(&1 in @allowed_env_keys)) and
         Enum.all?(environment, fn {key, value} -> is_binary(value) and byte_size(value) > 0 and (key === "CODEX_HOME" or not String.match?(key, @forbidden_env_key)) end) and
         Map.get(environment, "CODEX_HOME") === codex_home do
      :ok
    else
      {:error, :forbidden_launch_environment}
    end
  end

  defp validate_environment(_environment, _codex_home), do: {:error, :forbidden_launch_environment}

  defp validate_skill_roots(roots, codex_home) when is_list(roots) and length(roots) == 5 do
    expected_roots = canonical_skill_roots(codex_home)

    cond do
      roots != Enum.uniq(roots) ->
        {:error, :invalid_runtime_context}

      Enum.sort(roots) !== Enum.sort(expected_roots) ->
        {:error, :unsafe_path}

      true ->
        collect_skill_roots(expected_roots)
    end
  end

  defp validate_skill_roots(_roots, _codex_home), do: {:error, :invalid_runtime_context}

  defp canonical_skill_roots(codex_home) do
    Enum.map(@skill_names, &Path.join([codex_home, "skills", &1]))
  end

  defp collect_skill_roots(roots) do
    Enum.reduce_while(roots, {:ok, []}, &collect_skill_root/2)
  end

  defp collect_skill_root(root, {:ok, canonical_roots}) do
    with {:ok, canonical_root} <- safe_directory(root),
         {:ok, skill_file} <- safe_regular_file(Path.join(canonical_root, "SKILL.md")),
         true <- Path.dirname(skill_file) === canonical_root do
      {:cont, {:ok, canonical_roots ++ [canonical_root]}}
    else
      _other -> {:halt, {:error, :unsafe_path}}
    end
  end

  defp validate_instruction_paths(paths, workspace_root) when is_list(paths) and paths != [] do
    if paths == Enum.uniq(paths) do
      collect_instruction_paths(paths, workspace_root)
    else
      {:error, :invalid_runtime_context}
    end
  end

  defp validate_instruction_paths(_paths, _workspace_root), do: {:error, :invalid_runtime_context}

  defp collect_instruction_paths(paths, workspace_root) do
    Enum.reduce_while(paths, {:ok, []}, &collect_instruction_path(&1, &2, workspace_root))
  end

  defp collect_instruction_path(path, {:ok, canonical_paths}, workspace_root) do
    with {:ok, canonical_path} <- safe_regular_file(path),
         true <- contained_path?(canonical_path, workspace_root) do
      {:cont, {:ok, canonical_paths ++ [canonical_path]}}
    else
      _other -> {:halt, {:error, :unsafe_path}}
    end
  end

  defp validate_timeouts(timeouts) do
    expected = %{
      open: @open_timeout_ms,
      request: @request_timeout_ms,
      close: @close_timeout_ms,
      total: @total_timeout_ms
    }

    if timeouts === expected, do: :ok, else: {:error, :invalid_runtime_context}
  end

  defp validate_client(client) when is_map(client) do
    if exact_keys?(client, @client_keys) and
         is_function(client.open_runtime, 3) and
         is_function(client.request, 5) and
         is_function(client.close_runtime, 2) do
      :ok
    else
      {:error, :invalid_runtime_context}
    end
  end

  defp validate_client(_client), do: {:error, :invalid_runtime_context}

  defp open_transport(context, client, deadline_ms) do
    options = %{
      argv: @expected_argv,
      cwd: context.workspace_root,
      env: context.env,
      max_frame_bytes: @max_frame_bytes,
      max_noise_frames: @max_noise_frames
    }

    with {:ok, timeout} <- remaining_timeout(%{deadline_ms: deadline_ms}) do
      case invoke(client.open_runtime, [context.codex_executable, options, min(timeout, @open_timeout_ms)]) do
        {:ok, {:ok, transport}} when not is_nil(transport) -> {:ok, transport}
        {:ok, {:error, :timeout}} -> {:error, :runtime_timeout}
        _other -> {:error, :runtime_open_failed}
      end
    end
  end

  defp close_transport(transport, client) do
    case invoke(client.close_runtime, [transport, @close_timeout_ms]) do
      {:ok, :ok} -> :ok
      _other -> {:error, :runtime_close_failed}
    end
  end

  defp run_protocol(transport, context, client, admitted, deadline_ms) do
    state = %{
      transport: transport,
      client: client,
      context: context,
      deadline_ms: deadline_ms,
      next_id: 1
    }

    with {:ok, initialize, state} <- rpc(state, "initialize", initialize_params()),
         :ok <- validate_initialize(initialize, context),
         {:ok, state} <- notify_initialized(state),
         {:ok, account, state} <- rpc(state, "account/read", %{"refreshToken" => false}),
         :ok <- validate_account(account),
         {:ok, models, state} <- paginate(state, "model/list", %{"limit" => 100, "includeHidden" => true}),
         :ok <- validate_models(models),
         {:ok, environment_status, state} <- rpc(state, "environment/status", %{"environmentId" => "local"}),
         :ok <- validate_environment_status(environment_status),
         {:ok, environment_info, state} <- rpc(state, "environment/info", %{"environmentId" => "local"}),
         :ok <- validate_environment_info(environment_info, context),
         {:ok, skills, state} <- rpc(state, "skills/list", %{"cwds" => [context.workspace_root], "forceReload" => true}),
         :ok <- validate_skills(skills, context),
         {:ok, hooks, state} <- rpc(state, "hooks/list", %{"cwds" => [context.workspace_root]}),
         :ok <- validate_hooks(hooks, context),
         {:ok, profiles, state} <- paginate(state, "permissionProfile/list", %{"limit" => 100, "cwd" => context.workspace_root}),
         :ok <- validate_permission_profiles(profiles),
         {:ok, thread, state} <- rpc(state, "thread/start", thread_start_params(context)),
         {:ok, thread_id} <- validate_thread(thread, context),
         {:ok, features, state} <- paginate(state, "experimentalFeature/list", %{"limit" => 100, "threadId" => thread_id}),
         :ok <- validate_features(features),
         {:ok, mcp_statuses, _state} <- paginate(state, "mcpServerStatus/list", %{"limit" => 100, "threadId" => thread_id}),
         :ok <- require_true(mcp_statuses === [], :extension_mismatch) do
      {:ok, sanitized_session(transport, thread_id, admitted.repository, context)}
    else
      {:error, _reason} = error -> error
    end
  end

  defp initialize_params do
    %{
      "clientInfo" => %{"name" => "manafuel-symphony", "version" => "0.1.0"},
      "capabilities" => %{
        "experimentalApi" => true,
        "requestAttestation" => false,
        "mcpServerOpenaiFormElicitation" => false,
        "optOutNotificationMethods" => [],
        "extensions" => %{}
      }
    }
  end

  defp notify_initialized(state) do
    with {:ok, timeout} <- remaining_timeout(state),
         {:ok, :ok} <- invoke(state.client.request, [state.transport, :notification, "initialized", :omit, timeout]) do
      {:ok, state}
    else
      {:ok, {:error, :timeout}} -> {:error, :runtime_timeout}
      result -> if result === {:error, :runtime_timeout}, do: result, else: {:error, :runtime_protocol_error}
    end
  end

  defp rpc(state, method, params) do
    request_id = state.next_id

    with {:ok, timeout} <- remaining_timeout(state),
         {:ok, envelope} <- invoke_request(state.client, state.transport, request_id, method, params, timeout),
         {:ok, result} <- response_result(envelope, request_id) do
      {:ok, result, %{state | next_id: request_id + 1}}
    end
  end

  defp invoke_request(client, transport, request_id, method, params, timeout) do
    case invoke(client.request, [transport, request_id, method, params, timeout]) do
      {:ok, {:ok, envelope}} -> {:ok, envelope}
      {:ok, {:error, :timeout}} -> {:error, :runtime_timeout}
      _other -> {:error, :runtime_protocol_error}
    end
  end

  defp response_result(%{"frames" => frames, "noise" => noise, "eof" => false, "exited" => false} = envelope, request_id)
       when map_size(envelope) == 4 and is_list(frames) and is_list(noise) do
    with true <- length(noise) <= @max_noise_frames,
         true <- Enum.all?(noise, &(is_binary(&1) and byte_size(&1) <= @max_frame_bytes)),
         true <- length(frames) == 1,
         [frame] <- frames,
         true <- frame_under_limit?(frame),
         true <- valid_response_frame?(frame, request_id) do
      {:ok, Map.fetch!(frame, "result")}
    else
      _other -> {:error, :runtime_protocol_error}
    end
  end

  defp response_result(_envelope, _request_id), do: {:error, :runtime_protocol_error}

  defp valid_response_frame?(frame, request_id) when is_map(frame) do
    exact_keys?(frame, ["id", "result"]) and frame["id"] === request_id and json_value?(frame["result"])
  end

  defp valid_response_frame?(_frame, _request_id), do: false

  defp frame_under_limit?(frame) do
    case Jason.encode(frame) do
      {:ok, encoded} -> byte_size(encoded) <= @max_frame_bytes
      {:error, _reason} -> false
    end
  end

  defp json_value?(value) when is_binary(value) or is_boolean(value) or is_nil(value) or is_number(value), do: true
  defp json_value?(values) when is_list(values), do: Enum.all?(values, &json_value?/1)
  defp json_value?(value) when is_map(value), do: Enum.all?(value, fn {key, nested_value} -> is_binary(key) and json_value?(nested_value) end)
  defp json_value?(_value), do: false

  defp paginate(state, method, params) do
    collect_pages(state, method, params, nil, [], [], 0)
  end

  defp collect_pages(_state, _method, _params, _cursor, _seen_cursors, _entries, @max_pages), do: {:error, :runtime_protocol_error}

  defp collect_pages(state, method, params, cursor, seen_cursors, entries, page_count) do
    page_params = if is_nil(cursor), do: params, else: Map.put(params, "cursor", cursor)

    with {:ok, page, next_state} <- rpc(state, method, page_params),
         {:ok, page_entries, next_cursor} <- page_entries(page),
         true <- length(entries) + length(page_entries) <= @max_entries or {:error, :runtime_protocol_error},
         :ok <- validate_next_cursor(next_cursor, seen_cursors) do
      next_entries = entries ++ page_entries

      if is_nil(next_cursor) do
        {:ok, next_entries, next_state}
      else
        collect_pages(
          next_state,
          method,
          params,
          next_cursor,
          [next_cursor | seen_cursors],
          next_entries,
          page_count + 1
        )
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp page_entries(page) when is_map(page) and map_size(page) == 2 do
    with {:ok, entries} <- Map.fetch(page, "data"),
         {:ok, next_cursor} <- Map.fetch(page, "nextCursor"),
         true <- is_list(entries),
         true <- is_nil(next_cursor) or (is_binary(next_cursor) and byte_size(next_cursor) > 0) do
      {:ok, entries, next_cursor}
    else
      _other -> {:error, :runtime_protocol_error}
    end
  end

  defp page_entries(_page), do: {:error, :runtime_protocol_error}

  defp validate_next_cursor(nil, _seen_cursors), do: :ok

  defp validate_next_cursor(cursor, seen_cursors) when is_binary(cursor) do
    if cursor in seen_cursors, do: {:error, :runtime_protocol_error}, else: :ok
  end

  defp validate_initialize(result, context) do
    if exact_keys?(result, ["userAgent", "codexHome", "platformFamily", "platformOs"]) and
         result["codexHome"] === context.codex_home and
         result["platformFamily"] === "windows" and
         result["platformOs"] === "windows" and
         is_binary(result["userAgent"]) and
         valid_user_agent?(result["userAgent"]),
       do: :ok,
       else: {:error, :runtime_version_mismatch}
  end

  defp valid_user_agent?(user_agent) do
    prefix = "manafuel-symphony/0.147.0 ("
    suffix = " (manafuel-symphony; 0.1.0)"
    interior_size = byte_size(user_agent) - byte_size(prefix) - byte_size(suffix)

    interior_size > 0 and
      String.starts_with?(user_agent, prefix) and
      String.ends_with?(user_agent, suffix) and
      user_agent
      |> binary_part(byte_size(prefix), interior_size)
      |> :binary.bin_to_list()
      |> Enum.all?(&(&1 >= 0x20 and &1 <= 0x7E))
  end

  defp validate_account(%{"requiresOpenaiAuth" => true, "account" => account} = result) when map_size(result) == 2 do
    if valid_chatgpt_account?(account), do: :ok, else: {:error, :auth_mismatch}
  end

  defp validate_account(_result), do: {:error, :auth_mismatch}

  defp valid_chatgpt_account?(%{"type" => "chatgpt", "email" => email, "planType" => plan_type} = account) when map_size(account) == 3 do
    (is_nil(email) or is_binary(email)) and
      plan_type in [
        "free",
        "go",
        "plus",
        "pro",
        "prolite",
        "team",
        "self_serve_business_prolite",
        "self_serve_business_usage_based",
        "business",
        "ent26",
        "enterprise_cbp_automation",
        "enterprise_cbp_usage_based",
        "enterprise",
        "edu",
        "unknown"
      ]
  end

  defp valid_chatgpt_account?(_account), do: false

  defp validate_models(models) when is_list(models) do
    matching_models = Enum.filter(models, &(is_map(&1) and Map.get(&1, "model") === "gpt-5.6-terra"))

    case matching_models do
      [model] ->
        if valid_model?(model), do: :ok, else: {:error, :model_mismatch}

      _other ->
        {:error, :model_mismatch}
    end
  end

  defp valid_model?(model) when is_map(model) do
    required = [
      "id",
      "model",
      "upgrade",
      "upgradeInfo",
      "availabilityNux",
      "displayName",
      "description",
      "modelSpecialty",
      "hidden",
      "supportedReasoningEfforts",
      "defaultReasoningEffort",
      "inputModalities",
      "supportsPersonality",
      "additionalSpeedTiers",
      "serviceTiers",
      "defaultServiceTier",
      "isDefault"
    ]

    Enum.all?([
      exact_keys?(model, required),
      model["id"] === "gpt-5.6-terra",
      model["model"] === "gpt-5.6-terra",
      is_binary(model["displayName"]),
      is_binary(model["description"]),
      is_boolean(model["hidden"]),
      is_binary(model["defaultReasoningEffort"]),
      is_list(model["inputModalities"]),
      is_boolean(model["supportsPersonality"]),
      is_list(model["additionalSpeedTiers"]),
      is_list(model["serviceTiers"]),
      is_boolean(model["isDefault"]),
      valid_reasoning_efforts?(model["supportedReasoningEfforts"])
    ])
  end

  defp valid_reasoning_efforts?(efforts) when is_list(efforts) do
    with true <- efforts != [],
         true <- Enum.all?(efforts, &valid_reasoning_effort?/1),
         names <- Enum.map(efforts, & &1["reasoningEffort"]),
         true <- names === Enum.uniq(names),
         [%{"description" => description}] <- Enum.filter(efforts, &(&1["reasoningEffort"] === "medium")),
         true <- is_binary(description) and byte_size(description) > 0 do
      true
    else
      _other -> false
    end
  end

  defp valid_reasoning_efforts?(_efforts), do: false

  defp valid_reasoning_effort?(%{"reasoningEffort" => effort, "description" => description} = option) when map_size(option) == 2,
    do: is_binary(effort) and byte_size(effort) > 0 and is_binary(description)

  defp valid_reasoning_effort?(_option), do: false

  defp validate_environment_status(result) do
    if result === %{"status" => "ready"}, do: :ok, else: {:error, :environment_mismatch}
  end

  defp validate_environment_info(result, context) when is_map(result) do
    valid_shell = valid_shell?(result["shell"])
    expected_cwd = file_uri(context.workspace_root)

    if map_size(result) == 2 and is_binary(expected_cwd) and result["cwd"] === expected_cwd and valid_shell do
      :ok
    else
      {:error, :environment_mismatch}
    end
  end

  defp validate_environment_info(_result, _context), do: {:error, :environment_mismatch}

  defp valid_shell?(%{"name" => name, "path" => path} = shell) when map_size(shell) == 2 do
    is_binary(name) and byte_size(name) > 0 and is_binary(path) and Path.type(path) === :absolute and byte_size(path) > 0
  end

  defp valid_shell?(_shell), do: false

  defp validate_skills(result, context) when is_map(result) do
    with true <- exact_keys?(result, ["data"]),
         [%{"cwd" => cwd, "errors" => [], "skills" => skills} = entry] <- result["data"],
         true <- exact_keys?(entry, ["cwd", "errors", "skills"]),
         true <- cwd === context.workspace_root,
         skills when is_list(skills) <- skills,
         true <- length(skills) == length(@skill_names),
         true <- Enum.all?(skills, &valid_skill?(&1, context.codex_home)),
         true <- valid_skill_names?(skills) do
      :ok
    else
      _other -> {:error, :skill_mismatch}
    end
  end

  defp validate_skills(_result, _context), do: {:error, :skill_mismatch}

  defp valid_skill_names?(skills) do
    if Enum.all?(skills, &is_map/1) do
      names = Enum.map(skills, &Map.get(&1, "name"))
      names === Enum.uniq(names) and Enum.sort(names) === Enum.sort(@skill_names)
    else
      false
    end
  end

  defp valid_skill?(skill, codex_home) when is_map(skill) do
    required_keys = ["name", "description", "path", "scope", "enabled"]
    optional_keys = ["shortDescription", "interface", "dependencies"]
    allowed_keys = required_keys ++ optional_keys

    with true <- Enum.all?(required_keys, &Map.has_key?(skill, &1)),
         true <- Enum.all?(Map.keys(skill), &(&1 in allowed_keys)),
         true <- valid_skill_metadata?(skill),
         true <- valid_skill_optionals?(skill),
         expected_root <- Path.join([codex_home, "skills", skill["name"]]),
         {:ok, canonical_path} <- safe_regular_file(skill["path"]),
         true <- Path.dirname(canonical_path) === expected_root do
      true
    else
      _other -> false
    end
  end

  defp valid_skill?(_skill, _codex_home), do: false

  defp valid_skill_metadata?(skill) do
    Enum.all?([
      skill["name"] in @skill_names,
      is_binary(skill["description"]) and byte_size(skill["description"]) > 0,
      is_binary(skill["path"]),
      skill["scope"] === "user",
      skill["enabled"] === true
    ])
  end

  defp valid_skill_optionals?(skill) do
    (not Map.has_key?(skill, "shortDescription") or is_binary(skill["shortDescription"])) and
      (not Map.has_key?(skill, "interface") or valid_skill_interface?(skill["interface"])) and
      (not Map.has_key?(skill, "dependencies") or valid_skill_dependencies?(skill["dependencies"]))
  end

  defp valid_skill_interface?(interface) when is_map(interface) do
    allowed_keys = ["displayName", "shortDescription", "iconSmall", "iconLarge", "iconSmallUrl", "iconLargeUrl", "brandColor", "defaultPrompt"]

    Enum.all?(Map.keys(interface), &(&1 in allowed_keys)) and
      Enum.all?(interface, &valid_skill_interface_field?/1)
  end

  defp valid_skill_interface?(_interface), do: false

  defp valid_skill_interface_field?({key, value}) when key in ["iconSmall", "iconLarge"] do
    is_nil(value) or (is_binary(value) and Path.type(value) === :absolute)
  end

  defp valid_skill_interface_field?({_key, value}), do: is_nil(value) or is_binary(value)

  defp valid_skill_dependencies?(%{"tools" => tools} = dependencies) when map_size(dependencies) == 1 and is_list(tools), do: tools === []
  defp valid_skill_dependencies?(_dependencies), do: false

  defp validate_hooks(result, context) do
    expected = %{"data" => [%{"cwd" => context.workspace_root, "hooks" => [], "warnings" => [], "errors" => []}]}
    if result === expected, do: :ok, else: {:error, :extension_mismatch}
  end

  defp validate_permission_profiles(profiles) when is_list(profiles) do
    if Enum.all?(profiles, &is_map/1) do
      ids = Enum.map(profiles, &Map.get(&1, "id"))

      if ids === @permission_profile_ids and Enum.all?(profiles, &valid_permission_profile?/1) and Enum.find(profiles, &(&1["id"] === ":workspace"))["allowed"] === true do
        :ok
      else
        {:error, :permission_profile_mismatch}
      end
    else
      {:error, :permission_profile_mismatch}
    end
  end

  defp valid_permission_profile?(%{"id" => id, "description" => description, "allowed" => allowed} = profile) when map_size(profile) == 3 do
    id in @permission_profile_ids and (is_nil(description) or is_binary(description)) and is_boolean(allowed)
  end

  defp valid_permission_profile?(_profile), do: false

  defp validate_features(features) when is_list(features) do
    expected = Map.merge(Map.new(@enabled_features, &{&1, true}), Map.new(@disabled_features, &{&1, false}))

    with true <- Enum.all?(features, &is_map/1),
         names <- Enum.map(features, &Map.get(&1, "name")),
         true <- Enum.all?(features, &valid_feature?/1),
         true <- length(names) === length(Enum.uniq(names)),
         true <- Enum.all?(Map.keys(expected), &(&1 in names)),
         true <- Enum.all?(features, &expected_feature_enabled?(&1, expected)) do
      :ok
    else
      _other -> {:error, :extension_mismatch}
    end
  end

  defp expected_feature_enabled?(feature, expected) do
    not Map.has_key?(expected, feature["name"]) or Map.fetch!(expected, feature["name"]) === feature["enabled"]
  end

  defp valid_feature?(feature) when is_map(feature) and map_size(feature) == 7 do
    case feature do
      %{
        "name" => name,
        "stage" => stage,
        "displayName" => display_name,
        "description" => description,
        "announcement" => announcement,
        "enabled" => enabled,
        "defaultEnabled" => default_enabled
      } ->
        Enum.all?([
          is_binary(name) and name != "",
          stage in ["beta", "underDevelopment", "stable", "deprecated", "removed"],
          is_nil(display_name) or is_binary(display_name),
          is_nil(description) or is_binary(description),
          is_nil(announcement) or is_binary(announcement),
          is_boolean(enabled),
          is_boolean(default_enabled)
        ])

      _other ->
        false
    end
  end

  defp valid_feature?(_feature), do: false

  defp thread_start_params(context) do
    %{
      "model" => "gpt-5.6-terra",
      "modelProvider" => "openai",
      "allowProviderModelFallback" => false,
      "serviceTier" => "default",
      "cwd" => context.workspace_root,
      "runtimeWorkspaceRoots" => [context.workspace_root],
      "approvalPolicy" => "never",
      "approvalsReviewer" => "user",
      "permissions" => ":workspace",
      "serviceName" => "manafuel-symphony",
      "ephemeral" => true,
      "sessionStartSource" => "startup",
      "environments" => [%{"environmentId" => "local", "cwd" => context.workspace_root, "runtimeWorkspaceRoots" => [context.workspace_root]}],
      "dynamicTools" => [],
      "selectedCapabilityRoots" => [],
      "config" => runtime_config()
    }
  end

  defp runtime_config do
    %{
      "model_reasoning_effort" => "medium",
      "forced_login_method" => "chatgpt",
      "service_tier" => "default",
      "web_search" => "disabled",
      "mcp_servers" => %{},
      "skills" => %{"bundled" => %{"enabled" => false}},
      "tools" => %{"experimental_request_user_input" => %{"enabled" => false}, "update_plan" => %{"enabled" => false}},
      "features" =>
        Map.merge(Map.new(@disabled_features, &{&1, false}), %{
          "shell_tool" => true,
          "code_mode" => %{"enabled" => true, "excluded_tool_namespaces" => [], "direct_only_tool_namespaces" => []},
          "code_mode_host" => %{"enabled" => true, "disable_in_process_fallback" => true},
          "code_mode_only" => true,
          "tool_registry" => %{"error_on_tool_collisions" => true}
        })
    }
  end

  defp validate_thread(result, context) when is_map(result) do
    with thread <- Map.get(result, "thread"),
         true <- valid_thread?(thread, context),
         %{"id" => thread_id} <- thread,
         true <- canonical_uuid_v7?(thread_id) do
      expected = %{
        "thread" => thread,
        "model" => "gpt-5.6-terra",
        "modelProvider" => "openai",
        "reasoningEffort" => "medium",
        "serviceTier" => nil,
        "cwd" => context.workspace_root,
        "runtimeWorkspaceRoots" => [context.workspace_root],
        "approvalPolicy" => "never",
        "approvalsReviewer" => "user",
        "activePermissionProfile" => %{"id" => ":workspace", "extends" => nil},
        "sandbox" => %{
          "type" => "workspaceWrite",
          "writableRoots" => [],
          "networkAccess" => false,
          "excludeTmpdirEnvVar" => false,
          "excludeSlashTmp" => false
        },
        "instructionSources" => context.instruction_paths,
        "multiAgentMode" => "explicitRequestOnly"
      }

      if result === expected do
        {:ok, thread_id}
      else
        {:error, :effective_runtime_mismatch}
      end
    else
      _other -> {:error, :effective_runtime_mismatch}
    end
  end

  defp validate_thread(_result, _context), do: {:error, :effective_runtime_mismatch}

  defp valid_thread?(thread, context) when is_map(thread) do
    timestamps = [thread["createdAt"], thread["updatedAt"], thread["recencyAt"]]

    Enum.all?([
      exact_keys?(thread, @thread_keys),
      canonical_uuid_v7?(thread["id"]),
      thread["sessionId"] === thread["id"],
      thread["extra"] === nil,
      thread["forkedFromId"] === nil,
      thread["parentThreadId"] === nil,
      thread["preview"] === "",
      thread["ephemeral"] === true,
      thread["section"] === nil,
      thread["sectionEnteredAt"] === nil,
      thread["historyMode"] === "legacy",
      thread["modelProvider"] === "openai",
      Enum.all?(timestamps, &(is_integer(&1) and &1 > 0)),
      thread["createdAt"] <= thread["updatedAt"],
      thread["updatedAt"] <= thread["recencyAt"],
      thread["status"] === %{"type" => "idle"},
      thread["path"] === nil,
      thread["cwd"] === context.workspace_root,
      thread["cliVersion"] === "0.147.0",
      thread["source"] === "appServer",
      thread["canAcceptDirectInput"] === true,
      thread["threadSource"] === nil,
      thread["agentNickname"] === nil,
      thread["agentRole"] === nil,
      thread["gitInfo"] === nil,
      thread["name"] === nil,
      thread["turns"] === []
    ])
  end

  defp valid_thread?(_thread, _context), do: false

  defp sanitized_session(transport, thread_id, repository, context) do
    %{
      transport: transport,
      thread_id: thread_id,
      repository: repository,
      workspace_root: context.workspace_root,
      effective_runtime: %{
        model: "gpt-5.6-terra",
        provider: "openai",
        reasoning_effort: "medium",
        service_tier: nil,
        cwd: context.workspace_root,
        runtime_roots: [context.workspace_root],
        approval_policy: "never",
        approvals_reviewer: "user",
        permission_profile: %{id: ":workspace", extends: nil},
        sandbox: %{
          type: "workspaceWrite",
          network_access: false,
          writable_roots: [],
          exclude_tmpdir_env_var: false,
          exclude_slash_tmp: false
        },
        instruction_paths: context.instruction_paths,
        multi_agent_mode: "explicitRequestOnly",
        attestation: %{
          kind: "source_derived",
          codex_version: "0.147.0",
          tool_mode: "code_mode_only",
          tools: ["exec", "wait"],
          nested_tools: ["shell_command", "apply_patch"],
          credential_profile: "none",
          no_auto_subagents: true
        },
        capabilities: %{permission_profile: ":workspace", nested_tools: ["shell_command", "apply_patch"]}
      }
    }
  end

  defp remaining_timeout(state) do
    remaining = state.deadline_ms - monotonic_ms()
    if remaining > 0, do: {:ok, min(remaining, @request_timeout_ms)}, else: {:error, :runtime_timeout}
  end

  defp valid_session?(session) when is_map(session) do
    exact_keys?(session, [:transport, :thread_id, :repository, :workspace_root, :effective_runtime]) and
      not is_nil(session.transport) and
      is_binary(session.thread_id) and
      byte_size(session.thread_id) > 0 and
      is_binary(session.repository) and
      is_binary(session.workspace_root) and
      is_map(session.effective_runtime)
  end

  defp valid_session?(_session), do: false

  defp exact_keys?(map, keys) when is_map(map), do: map_size(map) == length(keys) and Enum.all?(Map.keys(map), &(&1 in keys))

  defp contained_path?(path, root) when is_binary(path) and is_binary(root) do
    relative = Path.relative_to(path, root)

    relative in ["", "."] or
      (Path.type(relative) !== :absolute and relative !== ".." and
         not String.starts_with?(relative, "../") and not String.starts_with?(relative, "..\\"))
  end

  defp file_uri(path) when is_binary(path) do
    cond do
      windows_drive_path?(path) ->
        normalized_path = String.replace(path, "\\", "/")
        <<drive::binary-size(1), ":/", remainder::binary>> = normalized_path
        "file:///" <> String.upcase(drive) <> ":/" <> encode_file_uri_path(remainder)

      unc_path?(path) ->
        path
        |> String.replace("\\", "/")
        |> unc_file_uri()

      String.starts_with?(path, "/") ->
        "file://" <> encode_file_uri_path(path)

      true ->
        nil
    end
  end

  defp file_uri(_path), do: nil

  @doc false
  @spec file_uri_for_test(term()) :: String.t() | nil
  def file_uri_for_test(path), do: file_uri(path)

  defp unc_file_uri(normalized_path) do
    with [host, remainder] when host != "" and remainder != "" <- String.split(String.trim_leading(normalized_path, "//"), "/", parts: 2),
         {:ok, canonical_host} <- canonical_unc_host(host) do
      "file://" <> canonical_host <> "/" <> encode_file_uri_path(remainder)
    else
      _other -> nil
    end
  end

  defp windows_drive_path?(<<drive, ?:, separator, _rest::binary>>) do
    (drive in ?A..?Z or drive in ?a..?z) and separator in [?/, ?\\]
  end

  defp windows_drive_path?(_path), do: false

  defp unc_path?(path), do: String.starts_with?(path, "\\\\") or String.starts_with?(path, "//")

  defp canonical_unc_host(host) do
    if valid_unc_host?(host), do: host |> String.downcase() |> canonical_unc_host_from_normalized(), else: :error
  end

  defp canonical_unc_host_from_normalized(host) do
    case canonical_ipv4_host(host) do
      {:ok, ipv4} -> {:ok, ipv4}
      :not_ipv4 -> canonical_unc_domain_host(host)
      :invalid -> :error
    end
  end

  defp canonical_unc_domain_host("localhost"), do: {:ok, ""}
  defp canonical_unc_domain_host(host), do: {:ok, host}

  defp canonical_ipv4_host(host) do
    parts = String.split(host, ".", trim: false)
    numeric_parts = if length(parts) > 1 and List.last(parts) === "", do: Enum.take(parts, length(parts) - 1), else: parts
    final_part = List.last(numeric_parts) || ""

    case parse_ipv4_number(final_part) do
      {:ok, _number} -> canonical_ipv4_parts(numeric_parts)
      :not_numeric -> :not_ipv4
      :invalid -> :invalid
    end
  end

  defp canonical_ipv4_parts(parts) when length(parts) in 1..4 do
    parsed_parts = Enum.map(parts, &parse_ipv4_number/1)

    if Enum.all?(parsed_parts, &match?({:ok, _number}, &1)) do
      values = Enum.map(parsed_parts, fn {:ok, value} -> value end)
      prefix = Enum.take(values, length(values) - 1)
      final_value = List.last(values)

      if Enum.all?(prefix, &(&1 <= 255)) and final_value < max_final_ipv4_value(length(values)) do
        values
        |> ipv4_value()
        |> format_ipv4()
        |> then(&{:ok, &1})
      else
        :invalid
      end
    else
      :invalid
    end
  end

  defp canonical_ipv4_parts(_parts), do: :invalid

  defp parse_ipv4_number("0x"), do: {:ok, 0}

  defp parse_ipv4_number(<<"0x", digits::binary>>), do: parse_prefixed_ipv4_number(digits, 16)

  defp parse_ipv4_number(<<"0", rest::binary>> = number) do
    if ascii_digits?(number) do
      if rest === "" or ascii_octal_digits?(rest), do: {:ok, String.to_integer(number, 8)}, else: :invalid
    else
      :not_numeric
    end
  end

  defp parse_ipv4_number(number) do
    if ascii_digits?(number), do: {:ok, String.to_integer(number)}, else: :not_numeric
  end

  defp parse_prefixed_ipv4_number(digits, radix) do
    if ascii_digits_for_radix?(digits, radix), do: {:ok, String.to_integer(digits, radix)}, else: :not_numeric
  end

  defp ascii_digits?(string), do: byte_size(string) > 0 and Enum.all?(:binary.bin_to_list(string), &(&1 in ?0..?9))
  defp ascii_octal_digits?(string), do: byte_size(string) > 0 and Enum.all?(:binary.bin_to_list(string), &(&1 in ?0..?7))

  defp ascii_digits_for_radix?(string, 16) do
    byte_size(string) > 0 and
      Enum.all?(:binary.bin_to_list(string), fn character ->
        character in ?0..?9 or character in ?A..?F or character in ?a..?f
      end)
  end

  defp max_final_ipv4_value(1), do: 4_294_967_296
  defp max_final_ipv4_value(2), do: 16_777_216
  defp max_final_ipv4_value(3), do: 65_536
  defp max_final_ipv4_value(4), do: 256

  defp ipv4_value([value]), do: value
  defp ipv4_value([first, value]), do: first * 16_777_216 + value
  defp ipv4_value([first, second, value]), do: first * 16_777_216 + second * 65_536 + value
  defp ipv4_value([first, second, third, value]), do: first * 16_777_216 + second * 65_536 + third * 256 + value

  defp format_ipv4(value) do
    first = div(value, 16_777_216)
    remainder = rem(value, 16_777_216)
    second = div(remainder, 65_536)
    remainder = rem(remainder, 65_536)
    third = div(remainder, 256)
    fourth = rem(remainder, 256)
    Enum.join([first, second, third, fourth], ".")
  end

  defp valid_unc_host?(host) do
    host
    |> :binary.bin_to_list()
    |> Enum.all?(fn character -> character in ?A..?Z or character in ?a..?z or character in ?0..?9 or character in ~c".-" end)
  end

  defp encode_file_uri_path(path), do: URI.encode(path, &file_uri_path_character?/1)

  defp file_uri_path_character?(character) do
    character === ?/ or
      (character >= 0x21 and character <= 0x7E and character not in ~c"\"#%<>?`{}\\")
  end

  defp canonical_uuid_v7?(thread_id) when is_binary(thread_id) do
    String.match?(thread_id, ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/)
  end

  defp canonical_uuid_v7?(_thread_id), do: false

  defp require_true(true, _error), do: :ok
  defp require_true(false, error), do: {:error, error}

  defp invoke(callback, args) do
    {:ok, apply(callback, args)}
  rescue
    _exception -> {:error, :callback_failure}
  catch
    _kind, _reason -> {:error, :callback_failure}
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
