defmodule SymphonyElixir.ProducerV6LedgerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{ExecutionLedgerRouter, Rfc8785Jcs}
  alias SymphonyElixir.ProducerV6.{Authority, Execution, Ledger}

  setup do
    prior = Authority.current_for_test()
    Authority.restore_for_test(nil)
    on_exit(fn -> Authority.restore_for_test(prior) end)
    :ok
  end

  test "missing production authority selects preview explicitly" do
    root = tmp_root("preview")

    assert {:ok, :preview, %{blocked: %{}, retrying: %{}, effects: %{}}} =
             ExecutionLedgerRouter.load(root)
  end

  test "invalid production authority fails closed without preview fallback" do
    Authority.restore_for_test(%{})

    assert {:error, :invalid_production_authority_property_set} =
             ExecutionLedgerRouter.load(tmp_root("invalid-authority"))
  end

  test "a durable terminal turn is complete without a closeout seal" do
    idempotency_key = String.duplicate("a", 64)

    effect =
      Execution.entry_from_document(%{
        "idempotency_key" => idempotency_key,
        "last_milestone" => "turn_terminal"
      })

    assert effect.status == :turn_terminal

    assert {:ok, %{^idempotency_key => ^effect}} =
             ExecutionLedgerRouter.mark_effect_completed(
               %{kind: :producer_v6},
               %{idempotency_key => effect},
               idempotency_key
             )
  end

  test "quiescent canonical v6 pair loads and mutation is refused" do
    root = tmp_root("v6")
    state_root = Path.join(root, ".symphony-state")
    File.mkdir_p!(state_root)

    ledger = %{
      "schema_version" => "symphony.execution_ledger.v6",
      "generation_id" => String.duplicate("a", 32),
      "generated_at" => "2026-08-01T13:00:00.000Z",
      "blocked" => [],
      "retrying" => [],
      "effects" => []
    }

    {:ok, bytes} = Rfc8785Jcs.encode(ledger)
    File.write!(Path.join(state_root, "execution.json"), bytes)
    File.write!(Path.join(state_root, "execution.previous.json"), bytes)

    context = authority(root)

    inspector = inspector()

    assert {:ok, %{blocked: %{}, retrying: %{}, effects: %{}}} =
             Ledger.load_with_inspector_for_test(root, context, inspector)

    assert :ok =
             Ledger.verify_unchanged_with_inspector_for_test(
               root,
               context,
               %{},
               %{},
               %{},
               inspector
             )

    assert {:error, :producer_v6_transaction_broker_required} =
             Ledger.verify_unchanged(root, context, %{"MAN-1" => %{}}, %{}, %{})
  end

  test "v6 pair rejects split generations, v5 bytes, and malformed effects" do
    root = tmp_root("reject")
    state_root = Path.join(root, ".symphony-state")
    File.mkdir_p!(state_root)

    base = %{
      "schema_version" => "symphony.execution_ledger.v6",
      "generation_id" => String.duplicate("b", 32),
      "generated_at" => "2026-08-01T13:00:00.000Z",
      "blocked" => [],
      "retrying" => [],
      "effects" => []
    }

    write_pair(state_root, base, %{base | "generation_id" => String.duplicate("c", 32)})

    assert {:error, :producer_v6_ledger_pair_identity_invalid} =
             Ledger.load_with_inspector_for_test(root, authority(root), inspector())

    v5 = %{base | "schema_version" => "symphony.execution_ledger.v5"}
    write_pair(state_root, v5, v5)

    assert {:error, {:producer_v6_ledger_value_mismatch, "schema_version"}} =
             Ledger.load_with_inspector_for_test(root, authority(root), inspector())

    active = %{base | "effects" => [%{"not" => "accepted"}]}
    write_pair(state_root, active, active)

    assert {:error, :producer_v6_effect_list_invalid} =
             Ledger.load_with_inspector_for_test(root, authority(root), inspector())
  end

  defp authority(root) do
    %{
      kind: :producer_v6,
      contract: %{
        document: %{
          "constants" => %{"workspace_root_windows" => root},
          "path_roots" => %{
            "current_ledger" => ".symphony-state/execution.json",
            "previous_ledger" => ".symphony-state/execution.previous.json"
          },
          "bounds" => %{"max_effects" => 10_000}
        }
      }
    }
  end

  defp write_pair(state_root, current, previous) do
    {:ok, current_bytes} = Rfc8785Jcs.encode(current)
    {:ok, previous_bytes} = Rfc8785Jcs.encode(previous)
    File.write!(Path.join(state_root, "execution.json"), current_bytes)
    File.write!(Path.join(state_root, "execution.previous.json"), previous_bytes)
  end

  defp inspector do
    fn path, _workspace_root, _authority ->
      bytes = File.read!(path)

      {:ok,
       %{
         "path" => Path.expand(path),
         "physical_path" => Path.expand(path),
         "volume_id" => "test-volume",
         "file_id" => :crypto.hash(:sha256, path) |> Base.encode16(case: :lower),
         "file_type" => "regular",
         "link_count" => 1,
         "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
         "length" => byte_size(bytes)
       }}
    end
  end

  defp tmp_root(label) do
    Path.join(System.tmp_dir!(), "symphony-producer-v6-#{label}-#{System.unique_integer([:positive])}")
  end
end
