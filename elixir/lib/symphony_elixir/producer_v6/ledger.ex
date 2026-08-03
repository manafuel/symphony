defmodule SymphonyElixir.ProducerV6.Ledger do
  @moduledoc """
  Read-only bootstrap validator for the producer-v6 durable ledger pair.

  This module deliberately refuses effect mutation until the reviewed transaction
  broker is wired. That keeps production from falling back to the v5 writer while
  still allowing startup to prove that a quiescent v6 pair is exact and canonical.
  """

  alias SymphonyElixir.ProducerV6.{Broker, Execution, Format}
  alias SymphonyElixir.Rfc8785Jcs

  @schema_version "symphony.execution_ledger.v6"
  @root_keys ~w(schema_version generation_id generated_at blocked retrying effects)

  @type authority :: %{
          required(:contract) => %{required(:document) => map()},
          required(:launch) => %{required(:document) => map()}
        }

  @spec load(Path.t(), authority()) ::
          {:ok, %{blocked: map(), retrying: map(), effects: map()}} | {:error, term()}
  def load(workspace_root, authority) do
    with :ok <- Broker.ensure_ledger_pair(workspace_root, authority) do
      do_load(workspace_root, authority, &Broker.inspect/3)
    end
  end

  @doc false
  @spec load_with_inspector_for_test(Path.t(), authority(), function()) ::
          {:ok, %{blocked: map(), retrying: map(), effects: map()}} | {:error, term()}
  def load_with_inspector_for_test(workspace_root, authority, inspector)
      when is_function(inspector, 3),
      do: do_load(workspace_root, authority, inspector)

  defp do_load(workspace_root, %{contract: %{document: contract}} = authority, inspector)
       when is_binary(workspace_root) and is_map(contract) do
    with :ok <- validate_workspace_root(workspace_root, contract),
         {:ok, paths} <- ledger_paths(workspace_root, contract),
         {:ok, current_identity} <- inspector.(paths.current, workspace_root, authority),
         {:ok, previous_identity} <- inspector.(paths.previous, workspace_root, authority),
         :ok <- distinct_equal_pair(current_identity, previous_identity),
         {:ok, current_bytes} <- read_required(paths.current, :current),
         {:ok, previous_bytes} <- read_required(paths.previous, :previous),
         :ok <- equal_pair(current_bytes, previous_bytes),
         {:ok, ledger} <- Rfc8785Jcs.validate_canonical(current_bytes),
         {:ok, effects} <- validate_ledger(ledger, contract) do
      {:ok, %{blocked: %{}, retrying: %{}, effects: effects}}
    end
  end

  defp do_load(_workspace_root, _authority, _inspector),
    do: {:error, :invalid_producer_v6_authority}

  @spec verify_unchanged(Path.t(), authority(), map(), map(), map()) ::
          :ok | {:error, term()}
  def verify_unchanged(workspace_root, authority, blocked, retrying, effects)
      when blocked == %{} and retrying == %{} and effects == %{} do
    case load(workspace_root, authority) do
      {:ok, _state} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_unchanged(_workspace_root, _authority, _blocked, _retrying, _effects),
    do: {:error, :producer_v6_transaction_broker_required}

  @doc false
  @spec verify_unchanged_with_inspector_for_test(
          Path.t(),
          authority(),
          map(),
          map(),
          map(),
          function()
        ) :: :ok | {:error, term()}
  def verify_unchanged_with_inspector_for_test(
        workspace_root,
        authority,
        blocked,
        retrying,
        effects,
        inspector
      )
      when blocked == %{} and retrying == %{} and effects == %{} and
             is_function(inspector, 3) do
    case load_with_inspector_for_test(workspace_root, authority, inspector) do
      {:ok, _state} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_unchanged_with_inspector_for_test(
        _workspace_root,
        _authority,
        _blocked,
        _retrying,
        _effects,
        _inspector
      ),
      do: {:error, :producer_v6_transaction_broker_required}

  defp validate_workspace_root(workspace_root, contract) do
    expected = get_in(contract, ["constants", "workspace_root_windows"])

    if comparable_path(workspace_root) == comparable_path(expected),
      do: :ok,
      else: {:error, :producer_v6_workspace_root_mismatch}
  end

  defp ledger_paths(workspace_root, contract) do
    current = get_in(contract, ["path_roots", "current_ledger"])
    previous = get_in(contract, ["path_roots", "previous_ledger"])

    with :ok <- exact_relative_path(current, ".symphony-state/execution.json"),
         :ok <-
           exact_relative_path(previous, ".symphony-state/execution.previous.json") do
      {:ok,
       %{
         current: Path.join([workspace_root | Path.split(current)]),
         previous: Path.join([workspace_root | Path.split(previous)])
       }}
    end
  end

  defp exact_relative_path(actual, expected) when actual == expected, do: :ok
  defp exact_relative_path(_actual, _expected), do: {:error, :producer_v6_ledger_path_drift}

  defp read_required(path, role) do
    if File.regular?(path),
      do: File.read(path),
      else: {:error, {:producer_v6_ledger_generation_missing, role}}
  end

  defp equal_pair(bytes, bytes), do: :ok
  defp equal_pair(_current, _previous), do: {:error, :producer_v6_ledger_pair_split}

  defp distinct_equal_pair(current, previous) when is_map(current) and is_map(previous) do
    with 1 <- current["link_count"],
         1 <- previous["link_count"],
         "regular" <- current["file_type"],
         "regular" <- previous["file_type"],
         true <- current["sha256"] == previous["sha256"],
         true <- current["length"] == previous["length"],
         false <-
           current["volume_id"] == previous["volume_id"] and
             current["file_id"] == previous["file_id"] do
      :ok
    else
      _ -> {:error, :producer_v6_ledger_pair_identity_invalid}
    end
  end

  defp distinct_equal_pair(_current, _previous),
    do: {:error, :producer_v6_ledger_pair_identity_invalid}

  defp validate_ledger(ledger, contract) when is_map(ledger) do
    max_effects = get_in(contract, ["bounds", "max_effects"])

    with :ok <- exact_keys(ledger),
         :ok <- exact_value(ledger, "schema_version", @schema_version),
         :ok <- generation_id(ledger["generation_id"]),
         :ok <- producer_datetime(ledger["generated_at"]),
         :ok <- exact_value(ledger, "blocked", []),
         :ok <- exact_value(ledger, "retrying", []) do
      effect_map(ledger["effects"], max_effects, contract)
    end
  end

  defp validate_ledger(_ledger, _contract),
    do: {:error, :producer_v6_ledger_not_an_object}

  defp exact_keys(ledger) do
    if Enum.sort(Map.keys(ledger)) == Enum.sort(@root_keys),
      do: :ok,
      else: {:error, :producer_v6_ledger_property_set_mismatch}
  end

  defp exact_value(map, key, expected) do
    if Map.get(map, key, :missing) === expected,
      do: :ok,
      else: {:error, {:producer_v6_ledger_value_mismatch, key}}
  end

  defp generation_id(value) when is_binary(value) do
    if Format.lower_hex?(value, 32),
      do: :ok,
      else: {:error, :producer_v6_generation_id_invalid}
  end

  defp generation_id(_value), do: {:error, :producer_v6_generation_id_invalid}

  defp producer_datetime(value) when is_binary(value) do
    if Format.producer_datetime?(value),
      do: :ok,
      else: {:error, :producer_v6_generated_at_invalid}
  end

  defp producer_datetime(_value), do: {:error, :producer_v6_generated_at_invalid}

  defp effect_map(effects, max_effects, contract)
       when is_list(effects) and is_integer(max_effects) and length(effects) <= max_effects do
    expected_keys = get_in(contract, ["ordered_fields", "effect"])

    effects
    |> Enum.reduce_while({:ok, %{}}, fn effect, {:ok, entries} ->
      with true <- is_list(expected_keys),
           true <- is_map(effect),
           true <- Enum.sort(Map.keys(effect)) == Enum.sort(expected_keys),
           key when is_binary(key) and key != "" <- effect["idempotency_key"],
           false <- Map.has_key?(entries, key) do
        {:cont, {:ok, Map.put(entries, key, Execution.entry_from_document(effect))}}
      else
        _ -> {:halt, {:error, :producer_v6_effect_list_invalid}}
      end
    end)
  end

  defp effect_map(_effects, _max_effects, _contract),
    do: {:error, :producer_v6_effect_list_invalid}

  defp comparable_path(path) when is_binary(path) do
    path
    |> Path.expand()
    |> String.replace("/", "\\")
    |> String.trim_trailing("\\")
    |> String.downcase()
  end

  defp comparable_path(_path), do: nil
end
