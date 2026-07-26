defmodule SymphonyElixir.Config.ModelRouting do
  @moduledoc false

  @reasoning_efforts ~w(none low medium high xhigh max ultra)

  @type resolved_route :: %{
          model: String.t() | nil,
          reasoning_effort: String.t() | nil,
          model_role: String.t() | nil,
          subagent_defaults: map() | nil
        }

  @spec validate(nil | map()) :: :ok | {:error, String.t()}
  def validate(nil), do: :ok

  def validate(routing) when is_map(routing) do
    with {:ok, default_role} <- required_string(routing, "default_role"),
         {:ok, roles} <- required_map(routing, "roles"),
         :ok <- validate_roles(roles),
         :ok <- validate_default_role(default_role, roles),
         {:ok, label_roles} <- required_map(routing, "label_roles"),
         :ok <- validate_label_roles(label_roles, roles),
         {:ok, subagents} <- required_map(routing, "subagents") do
      validate_subagents(subagents)
    end
  end

  def validate(_routing), do: {:error, "must be a map"}

  @spec resolve(nil | map(), map() | struct() | nil) ::
          {:ok, resolved_route()} | {:error, term()}
  def resolve(nil, _issue) do
    {:ok,
     %{
       model: nil,
       reasoning_effort: nil,
       model_role: nil,
       subagent_defaults: nil
     }}
  end

  def resolve(routing, issue) when is_map(routing) do
    roles = Map.fetch!(routing, "roles")
    label_roles = Map.fetch!(routing, "label_roles")

    selected_roles =
      issue
      |> issue_labels()
      |> Enum.map(&normalize_label/1)
      |> Enum.map(&Map.get(label_roles, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    with {:ok, role_name} <- select_role(selected_roles, routing["default_role"]),
         {:ok, route} <- fetch_route(roles, role_name) do
      {:ok,
       %{
         model: route["model"],
         reasoning_effort: route["reasoning_effort"],
         model_role: role_name,
         subagent_defaults: Map.fetch!(routing, "subagents")
       }}
    end
  end

  defp validate_roles(roles) when map_size(roles) == 0,
    do: {:error, "roles must define at least one route"}

  defp validate_roles(roles) do
    Enum.reduce_while(roles, :ok, fn {role_name, route}, :ok ->
      with :ok <- validate_name(role_name, "role names"),
           :ok <- validate_route(role_name, route) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_route(role_name, route) when is_map(route) do
    with {:ok, _model} <- required_string(route, "model"),
         {:ok, effort} <- required_string(route, "reasoning_effort"),
         :ok <- validate_effort(effort) do
      :ok
    else
      {:error, reason} -> {:error, "role #{inspect(role_name)} #{reason}"}
    end
  end

  defp validate_route(role_name, _route),
    do: {:error, "role #{inspect(role_name)} must be a map"}

  defp validate_default_role(default_role, roles) do
    if Map.has_key?(roles, default_role) do
      :ok
    else
      {:error, "default_role #{inspect(default_role)} is not present in roles"}
    end
  end

  defp validate_label_roles(label_roles, roles) do
    Enum.reduce_while(label_roles, :ok, fn {label, role_name}, :ok ->
      cond do
        not is_binary(label) or normalize_label(label) == "" ->
          {:halt, {:error, "label_roles keys must be non-blank strings"}}

        label != normalize_label(label) ->
          {:halt, {:error, "label_roles key #{inspect(label)} must be lowercase and trimmed"}}

        not is_binary(role_name) or not Map.has_key?(roles, role_name) ->
          {:halt, {:error, "label_roles value #{inspect(role_name)} for #{inspect(label)} is not present in roles"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_subagents(subagents) do
    with {:ok, _model} <- required_string(subagents, "default_model"),
         {:ok, effort} <- required_string(subagents, "default_reasoning_effort"),
         :ok <- validate_effort(effort),
         {:ok, concurrency} <- required_positive_integer(subagents, "max_concurrent_threads_per_session") do
      if concurrency > 0, do: :ok, else: {:error, "subagents max concurrency must be positive"}
    else
      {:error, reason} -> {:error, "subagents #{reason}"}
    end
  end

  defp validate_effort(effort) when effort in @reasoning_efforts, do: :ok

  defp validate_effort(effort),
    do: {:error, "reasoning_effort must be one of #{Enum.join(@reasoning_efforts, ", ")}; got #{inspect(effort)}"}

  defp validate_name(value, description) when is_binary(value) do
    if String.trim(value) == value and value != "" do
      :ok
    else
      {:error, "#{description} must be non-blank, trimmed strings"}
    end
  end

  defp validate_name(_value, description), do: {:error, "#{description} must be non-blank strings"}

  defp required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, "#{key} must not be blank"}, else: {:ok, value}

      _ ->
        {:error, "#{key} must be a string"}
    end
  end

  defp required_map(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, "#{key} must be a map"}
    end
  end

  defp required_positive_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, "#{key} must be a positive integer"}
    end
  end

  defp select_role([], default_role), do: {:ok, default_role}
  defp select_role([role_name], _default_role), do: {:ok, role_name}

  defp select_role(role_names, _default_role),
    do: {:error, {:conflicting_model_routing_roles, Enum.sort(role_names)}}

  defp fetch_route(roles, role_name) do
    case Map.fetch(roles, role_name) do
      {:ok, route} -> {:ok, route}
      :error -> {:error, {:unknown_model_routing_role, role_name}}
    end
  end

  defp issue_labels(%{labels: labels}) when is_list(labels), do: labels
  defp issue_labels(_issue), do: []

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_label(label), do: label |> to_string() |> normalize_label()
end
