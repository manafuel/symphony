defmodule SymphonyElixir.ProducerV6.RuntimeBindingTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProducerV6.RuntimeBinding
  alias SymphonyElixir.Rfc8785Jcs

  test "reconstructs the exact vendor and runtime semantic digests" do
    launch = launch_fixture()
    evidence = evidence_fixture()

    assert {:ok, result} =
             RuntimeBinding.build_for_test(launch, String.duplicate("6", 64), "linear-viewer-1", evidence)

    assert result.vendor_projection == vendor_projection_fixture()
    assert result.runtime_projection == runtime_projection_fixture("linear-viewer-1")
    assert result.binding["schema_version"] == "manafuel.symphony-runtime-binding.v1"
    assert result.binding["vendor_binding_sha256"] == digest(vendor_projection_fixture())
    assert result.binding["runtime_binding_sha256"] == digest(runtime_projection_fixture("linear-viewer-1"))
  end

  test "authenticated viewer drift changes only the runtime digest" do
    launch = launch_fixture()
    evidence = evidence_fixture()

    assert {:ok, first} =
             RuntimeBinding.build_for_test(launch, String.duplicate("6", 64), "linear-viewer-1", evidence)

    assert {:ok, second} =
             RuntimeBinding.build_for_test(launch, String.duplicate("6", 64), "linear-viewer-2", evidence)

    assert first.binding["vendor_binding_sha256"] == second.binding["vendor_binding_sha256"]
    refute first.binding["runtime_binding_sha256"] == second.binding["runtime_binding_sha256"]
  end

  test "rejects a receipt whose semantic digest is not the reconstructed digest" do
    launch =
      launch_fixture()
      |> put_in(["binding"], %{
        "schema_version" => "manafuel.symphony-runtime-binding.v1",
        "vendor_binding_sha256" => String.duplicate("0", 64),
        "runtime_binding_sha256" => String.duplicate("1", 64)
      })

    assert {:error, :vendor_binding_sha256_mismatch} =
             RuntimeBinding.validate_for_test(
               launch,
               String.duplicate("6", 64),
               "linear-viewer-1",
               evidence_fixture()
             )
  end

  defp launch_fixture do
    %{
      "launch_id" => String.duplicate("a", 32),
      "source" => %{"head_sha" => String.duplicate("b", 40)},
      "plugin" => %{
        "plugin_id" => "manafuel-codex@manafuel-local",
        "version" => "0.1.3",
        "package_sha256" => String.duplicate("c", 64)
      },
      "runtime" => %{
        "scheduled_task" => %{
          "task_name" => "MANAfuel Codex Symphony Worker",
          "action_sha256" => String.duplicate("d", 64)
        }
      },
      "workflow_render" => %{
        "runtime_workflow_path" => "C:\\runtime\\WORKFLOW.md",
        "runtime_workflow_sha256" => String.duplicate("e", 64),
        "workflow_rewrite_contract_sha256" => String.duplicate("f", 64),
        "workflow_render_inputs_sha256" => String.duplicate("1", 64)
      },
      "files" => %{
        "symphony_binary" => %{
          "lexical_path" => "C:\\vendor\\elixir\\symphony",
          "sha256" => String.duplicate("2", 64),
          "length" => 12_345
        }
      }
    }
  end

  defp evidence_fixture do
    %{
      vendor_source_head_sha: String.duplicate("3", 40),
      vendor_patch_manifest_sha256: String.duplicate("4", 64),
      contract_binding: %{
        path: ".codex/workflows/symphony-manafuel/symphony-producer-execution-contract.json",
        sha256: String.duplicate("6", 64),
        blob_oid: String.duplicate("7", 40)
      },
      template_binding: %{
        path: ".codex/workflows/symphony-manafuel/WORKFLOW.production.template.md",
        sha256: String.duplicate("8", 64),
        blob_oid: String.duplicate("9", 40)
      },
      runtime_command: "powershell.exe -NoProfile -File C:/runtime/admission.ps1",
      runtime_script_path: "C:\\runtime\\admission.ps1",
      runtime_script_sha256: String.duplicate("a", 64),
      runtime_child_script_path: "C:\\runtime\\admission-child.ps1",
      runtime_child_script_sha256: String.duplicate("b", 64)
    }
  end

  defp vendor_projection_fixture do
    evidence = evidence_fixture()

    %{
      "schema_version" => "manafuel.symphony_vendor_binding_projection.v1",
      "vendor_source_head_sha" => evidence.vendor_source_head_sha,
      "symphony_binary_sha256" => String.duplicate("2", 64),
      "symphony_binary_length" => 12_345,
      "vendor_patch_manifest_sha256" => evidence.vendor_patch_manifest_sha256,
      "producer_claim_contract_path" => evidence.contract_binding.path,
      "producer_claim_contract_sha256" => evidence.contract_binding.sha256,
      "producer_claim_contract_blob_oid" => evidence.contract_binding.blob_oid,
      "tracked_workflow_path" => evidence.template_binding.path,
      "tracked_workflow_sha256" => evidence.template_binding.sha256,
      "tracked_workflow_blob_oid" => evidence.template_binding.blob_oid
    }
  end

  defp runtime_projection_fixture(viewer_id) do
    launch = launch_fixture()
    evidence = evidence_fixture()

    %{
      "schema_version" => "manafuel.symphony_runtime_binding_projection.v1",
      "vendor_binding_sha256" => digest(vendor_projection_fixture()),
      "launch_id" => launch["launch_id"],
      "target_source_sha" => launch["source"]["head_sha"],
      "vendor_source_head_sha" => evidence.vendor_source_head_sha,
      "installed_ref_mode" => "detached_exact_head",
      "installed_ref" => evidence.vendor_source_head_sha,
      "plugin_id" => launch["plugin"]["plugin_id"],
      "plugin_version" => launch["plugin"]["version"],
      "plugin_package_sha256" => launch["plugin"]["package_sha256"],
      "linear_worker_actor_id" => viewer_id,
      "scheduled_task_name" => launch["runtime"]["scheduled_task"]["task_name"],
      "scheduled_task_action_sha256" => launch["runtime"]["scheduled_task"]["action_sha256"],
      "tracked_workflow_path" => evidence.template_binding.path,
      "tracked_workflow_sha256" => evidence.template_binding.sha256,
      "tracked_workflow_blob_oid" => evidence.template_binding.blob_oid,
      "runtime_workflow_path" => launch["workflow_render"]["runtime_workflow_path"],
      "runtime_workflow_sha256" => launch["workflow_render"]["runtime_workflow_sha256"],
      "workflow_rewrite_contract_sha256" => launch["workflow_render"]["workflow_rewrite_contract_sha256"],
      "workflow_render_inputs_sha256" => launch["workflow_render"]["workflow_render_inputs_sha256"],
      "runtime_command" => evidence.runtime_command,
      "runtime_command_sha256" => sha256(evidence.runtime_command),
      "runtime_script_path" => evidence.runtime_script_path,
      "runtime_script_sha256" => evidence.runtime_script_sha256,
      "runtime_child_script_path" => evidence.runtime_child_script_path,
      "runtime_child_script_sha256" => evidence.runtime_child_script_sha256,
      "symphony_binary_path" => launch["files"]["symphony_binary"]["lexical_path"],
      "symphony_binary_sha256" => launch["files"]["symphony_binary"]["sha256"],
      "symphony_binary_length" => launch["files"]["symphony_binary"]["length"],
      "producer_claim_contract_sha256" => evidence.contract_binding.sha256
    }
  end

  defp digest(value) do
    assert {:ok, bytes} = Rfc8785Jcs.encode(value)
    sha256(bytes)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
