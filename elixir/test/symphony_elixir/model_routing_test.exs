defmodule SymphonyElixir.ModelRoutingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.ModelRouting

  test "owner labels never select a route and unlabeled issues default to implementation worker" do
    assert {:ok, route} = ModelRouting.resolve(%Issue{labels: ["owner:ceo", "owner:financial-controller"]})
    assert route.role == "implementation-worker"
    assert route.model == "gpt-5.6-terra"
    assert route.reasoning_effort == "medium"
    assert route.thread_sandbox == "workspace-write"
  end

  test "routes every supported runtime role to its fixed model, effort, and sandbox" do
    expected = [
      {"implementation-worker", "gpt-5.6-terra", "medium", "workspace-write"},
      {"implementation-debugger", "gpt-5.6-terra", "high", "workspace-write"},
      {"implementation-reviewer", "gpt-5.6-sol", "xhigh", "read-only"},
      {"ceo", "gpt-5.6-sol", "xhigh", "read-only"},
      {"financial-controller", "gpt-5.6-sol", "high", "read-only"},
      {"marketing-manager", "gpt-5.6-sol", "high", "read-only"},
      {"department-head", "gpt-5.6-sol", "high", "read-only"},
      {"research-worker", "gpt-5.6-luna", "medium", "read-only"},
      {"grunt-worker", "gpt-5.6-luna", "low", "read-only"}
    ]

    for {role, model, effort, sandbox} <- expected do
      assert {:ok, route} = ModelRouting.resolve(%Issue{labels: ["runtime-role:" <> role, "owner:any"]})
      assert %{role: ^role, model: ^model, reasoning_effort: ^effort, thread_sandbox: ^sandbox} = route

      if sandbox == "read-only" do
        assert route.turn_sandbox_policy == %{"type" => "readOnly"}
      end
    end
  end

  test "fails closed for unknown or multiple runtime role labels" do
    assert {:error, {:unknown_runtime_role, "unknown"}} =
             ModelRouting.resolve(%Issue{labels: ["runtime-role:unknown"]})

    assert {:error, {:conflicting_runtime_roles, ["ceo", "research-worker"]}} =
             ModelRouting.resolve(%Issue{labels: ["runtime-role:research-worker", "runtime-role:ceo"]})
  end

  test "native thread and turn payloads receive the selected model and effort" do
    assert {:ok, policies} =
             Config.codex_runtime_settings(nil, issue: %Issue{labels: ["runtime-role:implementation-reviewer"]})

    thread_payload = AppServer.thread_start_payload("C:/workspaces/MANA-42", policies)

    assert get_in(thread_payload, ["params", "model"]) == "gpt-5.6-sol"
    assert get_in(thread_payload, ["params", "config", "model_reasoning_effort"]) == "xhigh"
    assert get_in(thread_payload, ["params", "sandbox"]) == "read-only"
    assert get_in(thread_payload, ["params", "dynamicTools"]) == []
  end

  test "run records the authoritative thread and runtime identity with the routed native requests" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-model-routing-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MANA-42")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "app-server.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEX_TRACE")

      on_exit(fn -> restore_env("SYMP_TEST_CODEX_TRACE", previous_trace) end)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf '%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-routed"}}}' ;;
          3) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-routed"}}}' ;;
          4) printf '%s\\n' '{"method":"turn/completed"}'; exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-routed",
        identifier: "MANA-42",
        title: "Route native Codex request",
        labels: ["owner:engineering", "runtime-role:implementation-reviewer"]
      }

      assert {:ok, result} = AppServer.run(workspace, "Review the change", issue)
      assert result.thread_id == "thread-routed"
      assert result.turn_id == "turn-routed"
      assert result.model_role == "implementation-reviewer"
      assert result.model == "gpt-5.6-sol"
      assert result.reasoning_effort == "xhigh"
      assert is_map(result.runtime_identity)

      requests = trace_file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      thread_request = Enum.find(requests, &(&1["method"] == "thread/start"))
      turn_request = Enum.find(requests, &(&1["method"] == "turn/start"))

      assert get_in(thread_request, ["params", "model"]) == "gpt-5.6-sol"
      assert get_in(thread_request, ["params", "config", "model_reasoning_effort"]) == "xhigh"
      assert get_in(thread_request, ["params", "sandbox"]) == "read-only"
      assert get_in(turn_request, ["params", "model"]) == "gpt-5.6-sol"
      assert get_in(turn_request, ["params", "effort"]) == "xhigh"
      assert get_in(turn_request, ["params", "sandboxPolicy"]) == %{"type" => "readOnly"}
    after
      File.rm_rf(test_root)
    end
  end
end
