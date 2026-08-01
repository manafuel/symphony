defmodule SymphonyElixir.ProducerContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{ProducerContract, Rfc8785Jcs}

  @contract_path Path.expand("../fixtures/symphony-producer-execution-contract.json", __DIR__)
  @template_path Path.expand("../fixtures/WORKFLOW.production.template.md", __DIR__)
  @contract_sha256 "106697e2525dce9d9c455dffb3bbd8d0fe469bf7b5b5d88985ede6fa7b66be96"
  @template_sha256 "1abe469ff2a06f994d0f9b273e87b3e8ac8ee296b367f0cef1fea7745960ab38"

  test "loads only the exact canonical producer contract" do
    assert sha256(File.read!(@contract_path)) == @contract_sha256

    assert {:ok, loaded} = ProducerContract.load(@contract_path, @contract_sha256)
    assert loaded.sha256 == @contract_sha256
    assert loaded.document["ledger_schema_version"] == "symphony.execution_ledger.v6"
    assert loaded.document["effect_schema_version"] == "symphony.execution_effect.v6"
    assert length(loaded.document["ledger_install_recovery_table"]) == 7
    assert length(loaded.document["recovery_table"]) == 12

    assert {:error, {:sha256_mismatch, _, _}} =
             ProducerContract.load(@contract_path, String.duplicate("0", 64))

    assert {:error, {:path_not_absolute, _}} =
             ProducerContract.load("relative-contract.json", @contract_sha256)
  end

  test "renders exactly eighteen literal production inputs without normalizing bytes" do
    assert sha256(File.read!(@template_path)) == @template_sha256
    assert {:ok, loaded} = ProducerContract.load(@contract_path, @contract_sha256)
    values = render_values()

    assert {:ok, rendered} =
             ProducerContract.render_workflow(loaded, @template_path, values)

    assert rendered.length == byte_size(rendered.bytes)
    assert rendered.sha256 == sha256(rendered.bytes)
    assert rendered.render_inputs_sha256 =~ ~r/\A[0-9a-f]{64}\z/
    refute String.contains?(rendered.bytes, "\r")
    refute String.ends_with?(rendered.bytes, "\n")
    assert String.contains?(rendered.bytes, "experimental_api: true")
    assert String.contains?(rendered.bytes, "history_mode: paginated")

    for rule <- loaded.document["workflow_rewrite_contract"]["rules"] do
      refute String.contains?(rendered.bytes, rule["placeholder"])
    end

    assert {:error, {:property_set_mismatch, :render_values}} =
             ProducerContract.render_workflow(
               loaded,
               @template_path,
               Map.delete(values, "runtime_truth_source_sha")
             )
  end

  test "rejects duplicate production placeholder occurrences" do
    assert {:ok, loaded} = ProducerContract.load(@contract_path, @contract_sha256)
    duplicate = Path.join(System.tmp_dir!(), "symphony-template-#{System.unique_integer([:positive])}.md")

    try do
      bytes = File.read!(@template_path)
      File.write!(duplicate, bytes <> "\n{{SYMPHONY_RUNTIME_TRUTH_SOURCE_SHA}}")

      assert {:error, {:workflow_placeholder_count_drift, "{{SYMPHONY_RUNTIME_TRUTH_SOURCE_SHA}}"}} =
               ProducerContract.render_workflow(loaded, duplicate, render_values())
    after
      File.rm(duplicate)
    end
  end

  test "validates and reopens the exact v2 launch, contract, and rendered workflow" do
    assert {:ok, contract} = ProducerContract.load(@contract_path, @contract_sha256)
    assert {:ok, rendered} = ProducerContract.render_workflow(contract, @template_path, render_values())
    runtime_path = Path.join(System.tmp_dir!(), "symphony-runtime-#{System.unique_integer([:positive])}.md")
    launch_path = Path.join(System.tmp_dir!(), "symphony-launch-#{System.unique_integer([:positive])}.json")

    try do
      File.write!(runtime_path, rendered.bytes)
      launch = launch_receipt(runtime_path, rendered, contract)
      assert {:ok, bytes} = Rfc8785Jcs.encode(launch)
      File.write!(launch_path, bytes)
      digest = sha256(bytes)

      assert {:ok, loaded} = ProducerContract.validate_launch_receipt(launch_path, digest)
      assert loaded.document["schema_version"] == "manafuel.symphony-runtime-launch-receipt.v2"
      assert :ok = ProducerContract.validate_production_authority(loaded, contract, runtime_path)

      forged = put_in(launch, ["binding", "runtime_binding_sha256"], "not-a-digest")
      assert {:ok, forged_bytes} = Rfc8785Jcs.encode(forged)
      File.write!(launch_path, forged_bytes)

      assert {:error, {:invalid_lower_hex, :runtime_binding_sha256}} =
               ProducerContract.validate_launch_receipt(launch_path, sha256(forged_bytes))

      File.write!(launch_path, bytes)
      File.write!(runtime_path, rendered.bytes <> "tampered")

      assert {:error, {:value_mismatch, "runtime_workflow_sha256"}} =
               ProducerContract.validate_production_authority(loaded, contract, runtime_path)
    after
      File.rm(launch_path)
      File.rm(runtime_path)
    end
  end

  defp render_values do
    %{
      "runtime_truth_source_sha" => String.duplicate("1", 40),
      "linear_project_slug" => "manafuel-production",
      "workspace_root" => "C:/Users/jclen/OneDrive/Documents/apps/manafuel/worktrees/symphony",
      "producer_before_run_command" => "powershell.exe -File producer-admission.ps1",
      "max_concurrent_agents" => "1",
      "max_concurrent_ready" => "1",
      "max_concurrent_in_progress" => "1",
      "max_concurrent_rework" => "1",
      "codex_phase" => "production",
      "codex_app_server_enabled" => "true",
      "codex_command" => "codex app-server --listen stdio://",
      "codex_app_server_command" => "codex app-server --listen stdio://",
      "codex_approval_policy" => "never",
      "codex_thread_sandbox" => "workspace-write",
      "codex_turn_sandbox_policy_yaml" => "{type: workspaceWrite, networkAccess: false}",
      "control_root" => "C:/Users/jclen/OneDrive/Documents/apps/manafuel/development/.codex",
      "implementation_root" => "C:/Users/jclen/OneDrive/Documents/apps/manafuel/development",
      "worktree_root" => "C:/Users/jclen/OneDrive/Documents/apps/manafuel/worktrees"
    }
  end

  defp launch_receipt(runtime_path, rendered, contract) do
    sha = String.duplicate("a", 64)
    git_sha = String.duplicate("b", 40)
    absolute = Path.expand(runtime_path)
    file_row = launch_file_row(absolute, rendered.sha256, rendered.length)
    assert {:ok, render_inputs_bytes} = Rfc8785Jcs.encode(render_values())
    assert {:ok, rewrite_bytes} = Rfc8785Jcs.encode(contract.document["workflow_rewrite_contract"])

    %{
      "schema_version" => "manafuel.symphony-runtime-launch-receipt.v2",
      "launch_id" => String.duplicate("c", 32),
      "launched_at_utc" => "2026-08-01T00:00:00.0000000Z",
      "source" => %{
        "git_root" => Path.expand("."),
        "head_sha" => git_sha,
        "protected_ref" => "origin/main",
        "protected_ref_sha" => git_sha
      },
      "plugin" => %{
        "plugin_id" => "manafuel-codex@manafuel-local",
        "version" => "0.1.5+codex.20260729180000",
        "package_sha256" => sha,
        "source_path" => Path.expand("."),
        "source_physical_path" => Path.expand(".")
      },
      "runtime" => %{
        "port" => 4077,
        "run_directory" => Path.dirname(absolute),
        "worker_process" => %{},
        "scheduled_task" => %{}
      },
      "lock_evidence" => %{
        "artifact_lock_count" => 7,
        "provenance_lock_count" => 1,
        "receipt_lock_count" => 1,
        "share_mode" => "FILE_SHARE_READ",
        "generic_write_probe_win32_error" => 32,
        "delete_probe_win32_error" => 32,
        "locks_retained_through" => "synchronous_mise_exit"
      },
      "files" => %{
        "run_local_workflow" => file_row,
        "registry_workflow" => file_row,
        "symphony_binary" => launch_file_row(Path.expand("symphony.exe"), sha, 1),
        "codex_executable" => launch_file_row(Path.expand("codex.exe"), sha, 1),
        "hidden_launcher" => launch_file_row(Path.expand("launcher.exe"), sha, 1),
        "start_script" => launch_file_row(Path.expand("start.ps1"), sha, 1),
        "worker_script" => launch_file_row(Path.expand("worker.ps1"), sha, 1)
      },
      "workflow_render" => %{
        "schema_version" => "manafuel.symphony_workflow_render_receipt.v1",
        "tracked_workflow_path" => ".codex/workflows/symphony-manafuel/WORKFLOW.production.template.md",
        "tracked_workflow_sha256" => sha256(File.read!(@template_path)),
        "tracked_workflow_blob_oid" => git_sha,
        "runtime_workflow_path" => absolute,
        "runtime_workflow_sha256" => rendered.sha256,
        "runtime_workflow_length" => rendered.length,
        "render_inputs" => render_values(),
        "workflow_render_inputs_sha256" => sha256(render_inputs_bytes),
        "workflow_rewrite_contract_sha256" => sha256(rewrite_bytes),
        "producer_claim_contract_sha256" => contract.sha256,
        "codex_app_server_experimental_api" => true,
        "codex_app_server_history_mode" => "paginated",
        "line_endings" => "lf",
        "text_encoding" => "utf-8-no-bom",
        "terminal_newline" => false,
        "decision" => "PASS"
      },
      "binding" => %{
        "schema_version" => "manafuel.symphony-runtime-binding.v1",
        "vendor_binding_sha256" => sha,
        "runtime_binding_sha256" => sha
      }
    }
  end

  defp launch_file_row(path, sha, length) do
    %{
      "file_type" => "regular_file",
      "lexical_path" => Path.expand(path),
      "physical_path" => Path.expand(path),
      "sha256" => sha,
      "volume_serial_number" => "1",
      "file_id" => "1",
      "link_count" => 1,
      "length" => length
    }
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
