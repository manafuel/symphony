defmodule SymphonyElixir.ProducerV6.RuntimeBinding.Live do
  @moduledoc """
  Live, fail-closed observer for the producer-v6 semantic launch binding.

  It reopens every bound file, verifies the protected source and frozen vendor
  Git identities, resolves the authenticated Linear viewer, and then delegates
  to the pure cross-language projection builder.
  """

  alias SymphonyElixir.ProducerV6.RuntimeBinding
  alias SymphonyElixir.Rfc8785Jcs

  @contract_relative ".codex/workflows/symphony-manafuel/symphony-producer-execution-contract.json"
  @template_relative ".codex/workflows/symphony-manafuel/WORKFLOW.production.template.md"
  @vendor_manifest_relative ".codex/workflows/symphony-vendor-manifest.json"
  @runtime_script_relative ".codex/scripts/codex-symphony-ticket-admission-hook.ps1"
  @runtime_child_script_relative ".codex/scripts/codex-symphony-cma-ticket-admission.ps1"
  @powershell "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
  @linear_endpoint "https://api.linear.app/graphql"
  @linear_timeout_ms 30_000

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec validate(map(), map(), String.t()) :: :ok | {:error, term()}
  def validate(
        %{document: launch},
        %{document: contract, sha256: contract_sha256},
        workflow_path
      )
      when is_map(launch) and is_map(contract) and is_binary(contract_sha256) and
             is_binary(workflow_path) do
    root = get_in(launch, ["source", "git_root"])
    target_source_sha = get_in(launch, ["source", "head_sha"])

    with :ok <- validate_source_repository(root, target_source_sha),
         :ok <- validate_launch_files(launch["files"]),
         :ok <- validate_workflow_path(launch, workflow_path),
         {:ok, contract_binding} <-
           tracked_binding(root, target_source_sha, @contract_relative),
         :ok <- exact(contract_binding.sha256, contract_sha256, :tracked_contract_digest_drift),
         :ok <-
           exact(
             contract_binding.sha256,
             get_in(launch, ["workflow_render", "producer_claim_contract_sha256"]),
             :render_contract_digest_drift
           ),
         {:ok, template_binding} <-
           tracked_binding(root, target_source_sha, @template_relative),
         :ok <- validate_template_binding(launch, template_binding),
         {:ok, vendor_state} <- validate_vendor(root, launch),
         {:ok, runtime_state} <- runtime_state(root),
         {:ok, viewer_id} <- authenticated_viewer_identity(),
         evidence =
           Map.merge(runtime_state, %{
             vendor_source_head_sha: vendor_state.source_head_sha,
             vendor_patch_manifest_sha256: vendor_state.manifest_sha256,
             contract_binding: contract_binding,
             template_binding: template_binding
           }),
         :ok <-
           RuntimeBinding.validate_for_test(
             launch,
             contract_sha256,
             viewer_id,
             evidence
           ),
         {:ok, reconstructed} <-
           RuntimeBinding.build_for_test(launch, contract_sha256, viewer_id, evidence),
         :ok <- cache_live_binding(launch, contract, contract_sha256, workflow_path, viewer_id, evidence, reconstructed) do
      :ok
    end
  end

  def validate(_launch, _contract, _workflow_path),
    do: {:error, :invalid_live_runtime_binding_input}

  @spec transition_binding(map(), Path.t(), module()) :: {:ok, map()} | {:error, term()}
  def transition_binding(
        %{contract: %{document: contract}} = context,
        workspace_root,
        broker
      ) do
    with {:ok, full} <- full_binding(context, workspace_root, broker),
         transition_keys when is_list(transition_keys) <-
           get_in(contract, ["ordered_fields", "transition_runtime_binding"]) do
      {:ok, Map.take(full, transition_keys)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_transition_runtime_binding_input}
    end
  end

  def transition_binding(_context, _workspace_root, _broker),
    do: {:error, :invalid_transition_runtime_binding_input}

  @spec full_binding(map(), Path.t(), module()) :: {:ok, map()} | {:error, term()}
  def full_binding(
        %{launch: %{document: launch, path: launch_path, sha256: launch_sha256}, contract: %{document: contract, path: contract_path, sha256: contract_sha256}, workflow_path: workflow_path},
        workspace_root,
        broker
      )
      when is_binary(workspace_root) and is_atom(broker) do
    with %{launch_id: launch_id} = cached <-
           Application.get_env(:symphony_elixir, :producer_v6_live_binding),
         :ok <- exact(launch_id, launch["launch_id"], :cached_launch_binding_drift),
         authority = %{
           kind: :producer_v6,
           launch: %{document: launch, path: launch_path, sha256: launch_sha256},
           contract: %{document: contract, path: contract_path, sha256: contract_sha256},
           workflow_path: workflow_path
         },
         {:ok, runtime_workflow_artifact} <- runtime_workflow_artifact(launch, workspace_root, broker, authority),
         {:ok, cli_contract_bytes} <- Rfc8785Jcs.encode(contract["production_cli_contract"]) do
      projection = cached.reconstructed.runtime_projection
      constants = contract["constants"]

      full = %{
        "launch_receipt_path" => Path.expand(launch_path),
        "launch_receipt_sha256" => launch_sha256,
        "launch_id" => launch["launch_id"],
        "target_source_sha" => projection["target_source_sha"],
        "vendor_source_head_sha" => projection["vendor_source_head_sha"],
        "installed_ref_mode" => projection["installed_ref_mode"],
        "installed_ref" => projection["installed_ref"],
        "plugin_id" => projection["plugin_id"],
        "plugin_version" => projection["plugin_version"],
        "plugin_package_sha256" => projection["plugin_package_sha256"],
        "linear_worker_actor_id" => projection["linear_worker_actor_id"],
        "tracked_workflow_path" => projection["tracked_workflow_path"],
        "tracked_workflow_sha256" => projection["tracked_workflow_sha256"],
        "tracked_workflow_blob_oid" => projection["tracked_workflow_blob_oid"],
        "runtime_workflow_path" => projection["runtime_workflow_path"],
        "runtime_workflow_sha256" => projection["runtime_workflow_sha256"],
        "runtime_workflow_artifact" => runtime_workflow_artifact,
        "workflow_rewrite_contract_sha256" => projection["workflow_rewrite_contract_sha256"],
        "workflow_render_inputs_sha256" => projection["workflow_render_inputs_sha256"],
        "codex_app_server_experimental_api" => true,
        "codex_app_server_history_mode" => "paginated",
        "file_transaction_broker" => cached.file_transaction_broker,
        "jcs_provider" => cached.jcs_provider,
        "production_cli" => %{
          "production_launch_receipt" => Path.expand(launch_path),
          "expected_launch_receipt_sha256" => launch_sha256,
          "producer_contract_manifest" => Path.expand(contract_path),
          "expected_producer_contract_sha256" => contract_sha256,
          "rendered_workflow" => Path.expand(workflow_path),
          "contract_sha256" => sha256(cli_contract_bytes)
        },
        "workspace_root_windows" => constants["workspace_root_windows"],
        "workspace_root_yaml" => constants["workspace_root_yaml"],
        "memory_mode" => constants["memory_mode"],
        "worker_host" => constants["worker_host"],
        "ssh_config_entries" => constants["ssh_config_entries"],
        "symphony_binary_path" => projection["symphony_binary_path"],
        "symphony_binary_sha256" => projection["symphony_binary_sha256"],
        "symphony_binary_length" => projection["symphony_binary_length"],
        "producer_claim_contract_sha256" => projection["producer_claim_contract_sha256"],
        "vendor_binding_sha256" => cached.reconstructed.binding["vendor_binding_sha256"],
        "runtime_binding_sha256" => cached.reconstructed.binding["runtime_binding_sha256"]
      }

      {:ok, full}
    else
      nil -> {:error, :live_runtime_binding_not_initialized}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :live_runtime_binding_invalid}
    end
  end

  def full_binding(_context, _workspace_root, _broker),
    do: {:error, :invalid_full_runtime_binding_input}

  @spec admission_contract(map()) :: {:ok, map()} | {:error, term()}
  def admission_contract(%{contract: %{document: contract}}) do
    with %{reconstructed: %{runtime_projection: projection}} <-
           Application.get_env(:symphony_elixir, :producer_v6_live_binding),
         keys when is_list(keys) <- get_in(contract, ["ordered_fields", "admission_contract"]) do
      admission = %{
        "runtime_command" => projection["runtime_command"],
        "runtime_command_sha256" => projection["runtime_command_sha256"],
        "runtime_script_path" => projection["runtime_script_path"],
        "runtime_script_sha256" => projection["runtime_script_sha256"],
        "runtime_child_script_path" => projection["runtime_child_script_path"],
        "runtime_child_script_sha256" => projection["runtime_child_script_sha256"],
        "monitor_only_enforcement" => "strict",
        "result_schema_version" => "manafuel.symphony_admission_result.v1",
        "required_decision" => "PASS"
      }

      if Enum.sort(Map.keys(admission)) == Enum.sort(keys),
        do: {:ok, admission},
        else: {:error, :admission_contract_projection_drift}
    else
      nil -> {:error, :live_runtime_binding_not_initialized}
      _ -> {:error, :admission_contract_binding_invalid}
    end
  end

  def admission_contract(_context), do: {:error, :invalid_admission_contract_context}

  defp cache_live_binding(
         launch,
         contract,
         _contract_sha256,
         _workflow_path,
         viewer_id,
         evidence,
         reconstructed
       ) do
    root = get_in(launch, ["source", "git_root"])
    source_sha = get_in(launch, ["source", "head_sha"])

    with {:ok, broker_binding} <- tracked_binding(root, source_sha, ".codex/scripts/codex-symphony-file-transaction-broker.ps1"),
         {:ok, guardian_binding} <- tracked_binding(root, source_sha, ".codex/bin/codex-symphony-broker-guardian.exe"),
         {:ok, jcs_implementation} <- tracked_binding(root, source_sha, ".codex/scripts/codex-rfc8785-jcs.ps1"),
         {:ok, jcs_tests} <- tracked_binding(root, source_sha, ".codex/scripts/codex-rfc8785-jcs.tests.ps1"),
         {:ok, jcs_fixture} <- tracked_binding(root, source_sha, ".codex/workflows/symphony-manafuel/fixtures/rfc8785-jcs-vectors.json"),
         {:ok, vendored_manifest} <- tracked_binding(root, source_sha, ".codex/scripts/vendor/rfc8785-jcs/source-manifest.json"),
         {:ok, vendored_license} <- tracked_binding(root, source_sha, ".codex/scripts/vendor/rfc8785-jcs/LICENSE"),
         {:ok, vendored_source_files} <- tracked_bindings(root, source_sha, vendored_source_paths()),
         {:ok, elixir_implementation_files} <- tracked_bindings(root, source_sha, [".codex/scripts/vendor/rfc8785-jcs/elixir/jcs.ex"]),
         {:ok, powershell_bytes} <- File.read(@powershell) do
      installed_jcs_path =
        Path.join(
          get_in(contract, ["constants", "workspace_root_windows"]),
          ".symphony-state\\jcs-providers\\sha256\\#{binary_part(jcs_implementation.sha256, 0, 2)}\\#{jcs_implementation.sha256}.json"
        )

      broker = %{
        "tracked_path" => broker_binding.path,
        "tracked_blob_oid" => broker_binding.blob_oid,
        "tracked_sha256" => broker_binding.sha256,
        "installed_path" => guardian_binding.full_path,
        "installed_sha256" => guardian_binding.sha256,
        "result_schema_version" => "manafuel.symphony_file_transaction_broker_result.v1",
        "powershell_executable_path" => @powershell,
        "powershell_executable_sha256" => sha256(powershell_bytes),
        "powershell_executable_trust" => "absolute_system32_microsoft_signed",
        "authority_root_windows" => get_in(contract, ["constants", "workspace_root_windows"]),
        "authority_root_yaml" => get_in(contract, ["constants", "workspace_root_yaml"]),
        "actions" => ~w(Inspect VerifyReference PublishCas CaptureFileToCas AcquireLedgerWriteLock ReplaceStaleLedgerWriteLock ReleaseLedgerWriteLockCas InstallDualLedgerAndReadback AllocateDispatch),
        "runner_mode" => "persistent_port_held_named_mutex_and_root_handles",
        "argument_transport" => "argument_array",
        "stdout_encoding" => "utf-8-no-bom",
        "stdout_terminal_newline" => false,
        "stdout_max_bytes" => 1_048_576,
        "stderr_max_bytes" => 0,
        "success_exit_code" => 0,
        "deadline_mode" => "single_persisted_absolute_deadline",
        "termination_mode" => "windows_job_object_process_tree",
        "override_policy" => "bound_only"
      }

      jcs_provider = %{
        "powershell_implementation_path" => jcs_implementation.path,
        "powershell_implementation_blob_oid" => jcs_implementation.blob_oid,
        "powershell_implementation_sha256" => jcs_implementation.sha256,
        "powershell_tests_path" => jcs_tests.path,
        "powershell_tests_blob_oid" => jcs_tests.blob_oid,
        "powershell_tests_sha256" => jcs_tests.sha256,
        "functions" => ~w(ConvertFrom-ManafuelJcsStrictJsonBytes ConvertTo-ManafuelJcsBytes ConvertTo-ManafuelJcsText Test-ManafuelJcsCanonicalBytes),
        "installed_path" => installed_jcs_path,
        "installed_sha256" => jcs_implementation.sha256,
        "result_schema_version" => "manafuel.rfc8785_jcs_result.v1",
        "fixture_path" => jcs_fixture.path,
        "fixture_blob_oid" => jcs_fixture.blob_oid,
        "fixture_sha256" => jcs_fixture.sha256,
        "vendored_source_manifest" => compact_binding(vendored_manifest),
        "vendored_license" => compact_binding(vendored_license),
        "vendored_source_files" => Enum.map(vendored_source_files, &compact_binding/1),
        "elixir_implementation_files" => Enum.map(elixir_implementation_files, &compact_binding/1)
      }

      Application.put_env(
        :symphony_elixir,
        :producer_v6_live_binding,
        %{
          launch_id: launch["launch_id"],
          viewer_id: viewer_id,
          evidence: evidence,
          reconstructed: reconstructed,
          file_transaction_broker: broker,
          jcs_provider: jcs_provider
        },
        persistent: true
      )

      :ok
    end
  end

  defp runtime_workflow_artifact(launch, workspace_root, broker, authority) do
    render = launch["workflow_render"]

    descriptor = %{
      "schema_version" => "manafuel.symphony_runtime_workflow_artifact.v1",
      "path" => Path.expand(render["runtime_workflow_path"]),
      "sha256" => render["runtime_workflow_sha256"],
      "length" => render["runtime_workflow_length"],
      "decision" => "PASS"
    }

    with {:ok, bytes} <- Rfc8785Jcs.encode(descriptor),
         digest = sha256(bytes),
         path = Path.join(workspace_root, ".symphony-state\\runtime-workflows\\sha256\\#{binary_part(digest, 0, 2)}\\#{digest}.json"),
         {:ok, identity} <- broker.inspect(path, workspace_root, authority) do
      {:ok, immutable_reference(identity, workspace_root)}
    end
  end

  defp immutable_reference(identity, workspace_root) do
    %{
      "path" => identity["path"] |> Path.relative_to(Path.expand(workspace_root)) |> String.replace("\\", "/"),
      "physical_path" => identity["physical_path"],
      "volume_id" => identity["volume_id"],
      "file_id" => identity["file_id"],
      "file_type" => identity["file_type"],
      "link_count" => identity["link_count"],
      "sha256" => identity["sha256"],
      "length" => identity["length"]
    }
  end

  defp compact_binding(binding), do: Map.take(binding, [:path, :blob_oid, :sha256]) |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

  defp tracked_bindings(root, source_sha, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, bindings} ->
      case tracked_binding(root, source_sha, path) do
        {:ok, binding} -> {:cont, {:ok, bindings ++ [binding]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp vendored_source_paths do
    ~w(
      .codex/scripts/vendor/rfc8785-jcs/dotnet/es6numberserializer/NumberCachedPowers.cs
      .codex/scripts/vendor/rfc8785-jcs/dotnet/es6numberserializer/NumberDiyFp.cs
      .codex/scripts/vendor/rfc8785-jcs/dotnet/es6numberserializer/NumberDoubleHelper.cs
      .codex/scripts/vendor/rfc8785-jcs/dotnet/es6numberserializer/NumberDToA.cs
      .codex/scripts/vendor/rfc8785-jcs/dotnet/es6numberserializer/NumberFastDToA.cs
      .codex/scripts/vendor/rfc8785-jcs/dotnet/es6numberserializer/NumberFastDToABuilder.cs
      .codex/scripts/vendor/rfc8785-jcs/dotnet/es6numberserializer/NumberToJson.cs
      .codex/scripts/vendor/rfc8785-jcs/dotnet/jsoncanonicalizer/JsonCanonicalizer.cs
    )
  end

  defp validate_source_repository(root, target_source_sha)
       when is_binary(root) and is_binary(target_source_sha) do
    expanded_root = Path.expand(root)

    with {:ok, top_level} <- git_value(expanded_root, ["rev-parse", "--show-toplevel"], :source_root),
         :ok <- same_path(top_level, expanded_root, :source_root_mismatch),
         {:ok, head} <- git_value(expanded_root, ["rev-parse", "HEAD^{commit}"], :source_head),
         {:ok, protected} <-
           git_value(expanded_root, ["rev-parse", "origin/main^{commit}"], :protected_source_head),
         :ok <- lower_hex(head, 40, :source_head),
         :ok <- lower_hex(protected, 40, :protected_source_head),
         :ok <- exact(head, target_source_sha, :source_head_drift),
         :ok <- exact(protected, target_source_sha, :protected_source_head_drift),
         {:ok, status} <-
           git_value(
             expanded_root,
             ["status", "--porcelain=v1", "--untracked-files=all"],
             :source_status
           ),
         :ok <- exact(status, "", :source_repository_dirty) do
      :ok
    end
  end

  defp validate_source_repository(_root, _target_source_sha),
    do: {:error, :invalid_source_repository_binding}

  defp validate_launch_files(files) when is_map(files) do
    Enum.reduce_while(files, :ok, fn {name, binding}, :ok ->
      case validate_file_binding(binding) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:launch_file_drift, name, reason}}}
      end
    end)
  end

  defp validate_launch_files(_files), do: {:error, :launch_files_not_an_object}

  defp validate_file_binding(binding) when is_map(binding) do
    path = binding["lexical_path"]

    with true <- is_binary(path) and Path.type(path) == :absolute,
         true <- File.regular?(path),
         {:ok, bytes} <- File.read(path),
         :ok <- exact(sha256(bytes), binding["sha256"], :sha256_drift),
         :ok <- exact(byte_size(bytes), binding["length"], :length_drift) do
      :ok
    else
      false -> {:error, :not_absolute_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_file_binding(_binding), do: {:error, :file_binding_not_an_object}

  defp validate_workflow_path(launch, workflow_path) do
    run_local = get_in(launch, ["files", "run_local_workflow"])
    registry = get_in(launch, ["files", "registry_workflow"])
    render = launch["workflow_render"]

    with :ok <- same_path(run_local["lexical_path"], workflow_path, :workflow_path_drift),
         :ok <-
           same_path(
             render["runtime_workflow_path"],
             workflow_path,
             :rendered_workflow_path_drift
           ),
         :ok <- exact(run_local["sha256"], registry["sha256"], :published_workflow_digest_drift),
         :ok <-
           exact(
             run_local["sha256"],
             render["runtime_workflow_sha256"],
             :rendered_workflow_digest_drift
           ),
         :ok <-
           exact(
             run_local["length"],
             render["runtime_workflow_length"],
             :rendered_workflow_length_drift
           ),
         :ok <-
           exact(
             get_in(render, ["render_inputs", "runtime_truth_source_sha"]),
             get_in(launch, ["source", "head_sha"]),
             :render_source_sha_drift
           ) do
      :ok
    end
  end

  defp validate_template_binding(launch, template_binding) do
    render = launch["workflow_render"]

    with :ok <-
           exact(
             template_binding.path,
             render["tracked_workflow_path"],
             :tracked_workflow_path_drift
           ),
         :ok <-
           exact(
             template_binding.sha256,
             render["tracked_workflow_sha256"],
             :tracked_workflow_sha256_drift
           ),
         :ok <-
           exact(
             template_binding.blob_oid,
             render["tracked_workflow_blob_oid"],
             :tracked_workflow_blob_drift
           ) do
      :ok
    end
  end

  defp tracked_binding(root, target_source_sha, relative_path) do
    with :ok <- canonical_relative_path(relative_path),
         path = Path.expand(Path.join(root, relative_path)),
         true <- File.regular?(path),
         {:ok, blob_oid} <-
           git_value(
             root,
             ["rev-parse", target_source_sha <> ":" <> relative_path],
             {:tracked_blob, relative_path}
           ),
         :ok <- lower_hex(blob_oid, 40, {:tracked_blob, relative_path}),
         {:ok, installed_blob_oid} <-
           git_value(
             root,
             ["hash-object", "--no-filters", path],
             {:installed_blob, relative_path}
           ),
         :ok <- exact(installed_blob_oid, blob_oid, {:tracked_file_drift, relative_path}),
         {:ok, bytes} <- File.read(path) do
      {:ok,
       %{
         path: relative_path,
         blob_oid: blob_oid,
         sha256: sha256(bytes),
         length: byte_size(bytes),
         full_path: path
       }}
    else
      false -> {:error, {:tracked_file_missing, relative_path}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_vendor(root, launch) do
    manifest_path = Path.expand(Path.join(root, @vendor_manifest_relative))

    with true <- File.regular?(manifest_path),
         {:ok, manifest_bytes} <- File.read(manifest_path),
         {:ok, manifest} <- Rfc8785Jcs.decode_strict(manifest_bytes),
         {:ok, vendor} <- exact_symphony_vendor(manifest),
         source_head_sha = vendor["expected_head"],
         :ok <- lower_hex(source_head_sha, 40, :vendor_source_head),
         :ok <- exact(get_in(vendor, ["binary", "source_head"]), source_head_sha, :vendor_binary_head_drift),
         :ok <-
           exact(
             get_in(vendor, ["binary", "sha256"]),
             get_in(launch, ["files", "symphony_binary", "sha256"]),
             :vendor_binary_digest_drift
           ),
         vendor_root = Path.expand(Path.join(root, vendor["path"])),
         {:ok, installed_head} <-
           git_value(vendor_root, ["rev-parse", "HEAD^{commit}"], :installed_vendor_head),
         :ok <- exact(installed_head, source_head_sha, :installed_vendor_head_drift),
         {:ok, status} <-
           git_value(
             vendor_root,
             ["status", "--porcelain=v1", "--untracked-files=all"],
             :installed_vendor_status
           ),
         :ok <- exact(status, "", :installed_vendor_dirty),
         expected_binary_path = Path.expand(Path.join(root, get_in(vendor, ["binary", "path"]))),
         :ok <-
           same_path(
             expected_binary_path,
             get_in(launch, ["files", "symphony_binary", "lexical_path"]),
             :installed_vendor_binary_path_drift
           ) do
      {:ok,
       %{
         source_head_sha: source_head_sha,
         manifest_sha256: sha256(manifest_bytes)
       }}
    else
      false -> {:error, :vendor_manifest_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exact_symphony_vendor(%{"vendors" => vendors}) when is_list(vendors) do
    case Enum.filter(vendors, &(is_map(&1) and &1["id"] == "symphony")) do
      [vendor] -> {:ok, vendor}
      _ -> {:error, :symphony_vendor_cardinality_drift}
    end
  end

  defp exact_symphony_vendor(_manifest), do: {:error, :vendor_manifest_not_an_object}

  defp runtime_state(root) do
    runtime_script_path = Path.expand(Path.join(root, @runtime_script_relative))
    runtime_child_script_path = Path.expand(Path.join(root, @runtime_child_script_relative))

    with true <- File.regular?(runtime_script_path),
         true <- File.regular?(runtime_child_script_path),
         {:ok, runtime_script_bytes} <- File.read(runtime_script_path),
         {:ok, runtime_child_script_bytes} <- File.read(runtime_child_script_path) do
      runtime_command =
        "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " <>
          String.replace(runtime_script_path, "\\", "/") <>
          " -MonitorOnlyEnforcement strict"

      {:ok,
       %{
         runtime_command: runtime_command,
         runtime_script_path: runtime_script_path,
         runtime_script_sha256: sha256(runtime_script_bytes),
         runtime_child_script_path: runtime_child_script_path,
         runtime_child_script_sha256: sha256(runtime_child_script_bytes)
       }}
    else
      false -> {:error, :runtime_admission_script_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authenticated_viewer_identity do
    case System.get_env("LINEAR_API_KEY") do
      token when is_binary(token) and token != "" ->
        with {:ok, _started} <- Application.ensure_all_started(:req),
             {:ok, %{status: 200, body: body}} <-
               Req.post(@linear_endpoint,
                 headers: [
                   {"Authorization", token},
                   {"Content-Type", "application/json"}
                 ],
                 json: %{query: @viewer_query, variables: %{}},
                 connect_options: [timeout: @linear_timeout_ms],
                 receive_timeout: @linear_timeout_ms,
                 retry: false
               ),
             {:ok, viewer_id} <- viewer_id(body) do
          {:ok, viewer_id}
        else
          {:ok, %{status: status}} -> {:error, {:linear_viewer_status, status}}
          {:error, reason} -> {:error, {:linear_viewer_request, reason}}
        end

      _ ->
        {:error, :missing_linear_api_token}
    end
  end

  defp viewer_id(%{"data" => %{"viewer" => %{"id" => id}}}) when is_binary(id) do
    cond do
      id == "" ->
        {:error, :missing_linear_viewer_identity}

      byte_size(id) > 256 ->
        {:error, :invalid_linear_viewer_identity}

      Enum.any?(String.to_charlist(id), &control_character?/1) ->
        {:error, :invalid_linear_viewer_identity}

      true ->
        {:ok, id}
    end
  end

  defp viewer_id(_body), do: {:error, :missing_linear_viewer_identity}

  defp control_character?(character), do: character < 32 or character == 127

  defp canonical_relative_path(path) when is_binary(path) do
    if Path.type(path) == :relative and not String.contains?(path, ["\\", ":"]) and
         path != "" do
      :ok
    else
      {:error, :noncanonical_repository_relative_path}
    end
  end

  defp canonical_relative_path(_path), do: {:error, :noncanonical_repository_relative_path}

  defp git_value(root, args, label) when is_binary(root) and is_list(args) do
    case System.cmd("git", ["-C", Path.expand(root) | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, status} -> {:error, {:git_command_failed, label, status}}
    end
  end

  defp same_path(left, right, error) when is_binary(left) and is_binary(right) do
    if String.downcase(Path.expand(left)) == String.downcase(Path.expand(right)),
      do: :ok,
      else: {:error, error}
  end

  defp same_path(_left, _right, error), do: {:error, error}

  defp exact(observed, expected, _error) when observed === expected, do: :ok
  defp exact(_observed, _expected, error), do: {:error, error}

  defp lower_hex(value, length, label) when is_binary(value) and byte_size(value) == length do
    if value
       |> :binary.bin_to_list()
       |> Enum.all?(&(&1 in ?0..?9 or &1 in ?a..?f)) do
      :ok
    else
      {:error, {:invalid_lower_hex, label}}
    end
  end

  defp lower_hex(_value, _length, label), do: {:error, {:invalid_lower_hex, label}}

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
