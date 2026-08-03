defmodule SymphonyElixir.ProducerContract do
  @moduledoc """
  Fail-closed loader and renderer for the reviewed producer-v6 contract.

  Production authority comes only from absolute command-line paths whose
  reopened bytes match their expected SHA-256 digests. Contract and launch
  receipts must already be canonical RFC 8785 JSON.
  """

  alias SymphonyElixir.ProducerV6.Format
  alias SymphonyElixir.Rfc8785Jcs

  @schema_version "manafuel.symphony_producer_execution_contract.v1"
  @contract_id "symphony-producer-execution-contract"
  @ledger_schema "symphony.execution_ledger.v6"
  @effect_schema "symphony.execution_effect.v6"

  @root_keys ~w(
    schema_version contract_id ledger_schema_version effect_schema_version
    dispatch_allocation_schema_version claim_receipt_schema_version
    ceo_prioritization_receipt_schema_version admission_result_schema_version
    completion_seal_schema_version recovery_journal_schema_version
    ledger_install_intent_core_schema_version ledger_install_plan_schema_version
    ledger_install_result_schema_version ledger_write_lock_schema_version
    legacy_recovery_record_schema_version terminal_recovery_deadline_schema_version
    natural_management_receipt_schema_version management_state_projection_schema_version
    transition_receipt_schema_version execution_binding_schema_version ordered_fields
    constants path_roots workflow_rewrite_contract production_cli_contract jcs_fixture
    cas_limits bounds milestone_vocabulary ledger_install_recovery_table stage_projections
    transition_table evidence_requirements recovery_table
  )

  @ordered_field_keys ~w(
    ledger effect effect_issue worker workspace producer_claim_state admission_state thread
    turn turn_history_reconciliation pagination_proof captured_page hold milestone
    dispatch_allocation claim_receipt claim_issue claim_dispatch claim_ledger_binding
    claim_workspace runtime_binding admission_contract admission_result admission_outcome
    transition_receipt transition_effect_binding transition_milestone transition_previous
    transition_ledger_before transition_runtime_binding transition_state terminal_tracker
    terminal_tracker_state terminal_tracker_comment terminal_tracker_marker
    terminal_tracker_transition completion_seal recovery_journal ledger_write_lock
    ledger_install_intent_core ledger_install_plan ledger_destination_install_outcome
    ledger_install_result expected_ledger_generation legacy_recovery_record
    terminal_recovery_deadline ceo_candidate ceo_scheduled_task_authority
    ceo_originator_source_authority ceo_cooldown_ledger_authority
    ceo_prioritization_receipt natural_management_receipt management_state_projection
    execution_binding execution_ledger_generation execution_effect_identity
    activation_execution_evidence
  )

  @rule_sources ~w(
    runtime_truth_source_sha linear_project_slug workspace_root producer_before_run_command
    max_concurrent_agents max_concurrent_ready max_concurrent_in_progress
    max_concurrent_rework codex_phase codex_app_server_enabled codex_command
    codex_app_server_command codex_approval_policy codex_thread_sandbox
    codex_turn_sandbox_policy_yaml control_root implementation_root worktree_root
  )

  @milestones ~w(
    prepared worker_registered workspace_ready claim_ready admission_passed thread_ready
    turn_start_intent turn_started turn_terminal completed held
  )

  @launch_root_keys ~w(
    schema_version launch_id launched_at_utc source plugin runtime lock_evidence files
    workflow_render binding
  )

  @launch_workflow_render_keys ~w(
    schema_version tracked_workflow_path tracked_workflow_sha256 tracked_workflow_blob_oid
    runtime_workflow_path runtime_workflow_sha256 runtime_workflow_length render_inputs
    workflow_render_inputs_sha256 workflow_rewrite_contract_sha256
    producer_claim_contract_sha256 codex_app_server_experimental_api
    codex_app_server_history_mode line_endings text_encoding terminal_newline decision
  )

  @cli_order [
    "symphony",
    "--production-mode",
    "--production-launch-receipt",
    "<absolute-launch-cas>",
    "--expected-launch-receipt-sha256",
    "<64lowerhex>",
    "--producer-contract-manifest",
    "<absolute-contract-cas>",
    "--expected-producer-contract-sha256",
    "<64lowerhex>",
    "<absolute-rendered-workflow>"
  ]

  @type loaded :: %{
          path: String.t(),
          sha256: String.t(),
          length: non_neg_integer(),
          document: map()
        }

  @spec load(String.t(), String.t()) :: {:ok, loaded()} | {:error, term()}
  def load(path, expected_sha256) when is_binary(path) and is_binary(expected_sha256) do
    with :ok <- absolute_regular_path(path),
         :ok <- valid_expected_sha(expected_sha256),
         {:ok, bytes} <- File.read(path),
         ^expected_sha256 <- sha256(bytes),
         {:ok, document} <- Rfc8785Jcs.validate_canonical(bytes),
         :ok <- validate(document) do
      {:ok,
       %{
         path: Path.expand(path),
         sha256: expected_sha256,
         length: byte_size(bytes),
         document: document
       }}
    else
      actual when is_binary(actual) -> {:error, {:sha256_mismatch, expected_sha256, actual}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate_launch_receipt(String.t(), String.t()) ::
          {:ok, loaded()} | {:error, term()}
  def validate_launch_receipt(path, expected_sha256)
      when is_binary(path) and is_binary(expected_sha256) do
    with :ok <- absolute_regular_path(path),
         :ok <- valid_expected_sha(expected_sha256),
         {:ok, bytes} <- File.read(path),
         ^expected_sha256 <- sha256(bytes),
         {:ok, document} <- Rfc8785Jcs.validate_canonical(bytes),
         :ok <- validate_launch_document(document) do
      {:ok,
       %{
         path: Path.expand(path),
         sha256: expected_sha256,
         length: byte_size(bytes),
         document: document
       }}
    else
      actual when is_binary(actual) -> {:error, {:sha256_mismatch, expected_sha256, actual}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate_production_authority(loaded(), loaded(), String.t()) ::
          :ok | {:error, term()}
  def validate_production_authority(
        %{document: launch},
        %{document: contract, sha256: contract_sha256},
        workflow_path
      )
      when is_map(launch) and is_map(contract) and is_binary(workflow_path) do
    render = launch["workflow_render"]

    with :ok <- absolute_regular_path(workflow_path),
         :ok <- same_expanded_path(render["runtime_workflow_path"], workflow_path),
         {:ok, workflow_bytes} <- File.read(workflow_path),
         :ok <- exact_value(render, "runtime_workflow_sha256", sha256(workflow_bytes)),
         :ok <- exact_value(render, "runtime_workflow_length", byte_size(workflow_bytes)),
         :ok <- exact_value(render, "producer_claim_contract_sha256", contract_sha256),
         {:ok, render_inputs_bytes} <- Rfc8785Jcs.encode(render["render_inputs"]),
         :ok <-
           exact_value(
             render,
             "workflow_render_inputs_sha256",
             sha256(render_inputs_bytes)
           ),
         {:ok, rewrite_contract_bytes} <-
           Rfc8785Jcs.encode(contract["workflow_rewrite_contract"]) do
      exact_value(
        render,
        "workflow_rewrite_contract_sha256",
        sha256(rewrite_contract_bytes)
      )
    end
  end

  def validate_production_authority(_launch, _contract, _workflow_path),
    do: {:error, :invalid_production_authority}

  @spec render_workflow(loaded(), String.t(), %{required(String.t()) => String.t()}) ::
          {:ok, map()} | {:error, term()}
  def render_workflow(%{document: contract}, template_path, values)
      when is_binary(template_path) and is_map(values) do
    rules = get_in(contract, ["workflow_rewrite_contract", "rules"])

    with :ok <- absolute_regular_path(template_path),
         {:ok, template} <- File.read(template_path),
         :ok <- validate_template_bytes(template),
         :ok <- exact_keys(values, @rule_sources, :render_values),
         :ok <- validate_rules(rules),
         {:ok, rendered} <- apply_rules(template, rules, values),
         :ok <- validate_rendered_bytes(rendered),
         {:ok, inputs_bytes} <- Rfc8785Jcs.encode(values) do
      {:ok,
       %{
         bytes: rendered,
         sha256: sha256(rendered),
         length: byte_size(rendered),
         render_inputs_sha256: sha256(inputs_bytes)
       }}
    end
  end

  @spec validate(map()) :: :ok | {:error, term()}
  def validate(document) when is_map(document) do
    with :ok <- exact_keys(document, @root_keys, :root),
         :ok <- exact_value(document, "schema_version", @schema_version),
         :ok <- exact_value(document, "contract_id", @contract_id),
         :ok <- exact_value(document, "ledger_schema_version", @ledger_schema),
         :ok <- exact_value(document, "effect_schema_version", @effect_schema),
         :ok <- validate_ordered_fields(document["ordered_fields"]),
         :ok <- validate_constants(document["constants"]),
         :ok <- validate_workflow_contract(document["workflow_rewrite_contract"]),
         :ok <- validate_cli_contract(document["production_cli_contract"]),
         :ok <- exact_value(document, "milestone_vocabulary", @milestones),
         :ok <- exact_count(document, "ledger_install_recovery_table", 7),
         :ok <- exact_count(document, "stage_projections", 11),
         :ok <- exact_count(document, "evidence_requirements", 11),
         :ok <- minimum_count(document, "transition_table", 11) do
      minimum_count(document, "recovery_table", 12)
    end
  end

  def validate(_document), do: {:error, :producer_contract_not_an_object}

  defp validate_launch_document(document) when is_map(document) do
    with :ok <- exact_keys(document, @launch_root_keys, :production_launch_receipt),
         :ok <-
           exact_value(
             document,
             "schema_version",
             "manafuel.symphony-runtime-launch-receipt.v2"
           ),
         :ok <- lower_hex(document["launch_id"], 32, :launch_id),
         :ok <- non_empty(document["launched_at_utc"], :launched_at_utc),
         :ok <- validate_launch_source(document["source"]),
         :ok <- validate_launch_plugin(document["plugin"]),
         :ok <- validate_launch_runtime(document["runtime"]),
         :ok <- validate_launch_lock_evidence(document["lock_evidence"]),
         :ok <- validate_launch_files(document["files"]),
         :ok <- validate_launch_workflow_render(document["workflow_render"]) do
      validate_launch_binding(document["binding"])
    end
  end

  defp validate_launch_document(_document),
    do: {:error, :production_launch_receipt_not_an_object}

  defp validate_launch_source(source) when is_map(source) do
    with :ok <-
           exact_keys(
             source,
             ~w(git_root head_sha protected_ref protected_ref_sha),
             :launch_source
           ),
         :ok <- absolute_path(source["git_root"], :launch_git_root),
         :ok <- lower_hex(source["head_sha"], 40, :launch_head_sha),
         :ok <- exact_value(source, "protected_ref", "origin/main") do
      exact_value(source, "protected_ref_sha", source["head_sha"])
    end
  end

  defp validate_launch_source(_source), do: {:error, :launch_source_not_an_object}

  defp validate_launch_plugin(plugin) when is_map(plugin) do
    with :ok <-
           exact_keys(
             plugin,
             ~w(plugin_id version package_sha256 source_path source_physical_path),
             :launch_plugin
           ),
         :ok <- exact_value(plugin, "plugin_id", "manafuel-codex@manafuel-local"),
         :ok <- non_empty(plugin["version"], :plugin_version),
         :ok <- lower_hex(plugin["package_sha256"], 64, :plugin_package_sha256),
         :ok <- absolute_path(plugin["source_path"], :plugin_source_path) do
      absolute_path(plugin["source_physical_path"], :plugin_source_physical_path)
    end
  end

  defp validate_launch_plugin(_plugin), do: {:error, :launch_plugin_not_an_object}

  defp validate_launch_runtime(runtime) when is_map(runtime) do
    with :ok <-
           exact_keys(
             runtime,
             ~w(port run_directory worker_process scheduled_task),
             :launch_runtime
           ),
         :ok <- positive_integer(runtime["port"], :runtime_port),
         :ok <- absolute_path(runtime["run_directory"], :runtime_run_directory),
         :ok <- map_value(runtime["worker_process"], :runtime_worker_process) do
      map_value(runtime["scheduled_task"], :runtime_scheduled_task)
    end
  end

  defp validate_launch_runtime(_runtime), do: {:error, :launch_runtime_not_an_object}

  defp validate_launch_lock_evidence(lock) when is_map(lock) do
    with :ok <-
           exact_keys(
             lock,
             ~w(artifact_lock_count provenance_lock_count receipt_lock_count share_mode
                generic_write_probe_win32_error delete_probe_win32_error locks_retained_through),
             :launch_lock_evidence
           ),
         :ok <- exact_value(lock, "share_mode", "FILE_SHARE_READ"),
         :ok <- exact_value(lock, "generic_write_probe_win32_error", 32),
         :ok <- exact_value(lock, "delete_probe_win32_error", 32) do
      exact_value(lock, "locks_retained_through", "synchronous_mise_exit")
    end
  end

  defp validate_launch_lock_evidence(_lock),
    do: {:error, :launch_lock_evidence_not_an_object}

  defp validate_launch_files(files) when is_map(files) do
    required = ~w(
      run_local_workflow registry_workflow symphony_binary codex_executable hidden_launcher
      start_script worker_script
    )

    with :ok <- exact_keys(files, required, :launch_files) do
      validate_launch_file_entries(files, required)
    end
  end

  defp validate_launch_files(_files), do: {:error, :launch_files_not_an_object}

  defp validate_launch_file_entries(files, required) do
    Enum.reduce_while(required, :ok, fn name, :ok ->
      case validate_launch_file(files[name], name) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_launch_file(file, name) when is_map(file) do
    with :ok <-
           exact_keys(
             file,
             ~w(file_type lexical_path physical_path sha256 volume_serial_number file_id
                link_count length),
             {:launch_file, name}
           ),
         :ok <- exact_value(file, "file_type", "regular_file"),
         :ok <- absolute_path(file["lexical_path"], {:launch_file_path, name}),
         :ok <- absolute_path(file["physical_path"], {:launch_file_physical_path, name}),
         :ok <- lower_hex(file["sha256"], 64, {:launch_file_sha256, name}),
         :ok <- exact_value(file, "link_count", 1) do
      non_negative_integer(file["length"], {:launch_file_length, name})
    end
  end

  defp validate_launch_file(_file, name), do: {:error, {:launch_file_not_an_object, name}}

  defp validate_launch_workflow_render(render) when is_map(render) do
    with :ok <- exact_keys(render, @launch_workflow_render_keys, :launch_workflow_render),
         :ok <-
           exact_value(
             render,
             "schema_version",
             "manafuel.symphony_workflow_render_receipt.v1"
           ),
         :ok <- non_empty(render["tracked_workflow_path"], :tracked_workflow_path),
         :ok <- lower_hex(render["tracked_workflow_sha256"], 64, :tracked_workflow_sha256),
         :ok <- lower_hex(render["tracked_workflow_blob_oid"], 40, :tracked_workflow_blob_oid),
         :ok <- absolute_path(render["runtime_workflow_path"], :runtime_workflow_path),
         :ok <- lower_hex(render["runtime_workflow_sha256"], 64, :runtime_workflow_sha256),
         :ok <-
           non_negative_integer(render["runtime_workflow_length"], :runtime_workflow_length),
         :ok <- exact_keys(render["render_inputs"], @rule_sources, :launch_render_inputs),
         :ok <-
           lower_hex(
             render["workflow_render_inputs_sha256"],
             64,
             :workflow_render_inputs_sha256
           ),
         :ok <-
           lower_hex(
             render["workflow_rewrite_contract_sha256"],
             64,
             :workflow_rewrite_contract_sha256
           ),
         :ok <-
           lower_hex(
             render["producer_claim_contract_sha256"],
             64,
             :producer_claim_contract_sha256
           ),
         :ok <- exact_value(render, "codex_app_server_experimental_api", true),
         :ok <- exact_value(render, "codex_app_server_history_mode", "paginated"),
         :ok <- exact_value(render, "line_endings", "lf"),
         :ok <- exact_value(render, "text_encoding", "utf-8-no-bom"),
         :ok <- exact_value(render, "terminal_newline", false) do
      exact_value(render, "decision", "PASS")
    end
  end

  defp validate_launch_workflow_render(_render),
    do: {:error, :launch_workflow_render_not_an_object}

  defp validate_launch_binding(binding) when is_map(binding) do
    with :ok <-
           exact_keys(
             binding,
             ~w(schema_version vendor_binding_sha256 runtime_binding_sha256),
             :launch_binding
           ),
         :ok <-
           exact_value(binding, "schema_version", "manafuel.symphony-runtime-binding.v1"),
         :ok <- lower_hex(binding["vendor_binding_sha256"], 64, :vendor_binding_sha256) do
      lower_hex(binding["runtime_binding_sha256"], 64, :runtime_binding_sha256)
    end
  end

  defp validate_launch_binding(_binding), do: {:error, :launch_binding_not_an_object}

  defp validate_ordered_fields(fields) when is_map(fields) do
    with :ok <- exact_keys(fields, @ordered_field_keys, :ordered_fields) do
      validate_ordered_field_entries(fields)
    end
  end

  defp validate_ordered_fields(_fields), do: {:error, :ordered_fields_not_an_object}

  defp validate_ordered_field_entries(fields) do
    Enum.reduce_while(@ordered_field_keys, :ok, fn name, :ok ->
      validate_ordered_field_entry(fields[name], name)
    end)
  end

  defp validate_ordered_field_entry(values, name) when is_list(values) and values != [] do
    if valid_ordered_projection?(values),
      do: {:cont, :ok},
      else: {:halt, {:error, {:invalid_ordered_field_projection, name}}}
  end

  defp validate_ordered_field_entry(_values, name),
    do: {:halt, {:error, {:invalid_ordered_field_projection, name}}}

  defp valid_ordered_projection?(values) do
    Enum.all?(values, &(is_binary(&1) and &1 != "")) and Enum.uniq(values) == values
  end

  defp validate_constants(constants) when is_map(constants) do
    required = ~w(
      execution_target experimental_api history_mode monitor_only_enforcement required_decision
      installed_ref_mode plugin_id dispatch_idempotency_domain claim_session_prefix
      turn_intent_domain terminal_state_type final_comment_marker_prefix file_identity_provider
      physical_path_provider link_count_provider file_identity_fallback transaction_broker_mode
      transaction_broker_result_schema transaction_broker_stdout_contract
      transaction_broker_deadline_mode jcs_result_schema ledger_write_lock_path
      ledger_write_lock_representation ledger_write_lock_release_policy
      ledger_write_lock_stale_replacement_policy persistent_graph_dependency azure_dependency
      global_cutover parallel_cutover blue_green_cutover memory_mode worker_host
      ssh_config_entries workspace_root_windows workspace_root_yaml
    )

    with :ok <- exact_keys(constants, required, :constants),
         :ok <- exact_value(constants, "execution_target", "local"),
         :ok <- exact_value(constants, "experimental_api", true),
         :ok <- exact_value(constants, "history_mode", "paginated"),
         :ok <- exact_value(constants, "memory_mode", "none"),
         :ok <- exact_value(constants, "worker_host", nil),
         :ok <- exact_value(constants, "ssh_config_entries", []),
         :ok <- exact_value(constants, "persistent_graph_dependency", false),
         :ok <- exact_value(constants, "azure_dependency", false),
         :ok <- exact_value(constants, "global_cutover", false),
         :ok <- exact_value(constants, "parallel_cutover", false) do
      exact_value(constants, "blue_green_cutover", false)
    end
  end

  defp validate_constants(_constants), do: {:error, :constants_not_an_object}

  defp validate_workflow_contract(contract) when is_map(contract) do
    keys = ~w(
      schema_version template_path rendering_mode placeholder_syntax text_encoding
      line_endings terminal_newline startup_contract rules
    )

    with :ok <- exact_keys(contract, keys, :workflow_rewrite_contract),
         :ok <-
           exact_value(
             contract,
             "schema_version",
             "manafuel.symphony_workflow_rewrite_contract.v1"
           ),
         :ok <-
           exact_value(
             contract,
             "template_path",
             ".codex/workflows/symphony-manafuel/WORKFLOW.production.template.md"
           ),
         :ok <- exact_value(contract, "rendering_mode", "exact_utf8_placeholder_projection"),
         :ok <- exact_value(contract, "placeholder_syntax", "symphony_double_brace_v1"),
         :ok <- exact_value(contract, "text_encoding", "utf-8-no-bom"),
         :ok <- exact_value(contract, "line_endings", "lf"),
         :ok <- exact_value(contract, "terminal_newline", false),
         :ok <- validate_startup_contract(contract["startup_contract"]) do
      validate_rules(contract["rules"])
    end
  end

  defp validate_workflow_contract(_contract), do: {:error, :workflow_contract_not_an_object}

  defp validate_startup_contract(contract) when is_map(contract) do
    keys = ~w(
      production_mode validation_phase tracker execution_target ssh_config_entries worker_host
      concurrency memory_mode experimental_api history_mode workflow_hot_reload
      general_workflow_fallback default_workflow_fallback unknown_key_policy
      prompt_builder_producer_assign rendered_workflow_cas_required
    )

    with :ok <- exact_keys(contract, keys, :startup_contract),
         :ok <- exact_value(contract, "production_mode", true),
         :ok <- exact_value(contract, "validation_phase", "before_effects"),
         :ok <- exact_value(contract, "tracker", "linear"),
         :ok <- exact_value(contract, "execution_target", "local"),
         :ok <- exact_value(contract, "ssh_config_entries", []),
         :ok <- exact_value(contract, "worker_host", nil),
         :ok <- exact_value(contract, "memory_mode", "none"),
         :ok <- exact_value(contract, "experimental_api", true),
         :ok <- exact_value(contract, "history_mode", "paginated"),
         :ok <- exact_value(contract, "workflow_hot_reload", false),
         :ok <- exact_value(contract, "general_workflow_fallback", false),
         :ok <- exact_value(contract, "default_workflow_fallback", false) do
      validate_concurrency(contract["concurrency"])
    end
  end

  defp validate_startup_contract(_contract), do: {:error, :startup_contract_not_an_object}

  defp validate_concurrency(concurrency) when is_map(concurrency) do
    keys = ~w(
      max_concurrent_agents max_concurrent_ready max_concurrent_in_progress
      max_concurrent_rework
    )

    with :ok <- exact_keys(concurrency, keys, :concurrency) do
      validate_concurrency_values(concurrency, keys)
    end
  end

  defp validate_concurrency(_concurrency), do: {:error, :concurrency_not_an_object}

  defp validate_concurrency_values(concurrency, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case exact_value(concurrency, key, 1) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_cli_contract(contract) when is_map(contract) do
    keys = ~w(
      argument_order cardinality path_policy authority_source environment_fallback
      default_fallback latest_pointer duplicate_arguments logs_root_override port_override
      unknown_arguments
    )

    with :ok <- exact_keys(contract, keys, :production_cli_contract),
         :ok <- exact_value(contract, "argument_order", @cli_order),
         :ok <- exact_value(contract, "cardinality", "each_exactly_once"),
         :ok <- exact_value(contract, "path_policy", "absolute_bound_cas_only"),
         :ok <-
           exact_value(contract, "authority_source", "command_line_and_reopened_receipts_only"),
         :ok <- exact_value(contract, "environment_fallback", false),
         :ok <- exact_value(contract, "default_fallback", false),
         :ok <- exact_value(contract, "latest_pointer", false),
         :ok <- exact_value(contract, "duplicate_arguments", false),
         :ok <- exact_value(contract, "logs_root_override", false),
         :ok <- exact_value(contract, "port_override", false) do
      exact_value(contract, "unknown_arguments", "reject")
    end
  end

  defp validate_cli_contract(_contract), do: {:error, :production_cli_contract_not_an_object}

  defp validate_rules(rules) when is_list(rules) and length(rules) == 18 do
    rules
    |> Enum.sort_by(& &1["ordinal"])
    |> Enum.zip(Enum.with_index(@rule_sources, 1))
    |> Enum.reduce_while(:ok, fn {rule, {source, ordinal}}, :ok ->
      expected_keys = ~w(ordinal placeholder value_source occurrences)

      cond do
        not is_map(rule) ->
          {:halt, {:error, {:invalid_workflow_rule, ordinal}}}

        exact_keys(rule, expected_keys, {:workflow_rule, ordinal}) != :ok ->
          {:halt, {:error, {:invalid_workflow_rule_keys, ordinal}}}

        rule["ordinal"] != ordinal or rule["value_source"] != source or
            rule["occurrences"] != 1 ->
          {:halt, {:error, {:invalid_workflow_rule_binding, ordinal}}}

        not valid_placeholder?(rule["placeholder"]) ->
          {:halt, {:error, {:invalid_workflow_placeholder, ordinal}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_rules(_rules), do: {:error, :workflow_rules_not_exactly_eighteen}

  defp apply_rules(template, rules, values) do
    rules
    |> Enum.sort_by(& &1["ordinal"])
    |> Enum.reduce_while({:ok, template}, fn rule, {:ok, current} ->
      placeholder = rule["placeholder"]
      source = rule["value_source"]
      replacement = values[source]

      cond do
        not is_binary(replacement) or replacement == "" ->
          {:halt, {:error, {:missing_render_value, source}}}

        length(:binary.matches(current, placeholder)) != rule["occurrences"] ->
          {:halt, {:error, {:workflow_placeholder_count_drift, placeholder}}}

        true ->
          {:cont, {:ok, :binary.replace(current, placeholder, replacement, [:global])}}
      end
    end)
  end

  defp validate_template_bytes(bytes) do
    cond do
      not String.valid?(bytes) ->
        {:error, :workflow_template_invalid_utf8}

      String.starts_with?(bytes, <<0xEF, 0xBB, 0xBF>>) ->
        {:error, :workflow_template_bom}

      :binary.match(bytes, "\r") != :nomatch ->
        {:error, :workflow_template_not_lf_only}

      String.ends_with?(bytes, "\n") ->
        {:error, :workflow_template_terminal_newline}

      :binary.match(bytes, "experimental_api: true") == :nomatch ->
        {:error, :workflow_template_experimental_api_drift}

      :binary.match(bytes, "history_mode: paginated") == :nomatch ->
        {:error, :workflow_template_history_mode_drift}

      true ->
        :ok
    end
  end

  defp validate_rendered_bytes(bytes) do
    cond do
      not String.valid?(bytes) -> {:error, :rendered_workflow_invalid_utf8}
      :binary.match(bytes, "\r") != :nomatch -> {:error, :rendered_workflow_not_lf_only}
      String.ends_with?(bytes, "\n") -> {:error, :rendered_workflow_terminal_newline}
      true -> :ok
    end
  end

  defp valid_placeholder?(value) when is_binary(value) do
    byte_size(value) >= 5 and String.starts_with?(value, "{{") and String.ends_with?(value, "}}")
  end

  defp valid_placeholder?(_value), do: false

  defp absolute_regular_path(path) do
    cond do
      Path.type(path) != :absolute -> {:error, {:path_not_absolute, path}}
      not File.regular?(path) -> {:error, {:path_not_regular_file, path}}
      true -> :ok
    end
  end

  defp same_expanded_path(left, right) when is_binary(left) and is_binary(right) do
    if Path.expand(left) == Path.expand(right),
      do: :ok,
      else: {:error, :runtime_workflow_path_mismatch}
  end

  defp same_expanded_path(_left, _right), do: {:error, :runtime_workflow_path_mismatch}

  defp absolute_path(path, _label) when is_binary(path) do
    if Path.type(path) == :absolute, do: :ok, else: {:error, :path_not_absolute}
  end

  defp absolute_path(_path, label), do: {:error, {:path_not_absolute, label}}

  defp non_empty(value, _label) when is_binary(value) and value != "", do: :ok
  defp non_empty(_value, label), do: {:error, {:empty_value, label}}

  defp map_value(value, _label) when is_map(value), do: :ok
  defp map_value(_value, label), do: {:error, {:not_an_object, label}}

  defp non_negative_integer(value, _label) when is_integer(value) and value >= 0, do: :ok

  defp non_negative_integer(_value, label),
    do: {:error, {:invalid_non_negative_integer, label}}

  defp valid_expected_sha(value) do
    if Format.lower_hex?(value, 64), do: :ok, else: {:error, :invalid_expected_sha256}
  end

  defp exact_keys(map, expected, label) when is_map(map) do
    if Enum.sort(Map.keys(map)) == Enum.sort(expected),
      do: :ok,
      else: {:error, {:property_set_mismatch, label}}
  end

  defp exact_keys(_map, _expected, label), do: {:error, {:property_set_mismatch, label}}

  defp exact_value(map, key, expected) do
    if Map.get(map, key, :__missing__) === expected,
      do: :ok,
      else: {:error, {:value_mismatch, key}}
  end

  defp exact_count(map, key, expected) do
    case map[key] do
      values when is_list(values) and length(values) == expected -> :ok
      _ -> {:error, {:count_mismatch, key, expected}}
    end
  end

  defp minimum_count(map, key, expected) do
    case map[key] do
      values when is_list(values) and length(values) >= expected -> :ok
      _ -> {:error, {:minimum_count_not_met, key, expected}}
    end
  end

  defp lower_hex(value, length, _label)
       when is_binary(value) and byte_size(value) == length do
    if Format.lower_hex?(value, length), do: :ok, else: {:error, :invalid_lower_hex}
  end

  defp lower_hex(_value, _length, label), do: {:error, {:invalid_lower_hex, label}}

  defp positive_integer(value, _label) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_value, label), do: {:error, {:invalid_positive_integer, label}}

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
