defmodule SymphonyElixir.Rfc8785Jcs do
  @moduledoc """
  Strict RFC 8785/JCS byte authority for production receipts and ledgers.

  Decoding retains object pairs until duplicate names have been rejected.
  Accepted values are restricted to the I-JSON data model before the vendored
  canonicalizer emits UTF-8 bytes.
  """

  @max_safe_integer 9_007_199_254_740_991

  @spec decode_strict(binary()) :: {:ok, term()} | {:error, term()}
  def decode_strict(bytes) when is_binary(bytes) do
    with :ok <- validate_input_bytes(bytes),
         {:ok, ordered} <- Jason.decode(bytes, objects: :ordered_objects),
         {:ok, normalized} <- normalize(ordered) do
      {:ok, normalized}
    else
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:invalid_json, reason.position}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(value) do
    with {:ok, normalized} <- normalize(value) do
      try do
        {:ok, Jcs.encode(normalized)}
      rescue
        error in [ArgumentError, RuntimeError] -> {:error, {:canonicalization_failed, Exception.message(error)}}
      end
    end
  end

  @spec canonical?(binary()) :: boolean()
  def canonical?(bytes) when is_binary(bytes) do
    with {:ok, value} <- decode_strict(bytes),
         {:ok, canonical} <- encode(value) do
      canonical == bytes
    else
      _ -> false
    end
  end

  @spec validate_canonical(binary()) :: {:ok, term()} | {:error, term()}
  def validate_canonical(bytes) when is_binary(bytes) do
    with {:ok, value} <- decode_strict(bytes),
         {:ok, canonical} <- encode(value),
         true <- canonical == bytes do
      {:ok, value}
    else
      false -> {:error, :noncanonical_json}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_input_bytes(<<0xEF, 0xBB, 0xBF, _rest::binary>>), do: {:error, :utf8_bom_forbidden}
  defp validate_input_bytes(bytes), do: if(String.valid?(bytes), do: :ok, else: {:error, :invalid_utf8})

  defp normalize(%Jason.OrderedObject{values: values}) do
    Enum.reduce_while(values, {:ok, %{}, MapSet.new()}, fn
      {key, value}, {:ok, acc, seen} when is_binary(key) ->
        normalize_ordered_entry(key, value, acc, seen)

      _entry, _acc ->
        {:halt, {:error, :invalid_object_entry}}
    end)
    |> case do
      {:ok, normalized, _seen} -> {:ok, normalized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize(value) when is_map(value) and not is_struct(value) do
    value
    |> Map.to_list()
    |> Enum.reduce_while({:ok, %{}}, fn
      {key, nested}, {:ok, acc} when is_binary(key) ->
        normalize_map_entry(key, nested, acc)

      _entry, _acc ->
        {:halt, {:error, :non_string_object_name}}
    end)
  end

  defp normalize(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case normalize(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize(value) when is_integer(value) and abs(value) <= @max_safe_integer, do: {:ok, value}
  defp normalize(value) when is_integer(value), do: {:error, {:integer_outside_i_json_range, value}}
  defp normalize(value) when is_float(value), do: {:ok, value}
  defp normalize(value) when is_binary(value), do: if(String.valid?(value), do: {:ok, value}, else: {:error, :invalid_utf8_string})
  defp normalize(value) when is_boolean(value) or is_nil(value), do: {:ok, value}
  defp normalize(_value), do: {:error, :unsupported_json_value}

  defp normalize_ordered_entry(key, value, acc, seen) do
    cond do
      MapSet.member?(seen, key) ->
        {:halt, {:error, {:duplicate_object_name, key}}}

      not String.valid?(key) ->
        {:halt, {:error, :invalid_utf8_string}}

      true ->
        case normalize(value) do
          {:ok, normalized} ->
            {:cont, {:ok, Map.put(acc, key, normalized), MapSet.put(seen, key)}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end
  end

  defp normalize_map_entry(key, nested, acc) do
    if String.valid?(key) do
      case normalize(nested) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    else
      {:halt, {:error, :invalid_utf8_string}}
    end
  end
end
