defmodule SymphonyElixir.AppServerTest do
  use SymphonyElixir.TestSupport

  test "app server rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-guard",
        identifier: "MT-999",
        title: "Validate workspace guard",
        description: "Ensure app-server refuses invalid cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-999",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               AppServer.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AppServer.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects symlink escape cwd paths under the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-symlink-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      symlink_workspace = Path.join(workspace_root, "MT-1000")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      case File.ln_s(outside_workspace, symlink_workspace) do
        :ok ->
          :ok

        {:error, :eperm} ->
          assert windows?()

        {:error, reason} ->
          flunk("failed to create symlink: #{inspect(reason)}")
      end

      if File.exists?(symlink_workspace) do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root
        )

        issue = %Issue{
          id: "issue-workspace-symlink-guard",
          identifier: "MT-1000",
          title: "Validate symlink workspace guard",
          description: "Ensure app-server refuses symlink escape cwd targets",
          state: "In Progress",
          url: "https://example.org/issues/MT-1000",
          labels: ["backend"]
        }

        assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
                 AppServer.run(symlink_workspace, "guard", issue)
      else
        assert windows?()
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "app server passes explicit turn sandbox policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-turn-policies-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1001")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-turn-policies.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-turn-policies.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1001"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1001"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      issue = %Issue{
        id: "issue-supported-turn-policies",
        identifier: "MT-1001",
        title: "Validate explicit turn sandbox policy passthrough",
        description: "Ensure runtime startup forwards configured turn sandbox policies unchanged",
        state: "In Progress",
        url: "https://example.org/issues/MT-1001",
        labels: ["backend"]
      }

      policy_cases = [
        %{"type" => "dangerFullAccess"},
        %{"type" => "externalSandbox", "profile" => "remote-ci"},
        %{"type" => "workspaceWrite", "writableRoots" => ["relative/path"], "networkAccess" => true},
        %{"type" => "futureSandbox", "nested" => %{"flag" => true}}
      ]

      Enum.each(policy_cases, fn configured_policy ->
        File.rm(trace_file)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server",
          codex_turn_sandbox_policy: configured_policy
        )

        assert {:ok, _result} = AppServer.run(workspace, "Validate supported turn policy", issue)

        trace = File.read!(trace_file)
        lines = String.split(trace, "\n", trim: true)

        assert Enum.any?(lines, fn line ->
                 if String.starts_with?(line, "JSON:") do
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()
                   |> then(fn payload ->
                     payload["method"] == "turn/start" &&
                       get_in(payload, ["params", "sandboxPolicy"]) == configured_policy
                   end)
                 else
                   false
                 end
               end)
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server advertises hosted sandboxed shell and issue-local clone instructions at thread start" do
    payload =
      AppServer.thread_start_payload("C:/workspaces/MT-1002", %{
        approval_policy: "never",
        thread_sandbox: "workspace-write"
      })

    instructions = get_in(payload, ["params", "developerInstructions"])
    dynamic_tools = get_in(payload, ["params", "dynamicTools"])

    assert payload["method"] == "thread/start"
    assert get_in(payload, ["params", "approvalPolicy"]) == "never"
    assert get_in(payload, ["params", "sandbox"]) == "workspace-write"
    assert get_in(payload, ["params", "cwd"]) == "C:/workspaces/MT-1002"
    assert Enum.map(dynamic_tools, & &1["name"]) == ["linear_graphql", "write_run_artifact"]
    assert is_binary(instructions)
    refute instructions =~ "local_shell"
    assert instructions =~ "Use hosted sandboxed `shell_command` for all local command work"
    assert instructions =~ "direct PowerShell read/navigation cmdlets"
    assert instructions =~ "Get-ChildItem"
    assert instructions =~ "current issue workspace `runs/` directory"
    assert instructions =~ "`write_run_artifact` for issue-local run evidence"
    assert instructions =~ "apply_patch for repository edits"
    assert instructions =~ "Issue at most one hosted `shell_command` tool call per assistant turn"
    assert instructions =~ "do not move a ticket to Human Review solely"
    assert instructions =~ "has already applied packaged MANAfuel skill orientation"
    assert instructions =~ "Do not use hosted shell_command to read packaged SKILL.md"
    assert instructions =~ "manafuel-codex:* skill files"
    assert instructions =~ "current cwd is a scratch Symphony issue workspace"
    assert instructions =~ "Before reading or editing product repository files"
    assert instructions =~ "issue-local normal clone"
    assert instructions =~ "based on current `origin/main`"
    assert instructions =~ "Do not use a linked Git worktree"
  end

  test "app server wraps local Windows app-server launch with hidden stdio launcher" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-hidden-stdio-launch-#{System.unique_integer([:positive])}"
      )

    previous_launcher = System.get_env("CODEX_HIDDEN_STDIO_LAUNCHER")
    previous_disabled = System.get_env("SYMPHONY_DISABLE_CODEX_HIDDEN_STDIO_LAUNCHER")

    on_exit(fn ->
      restore_env("CODEX_HIDDEN_STDIO_LAUNCHER", previous_launcher)
      restore_env("SYMPHONY_DISABLE_CODEX_HIDDEN_STDIO_LAUNCHER", previous_disabled)
    end)

    try do
      File.mkdir_p!(test_root)
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      if windows?() do
        launcher = Path.join(test_root, "codex-hidden-stdio-launcher.exe")
        File.write!(launcher, "")

        System.put_env("CODEX_HIDDEN_STDIO_LAUNCHER", launcher)
        System.delete_env("SYMPHONY_DISABLE_CODEX_HIDDEN_STDIO_LAUNCHER")

        assert {:ok, wrapped_executable, wrapped_args} =
                 AppServer.local_port_spawn_command_for_test(
                   "C:/tools/codex.exe",
                   ["app-server", "--listen", "stdio://"],
                   workspace
                 )

        assert wrapped_executable == Path.expand(launcher)

        assert wrapped_args == [
                 "--cwd",
                 workspace,
                 "--",
                 "C:/tools/codex.exe",
                 "app-server",
                 "--listen",
                 "stdio://"
               ]

        System.put_env("SYMPHONY_DISABLE_CODEX_HIDDEN_STDIO_LAUNCHER", "true")

        assert {:ok, "C:/tools/codex.exe", ["app-server"]} =
                 AppServer.local_port_spawn_command_for_test(
                   "C:/tools/codex.exe",
                   ["app-server"],
                   workspace
                 )
      else
        assert {:ok, "/usr/bin/codex", ["app-server"]} =
                 AppServer.local_port_spawn_command_for_test(
                   "/usr/bin/codex",
                   ["app-server"],
                   workspace
                 )
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "app server marks request-for-input events as a hard failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-input-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-input.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-input.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/input_required\",\"id\":\"resp-1\",\"params\":{\"requiresInput\":true,\"reason\":\"blocked\"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: String.replace(workspace_root, "\\", "/"),
        codex_command: "#{String.replace(codex_binary, "\\", "/")} app-server"
      )

      issue = %Issue{
        id: "issue-input",
        identifier: "MT-88",
        title: "Input needed",
        description: "Cannot satisfy codex input",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs input", issue)

      assert payload["method"] == "turn/input_required"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server treats MCP elicitation requests as hard input blockers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-mcp-elicitation-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-188")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-188"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-188"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"mcpServer/elicitation/request","params":{"message":"Need operator input"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-mcp-elicitation",
        identifier: "MT-188",
        title: "MCP elicitation",
        description: "Cannot satisfy MCP input",
        state: "In Progress",
        url: "https://example.org/issues/MT-188",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs MCP input", issue)

      assert payload["method"] == "mcpServer/elicitation/request"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks MCP tool approval elicitations under never policy" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-mcp-tool-elicitation-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-189")
      trace_file = Path.join(test_root, "codex-mcp-tool-elicitation.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)
      codex_command = write_mcp_tool_approval_elicitation_codex!(test_root, trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: String.replace(workspace_root, "\\", "/"),
        codex_command: codex_command,
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-mcp-tool-elicitation",
        identifier: "MT-189",
        title: "MCP tool approval elicitation",
        description: "Ensure app tool approval elicitations fail closed",
        state: "In Progress",
        url: "https://example.org/issues/MT-189",
        labels: ["backend"]
      }

      assert {:error, {:approval_required, payload}} =
               AppServer.run(workspace, "Handle MCP tool approval elicitation", issue)

      assert payload["method"] == "mcpServer/elicitation/request"

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      refute Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") and String.contains?(line, ~s("id":120)) do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 120 and
                   get_in(payload, ["result", "action"]) == "accept" and
                   get_in(payload, ["result", "content"]) == %{}
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks MCP tool approval elicitations that request form content" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-mcp-tool-elicitation-content-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-190")
      File.mkdir_p!(workspace)
      codex_command = write_mcp_tool_content_elicitation_codex!(test_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: String.replace(workspace_root, "\\", "/"),
        codex_command: codex_command,
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-mcp-tool-elicitation-content",
        identifier: "MT-190",
        title: "MCP tool approval content elicitation",
        description: "Ensure approval elicitations requesting form content fail closed",
        state: "In Progress",
        url: "https://example.org/issues/MT-190",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Handle MCP tool approval content elicitation", issue)

      assert payload["method"] == "mcpServer/elicitation/request"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server fails when command execution approval is required under safer defaults" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-approval-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-89"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-89"}}}'
            printf '%s\\n' '{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"gh pr view","cwd":"/tmp","reason":"need approval"}}'
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-approval-required",
        identifier: "MT-89",
        title: "Approval required",
        description: "Ensure safer defaults do not auto approve requests",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:error, {:approval_required, payload}} =
               AppServer.run(workspace, "Handle approval request", issue)

      assert payload["method"] == "item/commandExecution/requestApproval"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server denies and terminates unexpected command approval requests when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-89\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-89\"}}}'
            printf '%s\\n' '{\"id\":99,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"command\":\"gh pr view\",\"cwd\":\"/tmp\",\"reason\":\"need approval\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: String.replace(workspace_root, "\\", "/"),
        codex_command: "#{String.replace(codex_binary, "\\", "/")} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-auto-approve",
        identifier: "MT-89",
        title: "Auto approve request",
        description: "Ensure unattended app-server approval requests fail closed",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:error, {:approval_required, payload}} =
               AppServer.run(workspace, "Handle approval request", issue)

      assert payload["method"] == "item/commandExecution/requestApproval"

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 1 and
                   get_in(payload, ["params", "capabilities", "experimentalApi"]) == true
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 2 and linear_graphql_tool_present?(get_in(payload, ["params", "dynamicTools"]))
               else
                 false
               end
             end)

      refute Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 99
               else
                 false
               end
             end)

      refute trace =~ "acceptForSession"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server fails closed on file change approval requests when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-file-change-approval-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89-file-change")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-file-change-approval.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-file-change-approval.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-file-change"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-file-change"}}}'
            printf '%s\\n' '{"id":100,"method":"item/fileChange/requestApproval","params":{"reason":"need approval"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: String.replace(workspace_root, "\\", "/"),
        codex_command: "#{String.replace(codex_binary, "\\", "/")} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-file-change-approval",
        identifier: "MT-89",
        title: "File change approval",
        description: "Ensure unattended file change approvals fail closed",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:error, {:approval_required, payload}} =
               AppServer.run(workspace, "Handle file change approval request", issue)

      assert payload["method"] == "item/fileChange/requestApproval"
      trace = File.read!(trace_file)

      refute trace
             |> String.split("\n", trim: true)
             |> Enum.any?(fn line ->
               String.starts_with?(line, "JSON:") and
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> Map.get("id") == 100
             end)

      refute trace =~ "acceptForSession"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server times out idle command executions with the stall timeout" do
    test_root =
      Path.join(
        Path.join(File.cwd!(), "tmp"),
        "symphony-elixir-app-server-command-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90")
      File.mkdir_p!(workspace)

      codex_command =
        case :os.type() do
          {:win32, _} ->
            fake_script = Path.join(test_root, "fake-codex-timeout.cmd")
            cmd = System.find_executable("cmd.exe") || "cmd.exe"

            File.write!(fake_script, """
            @echo off
            set COUNT=0
            :loop
            set LINE=
            set /p LINE=
            if errorlevel 1 goto end
            set /a COUNT+=1
            if "%COUNT%"=="1" echo {"id":1,"result":{}}
            if "%COUNT%"=="3" echo {"id":2,"result":{"thread":{"id":"thread-command-timeout"}}}
            if "%COUNT%"=="4" echo {"id":3,"result":{"turn":{"id":"turn-command-timeout"}}}
            if "%COUNT%"=="4" echo {"method":"item/started","params":{"item":{"id":"call-hung","type":"commandExecution","command":"git --version","cwd":"C:/tmp"}}}
            goto loop
            :end
            """)

            "#{String.replace(cmd, "\\", "/")} /c #{String.replace(fake_script, "\\", "/")} app-server"

          _ ->
            codex_binary = Path.join(test_root, "fake-codex")

            File.write!(codex_binary, """
            #!/bin/sh
            count=0
            while IFS= read -r _line; do
              count=$((count + 1))

              case "$count" in
                1)
                  printf '%s\\n' '{"id":1,"result":{}}'
                  ;;
                2)
                  ;;
                3)
                  printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-command-timeout"}}}'
                  ;;
                4)
                  printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-command-timeout"}}}'
                  printf '%s\\n' '{"method":"item/started","params":{"item":{"id":"call-hung","type":"commandExecution","command":"git --version","cwd":"/tmp"}}}'
                  ;;
                *)
                  sleep 1
                  ;;
              esac
            done
            """)

            File.chmod!(codex_binary, 0o755)
            "#{codex_binary} app-server"
        end

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: String.replace(workspace_root, "\\", "/"),
        codex_command: codex_command,
        codex_turn_timeout_ms: 60_000,
        codex_stall_timeout_ms: 25
      )

      issue = %Issue{
        id: "issue-command-timeout",
        identifier: "MT-90",
        title: "Command timeout",
        description: "Ensure command execution silence fails before the turn timeout",
        state: "In Progress",
        url: "https://example.org/issues/MT-90",
        labels: ["backend"]
      }

      assert {:error, {:command_execution_timeout, 25}} =
               AppServer.run(workspace, "Run a command that never completes", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server restores turn timeout after command completion" do
    test_root =
      Path.join(
        Path.join(File.cwd!(), "tmp"),
        "symphony-elixir-app-server-command-complete-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-91")
      File.mkdir_p!(workspace)

      codex_command =
        case :os.type() do
          {:win32, _} ->
            fake_script = Path.join(test_root, "fake-codex-command-complete.cmd")
            cmd = System.find_executable("cmd.exe") || "cmd.exe"

            File.write!(fake_script, """
            @echo off
            set COUNT=0
            :loop
            set LINE=
            set /p LINE=
            if errorlevel 1 goto end
            set /a COUNT+=1
            if "%COUNT%"=="1" echo {"id":1,"result":{}}
            if "%COUNT%"=="3" echo {"id":2,"result":{"thread":{"id":"thread-command-complete"}}}
            if "%COUNT%"=="4" echo {"id":3,"result":{"turn":{"id":"turn-command-complete"}}}
            if "%COUNT%"=="4" echo {"method":"item/started","params":{"item":{"id":"call-finished","type":"commandExecution","command":"git --version","cwd":"C:/tmp"}}}
            if "%COUNT%"=="4" echo {"method":"item/completed","params":{"item":{"id":"call-finished","type":"commandExecution"}}}
            goto loop
            :end
            """)

            "#{String.replace(cmd, "\\", "/")} /c #{String.replace(fake_script, "\\", "/")} app-server"

          _ ->
            codex_binary = Path.join(test_root, "fake-codex")

            File.write!(codex_binary, """
            #!/bin/sh
            count=0
            while IFS= read -r _line; do
              count=$((count + 1))

              case "$count" in
                1)
                  printf '%s\\n' '{"id":1,"result":{}}'
                  ;;
                2)
                  ;;
                3)
                  printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-command-complete"}}}'
                  ;;
                4)
                  printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-command-complete"}}}'
                  printf '%s\\n' '{"method":"item/started","params":{"item":{"id":"call-finished","type":"commandExecution","command":"git --version","cwd":"/tmp"}}}'
                  printf '%s\\n' '{"method":"item/completed","params":{"item":{"id":"call-finished","type":"commandExecution"}}}'
                  ;;
                *)
                  sleep 1
                  ;;
              esac
            done
            """)

            File.chmod!(codex_binary, 0o755)
            "#{codex_binary} app-server"
        end

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: String.replace(workspace_root, "\\", "/"),
        codex_command: codex_command,
        codex_turn_timeout_ms: 80,
        codex_stall_timeout_ms: 25
      )

      issue = %Issue{
        id: "issue-command-complete-timeout",
        identifier: "MT-91",
        title: "Command complete timeout",
        description: "Ensure completed commands restore normal turn timeout",
        state: "In Progress",
        url: "https://example.org/issues/MT-91",
        labels: ["backend"]
      }

      assert {:error, :turn_timeout} =
               AppServer.run(workspace, "Run a command that completes, then think silently", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks product coordination checkout command executions" do
    unsafe_payload = %{
      "params" => %{
        "item" => %{
          "type" => "commandExecution",
          "id" => "call-block",
          "command" => "powershell.exe -Command Get-Content -Path C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\development\\one\\SECURITY.md",
          "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90",
          "commandActions" => [
            %{
              "type" => "unknown",
              "command" => "Get-Content -Path C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\development\\one\\SECURITY.md"
            }
          ]
        }
      }
    }

    safe_payload = %{
      "params" => %{
        "item" => %{
          "type" => "commandExecution",
          "id" => "call-safe",
          "command" => "cmd.exe /d /c type C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\one\\MAN-90\\SECURITY.md"
        }
      }
    }

    skill_payload = %{
      "params" => %{
        "item" => %{
          "type" => "commandExecution",
          "id" => "call-skill",
          "command" => "Get-Content -Path C:\\Users\\jclen\\.codex\\plugins\\cache\\manafuel-local\\manafuel-codex\\skills\\documenter\\SKILL.md"
        }
      }
    }

    unsafe_bob_payload = %{
      "params" => %{
        "item" => %{
          "type" => "commandExecution",
          "id" => "call-bob",
          "command" => "Get-Content C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\development\\bob\\README.md"
        }
      }
    }

    unsafe_discord_payload = %{
      "params" => %{
        "item" => %{
          "type" => "commandExecution",
          "id" => "call-discord",
          "command" => "Get-Content C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\development\\tools\\discord-iac\\README.md"
        }
      }
    }

    unsafe_top_level_cwd_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "Get-Content SECURITY.md",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\development\\one"
      }
    }

    unsafe_relative_cases = [
      {"one", "Get-Content one/SECURITY.md"},
      {"replicator", "Get-Content replicator/README.md"},
      {"bob", "Get-Content bob/README.md"},
      {"discord-iac", "Get-Content tools/discord-iac/README.md"}
    ]

    unsafe_plugin_relative_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "Get-Content skills/documenter/SKILL.md",
        "cwd" => "C:\\Users\\jclen\\.codex\\plugins\\cache\\manafuel-local\\manafuel-codex\\0.1.0+codex.20260629184500"
      }
    }

    unsafe_plugin_intermediate_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "Get-Content documenter/SKILL.md",
        "cwd" => "C:\\Users\\jclen\\.codex\\plugins\\cache\\manafuel-local\\manafuel-codex\\0.1.0+codex.20260629184500\\skills"
      }
    }

    unsafe_discord_intermediate_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "Get-Content discord-iac/README.md",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\development\\tools"
      }
    }

    unrelated_tool_payload = %{
      "method" => "item/tool/call",
      "params" => %{
        "command" => "Get-Content C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\development\\one\\SECURITY.md"
      }
    }

    unsafe_generation_payload = %{
      "params" => %{
        "item" => %{
          "type" => "commandExecution",
          "id" => "call-new-item",
          "command" => "New-Item -ItemType Directory -Force \"C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\development\\.codex\\runs\\2026-07-04-man-90-security-contact\"",
          "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90",
          "commandActions" => [
            %{
              "type" => "unknown",
              "command" => "New-Item -ItemType Directory -Force \"C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\development\\.codex\\runs\\2026-07-04-man-90-security-contact\""
            }
          ]
        }
      }
    }

    unsafe_set_content_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "powershell.exe -NoProfile -Command Set-Content out.txt 'generated'",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_wrapped_generation_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command New-Item -ItemType Directory -Force .codex\\runs\\man-90",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_script_block_generation_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "powershell.exe -NoProfile -Command \"if (!(Test-Path $p)) { New-Item -ItemType Directory -Path $p }\"",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_unwrapped_script_block_generation_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "if (!(Test-Path $p)) { New-Item -ItemType Directory -Path $p }",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_pwsh_short_generation_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "pwsh -c New-Item -ItemType Directory -Path .codex\\runs\\man-90",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_alias_generation_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "mkdir .codex\\runs\\man-90",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_cmd_wrapped_generation_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "cmd /c powershell.exe -NoProfile -Command \"if (!(Test-Path $p)) { New-Item -ItemType Directory -Path $p }\"",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_redirection_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "Get-Process > .codex\\runs\\man-90\\processes.txt",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_quoted_powershell_redirection_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "powershell.exe -NoProfile -Command \"Get-Process > .codex\\runs\\man-90\\processes.txt\"",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_numbered_stdout_redirection_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "Get-Process 1> .codex\\runs\\man-90\\processes.txt",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_numbered_stderr_redirection_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "Get-Process 2> .codex\\runs\\man-90\\errors.txt",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_numbered_append_redirection_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "Get-Process 2>> .codex\\runs\\man-90\\errors.txt",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    safe_quoted_comparison_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "Select-String -Path README.md -Pattern 'x > y'",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    safe_rg_generation_search_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "rg \"New-Item|Set-Content\" .",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    safe_select_string_generation_search_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "Select-String -Path README.md -Pattern New-Item",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    safe_wrapped_quoted_comparison_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "powershell.exe -NoProfile -Command \"Select-String -Path README.md -Pattern 'x > y'\"",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_direct_powershell_read_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "Get-ChildItem -Name C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\one",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_piped_powershell_read_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "git status --short | Select-Object -First 1",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_wrapped_powershell_read_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "powershell.exe -NoProfile -Command Get-ChildItem -Name .",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    safe_native_directory_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "cmd.exe /d /c dir /b C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\one",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_scratch_rg_files_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "rg --files",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_scratch_git_worktree_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "git worktree list",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_scratch_git_status_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "git status --short --branch",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_scratch_subdir_git_status_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "git status --short --branch",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90\\nested"
      }
    }

    unsafe_wrapped_scratch_git_status_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "cmd.exe /d /c git status --short --branch",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_ampersand_scratch_git_worktree_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "& git worktree list",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_wrapped_scratch_rg_files_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "powershell.exe -NoProfile -Command \"rg --files\"",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
      }
    }

    unsafe_global_product_rg_files_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "rg --files",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\one\\MAN-90"
      }
    }

    unsafe_inline_ticket_text_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" =>
          ".\\scripts\\codex-kanban-dry-run.ps1 --mode strict --ticket-text '{\"id\":\"MAN-90\",\"state\":\"Ready for Codex\",\"labels\":[\"codex-agent-ready\"]}' --evidence-output C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\development\\.codex\\runs\\MAN-90\\kanban-dry-run.md --json",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\development\\.codex"
      }
    }

    safe_ticket_file_script_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => ".\\scripts\\codex-kanban-dry-run.ps1 --mode strict --ticket-file C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90\\ticket.json --json",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\development\\.codex"
      }
    }

    unsafe_single_quoted_powershell_commands = [
      "powershell.exe -NoProfile -Command 'New-Item -ItemType Directory .codex\\runs\\man-90'",
      "pwsh -c 'Set-Content out.txt generated'",
      "powershell.exe -Command 'Out-File out.txt'",
      "powershell.exe -Command 'Add-Content out.txt generated'",
      "powershell.exe -Command 'mkdir .codex\\runs\\man-90'",
      "powershell.exe -Command 'Get-Process 2>> .codex\\runs\\man-90\\errors.txt'"
    ]

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_payload) =~
             "coordination-checkout"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_bob_payload) =~
             "coordination-checkout"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_discord_payload) =~
             "coordination-checkout"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_top_level_cwd_payload) =~
             "coordination-checkout"

    Enum.each(unsafe_relative_cases, fn {_name, command} ->
      payload = %{
        "method" => "item/commandExecution/requestApproval",
        "params" => %{
          "command" => command,
          "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\development"
        }
      }

      assert AppServer.unsafe_command_block_reason_for_test(payload) =~
               "coordination-checkout"
    end)

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_plugin_relative_payload) =~
             "packaged skill file"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_plugin_intermediate_payload) =~
             "packaged skill file"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_discord_intermediate_payload) =~
             "coordination-checkout"

    assert is_nil(AppServer.unsafe_command_block_reason_for_test(safe_payload))
    assert is_nil(AppServer.unsafe_command_block_reason_for_test(unrelated_tool_payload))

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_generation_payload) =~
             "filesystem-generation"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_set_content_payload) =~
             "filesystem-generation"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_wrapped_generation_payload) =~
             "filesystem-generation"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_script_block_generation_payload) =~
             "filesystem-generation"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_unwrapped_script_block_generation_payload) =~
             "filesystem-generation"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_pwsh_short_generation_payload) =~
             "filesystem-generation"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_alias_generation_payload) =~
             "filesystem-generation"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_cmd_wrapped_generation_payload) =~
             "filesystem-generation"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_redirection_payload) =~
             "filesystem-generation"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_quoted_powershell_redirection_payload) =~
             "filesystem-generation"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_numbered_stdout_redirection_payload) =~
             "filesystem-generation"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_numbered_stderr_redirection_payload) =~
             "filesystem-generation"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_numbered_append_redirection_payload) =~
             "filesystem-generation"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_direct_powershell_read_payload) =~
             "direct PowerShell cmdlet"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_piped_powershell_read_payload) =~
             "direct PowerShell cmdlet"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_wrapped_powershell_read_payload) =~
             "direct PowerShell cmdlet"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_inline_ticket_text_payload) =~
             "inline structured payload"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_scratch_rg_files_payload) =~
             "scratch Symphony workspace"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_scratch_git_worktree_payload) =~
             "scratch Symphony workspace"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_scratch_git_status_payload) =~
             "scratch Symphony workspace"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_scratch_subdir_git_status_payload) =~
             "scratch Symphony workspace"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_wrapped_scratch_git_status_payload) =~
             "scratch Symphony workspace"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_ampersand_scratch_git_worktree_payload) =~
             "scratch Symphony workspace"

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_wrapped_scratch_rg_files_payload) =~
             "scratch Symphony workspace"

    assert is_nil(AppServer.unsafe_command_block_reason_for_test(safe_quoted_comparison_payload))
    assert is_nil(AppServer.unsafe_command_block_reason_for_test(safe_rg_generation_search_payload))
    assert is_nil(AppServer.unsafe_command_block_reason_for_test(safe_select_string_generation_search_payload))
    assert is_nil(AppServer.unsafe_command_block_reason_for_test(safe_wrapped_quoted_comparison_payload))
    assert is_nil(AppServer.unsafe_command_block_reason_for_test(safe_native_directory_payload))
    assert is_nil(AppServer.unsafe_command_block_reason_for_test(safe_ticket_file_script_payload))

    assert AppServer.unsafe_command_block_reason_for_test(unsafe_global_product_rg_files_payload) =~
             "issue-local normal clone"

    poller_payload = %{
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "command" => "scripts/codex-kanban-linear-poll.ps1 --mode strict --json",
        "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\development\\.codex"
      }
    }

    assert AppServer.unsafe_command_block_reason_for_test(poller_payload) =~
             "legacy kanban poller"

    Enum.each(unsafe_single_quoted_powershell_commands, fn command ->
      payload = %{
        "method" => "item/commandExecution/requestApproval",
        "params" => %{
          "command" => command,
          "cwd" => "C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\symphony\\MAN-90"
        }
      }

      assert AppServer.unsafe_command_block_reason_for_test(payload) =~
               "filesystem-generation"
    end)

    assert AppServer.unsafe_command_block_reason_for_test(skill_payload) =~
             "packaged skill file"
  end

  test "app server bounds repository discovery to the current issue normal product clone" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-repository-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MAN-146")
      clone = Path.join([workspace, "products", "one"])
      clone_subdir = Path.join(clone, "src")
      linked_worktree = Path.join([workspace, "products", "replicator"])
      fake_clone = Path.join([workspace, "products", "bob"])
      unknown_clone = Path.join([workspace, "products", "marketing"])
      other_issue_clone = Path.join([workspace_root, "MAN-147", "products", "one"])
      global_worktree = Path.join([test_root, "worktrees", "one", "MAN-146"])
      coordination_checkout = Path.join([test_root, "development-production-main", "one"])
      path_lookalike = Path.join([workspace, "nested", "products", "development"])

      init_git_repo!(clone)
      File.mkdir_p!(clone_subdir)
      File.mkdir_p!(Path.join(fake_clone, ".git"))
      init_git_repo!(unknown_clone)
      init_git_repo!(other_issue_clone)
      init_git_repo!(global_worktree)
      init_git_repo!(coordination_checkout)
      init_git_repo!(path_lookalike)

      assert {_output, 0} =
               System.cmd(
                 git_executable!(),
                 ["-C", clone, "worktree", "add", "--quiet", "--detach", linked_worktree, "HEAD"],
                 stderr_to_stdout: true
               )

      payload = fn command, cwd ->
        %{
          "method" => "item/commandExecution/requestApproval",
          "params" => %{"command" => command, "cwd" => cwd}
        }
      end

      wrapped_status_payload = %{
        "params" => %{
          "item" => %{
            "type" => "commandExecution",
            "command" => "\"C:\\WINDOWS\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" -Command 'git status --short --branch'",
            "cwd" => clone,
            "commandActions" => [
              %{"type" => "unknown", "command" => "git status --short --branch"}
            ]
          }
        }
      }

      wrapped_issue_local_scoped_status_payload = %{
        "params" => %{
          "item" => %{
            "type" => "commandExecution",
            "command" => "\"C:\\WINDOWS\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" -NoProfile -Command 'git -C products/one status --short --branch'",
            "cwd" => workspace,
            "commandActions" => [
              %{
                "type" => "unknown",
                "command" => "git -C products/one status --short --branch"
              }
            ]
          }
        }
      }

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.("git status --short --branch", clone),
                 workspace
               )
             )

      assert is_nil(AppServer.unsafe_command_block_reason_for_test(wrapped_status_payload, workspace))

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.("git -C products/one status --short --branch", workspace),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.(~s(git "-C" "products/one" status --short --branch), workspace),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.("git --no-pager -C products/one status --short --branch", workspace),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 wrapped_issue_local_scoped_status_payload,
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.("git status --short --branch", clone_subdir),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.("rg --files", clone_subdir),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.("rg --files -g '*.ex'", clone_subdir),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.("rg --files --glob '*.ex'", clone),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.("rg -g '*.ex' --files", clone_subdir),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.("git --no-pager status --short --branch", clone),
                 workspace
               )
             )

      blocked_cases = [
        payload.("git status --short --branch", workspace),
        payload.("git -C . worktree list", workspace),
        payload.("git --no-pager worktree list", workspace),
        payload.("rg -g '*.ex' --files", workspace),
        payload.("cmd.exe /d /c git --no-pager worktree list", workspace),
        payload.("powershell.exe -NoProfile -Command \"rg -g '*.ex' --files\"", workspace),
        payload.("git status --short --branch", Path.join(workspace, "runs")),
        payload.("git status --short --branch", fake_clone),
        payload.("git status --short --branch", unknown_clone),
        payload.("git status --short --branch", other_issue_clone),
        payload.("git status --short --branch", global_worktree),
        payload.("git status --short --branch", coordination_checkout),
        payload.("git status --short --branch", path_lookalike),
        payload.("git status --short --branch", linked_worktree),
        payload.("git status --short --branch", Path.join([clone, "..", "one"])),
        payload.("git -C .. status --short --branch", clone),
        payload.("git -C products/one/src status --short --branch", workspace),
        payload.("git -C products/bob status --short --branch", workspace),
        payload.("git -C products/marketing status --short --branch", workspace),
        payload.("git -C #{clone} status --short --branch", workspace),
        payload.("git -C products/one -c core.worktree=#{other_issue_clone} status", workspace),
        payload.("git -C products/one --git-dir=#{Path.join(other_issue_clone, ".git")} status", workspace),
        payload.("git -C products/one status --work-tree=#{other_issue_clone}", workspace),
        payload.("git --namespace=escape -C products/one status", workspace),
        payload.("git -C products/one worktree list", workspace),
        payload.("git -C#{other_issue_clone} status --short --branch", clone),
        payload.("git --git-dir=../.git status --short --branch", clone),
        payload.("git --work-tree=#{other_issue_clone} status --short --branch", clone),
        payload.("$env:GIT_DIR='#{Path.join(other_issue_clone, ".git")}'; git status --short --branch", clone),
        payload.("rg --files ..", clone),
        payload.("rg --files -g '*.ex' #{other_issue_clone}", clone),
        payload.("rg --files #{other_issue_clone}", clone),
        payload.("git worktree list", clone)
      ]

      Enum.each(blocked_cases, fn blocked_payload ->
        assert is_binary(AppServer.unsafe_command_block_reason_for_test(blocked_payload, workspace))
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server normalizes quoted repository-discovery argv before enforcing clone scope" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-quoted-repository-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join([test_root, "workspaces", "MAN-263"])
      clone = Path.join([workspace, "products", "one"])
      outside_repo = Path.join([test_root, "outside", "one"])

      init_git_repo!(clone)
      init_git_repo!(outside_repo)

      payload = fn command, cwd ->
        %{
          "method" => "item/commandExecution/requestApproval",
          "params" => %{"command" => command, "cwd" => cwd}
        }
      end

      cmd_switch_cases =
        for switch <- [
              "/A",
              "/U",
              "/Q",
              "/D",
              "/S",
              "/X",
              "/Y",
              "/E:ON",
              "/E:OFF",
              "/F:ON",
              "/F:OFF",
              "/V:ON",
              "/V:OFF",
              "/T:0A"
            ] do
          {
            "cmd switch #{switch}",
            payload.(~s(CMD.EXE #{switch} /C g^it -^C "#{outside_repo}" status --short), clone)
          }
        end

      quoted_cases = [
        {"quoted git -C", payload.(~s(git "-C" "#{outside_repo}" status --short), clone)},
        {"quoted git-dir", payload.(~s(git "--git-dir" "#{Path.join(outside_repo, ".git")}" status --short), clone)},
        {"quoted worktree list", payload.(~s(git "worktree" "list"), clone)},
        {"quoted rg files", payload.(~s(rg "--files"), workspace)},
        {"PowerShell-wrapped git -C", payload.(~s(powershell.exe -NoProfile -Command 'git "-C" "#{outside_repo}" status --short'), clone)},
        {"PowerShell call-operator git -C", payload.(~s(powershell.exe -NoProfile -Command '& git "-C" "#{outside_repo}" status --short'), clone)},
        {"PowerShell quoted command flag git -C", payload.(~s(powershell.exe -NoProfile "-Command" '& git "-C" "#{outside_repo}" status --short'), clone)},
        {"PowerShell nested git -C", payload.(~s|powershell.exe -NoProfile -Command 'Write-Output $(git "-C" "#{outside_repo}" status --short)'|, clone)},
        {"PowerShell call-operator rg files", payload.(~s(powershell.exe -NoProfile -Command '& rg "--files"'), workspace)},
        {"cmd-wrapped git-dir", payload.(~s(cmd.exe /d /c git "--git-dir" "#{Path.join(outside_repo, ".git")}" status --short), clone)},
        {"cmd multi-switch git-dir", payload.(~s(cmd.exe /s /d /c git "--git-dir" "#{Path.join(outside_repo, ".git")}" status --short), clone)},
        {"cmd quoted command flag git-dir", payload.(~s(cmd.exe /s /d "/c" git "--git-dir" "#{Path.join(outside_repo, ".git")}" status --short), clone)},
        {"direct rg path before files", payload.(~s(rg #{outside_repo} --files), clone)},
        {"quoted rg path before files", payload.(~s(rg "#{outside_repo}" "--files"), clone)},
        {"PowerShell-wrapped rg path before files", payload.(~s(powershell.exe -NoProfile -Command 'rg "#{outside_repo}" "--files"'), clone)},
        {"rg path between valued option and files", payload.(~s(rg --type elixir "#{outside_repo}" --files), clone)},
        {"rg path after end-of-options", payload.(~s(rg --files -- "#{outside_repo}"), clone)},
        {"cmd caret-escaped git executable", payload.(~s(cmd.exe /s /d /c g^it -C "#{outside_repo}" status --short), clone)},
        {"cmd caret-escaped git scope option", payload.(~s(cmd.exe /s /d /c git -^C "#{outside_repo}" status --short), clone)},
        {"cmd caret-escaped git scope override", payload.(~s(cmd.exe /s /d /c g^it -^C "#{outside_repo}" status --short), clone)},
        {"cmd extension switch caret-escaped scope override", payload.(~s(cmd.exe /e:on /d /c g^it -^C "#{outside_repo}" status --short), clone)},
        {"uppercase cmd extension and compatibility marker scope override", payload.(~s(CMD.EXE /E:ON /R g^it -^C "#{outside_repo}" status --short), clone)},
        {"cmd valued switches unescaped scope override", payload.(~s(cmd.exe /f:on /v:off /t:0a /d /c git -C "#{outside_repo}" status --short), clone)},
        {"cmd ignored switch caret-escaped scope override", payload.(~s(cmd.exe /z /d /c g^it -^C "#{outside_repo}" status --short), clone)},
        {"cmd keep-open marker scope override", payload.(~s(cmd.exe /d /k g^it -^C "#{outside_repo}" status --short), clone)},
        {"cmd compatibility marker scope override", payload.(~s(cmd.exe /d /r g^it -^C "#{outside_repo}" status --short), clone)},
        {"cmd attached marker scope override", payload.(~s(cmd.exe /d /cg^it -^C "#{outside_repo}" status --short), clone)},
        {"cmd quote-attached marker scope override", payload.(~s(cmd.exe /d /c"g^it -^C #{outside_repo} status --short"), clone)},
        {"cmd quoted marker caret-escaped git scope override", payload.(~s(cmd.exe /s /d "/c" g^it -^C "#{outside_repo}" status --short), clone)},
        {"cmd quoted command caret-escaped git scope override", payload.(~s(cmd.exe /s /d /c "g^it -^C #{outside_repo} status --short"), clone)},
        {"PowerShell-wrapped worktree list", payload.(~s(powershell.exe -NoProfile -Command 'git "worktree" "list"'), clone)},
        {"cmd-wrapped rg files", payload.(~s(cmd.exe /d /c rg "--files"), workspace)},
        {"compound quoted git -C", payload.(~s(echo "checking"; git "-C" "#{outside_repo}" status --short), clone)},
        {"git config-env worktree override", payload.(~s($env:MF_SCOPE='#{outside_repo}'; git --config-env=core.worktree=MF_SCOPE status --short), clone)}
      ]

      quoted_cases = quoted_cases ++ cmd_switch_cases

      bypasses =
        for {name, quoted_payload} <- quoted_cases,
            not is_binary(AppServer.unsafe_command_block_reason_for_test(quoted_payload, workspace)),
            do: name

      assert bypasses == [], "repository guard bypasses: #{Enum.join(bypasses, ", ")}"

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.(~s(rg -n 'git "worktree" "list"' README.md), clone),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.(~s(rg -n "git worktree list" README.md), clone),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.(~s(echo "git worktree list"), clone),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.(~s|powershell.exe -NoProfile -Command "Write-Output '$(git worktree list)'"|, clone),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.(~s|powershell.exe -NoProfile -Command "Write-Output 'g^it -^C #{outside_repo} status'"|, clone),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.(~s(cmd.exe /s /d /c echo "g^it -^C #{outside_repo} status"), clone),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.(~s(cmd.exe /s /d /c echo safe ^& g^it -^C), clone),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.(~s(echo "cmd.exe /s /d /c g^it -^C .. status"), clone),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.(~s(rg -e "--files" README.md), clone),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.(~s(rg --files --type elixir), clone),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.(~s(rg --type elixir --files), clone),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.(~s(rg -- --files), clone),
                 workspace
               )
             )

      assert is_nil(
               AppServer.unsafe_command_block_reason_for_test(
                 payload.(~s(git log --grep "status" --oneline), clone),
                 workspace
               )
             )
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks unsafe top-level cwd approval before auto approval" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-unsafe-cwd-approval-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MAN-90")
      trace_file = Path.join(test_root, "codex-unsafe-cwd-approval.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      codex_command =
        case :os.type() do
          {:win32, _} ->
            fake_script = Path.join(test_root, "fake-codex.cmd")
            cmd = System.find_executable("cmd.exe") || "cmd.exe"

            File.write!(fake_script, """
            @echo off
            set TRACE=%SYMP_TEST_CODEx_TRACE%
            if "%TRACE%"=="" set TRACE=#{String.replace(trace_file, "\\", "/")}
            set COUNT=0
            :loop
            set LINE=
            set /p LINE=
            if errorlevel 1 goto end
            set /a COUNT+=1
            >> "%TRACE%" echo JSON:%LINE%
            if "%COUNT%"=="1" echo {"id":1,"result":{}}
            if "%COUNT%"=="3" echo {"id":2,"result":{"thread":{"id":"thread-unsafe-cwd"}}}
            if "%COUNT%"=="4" echo {"id":3,"result":{"turn":{"id":"turn-unsafe-cwd"}}}
            if "%COUNT%"=="4" echo {"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"Get-Content one/SECURITY.md","cwd":"C:/Users/jclen/OneDrive/Documents/apps/manafuel/development","reason":"need approval"}}
            goto loop
            :end
            """)

            "#{String.replace(cmd, "\\", "/")} /c #{String.replace(fake_script, "\\", "/")} app-server"

          _ ->
            codex_binary = Path.join(test_root, "fake-codex")

            File.write!(codex_binary, """
            #!/bin/sh
            trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-unsafe-cwd-approval.trace}"
            count=0
            while IFS= read -r line; do
              count=$((count + 1))
              printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

              case \"$count\" in
                1)
                  printf '%s\\n' '{\"id\":1,\"result\":{}}'
                  ;;
                2)
                  ;;
                3)
                  printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-unsafe-cwd\"}}}'
                  ;;
                4)
                  printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-unsafe-cwd\"}}}'
                  printf '%s\\n' '{\"id\":99,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"command\":\"Get-Content one/SECURITY.md\",\"cwd\":\"C:/Users/jclen/OneDrive/Documents/apps/manafuel/development\",\"reason\":\"need approval\"}}'
                  ;;
                *)
                  sleep 1
                  ;;
              esac
            done
            """)

            File.chmod!(codex_binary, 0o755)
            "#{codex_binary} app-server"
        end

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: String.replace(workspace_root, "\\", "/"),
        codex_command: codex_command,
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-unsafe-cwd-approval",
        identifier: "MAN-90",
        title: "Block unsafe cwd approval",
        description: "Ensure unsafe coordination-checkout cwd is never auto approved",
        state: "In Progress",
        url: "https://example.org/issues/MAN-90",
        labels: ["harness"]
      }

      assert {:error, {:unsafe_command_blocked, reason, payload}} =
               AppServer.run(workspace, "Handle unsafe approval request", issue)

      assert reason =~ "coordination-checkout"
      assert payload["method"] == "item/commandExecution/requestApproval"
      refute File.read!(trace_file) =~ "acceptForSession"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks unsafe started command before output deltas are delivered" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-unsafe-started-command-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MAN-90")
      trace_file = Path.join(test_root, "codex-unsafe-started-command.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      {:ok, event_log} = Agent.start_link(fn -> [] end)

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end

        if Process.alive?(event_log), do: Agent.stop(event_log)
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      codex_command =
        case :os.type() do
          {:win32, _} ->
            fake_script = Path.join(test_root, "fake-codex-started.cmd")
            cmd = System.find_executable("cmd.exe") || "cmd.exe"

            File.write!(fake_script, """
            @echo off
            set TRACE=%SYMP_TEST_CODEx_TRACE%
            if "%TRACE%"=="" set TRACE=#{String.replace(trace_file, "\\", "/")}
            set COUNT=0
            :loop
            set LINE=
            set /p LINE=
            if errorlevel 1 goto end
            set /a COUNT+=1
            >> "%TRACE%" echo JSON:%LINE%
            if "%COUNT%"=="1" echo {"id":1,"result":{}}
            if "%COUNT%"=="3" echo {"id":2,"result":{"thread":{"id":"thread-unsafe-started"}}}
            if "%COUNT%"=="4" echo {"id":3,"result":{"turn":{"id":"turn-unsafe-started"}}}
            if "%COUNT%"=="4" echo {"method":"item/started","params":{"item":{"type":"commandExecution","id":"call-leak","command":"Get-Content one/SECRET.txt","cwd":"C:/Users/jclen/OneDrive/Documents/apps/manafuel/development","commandActions":[{"type":"unknown","command":"Get-Content one/SECRET.txt"}]},"threadId":"thread-unsafe-started","turnId":"turn-unsafe-started"}}
            if "%COUNT%"=="4" echo {"method":"item/commandExecution/outputDelta","params":{"threadId":"thread-unsafe-started","turnId":"turn-unsafe-started","itemId":"call-leak","delta":"LEAKED_STALE_CONTENT"}}
            goto loop
            :end
            """)

            "#{String.replace(cmd, "\\", "/")} /c #{String.replace(fake_script, "\\", "/")} app-server"

          _ ->
            codex_binary = Path.join(test_root, "fake-codex-started")

            File.write!(codex_binary, """
            #!/bin/sh
            trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-unsafe-started-command.trace}"
            count=0
            while IFS= read -r line; do
              count=$((count + 1))
              printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

              case \"$count\" in
                1)
                  printf '%s\\n' '{\"id\":1,\"result\":{}}'
                  ;;
                3)
                  printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-unsafe-started\"}}}'
                  ;;
                4)
                  printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-unsafe-started\"}}}'
                  printf '%s\\n' '{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"commandExecution\",\"id\":\"call-leak\",\"command\":\"Get-Content one/SECRET.txt\",\"cwd\":\"C:/Users/jclen/OneDrive/Documents/apps/manafuel/development\",\"commandActions\":[{\"type\":\"unknown\",\"command\":\"Get-Content one/SECRET.txt\"}]},\"threadId\":\"thread-unsafe-started\",\"turnId\":\"turn-unsafe-started\"}}'
                  printf '%s\\n' '{\"method\":\"item/commandExecution/outputDelta\",\"params\":{\"threadId\":\"thread-unsafe-started\",\"turnId\":\"turn-unsafe-started\",\"itemId\":\"call-leak\",\"delta\":\"LEAKED_STALE_CONTENT\"}}'
                  ;;
                *)
                  sleep 1
                  ;;
              esac
            done
            """)

            File.chmod!(codex_binary, 0o755)
            "#{codex_binary} app-server"
        end

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: String.replace(workspace_root, "\\", "/"),
        codex_command: codex_command,
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-unsafe-started-command",
        identifier: "MAN-90",
        title: "Block unsafe started command",
        description: "Ensure unsafe command output is not delivered",
        state: "In Progress",
        url: "https://example.org/issues/MAN-90",
        labels: ["harness"]
      }

      on_message = fn message ->
        Agent.update(event_log, fn messages -> [message | messages] end)
      end

      assert {:error, {:unsafe_command_blocked, reason, payload}} =
               AppServer.run(workspace, "Handle unsafe started command", issue, on_message: on_message)

      assert reason =~ "coordination-checkout"
      assert get_in(payload, ["params", "item", "id"]) == "call-leak"

      delivered =
        event_log
        |> Agent.get(& &1)
        |> Enum.map(&inspect/1)
        |> Enum.join("\n")

      refute delivered =~ "LEAKED_STALE_CONTENT"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks MCP tool approval prompts when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-717")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-user-input-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-user-input-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-717\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-717\"}}}'
            printf '%s\\n' '{\"id\":110,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-717\",\"questions\":[{\"header\":\"Approve app tool call?\",\"id\":\"mcp_tool_call_approval_call-717\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Run the tool and continue.\",\"label\":\"Approve Once\"},{\"description\":\"Run the tool and remember this choice for this session.\",\"label\":\"Approve this Session\"},{\"description\":\"Decline this tool call and continue.\",\"label\":\"Deny\"},{\"description\":\"Cancel this tool call\",\"label\":\"Cancel\"}],\"question\":\"The linear MCP server wants to run the tool \\\"Save issue\\\", which may modify or delete data. Allow this action?\"}],\"threadId\":\"thread-717\",\"turnId\":\"turn-717\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-auto-approve",
        identifier: "MT-717",
        title: "Auto approve MCP tool request user input",
        description: "Ensure app tool approval prompts fail closed",
        state: "In Progress",
        url: "https://example.org/issues/MT-717",
        labels: ["backend"]
      }

      assert {:error, {:approval_required, payload}} =
               AppServer.run(workspace, "Handle tool approval prompt", issue)

      assert payload["method"] == "item/tool/requestUserInput"

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      refute Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 110 and
                   get_in(payload, ["result", "answers", "mcp_tool_call_approval_call-717", "answers"]) ==
                     ["Approve this Session"]
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server sends a generic non-interactive answer for freeform tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-718")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-718"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-718"}}}'
            printf '%s\\n' '{"id":111,"method":"item/tool/requestUserInput","params":{"itemId":"call-718","questions":[{"header":"Provide context","id":"freeform-718","isOther":false,"isSecret":false,"options":null,"question":"What comment should I post back to the issue?"}],"threadId":"thread-718","turnId":"turn-718"}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-required",
        identifier: "MT-718",
        title: "Non interactive tool input answer",
        description: "Ensure arbitrary tool prompts receive a generic answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-718",
        labels: ["backend"]
      }

      on_message = fn message -> send(self(), {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle generic tool input", issue, on_message: on_message)

      assert_received {:app_server_message,
                       %{
                         event: :tool_input_auto_answered,
                         answer: "This is a non-interactive session. Operator input is unavailable."
                       }}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server sends a generic non-interactive answer for option-based tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-options-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-719")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-user-input-options.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-user-input-options.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-719\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-719\"}}}'
            printf '%s\\n' '{\"id\":112,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-719\",\"questions\":[{\"header\":\"Choose an action\",\"id\":\"options-719\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Use the default behavior.\",\"label\":\"Use default\"},{\"description\":\"Skip this step.\",\"label\":\"Skip\"}],\"question\":\"How should I proceed?\"}],\"threadId\":\"thread-719\",\"turnId\":\"turn-719\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-user-input-options",
        identifier: "MT-719",
        title: "Option based tool input answer",
        description: "Ensure option prompts receive a generic non-interactive answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-719",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle option based tool input", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 112 and
                   get_in(payload, ["result", "answers", "options-719", "answers"]) == [
                     "This is a non-interactive session. Operator input is unavailable."
                   ]
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects unsupported dynamic tool calls without stalling" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90\"}}}'
            printf '%s\\n' '{\"id\":101,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"some_tool\",\"callId\":\"call-90\",\"threadId\":\"thread-90\",\"turnId\":\"turn-90\",\"arguments\":{}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call",
        identifier: "MT-90",
        title: "Unsupported tool call",
        description: "Ensure unsupported tool calls do not stall a turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-90",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Reject unsupported tool calls", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 101 and
                   get_in(payload, ["result", "success"]) == false and
                   String.contains?(
                     get_in(payload, ["result", "output"]),
                     "Unsupported dynamic tool"
                   )
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server executes supported dynamic tool calls and returns the tool result" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90A")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90a\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90a\"}}}'
            printf '%s\\n' '{\"id\":102,\"method\":\"item/tool/call\",\"params\":{\"name\":\"linear_graphql\",\"callId\":\"call-90a\",\"threadId\":\"thread-90a\",\"turnId\":\"turn-90a\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\",\"variables\":{\"includeTeams\":false}}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-supported-tool-call",
        identifier: "MT-90A",
        title: "Supported tool call",
        description: "Ensure supported tool calls return tool output",
        state: "In Progress",
        url: "https://example.org/issues/MT-90A",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => true,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"data":{"viewer":{"id":"usr_123"}}})
            }
          ]
        }
      end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle supported tool calls", issue, tool_executor: tool_executor)

      assert_received {:tool_called, "linear_graphql",
                       %{
                         "query" => "query Viewer { viewer { id } }",
                         "variables" => %{"includeTeams" => false}
                       }}

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 102 and
                   get_in(payload, ["result", "success"]) == true and
                   get_in(payload, ["result", "output"]) ==
                     ~s({"data":{"viewer":{"id":"usr_123"}}})
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server truncates oversized dynamic tool result payloads" do
    large_text = String.duplicate("x", 10_000)

    result =
      AppServer.normalize_dynamic_tool_result_for_test(%{
        "success" => true,
        "output" => large_text,
        "contentItems" => [
          %{
            "type" => "inputText",
            "text" => large_text
          }
        ]
      })

    assert result["success"] == true
    assert String.length(result["output"]) < 8_100
    assert result["output"] =~ "[dynamic tool output truncated after 8000 characters]"
    assert String.length(get_in(result, ["contentItems", Access.at(0), "text"])) < 8_100

    assert get_in(result, ["contentItems", Access.at(0), "text"]) =~
             "[dynamic tool output truncated after 8000 characters]"
  end

  test "app server strips oversized dynamic tool side fields before returning results" do
    large_text = String.duplicate("x", 10_000)

    result =
      AppServer.normalize_dynamic_tool_result_for_test(%{
        "success" => true,
        "output" => large_text,
        "data" => %{"large" => large_text},
        "debug" => large_text
      })

    assert Map.keys(result) |> Enum.sort() == ["contentItems", "output", "success"]
    assert result["success"] == true
    assert String.length(result["output"]) < 8_100
    refute Map.has_key?(result, "data")
    refute Map.has_key?(result, "debug")
  end

  test "app server emits tool_call_failed for supported tool failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-failed-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90B")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call-failed.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call-failed.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90b\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90b\"}}}'
            printf '%s\\n' '{\"id\":103,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"linear_graphql\",\"callId\":\"call-90b\",\"threadId\":\"thread-90b\",\"turnId\":\"turn-90b\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\"}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call-failed",
        identifier: "MT-90B",
        title: "Tool call failed",
        description: "Ensure supported tool failures emit a distinct event",
        state: "In Progress",
        url: "https://example.org/issues/MT-90B",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => false,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"error":{"message":"boom"}})
            }
          ]
        }
      end

      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle failed tool calls", issue,
                 on_message: on_message,
                 tool_executor: tool_executor
               )

      assert_received {:tool_called, "linear_graphql", %{"query" => "query Viewer { viewer { id } }"}}

      assert_received {:app_server_message, %{event: :tool_call_failed, payload: %{"params" => %{"tool" => "linear_graphql"}}}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server buffers partial JSON lines until newline terminator" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-partial-line-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-91")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            padding=$(printf '%*s' 1100000 '' | tr ' ' a)
            printf '{"id":1,"result":{},"padding":"%s"}\\n' "$padding"
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-91"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-91"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-partial-line",
        identifier: "MT-91",
        title: "Partial line decode",
        description: "Ensure JSON parsing waits for newline-delimited messages",
        state: "In Progress",
        url: "https://example.org/issues/MT-91",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate newline-delimited buffering", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server captures codex side output and logs it through Logger" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stderr-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-92")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-92"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-92"}}}'
            ;;
          4)
            printf '%s\\n' 'warning: this is stderr noise' >&2
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-stderr",
        identifier: "MT-92",
        title: "Capture stderr",
        description: "Ensure codex stderr is captured and logged",
        state: "In Progress",
        url: "https://example.org/issues/MT-92",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   AppServer.run(workspace, "Capture stderr log", issue, on_message: on_message)
        end)

      assert_received {:app_server_message, %{event: :turn_completed}}
      refute_received {:app_server_message, %{event: :malformed}}
      assert log =~ "Codex turn stream output: warning: this is stderr noise"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits malformed events for JSON-like protocol lines that fail to decode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-malformed-protocol-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-93")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-93"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-93"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-malformed-protocol",
        identifier: "MT-93",
        title: "Malformed protocol frame",
        description: "Ensure malformed JSON-like frames are surfaced to the orchestrator",
        state: "In Progress",
        url: "https://example.org/issues/MT-93",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Capture malformed protocol line", issue, on_message: on_message)

      assert_received {:app_server_message, %{event: :malformed, payload: "{\"method\":\"turn/completed\""}}
      assert_received {:app_server_message, %{event: :turn_completed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server launches over ssh for remote workers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-remote-ssh-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      if windows?() do
        assert windows?()
      else
        trace_file = Path.join(test_root, "ssh.trace")
        remote_workspace = "/remote/workspaces/MT-REMOTE"

        File.mkdir_p!(test_root)
        System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
        System.put_env("PATH", Enum.join([test_root, previous_path || ""], path_separator()))
        write_remote_app_server_fake_ssh!(test_root, trace_file)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: "/remote/workspaces",
          codex_command: "fake-remote-codex app-server"
        )

        issue = %Issue{
          id: "issue-remote",
          identifier: "MT-REMOTE",
          title: "Run remote app server",
          description: "Validate ssh-backed codex startup",
          state: "In Progress",
          url: "https://example.org/issues/MT-REMOTE",
          labels: ["backend"]
        }

        assert {:ok, _result} =
                 AppServer.run(
                   remote_workspace,
                   "Run remote worker",
                   issue,
                   worker_host: "worker-01:2200"
                 )

        trace = File.read!(trace_file)
        lines = String.split(trace, "\n", trim: true)

        assert argv_line = Enum.find(lines, &String.starts_with?(&1, "ARGV:"))
        assert argv_line =~ "-T -p 2200 worker-01 bash -lc"
        assert argv_line =~ "cd "
        assert argv_line =~ remote_workspace
        assert argv_line =~ "exec "
        assert argv_line =~ "fake-remote-codex app-server"

        assert Enum.any?(lines, fn line ->
                 String.starts_with?(line, "JSON:") and
                   line =~ ~s("method":"thread/start") and
                   line =~ ~s("cwd":"#{remote_workspace}")
               end)

        assert Enum.any?(lines, fn line ->
                 String.starts_with?(line, "JSON:") and
                   line =~ ~s("method":"turn/start") and
                   line =~ ~s("cwd":"#{remote_workspace}") and
                   line =~ ~s("sandboxPolicy":) and
                   line =~ ~s("type":"workspaceWrite")
               end)
      end
    after
      File.rm_rf(test_root)
    end
  end

  defp write_mcp_tool_approval_elicitation_codex!(test_root, trace_file) do
    case :os.type() do
      {:win32, _} ->
        fake_script = Path.join(test_root, "fake-codex.py")
        python = System.find_executable("python.exe") || System.find_executable("python") || "python"

        File.write!(fake_script, """
        import os
        import sys

        trace = os.environ.get("SYMP_TEST_CODEx_TRACE") or "#{String.replace(trace_file, "\\", "/")}"
        count = 0

        for line in sys.stdin:
            count += 1
            with open(trace, "a", encoding="utf-8") as trace_file:
                trace_file.write("JSON:" + line.rstrip("\\n") + "\\n")

            if count == 1:
                print('{"id":1,"result":{}}', flush=True)
            if count == 3:
                print('{"id":2,"result":{"thread":{"id":"thread-189"}}}', flush=True)
            if count == 4:
                print('{"id":3,"result":{"turn":{"id":"turn-189"}}}', flush=True)
                print('{"id":120,"method":"mcpServer/elicitation/request","params":{"_meta":{"codex_approval_kind":"mcp_tool_call","connector_name":"GitHub","source":"connector","tool_title":"create_branch"},"message":"Allow GitHub to create a branch?","mode":"form","requestedSchema":{"properties":{},"type":"object"},"serverName":"codex_apps","threadId":"thread-189","turnId":"turn-189"}}', flush=True)
            if count == 5:
                print('{"method":"turn/completed"}', flush=True)
        """)

        "#{String.replace(python, "\\", "/")} #{String.replace(fake_script, "\\", "/")} app-server"

      _ ->
        codex_binary = Path.join(test_root, "fake-codex")

        File.write!(codex_binary, """
        #!/bin/sh
        trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-mcp-tool-elicitation.trace}"
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          printf 'JSON:%s\\n' "$line" >> "$trace_file"

          case "$count" in
            1)
              printf '%s\\n' '{"id":1,"result":{}}'
              ;;
            2)
              ;;
            3)
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-189"}}}'
              ;;
            4)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-189"}}}'
              printf '%s\\n' '{"id":120,"method":"mcpServer/elicitation/request","params":{"_meta":{"codex_approval_kind":"mcp_tool_call","connector_name":"GitHub","source":"connector","tool_title":"create_branch"},"message":"Allow GitHub to create a branch?","mode":"form","requestedSchema":{"properties":{},"type":"object"},"serverName":"codex_apps","threadId":"thread-189","turnId":"turn-189"}}'
              ;;
            5)
              printf '%s\\n' '{"method":"turn/completed"}'
              exit 0
              ;;
            *)
              exit 0
              ;;
          esac
        done
        """)

        File.chmod!(codex_binary, 0o755)
        "#{codex_binary} app-server"
    end
  end

  defp linear_graphql_tool_present?(tools) when is_list(tools) do
    Enum.any?(tools, fn
      %{
        "description" => description,
        "inputSchema" => %{"required" => ["query"]},
        "name" => "linear_graphql"
      } ->
        description =~ "Linear"

      _ ->
        false
    end)
  end

  defp linear_graphql_tool_present?(_tools), do: false

  defp write_remote_app_server_fake_ssh!(test_root, trace_file) do
    if windows?() do
      script = Path.join(test_root, "ssh.ps1")
      command = Path.join(test_root, "ssh.cmd")

      File.write!(script, """
      [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
      $tracePath = @'
      #{trace_file}
      '@.Trim()
      $argv = $args -join ' '
      Add-Content -LiteralPath $tracePath -Value ("ARGV:" + $argv)
      $count = 0
      while ($null -ne ($line = [Console]::In.ReadLine())) {
        $count += 1
        Add-Content -LiteralPath $tracePath -Value ("JSON:" + $line)

        if ($count -eq 1) {
          [Console]::Out.WriteLine('{"id":1,"result":{}}')
          [Console]::Out.Flush()
        } elseif ($count -eq 3) {
          [Console]::Out.WriteLine('{"id":2,"result":{"thread":{"id":"thread-remote"}}}')
          [Console]::Out.Flush()
        } elseif ($count -eq 4) {
          [Console]::Out.WriteLine('{"id":3,"result":{"turn":{"id":"turn-remote"}}}')
          [Console]::Out.WriteLine('{"method":"turn/completed"}')
          [Console]::Out.Flush()
          exit 0
        }
      }
      exit 0
      """)

      File.write!(
        command,
        """
        @echo off
        powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "#{script}" %*
        exit /b %ERRORLEVEL%
        """
      )
    else
      fake_ssh = Path.join(test_root, "ssh")

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      count=0
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-remote"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-remote"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(fake_ssh, 0o755)
    end
  end

  defp init_git_repo!(path) do
    git = git_executable!()
    File.mkdir_p!(path)

    assert {_output, 0} =
             System.cmd(git, ["init", "--quiet", path], stderr_to_stdout: true)

    assert {_output, 0} =
             System.cmd(
               git,
               ["-C", path, "config", "user.email", "symphony-test@example.invalid"],
               stderr_to_stdout: true
             )

    assert {_output, 0} =
             System.cmd(
               git,
               ["-C", path, "config", "user.name", "Symphony Test"],
               stderr_to_stdout: true
             )

    File.write!(Path.join(path, "README.md"), "# test repository\n")

    assert {_output, 0} =
             System.cmd(git, ["-C", path, "add", "README.md"], stderr_to_stdout: true)

    assert {_output, 0} =
             System.cmd(
               git,
               ["-C", path, "commit", "--quiet", "-m", "test fixture"],
               stderr_to_stdout: true
             )

    path
  end

  defp git_executable! do
    System.find_executable("git") || raise "git executable is required for app-server tests"
  end

  defp windows? do
    match?({:win32, _}, :os.type())
  end

  defp path_separator do
    if windows?(), do: ";", else: ":"
  end

  defp write_mcp_tool_content_elicitation_codex!(test_root) do
    case :os.type() do
      {:win32, _} ->
        fake_script = Path.join(test_root, "fake-codex-content.py")
        python = System.find_executable("python.exe") || System.find_executable("python") || "python"

        File.write!(fake_script, """
        import sys

        count = 0

        for _line in sys.stdin:
            count += 1
            if count == 1:
                print('{"id":1,"result":{}}', flush=True)
            if count == 3:
                print('{"id":2,"result":{"thread":{"id":"thread-190"}}}', flush=True)
            if count == 4:
                print('{"id":3,"result":{"turn":{"id":"turn-190"}}}', flush=True)
                print('{"id":121,"method":"mcpServer/elicitation/request","params":{"_meta":{"codex_approval_kind":"mcp_tool_call"},"message":"Need additional content","mode":"form","requestedSchema":{"properties":{"reason":{"type":"string"}},"required":["reason"],"type":"object"},"serverName":"codex_apps","threadId":"thread-190","turnId":"turn-190"}}', flush=True)
        """)

        "#{String.replace(python, "\\", "/")} #{String.replace(fake_script, "\\", "/")} app-server"

      _ ->
        codex_binary = Path.join(test_root, "fake-codex-content")

        File.write!(codex_binary, """
        #!/bin/sh
        count=0
        while IFS= read -r _line; do
          count=$((count + 1))

          case "$count" in
            1)
              printf '%s\\n' '{"id":1,"result":{}}'
              ;;
            2)
              ;;
            3)
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-190"}}}'
              ;;
            4)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-190"}}}'
              printf '%s\\n' '{"id":121,"method":"mcpServer/elicitation/request","params":{"_meta":{"codex_approval_kind":"mcp_tool_call"},"message":"Need additional content","mode":"form","requestedSchema":{"properties":{"reason":{"type":"string"}},"required":["reason"],"type":"object"},"serverName":"codex_apps","threadId":"thread-190","turnId":"turn-190"}}'
              ;;
            *)
              exit 0
              ;;
          esac
        done
        """)

        File.chmod!(codex_binary, 0o755)
        "#{codex_binary} app-server"
    end
  end
end
