defmodule SymphonyElixir.Manafuel.AdmissionAdapter do
  @moduledoc """
  Pure, fail-closed admission for the initial MANAfuel implementation lane.

  The adapter accepts raw Phase 4 initiative rows and the raw Phase 3 manifest
  only through injected dependencies. It owns neither parsing nor runtime IO.
  """

  @implementation_worker_manifest %{
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

  @repository_native_ids %{
    "manafuel/development" => "development",
    "manafuel/one" => "one",
    "manafuel/replicator" => "replicator"
  }

  @artifact_authorities [
    "github",
    "cms",
    "site",
    "linear",
    "google_ads",
    "meta_ads",
    "microsoft_ads",
    "reddit_ads",
    "stripe",
    "supabase"
  ]
  @artifact_keys ["authority", "kind", "native_id", "uri", "observed_at"]
  @artifact_kind ~r/\A[a-z][a-z0-9-]{0,63}\z/

  @canonical_safe_http_uri ~r<\Ahttps?://([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*(:(0|[1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?(/([A-Za-z0-9._~!$&'()*+,;=:@/-]|%[0-9A-Fa-f]{2})*)?\z>

  @rfc3339_offset_datetime ~r/\A(?:(?:[0-9][0-9][2468][048]|[0-9][0-9][13579][26]|[0-9][0-9]0[48]|[02468][048]00|[13579][26]00)-02-29|[0-9]{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12][0-9]|3[01])|(?:0[469]|11)-(?:0[1-9]|[12][0-9]|30)|(?:02)-(?:0[1-9]|1[0-9]|2[0-8])))T(?:(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]+)?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9]))\z/

  @canonical_uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  @type admitted_run :: %{
          linear_issue_id: String.t(),
          experiment_key: String.t(),
          agent_id: String.t(),
          repository: String.t(),
          repository_artifact: map(),
          status: String.t(),
          manifest: map()
        }

  @type dependencies :: %{
          initiative_loader: (String.t() -> {:ok, [map()]} | {:error, term()}),
          binding_marker_validator: (String.t(), String.t(), String.t() -> :ok | {:error, term()}),
          manifest_resolver: (String.t() -> {:ok, map()} | {:error, term()})
        }

  @spec admit(String.t(), String.t(), dependencies()) :: {:ok, admitted_run()} | {:error, term()}
  def admit(linear_issue_id, marker_text, dependencies)
      when is_binary(linear_issue_id) and is_binary(marker_text) and is_map(dependencies) do
    with true <- canonical_uuid?(linear_issue_id) or {:error, :invalid_admission_input},
         {:ok, row} <- load_exactly_one(linear_issue_id, dependencies),
         {:ok, experiment_key, status} <- validate_row(row, linear_issue_id),
         {:ok, repository, repository_artifact} <- repository_artifact(row),
         :ok <- validate_marker(marker_text, experiment_key, "implementation-worker", dependencies),
         {:ok, manifest} <- resolve_manifest("implementation-worker", dependencies),
         :ok <- validate_manifest(manifest) do
      {:ok,
       %{
         linear_issue_id: linear_issue_id,
         experiment_key: experiment_key,
         agent_id: "implementation-worker",
         repository: repository,
         repository_artifact: repository_artifact,
         status: status,
         manifest: manifest
       }}
    end
  end

  def admit(_linear_issue_id, _marker_text, _dependencies), do: {:error, :invalid_admission_input}

  defp canonical_uuid?(linear_issue_id) when is_binary(linear_issue_id), do: String.match?(linear_issue_id, @canonical_uuid)

  defp load_exactly_one(linear_issue_id, %{initiative_loader: loader}) when is_function(loader, 1) do
    case loader.(linear_issue_id) do
      {:ok, []} -> {:error, :initiative_not_found}
      {:ok, [row]} when is_map(row) -> {:ok, row}
      {:ok, [_row]} -> {:error, :invalid_initiative}
      {:ok, [_first | _rest]} -> {:error, :initiative_not_unique}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_initiative_loader}
    end
  end

  defp load_exactly_one(_linear_issue_id, _dependencies), do: {:error, :invalid_initiative_loader}

  defp validate_row(row, linear_issue_id) do
    with :ok <- require_exact(row, "linear_issue_id", linear_issue_id, :native_issue_uuid_mismatch),
         {:ok, experiment_key} <- nonempty_string(row, "experiment_key"),
         :ok <- require_exact(row, "agent_id", "implementation-worker", :unsupported_agent),
         :ok <- require_exact(row, "action_type", "product-change", :unsupported_action),
         {:ok, status} <- allowed_status(row) do
      {:ok, experiment_key, status}
    end
  end

  defp nonempty_string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _other -> {:error, :invalid_initiative}
    end
  end

  defp allowed_status(map) when is_map(map) do
    case Map.get(map, "status") do
      status when status in ["proposed", "running"] -> {:ok, status}
      _other -> {:error, :unsupported_status}
    end
  end

  defp repository_artifact(%{"artifact_refs" => artifact_refs}) when is_list(artifact_refs) and length(artifact_refs) <= 40 do
    artifact_refs
    |> collect_repository_artifacts()
    |> exactly_one_repository_artifact()
  end

  defp repository_artifact(_row), do: {:error, :unsupported_repository_artifact}

  defp collect_repository_artifacts(artifact_refs) do
    Enum.reduce_while(artifact_refs, {:ok, MapSet.new(), []}, &collect_artifact/2)
  end

  defp collect_artifact(artifact, {:ok, identities, repository_artifacts}) do
    case valid_artifact_identity(artifact, identities) do
      {:ok, identity} -> collect_valid_artifact(artifact, identity, identities, repository_artifacts)
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp valid_artifact_identity(artifact, identities) do
    with true <- valid_raw_artifact?(artifact),
         identity <- artifact_identity(artifact),
         false <- MapSet.member?(identities, identity) do
      {:ok, identity}
    else
      _other -> {:error, :unsupported_repository_artifact}
    end
  end

  defp collect_valid_artifact(artifact, identity, identities, repository_artifacts) do
    case canonical_repository_artifact(artifact) do
      {:ok, _repository, _artifact} = repository_artifact ->
        {:cont, {:ok, MapSet.put(identities, identity), [repository_artifact | repository_artifacts]}}

      :non_repository ->
        {:cont, {:ok, MapSet.put(identities, identity), repository_artifacts}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp exactly_one_repository_artifact({:ok, _identities, [{:ok, repository, artifact}]}), do: {:ok, repository, artifact}

  defp exactly_one_repository_artifact({:ok, _identities, _repository_artifacts}),
    do: {:error, :unsupported_repository_artifact}

  defp exactly_one_repository_artifact({:error, _reason} = error), do: error

  defp canonical_repository_artifact(%{"authority" => "github", "kind" => "repository", "native_id" => native_id} = artifact) do
    with true <- map_size(artifact) == 3,
         {:ok, repository} <- Map.fetch(@repository_native_ids, native_id) do
      {:ok, repository, artifact}
    else
      _other -> {:error, :unsupported_repository_artifact}
    end
  end

  defp canonical_repository_artifact(_artifact), do: :non_repository

  defp valid_raw_artifact?(artifact) when is_map(artifact) do
    closed_artifact_keys?(artifact) and valid_authority?(Map.get(artifact, "authority")) and
      valid_kind?(Map.get(artifact, "kind")) and valid_native_id?(Map.get(artifact, "native_id")) and
      valid_optional_uri?(artifact) and valid_optional_observed_at?(artifact)
  end

  defp valid_raw_artifact?(_artifact), do: false

  defp closed_artifact_keys?(artifact) do
    Map.has_key?(artifact, "authority") and Map.has_key?(artifact, "kind") and Map.has_key?(artifact, "native_id") and
      Enum.all?(Map.keys(artifact), &(&1 in @artifact_keys))
  end

  defp valid_authority?(authority) when is_binary(authority), do: authority in @artifact_authorities
  defp valid_authority?(_authority), do: false

  defp valid_kind?(kind) when is_binary(kind), do: String.valid?(kind) and String.match?(kind, @artifact_kind)
  defp valid_kind?(_kind), do: false

  defp valid_native_id?(value) when is_binary(value) do
    String.valid?(value) and value === String.trim(value) and utf16_length(value) in 1..500
  end

  defp valid_native_id?(_value), do: false

  defp utf16_length(value) do
    value
    |> String.to_charlist()
    |> Enum.reduce(0, &add_utf16_units/2)
  end

  defp add_utf16_units(codepoint, total) when codepoint > 0xFFFF, do: total + 2
  defp add_utf16_units(_codepoint, total), do: total + 1

  defp valid_optional_uri?(artifact) do
    not Map.has_key?(artifact, "uri") or valid_uri?(Map.get(artifact, "uri"))
  end

  defp valid_uri?(uri) when is_binary(uri), do: String.valid?(uri) and String.match?(uri, @canonical_safe_http_uri)
  defp valid_uri?(_uri), do: false

  defp valid_optional_observed_at?(artifact) do
    not Map.has_key?(artifact, "observed_at") or valid_rfc3339_offset_datetime?(Map.get(artifact, "observed_at"))
  end

  defp valid_rfc3339_offset_datetime?(value) when is_binary(value) do
    String.valid?(value) and String.match?(value, @rfc3339_offset_datetime)
  end

  defp valid_rfc3339_offset_datetime?(_value), do: false

  defp artifact_identity(artifact), do: {artifact["authority"], artifact["kind"], artifact["native_id"]}

  defp validate_marker(marker_text, experiment_key, agent_id, %{binding_marker_validator: validator}) when is_function(validator, 3) do
    case validator.(marker_text, experiment_key, agent_id) do
      :ok -> :ok
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_binding_marker_validator}
    end
  end

  defp validate_marker(_marker_text, _experiment_key, _agent_id, _dependencies), do: {:error, :invalid_binding_marker_validator}

  defp resolve_manifest(agent_id, %{manifest_resolver: resolver}) when is_function(resolver, 1) do
    case resolver.(agent_id) do
      {:ok, manifest} when is_map(manifest) -> {:ok, manifest}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_manifest_resolver}
    end
  end

  defp resolve_manifest(_agent_id, _dependencies), do: {:error, :invalid_manifest_resolver}

  defp validate_manifest(manifest) when manifest === @implementation_worker_manifest, do: :ok
  defp validate_manifest(_manifest), do: {:error, :invalid_manifest}

  defp require_exact(map, key, expected, error) when is_map(map) do
    if Map.get(map, key) === expected, do: :ok, else: {:error, error}
  end
end
