defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer

  alias SymphonyElixir.Manafuel.{
    AdmissionAdapter,
    AppServerPortClient,
    DeliveryAdapter,
    RuntimeAdapter
  }

  alias SymphonyElixir.{Config, PromptBuilder, Tracker, Workflow, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    if manafuel_delivery_enabled?(opts) do
      run_manafuel_issue(issue, codex_update_recipient, opts, worker_host)
    else
      run_legacy_issue(issue, codex_update_recipient, opts, worker_host)
    end
  end

  defp run_legacy_issue(issue, codex_update_recipient, opts, worker_host) do
    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_manafuel_issue(_issue, _recipient, _opts, worker_host) when not is_nil(worker_host),
    do: {:error, :remote_worker_not_supported}

  defp run_manafuel_issue(%Issue{} = issue, recipient, opts, nil) do
    attempt = normalize_attempt(Keyword.get(opts, :attempt))
    dependencies = Keyword.get_lazy(opts, :manafuel_admission_dependencies, &production_admission_dependencies/0)

    with {:ok, admitted_run} <-
           AdmissionAdapter.admit(issue.id, issue.description || "", dependencies),
         delivery_client <-
           Keyword.get_lazy(opts, :manafuel_delivery_client, fn ->
             DeliveryAdapter.client(admitted_run, issue)
           end),
         prepare_result <-
           DeliveryAdapter.prepare(
             admitted_run,
             issue,
             Config.local_workspace_root(),
             attempt,
             delivery_client
           ) do
      handle_manafuel_prepare(
        prepare_result,
        admitted_run,
        issue,
        recipient,
        opts,
        delivery_client
      )
    end
  end

  defp handle_manafuel_prepare({:waiting, result}, _admitted, issue, _recipient, _opts, _client) do
    Logger.info("Delivery already waiting for #{issue_context(issue)} pull_request=#{result.pull_request.number}")
    :ok
  end

  defp handle_manafuel_prepare({:complete, result}, _admitted, issue, _recipient, _opts, _client) do
    Logger.info("Delivery already complete for #{issue_context(issue)} pull_request=#{result.pull_request.number}")
    :ok
  end

  defp handle_manafuel_prepare({:ok, delivery_run}, admitted, issue, recipient, opts, delivery_client) do
    send_worker_runtime_info(recipient, issue, nil, delivery_run.repository_path)
    run_validated_manafuel_turn(admitted, delivery_run, issue, recipient, opts, delivery_client)
  end

  defp handle_manafuel_prepare({:error, reason}, _admitted, _issue, _recipient, _opts, _client),
    do: {:error, reason}

  defp run_validated_manafuel_turn(admitted, delivery_run, issue, recipient, opts, delivery_client) do
    runtime_client = Keyword.get_lazy(opts, :manafuel_runtime_client, &AppServerPortClient.client/0)
    context_builder = Keyword.get(opts, :manafuel_runtime_context_builder, &production_runtime_context/2)

    with {:ok, runtime_context} <- context_builder.(admitted, delivery_run.repository_path),
         {:ok, runtime_session} <-
           RuntimeAdapter.open_validated(admitted, runtime_context, runtime_client) do
      finish_validated_manafuel_turn(
        runtime_session,
        runtime_client,
        delivery_run,
        delivery_client,
        issue,
        recipient,
        opts
      )
    end
  end

  defp finish_validated_manafuel_turn(
         runtime_session,
         runtime_client,
         delivery_run,
         delivery_client,
         issue,
         recipient,
         opts
       ) do
    case AppServerPortClient.handoff(runtime_session.transport, 5_000) do
      {:ok, port, metadata} ->
        adopt_and_run_manafuel(
          runtime_session,
          port,
          metadata,
          delivery_run,
          delivery_client,
          issue,
          recipient,
          opts
        )

      {:error, reason} ->
        _ = RuntimeAdapter.close(runtime_session, runtime_client)
        {:error, reason}
    end
  end

  defp adopt_and_run_manafuel(
         runtime_session,
         port,
         metadata,
         delivery_run,
         delivery_client,
         issue,
         recipient,
         opts
       ) do
    case AppServer.adopt_validated_session(runtime_session, port, metadata) do
      {:ok, app_session} ->
        run_and_stop_manafuel(
          app_session,
          delivery_run,
          delivery_client,
          issue,
          recipient,
          opts
        )

      {:error, reason} ->
        if Port.info(port) != nil, do: Port.close(port)
        {:error, reason}
    end
  end

  defp run_and_stop_manafuel(app_session, delivery_run, delivery_client, issue, recipient, opts) do
    with {:ok, _turn} <-
           AppServer.run_turn(
             app_session,
             manafuel_prompt(issue, opts),
             issue,
             on_message: codex_message_handler(recipient, issue)
           ),
         {:ok, _delivery} <- DeliveryAdapter.deliver(delivery_run, delivery_client) do
      :ok
    end
  after
    AppServer.stop_session(app_session)
  end

  defp manafuel_prompt(issue, opts) do
    PromptBuilder.build_prompt(issue, opts) <>
      """

      Host delivery boundary:
      - Implement and validate the requested change in this repository only.
      - Do not commit, push, create or merge a pull request, or update Linear.
      - Do not call GitHub, Linear, Supabase, or deployment systems.
      - The host runs the final candidate gate and delivery after this one turn.
      """
  end

  defp manafuel_delivery_enabled?(opts) do
    case Keyword.fetch(opts, :manafuel_delivery_enabled) do
      {:ok, enabled} when is_boolean(enabled) ->
        enabled

      _other ->
        case workflow_manafuel_config() do
          {:ok, %{"delivery_loop" => %{"enabled" => true}}} -> true
          _other -> false
        end
    end
  end

  defp normalize_attempt(attempt) when attempt in [0, 1], do: attempt
  defp normalize_attempt(_attempt), do: 0

  defp production_admission_dependencies do
    {:ok, config} = workflow_manafuel_config()
    control_root = normalize_control_root(config["control_root"])
    model_metadata_path = model_metadata_path(config)

    %{
      initiative_loader: &load_growth_initiative/1,
      binding_marker_validator: fn marker_text, experiment_key, agent_id ->
        case run_manifest_command(control_root, [
               "-Action",
               "ValidateBindingMarker",
               "-AgentId",
               agent_id,
               "-MarkerText",
               marker_text,
               "-ExperimentKey",
               experiment_key
             ]) do
          {:ok, _output} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end,
      manifest_resolver: fn agent_id ->
        with {:ok, output} <-
               run_manifest_command(control_root, [
                 "-Action",
                 "Resolve",
                 "-AgentId",
                 agent_id,
                 "-ModelMetadataPath",
                 model_metadata_path
               ]),
             {:ok, manifest} when is_map(manifest) <- Jason.decode(output) do
          {:ok, manifest}
        else
          _other -> {:error, :manifest_resolve_failed}
        end
      end
    }
  end

  defp load_growth_initiative(linear_issue_id) do
    base_url = System.get_env("SUPABASE_URL") || System.get_env("NEXT_PUBLIC_SUPABASE_URL")
    service_key = System.get_env("SUPABASE_SERVICE_ROLE_KEY")

    if present_env?(base_url) and present_env?(service_key) do
      case Req.get(
             String.trim_trailing(base_url, "/") <> "/rest/v1/growth_experiments",
             headers: [
               {"apikey", service_key},
               {"authorization", "Bearer #{service_key}"}
             ],
             params: [
               select: "linear_issue_id,experiment_key,agent_id,action_type,status,artifact_refs",
               linear_issue_id: "eq.#{linear_issue_id}"
             ],
             connect_options: [timeout: 30_000]
           ) do
        {:ok, %{status: status, body: rows}} when status in 200..299 and is_list(rows) ->
          {:ok, rows}

        _other ->
          {:error, :initiative_load_failed}
      end
    else
      {:error, :missing_supabase_credentials}
    end
  end

  defp run_manifest_command(control_root, arguments) do
    script = Path.join([control_root, ".codex", "scripts", "codex-agent-manifest.ps1"])

    case System.cmd(
           "powershell.exe",
           [
             "-NoLogo",
             "-NoProfile",
             "-NonInteractive",
             "-ExecutionPolicy",
             "Bypass",
             "-File",
             script,
             "-ControlRoot",
             control_root
           ] ++ arguments,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      _other -> {:error, :manifest_validation_failed}
    end
  rescue
    _error -> {:error, :manifest_validation_failed}
  end

  defp production_runtime_context(admitted, repository_path) do
    with {:ok, config} <- workflow_manafuel_config(),
         {:ok, runtime} <- runtime_settings(config),
         :ok <- provision_codex_home(runtime.codex_home, runtime.skill_source_root),
         instruction_paths when instruction_paths != [] <- instruction_paths(repository_path) do
      {:ok,
       %{
         repository: admitted.repository,
         workspace_root: repository_path,
         codex_home: runtime.codex_home,
         codex_executable: runtime.codex_executable,
         codex_install_root: Path.dirname(runtime.codex_executable),
         expected_sha256: runtime.expected_sha256,
         argv: ["-c", "skills.bundled.enabled=false", "app-server", "--listen", "stdio://"],
         env: runtime_environment(runtime.codex_home),
         skill_roots:
           Enum.map(
             ["manafuel-control", "implementation-system", "frontend-system", "fullstack-api", "testing"],
             &Path.join([runtime.codex_home, "skills", &1])
           ),
         instruction_paths: instruction_paths,
         timeouts: %{open: 10_000, request: 10_000, close: 5_000, total: 60_000}
       }}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_runtime_context}
    end
  end

  defp runtime_settings(config) do
    codex_home =
      Path.expand(
        config["codex_home"] ||
          Path.join([Config.local_workspace_root(), "..", "..", "runtime", "codex-home"])
      )

    codex_executable =
      Path.expand(
        config["codex_executable"] ||
          "C:/nvm4w/nodejs/node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin/codex.exe"
      )

    expected_sha256 =
      config["codex_sha256"] ||
        "935a1911ed2556e4ffcec995f4886ac2ac425863ba26fed264df62e30272ad9d"

    skill_source_root =
      Path.expand(
        config["skill_source_root"] ||
          "C:/Users/jclen/.codex/plugins/cache/manafuel-local/manafuel-codex/0.1.5+codex.20260729180000/skills"
      )

    if Enum.all?([codex_home, codex_executable, expected_sha256, skill_source_root], &present_env?/1) do
      {:ok,
       %{
         codex_home: codex_home,
         codex_executable: codex_executable,
         expected_sha256: String.downcase(expected_sha256),
         skill_source_root: skill_source_root
       }}
    else
      {:error, :invalid_runtime_context}
    end
  end

  defp provision_codex_home(codex_home, skill_source_root) do
    source_home = Path.join(System.fetch_env!("USERPROFILE"), ".codex")

    with :ok <- File.mkdir_p(Path.join(codex_home, "skills")),
         :ok <- copy_required_file(Path.join(source_home, "auth.json"), Path.join(codex_home, "auth.json")),
         :ok <- copy_runtime_skills(codex_home, skill_source_root) do
      :ok
    else
      _other -> {:error, :runtime_provision_failed}
    end
  rescue
    _error -> {:error, :runtime_provision_failed}
  end

  defp copy_required_file(source, destination) do
    case File.cp(source, destination) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy_runtime_skills(codex_home, skill_source_root) do
    ["manafuel-control", "implementation-system", "frontend-system", "fullstack-api", "testing"]
    |> Enum.reduce_while(:ok, fn skill, :ok ->
      source = Path.join(skill_source_root, skill)
      destination = Path.join([codex_home, "skills", skill])

      copy_runtime_skill(source, destination)
    end)
  end

  defp copy_runtime_skill(source, destination) do
    case File.cp_r(source, destination, fn _source, _destination -> true end) do
      {:ok, _files} -> {:cont, :ok}
      {:error, _source, reason} -> {:halt, {:error, reason}}
    end
  end

  defp runtime_environment(codex_home) do
    [
      "APPDATA",
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
    |> Enum.reduce(%{"CODEX_HOME" => codex_home}, fn key, environment ->
      case System.get_env(key) do
        value when is_binary(value) and value != "" -> Map.put(environment, key, value)
        _other -> environment
      end
    end)
  end

  defp instruction_paths(repository_path) do
    ["AGENTS.md", "CLAUDE.md", ".codex/AGENTS.md"]
    |> Enum.map(&Path.join(repository_path, &1))
    |> Enum.filter(&File.regular?/1)
  end

  defp workflow_manafuel_config do
    case Workflow.current() do
      {:ok, %{config: %{"manafuel" => config}}} when is_map(config) -> {:ok, config}
      _other -> {:error, :missing_manafuel_config}
    end
  end

  defp normalize_control_root(path) when is_binary(path) do
    expanded = Path.expand(path)
    if Path.basename(expanded) === ".codex", do: Path.dirname(expanded), else: expanded
  end

  defp model_metadata_path(config) do
    config["model_metadata_path"] ||
      Path.join([System.fetch_env!("USERPROFILE"), ".codex", "models_cache.json"])
  end

  defp present_env?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_env?(_value), do: false

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)

    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
