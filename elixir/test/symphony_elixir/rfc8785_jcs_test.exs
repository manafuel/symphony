defmodule SymphonyElixir.Rfc8785JcsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Rfc8785Jcs

  @fixture_path Path.expand("../fixtures/rfc8785-jcs-vectors.json", __DIR__)
  @fixture_sha256 "031935a7307e3a5a511ae3221379d44ee359a4c129ede44fd2a49baa3f269539"

  test "fixture is frozen and every upstream canonical vector byte-matches" do
    bytes = File.read!(@fixture_path)
    assert sha256(bytes) == @fixture_sha256
    assert Rfc8785Jcs.canonical?(bytes)
    assert {:ok, fixture} = Rfc8785Jcs.validate_canonical(bytes)

    for row <- fixture["valid_json"] do
      input = Base.decode64!(row["input_base64"])
      expected = Base.decode64!(row["canonical_base64"])
      assert {:ok, value} = Rfc8785Jcs.decode_strict(input)
      assert {:ok, ^expected} = Rfc8785Jcs.encode(value)
      assert sha256(expected) == row["canonical_sha256"]
      assert Rfc8785Jcs.canonical?(expected)
    end
  end

  test "all Appendix B IEEE-754 samples match the frozen PowerShell authority" do
    {:ok, fixture} = @fixture_path |> File.read!() |> Rfc8785Jcs.validate_canonical()

    for row <- fixture["appendix_b_numbers"] do
      <<number::float-64>> = Base.decode16!(row["ieee754_hex"], case: :lower)
      assert {:ok, encoded} = Rfc8785Jcs.encode(number)
      assert encoded == row["canonical"], row["ieee754_hex"]
    end
  end

  test "duplicate names and every frozen malformed or noncanonical byte form fail closed" do
    {:ok, fixture} = @fixture_path |> File.read!() |> Rfc8785Jcs.validate_canonical()

    for row <- fixture["rejection_and_noncanonical_json"] do
      input = Base.decode64!(row["input_base64"])

      if row["expected_decision"] == "BLOCK" do
        refute Rfc8785Jcs.canonical?(input)
      else
        assert {:ok, _value} = Rfc8785Jcs.decode_strict(input)
        refute Rfc8785Jcs.canonical?(input)
      end
    end
  end

  test "unsafe integers and non-string programmatic keys are rejected" do
    assert {:error, {:integer_outside_i_json_range, _}} = Rfc8785Jcs.encode(9_007_199_254_740_992)
    assert {:error, :non_string_object_name} = Rfc8785Jcs.encode(%{atom_key: true})
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
