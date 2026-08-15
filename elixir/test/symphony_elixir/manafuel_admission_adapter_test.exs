defmodule SymphonyElixir.Manafuel.AdmissionAdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Manafuel.AdmissionAdapter

  @linear_issue_id "4c3dfde2-8c4d-4d46-8dc6-e633bb0ed226"
  @marker_text "<!-- manafuel-agent-binding:v1 initiative_id=growth-experiment-1 agent_id=implementation-worker -->"
  @repository_artifact %{"authority" => "github", "kind" => "repository", "native_id" => "manafuel/one"}
  @manifest %{
    "version" => "manafuel.agent-manifest.v1",
    "agent_id" => "implementation-worker",
    "model" => "gpt-5.6-terra",
    "reasoning_effort" => "medium",
    "sandbox" => %{"mode" => "workspace-write", "network_access" => false},
    "approval_policy" => "never",
    "tools" => ["shell_command", "apply_patch"],
    "skills" => ["manafuel-control", "implementation-system", "frontend-system", "fullstack-api", "testing"],
    "capabilities" => ["repo-write", "repository.patch", "local-validation.run"],
    "credential_profile" => "none",
    "repository_roots" => [%{"token" => "ASSIGNED_REPOSITORY", "access" => "task-tracked", "allowlist" => "task-tracked-allowlist"}],
    "output_contract" => %{"format" => "json", "schema_path" => "output-contracts/implementation-result.v1.schema.json"},
    "concurrency" => 1,
    "no_auto_subagents" => true
  }

  test "admits a raw Phase 4 row and preserves the exact raw Phase 3 manifest" do
    pr_artifact = %{
      "authority" => "github",
      "kind" => "pull-request",
      "native_id" => "manafuel/one#77",
      "uri" => "https://github.com/manafuel/one/pull/77",
      "observed_at" => "2026-08-15T00:00:00+03:15"
    }

    row = row(%{"artifact_refs" => [@repository_artifact, pr_artifact]})

    assert {:ok, admitted_run} = AdmissionAdapter.admit(@linear_issue_id, @marker_text, dependencies(rows: [row]))

    assert admitted_run == %{
             linear_issue_id: @linear_issue_id,
             experiment_key: "growth-experiment-1",
             agent_id: "implementation-worker",
             repository: "one",
             repository_artifact: @repository_artifact,
             status: "proposed",
             manifest: @manifest
           }

    assert_received {:loaded, @linear_issue_id}
    assert_received {:marker_validated, @marker_text, "growth-experiment-1", "implementation-worker"}
    assert_received {:manifest_resolved, "implementation-worker"}
    refute_received :mutation_attempted
  end

  test "requires a canonical UUID and raw byte equality before marker validation" do
    for linear_issue_id <- [
          "4C3DFDE2-8C4D-4D46-8DC6-E633BB0ED226",
          "4c3dfde2-8c4d-0d46-8dc6-e633bb0ed226",
          "4c3dfde2-8c4d-4d46-7dc6-e633bb0ed226",
          " #{@linear_issue_id}",
          "not-a-uuid"
        ] do
      assert {:error, :invalid_admission_input} = AdmissionAdapter.admit(linear_issue_id, @marker_text, dependencies())
      refute_received {:loaded, _id}
    end

    assert {:error, :invalid_admission_input} = AdmissionAdapter.admit(@linear_issue_id, 123, dependencies())
    assert {:error, :invalid_admission_input} = AdmissionAdapter.admit(@linear_issue_id, @marker_text, [])

    assert {:error, :native_issue_uuid_mismatch} =
             AdmissionAdapter.admit(@linear_issue_id, @marker_text, dependencies(rows: [row(%{"linear_issue_id" => uuid("5")})]))

    refute_received {:marker_validated, _, _, _}
  end

  test "rejects zero many and malformed raw loader results" do
    assert {:error, :initiative_not_found} = AdmissionAdapter.admit(@linear_issue_id, @marker_text, dependencies(rows: []))
    assert {:error, :initiative_not_unique} = AdmissionAdapter.admit(@linear_issue_id, @marker_text, dependencies(rows: [row(), row()]))
    assert {:error, :invalid_initiative} = AdmissionAdapter.admit(@linear_issue_id, @marker_text, dependencies(rows: [:not_a_map]))

    for {loader, expected} <- [
          {fn _linear_issue_id -> {:error, :loader_unavailable} end, :loader_unavailable},
          {fn _linear_issue_id -> {:ok, :not_a_list} end, :invalid_initiative_loader}
        ] do
      assert {:error, ^expected} =
               AdmissionAdapter.admit(@linear_issue_id, @marker_text, Map.put(dependencies(), :initiative_loader, loader))
    end

    for dependencies <- [
          Map.delete(dependencies(), :initiative_loader),
          Map.put(dependencies(), :initiative_loader, :not_a_function)
        ] do
      assert {:error, :invalid_initiative_loader} = AdmissionAdapter.admit(@linear_issue_id, @marker_text, dependencies)
    end
  end

  test "rejects missing and substituted raw Phase 4 fields" do
    for {changes, error} <- [
          {%{"experiment_key" => ""}, :invalid_initiative},
          {%{"experiment_key" => 1}, :invalid_initiative},
          {%{"agent_id" => "implementation-debugger"}, :unsupported_agent},
          {%{"agent_id" => "Implementation-Worker"}, :unsupported_agent},
          {%{"action_type" => "documentation"}, :unsupported_action},
          {%{"status" => "done"}, :unsupported_status},
          {%{"status" => "Proposed"}, :unsupported_status}
        ] do
      assert {:error, ^error} = AdmissionAdapter.admit(@linear_issue_id, @marker_text, dependencies(rows: [row(changes)]))
    end

    assert {:error, :invalid_initiative} =
             AdmissionAdapter.admit(@linear_issue_id, @marker_text, dependencies(rows: [Map.delete(row(), "experiment_key")]))
  end

  test "mirrors raw Phase 4 artifact references while requiring one closed canonical repository" do
    pr_artifact = %{
      "authority" => "github",
      "kind" => "pull-request",
      "native_id" => "manafuel/one#88",
      "uri" => "https://github.com/manafuel/one/pull/88",
      "observed_at" => "2026-08-15T00:00:00+03:15"
    }

    utf16_boundary_pr_artifact = %{
      "authority" => "github",
      "kind" => "pull-request",
      "native_id" => String.duplicate("🙂", 250)
    }

    assert {:ok, _admitted_run} =
             AdmissionAdapter.admit(
               @linear_issue_id,
               @marker_text,
               dependencies(rows: [row(%{"artifact_refs" => [pr_artifact, @repository_artifact, utf16_boundary_pr_artifact]})])
             )

    invalid_artifact_refs = [
      [],
      [pr_artifact],
      [@repository_artifact, @repository_artifact],
      [@repository_artifact, pr_artifact, pr_artifact],
      [%{"authority" => "github", "kind" => "repository", "native_id" => "manafuel/unknown"}],
      [%{"authority" => "GitHub", "kind" => "repository", "native_id" => "manafuel/one"}],
      [%{"authority" => "github", "kind" => "Repository", "native_id" => "manafuel/one"}],
      [%{"authority" => "github", "kind" => "repository", "native_id" => "manafuel/one "}],
      [Map.put(@repository_artifact, "uri", "https://github.com/manafuel/one")],
      [Map.put(@repository_artifact, "observed_at", "2026-08-15T00:00:00Z")],
      [%{"authority" => "gitlab", "kind" => "pull-request", "native_id" => "manafuel/one#89"}],
      [%{"authority" => "github", "kind" => "pull_request", "native_id" => "manafuel/one#89"}],
      [%{"authority" => "github", "kind" => 123, "native_id" => "manafuel/one#89"}],
      [%{"authority" => "github", "kind" => "pull-request", "native_id" => " manafuel/one#89"}],
      [%{"authority" => "github", "kind" => "pull-request", "native_id" => String.duplicate("a", 501)}],
      [%{"authority" => "github", "kind" => "pull-request", "native_id" => String.duplicate("🙂", 251)}],
      [%{"authority" => "github", "kind" => "pull-request", "native_id" => 123}],
      [Map.put(pr_artifact, "unexpected", true)],
      [Map.put(pr_artifact, "secret", "not-accepted")],
      [Map.put(pr_artifact, "uri", "ftp://github.com/manafuel/one/pull/88")],
      [Map.put(pr_artifact, "uri", 123)],
      [Map.put(pr_artifact, "observed_at", "2026-08-15T00:00:00+0315")],
      [Map.put(pr_artifact, "observed_at", "2026-08-15T00:00+03:15")],
      [Map.put(pr_artifact, "observed_at", 123)],
      [%{"kind" => "branch"}],
      [%{"authority" => 123, "kind" => "branch", "native_id" => "x"}],
      [:not_a_map]
    ]

    for artifact_refs <- invalid_artifact_refs do
      assert {:error, :unsupported_repository_artifact} =
               AdmissionAdapter.admit(@linear_issue_id, @marker_text, dependencies(rows: [row(%{"artifact_refs" => artifact_refs})]))
    end

    oversized_artifact_refs =
      [@repository_artifact | Enum.map(1..40, fn number -> %{"authority" => "github", "kind" => "pull-request", "native_id" => "manafuel/one##{number}"} end)]

    assert {:error, :unsupported_repository_artifact} =
             AdmissionAdapter.admit(
               @linear_issue_id,
               @marker_text,
               dependencies(rows: [row(%{"artifact_refs" => oversized_artifact_refs})])
             )

    assert {:error, :unsupported_repository_artifact} =
             AdmissionAdapter.admit(@linear_issue_id, @marker_text, dependencies(rows: [Map.delete(row(), "artifact_refs")]))
  end

  test "calls the marker validator with exact raw values and never resolves after marker failure" do
    assert {:error, :marker_absent} =
             AdmissionAdapter.admit(
               @linear_issue_id,
               @marker_text,
               dependencies(
                 marker_validator: fn marker_text, experiment_key, agent_id ->
                   send(self(), {:raw_marker, marker_text, experiment_key, agent_id})
                   {:error, :marker_absent}
                 end
               )
             )

    assert_received {:raw_marker, @marker_text, "growth-experiment-1", "implementation-worker"}
    refute_received {:manifest_resolved, _agent_id}
    refute_received :mutation_attempted
  end

  test "propagates marker errors and rejects malformed marker callbacks" do
    for {validator, expected} <- [
          {fn _marker_text, _experiment_key, _agent_id -> {:error, :marker_escaped} end, :marker_escaped},
          {fn _marker_text, _experiment_key, _agent_id -> :unexpected end, :invalid_binding_marker_validator}
        ] do
      assert {:error, ^expected} =
               AdmissionAdapter.admit(@linear_issue_id, @marker_text, Map.put(dependencies(), :binding_marker_validator, validator))
    end

    for dependencies <- [
          Map.delete(dependencies(), :binding_marker_validator),
          Map.put(dependencies(), :binding_marker_validator, :not_a_function)
        ] do
      assert {:error, :invalid_binding_marker_validator} = AdmissionAdapter.admit(@linear_issue_id, @marker_text, dependencies)
    end
  end

  test "propagates resolver errors and rejects malformed resolver callbacks" do
    for {resolver, expected} <- [
          {fn _agent_id -> {:error, :manifest_missing} end, :manifest_missing},
          {fn _agent_id -> :unexpected end, :invalid_manifest_resolver}
        ] do
      assert {:error, ^expected} =
               AdmissionAdapter.admit(@linear_issue_id, @marker_text, Map.put(dependencies(), :manifest_resolver, resolver))
    end

    for dependencies <- [
          Map.delete(dependencies(), :manifest_resolver),
          Map.put(dependencies(), :manifest_resolver, :not_a_function)
        ] do
      assert {:error, :invalid_manifest_resolver} = AdmissionAdapter.admit(@linear_issue_id, @marker_text, dependencies)
    end
  end

  test "requires the entire closed raw Phase 3 manifest with exact nested values and array order" do
    invalid_manifests = [
      Map.delete(@manifest, "version"),
      Map.put(@manifest, "version", "manafuel.agent-manifest.v2"),
      Map.put(@manifest, "agent_id", "implementation-debugger"),
      Map.put(@manifest, "model", "gpt-5.6-terra-preview"),
      Map.put(@manifest, "reasoning_effort", "high"),
      Map.put(@manifest, "sandbox", %{"mode" => "workspace-write", "network_access" => true}),
      Map.put(@manifest, "sandbox", %{"mode" => "danger-full-access", "network_access" => false}),
      Map.put(@manifest, "approval_policy", "on-request"),
      Map.put(@manifest, "tools", ["apply_patch", "shell_command"]),
      Map.put(@manifest, "skills", Enum.reverse(@manifest["skills"])),
      Map.put(@manifest, "capabilities", Enum.reverse(@manifest["capabilities"])),
      Map.put(@manifest, "credential_profile", "github"),
      Map.put(@manifest, "repository_roots", [%{"token" => "ASSIGNED_REPOSITORY", "access" => "task-tracked", "allowlist" => "different"}]),
      Map.put(@manifest, "output_contract", %{"format" => "text", "schema_path" => "output-contracts/implementation-result.v1.schema.json"}),
      Map.put(@manifest, "concurrency", 2),
      Map.put(@manifest, "concurrency", 1.0),
      Map.put(@manifest, "no_auto_subagents", false),
      Map.put(@manifest, "network_access", false),
      Map.put(@manifest, "extra", true)
    ]

    for manifest <- invalid_manifests do
      assert {:error, :invalid_manifest} = AdmissionAdapter.admit(@linear_issue_id, @marker_text, dependencies(manifest: manifest))
    end
  end

  defp dependencies(overrides \\ []) do
    rows = Keyword.get(overrides, :rows, [row()])
    resolved_manifest = Keyword.get(overrides, :manifest, @manifest)

    %{
      initiative_loader: fn linear_issue_id ->
        send(self(), {:loaded, linear_issue_id})
        {:ok, rows}
      end,
      binding_marker_validator:
        Keyword.get(overrides, :marker_validator, fn marker_text, experiment_key, agent_id ->
          send(self(), {:marker_validated, marker_text, experiment_key, agent_id})
          :ok
        end),
      manifest_resolver: fn agent_id ->
        send(self(), {:manifest_resolved, agent_id})
        {:ok, resolved_manifest}
      end
    }
  end

  defp row(changes \\ %{}) do
    Map.merge(
      %{
        "linear_issue_id" => @linear_issue_id,
        "experiment_key" => "growth-experiment-1",
        "agent_id" => "implementation-worker",
        "action_type" => "product-change",
        "status" => "proposed",
        "artifact_refs" => [@repository_artifact]
      },
      changes
    )
  end

  defp uuid(last_hex_digit) do
    "4c3dfde2-8c4d-4d46-8dc6-e633bb0ed22#{last_hex_digit}"
  end
end
