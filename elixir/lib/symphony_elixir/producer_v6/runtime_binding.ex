defmodule SymphonyElixir.ProducerV6.RuntimeBinding do
  @moduledoc """
  Reconstructs and verifies the producer-v6 semantic launch binding.

  The PowerShell launcher and this module independently build the same RFC 8785
  vendor and runtime projections. Production startup proceeds only when both
  independently computed digests equal the sealed launch receipt.
  """

  alias SymphonyElixir.Rfc8785Jcs

  @binding_schema "manafuel.symphony-runtime-binding.v1"
  @vendor_projection_schema "manafuel.symphony_vendor_binding_projection.v1"
  @runtime_projection_schema "manafuel.symphony_runtime_binding_projection.v1"

  @type evidence :: %{
          required(:vendor_source_head_sha) => String.t(),
          required(:vendor_patch_manifest_sha256) => String.t(),
          required(:contract_binding) => map(),
          required(:template_binding) => map(),
          required(:runtime_command) => String.t(),
          required(:runtime_script_path) => String.t(),
          required(:runtime_script_sha256) => String.t(),
          required(:runtime_child_script_path) => String.t(),
          required(:runtime_child_script_sha256) => String.t()
        }

  @doc false
  @spec build_for_test(map(), String.t(), String.t(), evidence()) ::
          {:ok, map()} | {:error, term()}
  def build_for_test(launch, contract_sha256, viewer_id, evidence) do
    build(launch, contract_sha256, viewer_id, evidence)
  end

  @doc false
  @spec validate_for_test(map(), String.t(), String.t(), evidence()) ::
          :ok | {:error, term()}
  def validate_for_test(launch, contract_sha256, viewer_id, evidence) do
    with {:ok, reconstructed} <- build(launch, contract_sha256, viewer_id, evidence),
         :ok <-
           exact_digest(
             get_in(launch, ["binding", "vendor_binding_sha256"]),
             reconstructed.binding["vendor_binding_sha256"],
             :vendor_binding_sha256_mismatch
           ) do
      exact_digest(
        get_in(launch, ["binding", "runtime_binding_sha256"]),
        reconstructed.binding["runtime_binding_sha256"],
        :runtime_binding_sha256_mismatch
      )
    end
  end

  defp build(launch, contract_sha256, viewer_id, evidence)
       when is_map(launch) and is_binary(contract_sha256) and is_binary(viewer_id) and
              is_map(evidence) do
    with :ok <- non_empty(viewer_id, :linear_worker_actor_id),
         :ok <-
           exact_digest(
             evidence.contract_binding.sha256,
             contract_sha256,
             :producer_contract_binding_mismatch
           ),
         {:ok, vendor_projection} <- vendor_projection(launch, evidence),
         {:ok, vendor_bytes} <- Rfc8785Jcs.encode(vendor_projection) do
      vendor_digest = sha256(vendor_bytes)
      runtime_projection = runtime_projection(launch, viewer_id, evidence, vendor_digest)

      with {:ok, runtime_bytes} <- Rfc8785Jcs.encode(runtime_projection) do
        {:ok,
         %{
           binding: %{
             "schema_version" => @binding_schema,
             "vendor_binding_sha256" => vendor_digest,
             "runtime_binding_sha256" => sha256(runtime_bytes)
           },
           vendor_projection: vendor_projection,
           runtime_projection: runtime_projection
         }}
      end
    end
  end

  defp build(_launch, _contract_sha256, _viewer_id, _evidence),
    do: {:error, :invalid_runtime_binding_inputs}

  defp vendor_projection(launch, evidence) do
    binary = get_in(launch, ["files", "symphony_binary"])
    contract = evidence.contract_binding
    template = evidence.template_binding

    if is_map(binary) and is_map(contract) and is_map(template) do
      {:ok,
       %{
         "schema_version" => @vendor_projection_schema,
         "vendor_source_head_sha" => evidence.vendor_source_head_sha,
         "symphony_binary_sha256" => binary["sha256"],
         "symphony_binary_length" => binary["length"],
         "vendor_patch_manifest_sha256" => evidence.vendor_patch_manifest_sha256,
         "producer_claim_contract_path" => contract.path,
         "producer_claim_contract_sha256" => contract.sha256,
         "producer_claim_contract_blob_oid" => contract.blob_oid,
         "tracked_workflow_path" => template.path,
         "tracked_workflow_sha256" => template.sha256,
         "tracked_workflow_blob_oid" => template.blob_oid
       }}
    else
      {:error, :invalid_vendor_projection_inputs}
    end
  end

  defp runtime_projection(launch, viewer_id, evidence, vendor_digest) do
    source = launch["source"]
    plugin = launch["plugin"]
    task = get_in(launch, ["runtime", "scheduled_task"])
    render = launch["workflow_render"]
    binary = get_in(launch, ["files", "symphony_binary"])
    template = evidence.template_binding

    %{
      "schema_version" => @runtime_projection_schema,
      "vendor_binding_sha256" => vendor_digest,
      "launch_id" => launch["launch_id"],
      "target_source_sha" => source["head_sha"],
      "vendor_source_head_sha" => evidence.vendor_source_head_sha,
      "installed_ref_mode" => "detached_exact_head",
      "installed_ref" => evidence.vendor_source_head_sha,
      "plugin_id" => plugin["plugin_id"],
      "plugin_version" => plugin["version"],
      "plugin_package_sha256" => plugin["package_sha256"],
      "linear_worker_actor_id" => viewer_id,
      "scheduled_task_name" => task["task_name"],
      "scheduled_task_action_sha256" => task["action_sha256"],
      "tracked_workflow_path" => template.path,
      "tracked_workflow_sha256" => template.sha256,
      "tracked_workflow_blob_oid" => template.blob_oid,
      "runtime_workflow_path" => render["runtime_workflow_path"],
      "runtime_workflow_sha256" => render["runtime_workflow_sha256"],
      "workflow_rewrite_contract_sha256" => render["workflow_rewrite_contract_sha256"],
      "workflow_render_inputs_sha256" => render["workflow_render_inputs_sha256"],
      "runtime_command" => evidence.runtime_command,
      "runtime_command_sha256" => sha256(evidence.runtime_command),
      "runtime_script_path" => evidence.runtime_script_path,
      "runtime_script_sha256" => evidence.runtime_script_sha256,
      "runtime_child_script_path" => evidence.runtime_child_script_path,
      "runtime_child_script_sha256" => evidence.runtime_child_script_sha256,
      "symphony_binary_path" => binary["lexical_path"],
      "symphony_binary_sha256" => binary["sha256"],
      "symphony_binary_length" => binary["length"],
      "producer_claim_contract_sha256" => evidence.contract_binding.sha256
    }
  end

  defp non_empty(value, _label) when is_binary(value) and value != "", do: :ok
  defp non_empty(_value, label), do: {:error, {:empty_value, label}}

  defp exact_digest(observed, expected, _error) when observed === expected, do: :ok
  defp exact_digest(_observed, _expected, error), do: {:error, error}

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
