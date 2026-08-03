defmodule SymphonyElixir.ProducerV6ManagementTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{ProducerV6.Management, Rfc8785Jcs}

  defmodule BrokerStub do
    alias SymphonyElixir.Rfc8785Jcs

    def inspect(path, _workspace_root, _context), do: identity(path)

    def publish_cas(document, root_name, workspace_root, context, _deadline) do
      relative = get_in(context, [:contract, :document, "path_roots", root_name])
      {:ok, bytes} = Rfc8785Jcs.encode(document)
      digest = sha256(bytes)
      path = Path.join([workspace_root, String.replace(relative, "\\", "/"), String.slice(digest, 0, 2), digest <> ".json"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
      {:ok, reference(path, workspace_root)}
    end

    def reference(path, workspace_root) do
      {:ok, identity} = identity(path)

      %{
        "path" => path |> Path.relative_to(workspace_root) |> String.replace("\\", "/"),
        "physical_path" => identity["physical_path"],
        "volume_id" => identity["volume_id"],
        "file_id" => identity["file_id"],
        "file_type" => identity["file_type"],
        "link_count" => identity["link_count"],
        "sha256" => identity["sha256"],
        "length" => identity["length"]
      }
    end

    defp identity(path) do
      case File.read(path) do
        {:ok, bytes} ->
          digest = sha256(bytes)

          {:ok,
           %{
             "path" => Path.expand(path),
             "physical_path" => "test://#{digest}",
             "volume_id" => "test-volume",
             "file_id" => digest,
             "file_type" => "regular",
             "link_count" => 1,
             "sha256" => digest,
             "length" => byte_size(bytes)
           }}

        error ->
          error
      end
    end

    defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  test "publishes exactly one causally later recurring management receipt and projection" do
    {root, context} = workspace_context()
    ceo_reference = publish_fixture(root, context, "ceo_prioritization_receipt", "ceo_prioritization_receipt", %{"process_epoch_id" => "symceo-test"})
    tracker = tracker(at(-60), at(3_600))

    publish_fixture(root, context, "execution_binding", "execution_binding", %{
      "decision" => "PASS",
      "completion_outcome" => "issue_terminal",
      "task_down_observed_at_utc" => at(-30),
      "completed_at_utc" => at(-45),
      "terminal_tracker" => tracker,
      "ceo_prioritization_receipt" => ceo_reference,
      "effect_identity" => %{
        "issue_id" => "issue-1",
        "identifier" => "MAN-900",
        "claim_session_id" => "symcs-" <> String.duplicate("a", 32),
        "idempotency_key" => String.duplicate("b", 64)
      }
    })

    assert {:ok, 1} = Management.observe_with_broker(context, BrokerStub)
    assert {:ok, 0} = Management.observe_with_broker(context, BrokerStub)

    [receipt] = documents(root, context, "natural_management_receipt")
    [projection] = documents(root, context, "management_state_projection")
    assert receipt["publisher_kind"] == "SYMPHONY_RECURRING"
    assert receipt["management_action"] == "ISSUE_TERMINAL_STATE_RECONCILED"
    assert projection["causal_order"] == "V6_ISSUE_TERMINAL_THEN_NATURAL_MANAGEMENT"
    assert projection["natural_management_receipt_sha256"] == canonical_sha256(receipt)
    assert projection["management_process_epoch_id"] == receipt["publisher_process_epoch_id"]

    publish_fixture(root, context, "execution_binding", "execution_binding", %{
      "decision" => "PASS",
      "completion_outcome" => "issue_terminal",
      "task_down_observed_at_utc" => at(-20),
      "completed_at_utc" => at(-35),
      "terminal_tracker" => tracker(at(-50), at(3_600)),
      "ceo_prioritization_receipt" => ceo_reference,
      "effect_identity" => %{
        "issue_id" => "issue-2",
        "identifier" => "MAN-901",
        "claim_session_id" => "symcs-" <> String.duplicate("c", 32),
        "idempotency_key" => String.duplicate("d", 64)
      }
    })

    assert {:ok, 1} = Management.observe_with_broker(context, BrokerStub)

    epochs =
      documents(root, context, "natural_management_receipt")
      |> Enum.map(& &1["publisher_process_epoch_id"])

    assert length(epochs) == 2
    assert MapSet.size(MapSet.new(epochs)) == 2
  end

  test "malformed terminal tracker fails closed instead of crashing" do
    {root, context} = workspace_context()
    ceo_reference = publish_fixture(root, context, "ceo_prioritization_receipt", "ceo_prioritization_receipt", %{"process_epoch_id" => "symceo-test"})

    publish_fixture(root, context, "execution_binding", "execution_binding", %{
      "decision" => "PASS",
      "completion_outcome" => "issue_terminal",
      "task_down_observed_at_utc" => at(-30),
      "terminal_tracker" => nil,
      "ceo_prioritization_receipt" => ceo_reference
    })

    assert {:error, :producer_management_evidence_invalid} =
             Management.observe_with_broker(context, BrokerStub)
  end

  defp workspace_context do
    root = Path.join(System.tmp_dir!(), "producer-v6-management-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    contract = contract() |> put_in(["constants", "workspace_root_windows"], root)
    {root, %{kind: :producer_v6, contract: %{document: contract}}}
  end

  defp publish_fixture(root, context, root_name, projection, values) do
    fields = get_in(context, [:contract, :document, "ordered_fields", projection])
    document = fields |> Map.new(&{&1, nil}) |> Map.merge(values)
    {:ok, reference} = BrokerStub.publish_cas(document, root_name, root, context, at(3_600))
    reference
  end

  defp documents(root, context, root_name) do
    relative = get_in(context, [:contract, :document, "path_roots", root_name])

    Path.wildcard(Path.join([String.replace(root, "\\", "/"), String.replace(relative, "\\", "/"), "**", "*.json"]), match_dot: true)
    |> Enum.map(fn path ->
      {:ok, document} = path |> File.read!() |> Rfc8785Jcs.validate_canonical()
      document
    end)
  end

  defp tracker(refreshed_at, deadline_at) do
    %{
      "deadline_at_utc" => deadline_at,
      "state" => %{"id" => "state-done", "type" => "completed"},
      "final_worker_comment" => %{"marker" => %{"prefix" => "symphony:final:"}, "author_id" => "worker-1"},
      "done_transition" => %{"history_id" => "history-1", "actor_id" => "worker-1"},
      "refreshed_at_utc" => refreshed_at
    }
  end

  defp contract do
    path = Path.expand("../fixtures/symphony-producer-execution-contract.json", __DIR__)
    {:ok, contract} = path |> File.read!() |> Rfc8785Jcs.validate_canonical()
    contract
  end

  defp canonical_sha256(document) do
    {:ok, bytes} = Rfc8785Jcs.encode(document)
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp at(seconds) do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.%3fZ")
  end
end
