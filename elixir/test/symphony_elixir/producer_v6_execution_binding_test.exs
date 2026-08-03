defmodule SymphonyElixir.ProducerV6ExecutionBindingTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{ProducerV6.ExecutionBinding, Rfc8785Jcs}

  test "minimum valid immutable chain fits the corrected bounded envelope" do
    contract = contract()
    context = %{contract: %{document: contract}}
    reference = reference()

    fields =
      contract["ordered_fields"]["execution_binding"]
      |> Enum.reject(&(&1 == "schema_version"))
      |> Map.new(&{&1, nil})
      |> Map.merge(%{
        "effect_identity" => Map.new(contract["ordered_fields"]["execution_effect_identity"], &{&1, "bound"}),
        "transition_receipts" => List.duplicate(reference, 10),
        "ledger_install_plans" => List.duplicate(reference, 10),
        "ledger_install_results" => List.duplicate(reference, 10)
      })

    assert {:ok, binding} = ExecutionBinding.build_for_test(context, fields)
    assert {:ok, bytes} = Rfc8785Jcs.encode(binding)
    assert byte_size(bytes) > 10_000
    assert byte_size(bytes) <= contract["cas_limits"]["execution_binding"]
  end

  test "unknown execution binding fields fail closed" do
    contract = contract()
    context = %{contract: %{document: contract}}

    fields =
      contract["ordered_fields"]["execution_binding"]
      |> Enum.reject(&(&1 == "schema_version"))
      |> Map.new(&{&1, nil})
      |> Map.put(
        "effect_identity",
        Map.new(contract["ordered_fields"]["execution_effect_identity"], &{&1, "bound"})
      )
      |> Map.put("legacy_fallback", true)

    assert {:error, {:producer_execution_binding_projection_mismatch, "execution_binding"}} =
             ExecutionBinding.build_for_test(context, fields)
  end

  defp contract do
    path = Path.expand("../fixtures/symphony-producer-execution-contract.json", __DIR__)
    bytes = File.read!(path)
    {:ok, contract} = Rfc8785Jcs.validate_canonical(bytes)
    contract
  end

  defp reference do
    digest = String.duplicate("a", 64)

    %{
      "path" => ".symphony-state/producer-transitions/sha256/aa/#{digest}.json",
      "physical_path" => "\\\\?\\Volume{11111111-2222-3333-4444-555555555555}\\workspace\\.symphony-state\\producer-transitions\\sha256\\aa\\#{digest}.json",
      "volume_id" => "11111111",
      "file_id" => String.duplicate("b", 32),
      "file_type" => "regular",
      "link_count" => 1,
      "sha256" => digest,
      "length" => 430_000
    }
  end
end
