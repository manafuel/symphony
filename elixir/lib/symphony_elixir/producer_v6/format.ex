defmodule SymphonyElixir.ProducerV6.Format do
  @moduledoc false

  @spec lower_hex?(term(), pos_integer()) :: boolean()
  def lower_hex?(value, length)
      when is_binary(value) and is_integer(length) and length > 0 and
             byte_size(value) == length do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 in ?0..?9 or &1 in ?a..?f))
  end

  def lower_hex?(_value, _length), do: false

  @spec producer_datetime?(term()) :: boolean()
  def producer_datetime?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} ->
        Calendar.strftime(datetime, "%Y-%m-%dT%H:%M:%S.%3fZ") == value

      _ ->
        false
    end
  end

  def producer_datetime?(_value), do: false
end
