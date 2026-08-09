defmodule SymphonyElixir.Config.ModelRouting do
  @moduledoc false

  @type route :: %{
          role: String.t(),
          model: String.t(),
          reasoning_effort: String.t(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map() | nil
        }

  @routes %{
    "implementation-worker" => %{
      model: "gpt-5.6-terra",
      reasoning_effort: "medium",
      thread_sandbox: "workspace-write",
      turn_sandbox_policy: nil
    },
    "implementation-debugger" => %{
      model: "gpt-5.6-terra",
      reasoning_effort: "high",
      thread_sandbox: "workspace-write",
      turn_sandbox_policy: nil
    },
    "implementation-reviewer" => %{
      model: "gpt-5.6-sol",
      reasoning_effort: "xhigh",
      thread_sandbox: "read-only",
      turn_sandbox_policy: %{"type" => "readOnly"}
    },
    "ceo" => %{
      model: "gpt-5.6-sol",
      reasoning_effort: "xhigh",
      thread_sandbox: "read-only",
      turn_sandbox_policy: %{"type" => "readOnly"}
    },
    "financial-controller" => %{
      model: "gpt-5.6-sol",
      reasoning_effort: "high",
      thread_sandbox: "read-only",
      turn_sandbox_policy: %{"type" => "readOnly"}
    },
    "marketing-manager" => %{
      model: "gpt-5.6-sol",
      reasoning_effort: "high",
      thread_sandbox: "read-only",
      turn_sandbox_policy: %{"type" => "readOnly"}
    },
    "department-head" => %{
      model: "gpt-5.6-sol",
      reasoning_effort: "high",
      thread_sandbox: "read-only",
      turn_sandbox_policy: %{"type" => "readOnly"}
    },
    "research-worker" => %{
      model: "gpt-5.6-luna",
      reasoning_effort: "medium",
      thread_sandbox: "read-only",
      turn_sandbox_policy: %{"type" => "readOnly"}
    },
    "grunt-worker" => %{
      model: "gpt-5.6-luna",
      reasoning_effort: "low",
      thread_sandbox: "read-only",
      turn_sandbox_policy: %{"type" => "readOnly"}
    }
  }

  @spec resolve(map() | struct() | nil) :: {:ok, route()} | {:error, term()}
  def resolve(issue) do
    case runtime_roles(issue) do
      [] -> fetch_route("implementation-worker")
      [role] -> fetch_route(role)
      roles -> {:error, {:conflicting_runtime_roles, Enum.sort(roles)}}
    end
  end

  defp fetch_route(role) do
    case Map.fetch(@routes, role) do
      {:ok, route} -> {:ok, Map.put(route, :role, role)}
      :error -> {:error, {:unknown_runtime_role, role}}
    end
  end

  defp runtime_roles(%{labels: labels}) when is_list(labels) do
    labels
    |> Enum.map(&normalize_label/1)
    |> Enum.filter(&String.starts_with?(&1, "runtime-role:"))
    |> Enum.map(&String.trim_leading(&1, "runtime-role:"))
  end

  defp runtime_roles(_issue), do: []

  defp normalize_label(label) when is_binary(label),
    do: label |> String.trim() |> String.downcase()

  defp normalize_label(label), do: label |> to_string() |> normalize_label()
end
