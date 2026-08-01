defmodule SymphonyElixir.ProducerV6LifecycleTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{ProducerV6.Lifecycle, Rfc8785Jcs}

  test "admission hook accepts only the exact canonical live PASS receipt" do
    receipt = %{
      "schema_version" => "manafuel.symphony_admission_hook_receipt.v1",
      "child_exit_code" => 0,
      "child_invoked" => true,
      "child_stdout_sha256" => String.duplicate("a", 64),
      "completed_at_utc" => "2026-08-01T13:00:00.000Z",
      "decision" => "PASS",
      "hook_exit_code" => 0
    }

    assert {:ok, bytes} = Rfc8785Jcs.encode(receipt)
    assert :ok = Lifecycle.validate_hook_receipt_for_test(bytes)

    assert {:ok, block_bytes} = Rfc8785Jcs.encode(%{receipt | "decision" => "BLOCK"})

    assert {:error, :producer_admission_hook_receipt_not_pass} =
             Lifecycle.validate_hook_receipt_for_test(block_bytes)

    assert {:error, _reason} =
             Lifecycle.validate_hook_receipt_for_test(bytes <> "\n")
  end

  test "admission hook rejects fabricated child success and extra fields" do
    base = %{
      "schema_version" => "manafuel.symphony_admission_hook_receipt.v1",
      "child_exit_code" => 0,
      "child_invoked" => true,
      "child_stdout_sha256" => String.duplicate("b", 64),
      "completed_at_utc" => "2026-08-01T13:00:00.000Z",
      "decision" => "PASS",
      "hook_exit_code" => 0
    }

    for tampered <- [
          %{base | "child_invoked" => false},
          %{base | "child_exit_code" => 1},
          %{base | "hook_exit_code" => 1},
          Map.put(base, "caller_asserted_pass", true)
        ] do
      assert {:ok, bytes} = Rfc8785Jcs.encode(tampered)

      assert {:error, :producer_admission_hook_receipt_not_pass} =
               Lifecycle.validate_hook_receipt_for_test(bytes)
    end
  end

  test "turn intent derives a content-bound unique client message id" do
    first = Lifecycle.turn_intent(1, "do the exact work")
    second = Lifecycle.turn_intent(2, "do the exact work")

    assert first["turn_number"] == 1
    assert byte_size(first["prompt_sha256"]) == 64
    assert byte_size(first["client_user_message_id"]) == 64
    refute first["client_user_message_id"] == second["client_user_message_id"]
    refute first["intent_at_utc"] == nil
  end

  test "thread projection binds the actual app-server pid and forbids legacy history" do
    thread =
      Lifecycle.thread(%{
        thread_id: "thread-live-1",
        metadata: %{codex_app_server_pid: 4242}
      })

    assert thread["id"] == "thread-live-1"
    assert thread["app_server_os_pid"] == 4242
    assert thread["experimental_api"]
    assert thread["history_mode"] == "paginated"
    refute thread["legacy_include_turns_used"]
    assert thread["memory_mode"] == "none"
  end
end
