defmodule SymphonyElixir.ModelRoutingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  test "routes explicit executive roles while keeping ownership-only work on Terra" do
    write_workflow_file!(Workflow.workflow_file_path(), codex_model_routing: model_routing())

    assert {:ok, ceo} =
             Config.codex_runtime_settings(nil,
               issue: %Issue{labels: ["runtime-role:ceo", "owner:executive"]}
             )

    assert ceo.model_role == "ceo"
    assert ceo.model == "gpt-5.6-sol"
    assert ceo.reasoning_effort == "xhigh"

    assert {:ok, cmo} =
             Config.codex_runtime_settings(nil,
               issue: %Issue{labels: ["runtime-role:cmo", "owner:cmo"]}
             )

    assert cmo.model_role == "department_head"
    assert cmo.model == "gpt-5.6-sol"
    assert cmo.reasoning_effort == "high"

    assert {:ok, implementation} =
             Config.codex_runtime_settings(nil,
               issue: %Issue{labels: ["owner:cmo", "ceo-originated"]}
             )

    assert implementation.model_role == "implementation_worker"
    assert implementation.model == "gpt-5.6-terra"
    assert implementation.reasoning_effort == "medium"
  end

  test "routes research and grunt workers to Luna and implementation review to Terra high" do
    write_workflow_file!(Workflow.workflow_file_path(), codex_model_routing: model_routing())

    for {label, role, model, effort} <- [
          {"runtime-role:research-worker", "research_worker", "gpt-5.6-luna", "medium"},
          {"runtime-role:grunt-worker", "grunt_worker", "gpt-5.6-luna", "low"},
          {"runtime-role:implementation-reviewer", "implementation_reviewer", "gpt-5.6-terra", "high"}
        ] do
      assert {:ok, route} =
               Config.codex_runtime_settings(nil, issue: %Issue{labels: [label]})

      assert route.model_role == role
      assert route.model == model
      assert route.reasoning_effort == effort
    end
  end

  test "injects explicit parent and subagent settings into thread start" do
    write_workflow_file!(Workflow.workflow_file_path(), codex_model_routing: model_routing())

    assert {:ok, policies} =
             Config.codex_runtime_settings(nil,
               issue: %Issue{labels: ["runtime-role:department-head"]}
             )

    payload = AppServer.thread_start_payload("C:/workspaces/MANA-42", policies)

    assert get_in(payload, ["params", "model"]) == "gpt-5.6-sol"
    assert get_in(payload, ["params", "config", "model_reasoning_effort"]) == "high"

    assert get_in(payload, ["params", "config", "agents"]) == %{
             "default_subagent_model" => "gpt-5.6-luna",
             "default_subagent_reasoning_effort" => "low",
             "max_concurrent_threads_per_session" => 2
           }

    instructions = get_in(payload, ["params", "developerInstructions"])
    assert instructions =~ "explicitly routed as department_head on gpt-5.6-sol with high reasoning"
    assert instructions =~ "Do not inherit the parent model for delegated work"
    assert instructions =~ "Token telemetry is advisory only"

    turn_payload =
      AppServer.turn_start_payload(
        "thread-42",
        "Review the strategy",
        %Issue{identifier: "MANA-42", title: "Model routing"},
        "C:/workspaces/MANA-42",
        policies.approval_policy,
        policies.turn_sandbox_policy,
        policies.reasoning_effort
      )

    assert get_in(turn_payload, ["params", "effort"]) == "high"
  end

  test "omits model overrides when model routing is not configured" do
    assert {:ok, policies} = Config.codex_runtime_settings(nil)

    payload = AppServer.thread_start_payload("C:/workspaces/MANA-43", policies)

    refute Map.has_key?(payload["params"], "model")
    refute Map.has_key?(payload["params"], "config")

    turn_payload =
      AppServer.turn_start_payload(
        "thread-43",
        "Implement the issue",
        %Issue{identifier: "MANA-43", title: "Legacy routing"},
        "C:/workspaces/MANA-43",
        policies.approval_policy,
        policies.turn_sandbox_policy,
        policies.reasoning_effort
      )

    refute Map.has_key?(turn_payload["params"], "effort")
  end

  test "rejects conflicting explicit runtime roles" do
    write_workflow_file!(Workflow.workflow_file_path(), codex_model_routing: model_routing())

    assert {:error, {:conflicting_model_routing_roles, ["ceo", "department_head"]}} =
             Config.codex_runtime_settings(nil,
               issue: %Issue{
                 labels: ["runtime-role:ceo", "runtime-role:department-head"]
               }
             )
  end

  test "schema rejects missing defaults, unknown labels, and invalid reasoning efforts" do
    base = model_routing()

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{codex: %{model_routing: Map.delete(base, "subagents")}})

    assert message =~ "subagents must be a map"

    invalid_label_role = put_in(base, ["label_roles", "runtime-role:ceo"], "missing")

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{codex: %{model_routing: invalid_label_role}})

    assert message =~ "is not present in roles"

    invalid_effort = put_in(base, ["roles", "ceo", "reasoning_effort"], "impossible")

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{codex: %{model_routing: invalid_effort}})

    assert message =~ "reasoning_effort must be one of"
  end

  defp model_routing do
    %{
      "default_role" => "implementation_worker",
      "subagents" => %{
        "default_model" => "gpt-5.6-luna",
        "default_reasoning_effort" => "low",
        "max_concurrent_threads_per_session" => 2
      },
      "roles" => %{
        "ceo" => %{"model" => "gpt-5.6-sol", "reasoning_effort" => "xhigh"},
        "department_head" => %{"model" => "gpt-5.6-sol", "reasoning_effort" => "high"},
        "implementation_worker" => %{
          "model" => "gpt-5.6-terra",
          "reasoning_effort" => "medium"
        },
        "implementation_reviewer" => %{
          "model" => "gpt-5.6-terra",
          "reasoning_effort" => "high"
        },
        "research_worker" => %{"model" => "gpt-5.6-luna", "reasoning_effort" => "medium"},
        "grunt_worker" => %{"model" => "gpt-5.6-luna", "reasoning_effort" => "low"}
      },
      "label_roles" => %{
        "runtime-role:ceo" => "ceo",
        "runtime-role:department-head" => "department_head",
        "runtime-role:cfo" => "department_head",
        "runtime-role:cmo" => "department_head",
        "runtime-role:cto" => "department_head",
        "runtime-role:coo" => "department_head",
        "runtime-role:cpo" => "department_head",
        "runtime-role:implementation-reviewer" => "implementation_reviewer",
        "runtime-role:research-worker" => "research_worker",
        "runtime-role:grunt-worker" => "grunt_worker"
      }
    }
  end
end
