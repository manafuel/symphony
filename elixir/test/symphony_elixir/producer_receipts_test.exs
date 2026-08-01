defmodule SymphonyElixir.ProducerReceiptsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{ProducerReceipts, Rfc8785Jcs}
  alias SymphonyElixir.ProducerV6.Execution

  @contract_path Path.expand("../fixtures/symphony-producer-execution-contract.json", __DIR__)
  @deadline "2027-08-01T14:00:00.000Z"

  defmodule BrokerFixture do
    alias SymphonyElixir.Rfc8785Jcs

    def allocate_dispatch(issue, dispatch_sequence, retry_attempt, allocated_at, workspace_root, _authority, _deadline) do
      record(:allocate_dispatch)

      document = %{
        "schema_version" => "manafuel.symphony_dispatch_allocation.v1",
        "issue" => issue,
        "dispatch_sequence" => dispatch_sequence,
        "retry_attempt" => retry_attempt,
        "idempotency_key" => String.duplicate("2", 64),
        "claim_session_id" => "symcs-" <> String.duplicate("3", 32),
        "previous_allocation" => nil,
        "allocated_at_utc" => allocated_at,
        "decision" => "ALLOCATED"
      }

      {:ok, bytes} = Rfc8785Jcs.encode(document)
      digest = sha256(bytes)
      path = ".symphony-state/dispatch-allocations/sha256/#{binary_part(digest, 0, 2)}/#{digest}.json"
      physical = Path.join(workspace_root, String.replace(path, "/", "\\"))
      File.mkdir_p!(Path.dirname(physical))
      File.write!(physical, bytes)

      {:ok,
       %{
         allocation: document,
         reference: reference(path, physical, digest, byte_size(bytes), "allocation-file"),
         replay: false
       }}
    end

    def acquire_lock(process_epoch_id, owner_os_pid, deadline, workspace_root, _authority) do
      record(:acquire_lock)
      physical = Path.join(workspace_root, ".symphony-state\\execution.lock")

      identity = reference(".symphony-state/execution.lock", physical, String.duplicate("1", 64), 256, "lock-file")

      {:ok,
       %{
         lock: %{
           "schema_version" => "manafuel.symphony_ledger_write_lock.v1",
           "path" => ".symphony-state/execution.lock",
           "physical_path" => physical,
           "volume_id" => "volume-test",
           "file_id" => "lock-file",
           "file_type" => "regular",
           "link_count" => 1,
           "owner_process_epoch_id" => process_epoch_id,
           "owner_os_pid" => owner_os_pid,
           "acquired_at_utc" => "2026-08-01T14:00:00.000Z",
           "authority_deadline_at_utc" => deadline,
           "stale_break_policy" => "owner_dead_and_authority_deadline_expired_with_recovery_journal",
           "decision" => "LOCKED"
         },
         reference: identity
       }}
    end

    def release_lock(_reference, _deadline, _workspace_root, _authority) do
      record(:release_lock)
      :ok
    end

    def publish_cas(document, root_name, workspace_root, authority, _deadline) do
      record({:publish_cas, root_name})
      relative_root = get_in(authority, [:contract, :document, "path_roots", root_name])
      publish(document, relative_root, workspace_root)
    end

    def publish_cas_at(document, relative_root, _maximum, workspace_root, _authority, _deadline) do
      record({:publish_cas_at, relative_root})
      publish(document, relative_root, workspace_root)
    end

    def invoke_receipt(
          "InstallDualLedgerAndReadback",
          parameters,
          workspace_root,
          _authority,
          deadline
        ) do
      record(:install_dual_ledger)
      relative = Path.relative_to(parameters["target_ledger_path"], workspace_root) |> String.replace("\\", "/")
      bytes = Process.get({__MODULE__, :cas, relative})
      digest = sha256(bytes)
      length = byte_size(bytes)

      previous = destination("PREVIOUS", 1, workspace_root, digest, length, "previous-file")
      current = destination("CURRENT", 2, workspace_root, digest, length, "current-file")

      {:ok,
       %{
         "schema_version" => "manafuel.symphony_file_transaction_broker_result.v1",
         "action" => "InstallDualLedgerAndReadback",
         "request_sha256" => String.duplicate("a", 64),
         "deadline_at_utc" => deadline,
         "completed_at_utc" => "2026-08-01T14:00:01.000Z",
         "decision" => "PASS",
         "error_code" => nil,
         "result" => %{
           "installation_order" => ["PREVIOUS", "CURRENT"],
           "destination_results" => [previous, current],
           "generation_sha256" => digest,
           "generation_length" => length
         }
       }}
    end

    def calls, do: Process.get({__MODULE__, :calls}, []) |> Enum.reverse()

    defp publish(document, relative_root, workspace_root) do
      {:ok, bytes} = Rfc8785Jcs.encode(document)
      digest = sha256(bytes)
      relative = "#{relative_root}/#{binary_part(digest, 0, 2)}/#{digest}.json"
      physical = Path.join(workspace_root, String.replace(relative, "/", "\\"))
      Process.put({__MODULE__, :cas, relative}, bytes)
      {:ok, reference(relative, physical, digest, byte_size(bytes), "cas-#{digest}")}
    end

    defp destination(role, ordinal, workspace_root, digest, length, file_id) do
      relative = if role == "CURRENT", do: ".symphony-state/execution.json", else: ".symphony-state/execution.previous.json"
      physical = Path.join(workspace_root, String.replace(relative, "/", "\\"))

      %{
        "role" => role,
        "ordinal" => ordinal,
        "file_flushed" => true,
        "parent_directory_flushed" => true,
        "handle_reopened" => true,
        "identity_verified" => true,
        "bytes_verified" => true,
        "completed_at_utc" => "2026-08-01T14:00:01.000Z",
        "reference" => reference(physical, physical, digest, length, file_id)
      }
    end

    defp reference(path, physical, digest, length, file_id) do
      %{
        "path" => path,
        "physical_path" => physical,
        "volume_id" => "volume-test",
        "file_id" => file_id,
        "file_type" => "regular",
        "link_count" => 1,
        "sha256" => digest,
        "length" => length
      }
    end

    defp record(value) do
      Process.put({__MODULE__, :calls}, [value | Process.get({__MODULE__, :calls}, [])])
    end

    defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  setup do
    Process.delete({BrokerFixture, :calls})
    root = Path.join(System.tmp_dir!(), "producer-receipts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, contract_bytes} = File.read(@contract_path)
    {:ok, contract} = Rfc8785Jcs.validate_canonical(contract_bytes)
    %{root: root, authority: %{contract: %{document: contract}}}
  end

  test "production adapter reserves and commits prepared through the broker", %{
    root: root,
    authority: authority
  } do
    issue = %{
      id: "issue-1",
      identifier: "MAN-1",
      state: "Ready for Codex",
      url: "https://linear.app/manafuel/issue/MAN-1",
      assigned_to_worker: true
    }

    authority = put_in(authority, [:contract, :document, "constants", "workspace_root_windows"], root)

    context =
      authority
      |> Map.put(:kind, :producer_v6)
      |> Map.put(:runtime_binding, runtime_binding(authority.contract.document))

    assert {:ok, effects, prepared} =
             Execution.reserve_with_broker(context, %{}, issue, 1, 1, BrokerFixture)

    assert prepared.status == :prepared
    assert prepared.document["last_milestone"] == "prepared"
    assert prepared.document["milestone_sequence"] == 1
    assert Map.fetch!(effects, prepared.idempotency_key) == prepared

    assert BrokerFixture.calls() == [
             :allocate_dispatch,
             :acquire_lock,
             {:publish_cas, "milestone_evidence"},
             {:publish_cas, "transition"},
             {:publish_cas, "ledger_write_lock_receipt"},
             {:publish_cas, "ledger_install_intent_core"},
             {:publish_cas, "ledger_snapshot"},
             {:publish_cas, "ledger_install_plan"},
             :install_dual_ledger,
             {:publish_cas_at, ".symphony-state/file-transaction-broker-results/sha256"},
             {:publish_cas, "ledger_install_result"},
             :release_lock
           ]
  end

  test "commits the first prepared transition in exact immutable DAG order", %{root: root, authority: authority} do
    allocation_document = %{
      "schema_version" => "manafuel.symphony_dispatch_allocation.v1",
      "issue" => %{"id" => "issue-1", "identifier" => "MAN-1"},
      "dispatch_sequence" => 1,
      "retry_attempt" => 1,
      "idempotency_key" => String.duplicate("2", 64),
      "claim_session_id" => "symcs-" <> String.duplicate("3", 32),
      "previous_allocation" => nil,
      "allocated_at_utc" => "2026-08-01T14:00:00.000Z",
      "decision" => "ALLOCATED"
    }

    input = %{
      issue: %{
        "id" => "issue-1",
        "identifier" => "MAN-1",
        "state" => "Ready for Codex",
        "url" => "https://linear.app/manafuel/issue/MAN-1",
        "assigned_to_worker" => true
      },
      dispatch_allocation: %{
        document: allocation_document,
        reference: fixture_reference(".symphony-state/dispatch-allocations/sha256/aa/#{String.duplicate("a", 64)}.json", String.duplicate("a", 64), 512)
      },
      process_epoch_id: "process-epoch-1",
      runtime_binding: runtime_binding(authority.contract.document),
      producer_claim: nil,
      admission_result: nil,
      state: %{
        "attempt_phase" => "reserved",
        "disposition" => "active",
        "milestone_sequence" => 1,
        "last_milestone" => "prepared",
        "worker" => nil,
        "workspace" => nil,
        "producer_claim" => nil,
        "admission" => nil,
        "thread" => nil,
        "turns" => [],
        "completed_at_utc" => nil,
        "completion_outcome" => nil,
        "terminal_tracker" => nil,
        "hold" => nil
      },
      prepared_at_utc: "2026-08-01T14:00:00.000Z",
      previous_transition: nil,
      prior_milestones: [],
      evidence: %{"prepared_at_utc" => "2026-08-01T14:00:00.000Z"},
      deadline_at_utc: @deadline,
      owner_os_pid: 4242
    }

    assert {:ok, committed} =
             ProducerReceipts.commit_transition_with_broker(
               root,
               authority,
               input,
               BrokerFixture
             )

    assert committed.effect["last_milestone"] == "prepared"
    assert committed.effect["milestone_sequence"] == 1
    assert length(committed.effect["milestones"]) == 1
    assert committed.current["sha256"] == committed.previous["sha256"]
    refute committed.current["file_id"] == committed.previous["file_id"]
    assert committed.install_result.document["decision"] == "PASS"

    assert BrokerFixture.calls() == [
             :acquire_lock,
             {:publish_cas, "milestone_evidence"},
             {:publish_cas, "transition"},
             {:publish_cas, "ledger_write_lock_receipt"},
             {:publish_cas, "ledger_install_intent_core"},
             {:publish_cas, "ledger_snapshot"},
             {:publish_cas, "ledger_install_plan"},
             :install_dual_ledger,
             {:publish_cas_at, ".symphony-state/file-transaction-broker-results/sha256"},
             {:publish_cas, "ledger_install_result"},
             :release_lock
           ]
  end

  defp runtime_binding(contract) do
    contract["ordered_fields"]["transition_runtime_binding"]
    |> Map.new(fn key -> {key, "fixture-#{key}"} end)
  end

  defp fixture_reference(path, sha, length) do
    %{
      "path" => path,
      "physical_path" => "C:\\fixture\\#{sha}.json",
      "volume_id" => "volume-test",
      "file_id" => "file-#{sha}",
      "file_type" => "regular",
      "link_count" => 1,
      "sha256" => sha,
      "length" => length
    }
  end
end
