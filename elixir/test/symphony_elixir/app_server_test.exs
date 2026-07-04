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
      File.ln_s!(outside_workspace, symlink_workspace)

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

  test "app server injects MANAfuel hosted shell serialization instructions at thread start" do
    payload =
      AppServer.thread_start_payload("C:/workspaces/MT-1002", %{
        approval_policy: "never",
        thread_sandbox: "workspace-write"
      })

    instructions = get_in(payload, ["params", "developerInstructions"])

    assert payload["method"] == "thread/start"
    assert get_in(payload, ["params", "approvalPolicy"]) == "never"
    assert get_in(payload, ["params", "sandbox"]) == "workspace-write"
    assert get_in(payload, ["params", "cwd"]) == "C:/workspaces/MT-1002"
    assert is_list(get_in(payload, ["params", "dynamicTools"]))
    assert is_binary(instructions)
    assert instructions =~ "Hard runtime rule: issue at most one hosted shell_command"
    assert instructions =~ "even after a failed, declined, or blocked command"
    assert instructions =~ "A shell_command must be simple"
    assert instructions =~ "Use apply_patch for file edits"
    assert instructions =~ "bulk-generate files through shell_command"
    assert instructions =~ "has already applied packaged MANAfuel skill orientation"
    assert instructions =~ "Do not use hosted shell_command to read packaged SKILL.md"
    assert instructions =~ "manafuel-codex:* skill files"
    assert instructions =~ "current cwd is a scratch Symphony issue workspace"
    assert instructions =~ "Before reading or editing product repository files"
    assert instructions =~ "manafuel.implementation_root/<repo>"
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
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
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

  test "app server auto-approves command execution approval requests when approval policy is never" do
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
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-auto-approve",
        identifier: "MT-89",
        title: "Auto approve request",
        description: "Ensure app-server approval requests are handled automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle approval request", issue)

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

                 payload["id"] == 2 and
                   case get_in(payload, ["params", "dynamicTools"]) do
                     [
                       %{
                         "description" => description,
                         "inputSchema" => %{"required" => ["query"]},
                         "name" => "linear_graphql"
                       }
                     ] ->
                       description =~ "Linear"

                     _ ->
                       false
                   end
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

                 payload["id"] == 99 and get_in(payload, ["result", "decision"]) == "acceptForSession"
               else
                 false
               end
             end)
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
            if "%COUNT%"=="4" echo {"method":"item/started","params":{"item":{"id":"call-hung","type":"commandExecution","command":"rg --files .","cwd":"C:/tmp"}}}
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
                  printf '%s\\n' '{"method":"item/started","params":{"item":{"id":"call-hung","type":"commandExecution","command":"rg --files .","cwd":"/tmp"}}}'
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
            if "%COUNT%"=="4" echo {"method":"item/started","params":{"item":{"id":"call-finished","type":"commandExecution","command":"rg --files .","cwd":"C:/tmp"}}}
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
                  printf '%s\\n' '{"method":"item/started","params":{"item":{"id":"call-finished","type":"commandExecution","command":"rg --files .","cwd":"/tmp"}}}'
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
          "command" => "powershell.exe -Command Get-Content -Path C:\\Users\\jclen\\OneDrive\\Documents\\apps\\manafuel\\worktrees\\one\\MAN-90\\SECURITY.md"
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

    assert is_nil(AppServer.unsafe_command_block_reason_for_test(safe_quoted_comparison_payload))
    assert is_nil(AppServer.unsafe_command_block_reason_for_test(safe_rg_generation_search_payload))
    assert is_nil(AppServer.unsafe_command_block_reason_for_test(safe_select_string_generation_search_payload))
    assert is_nil(AppServer.unsafe_command_block_reason_for_test(safe_wrapped_quoted_comparison_payload))

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

  test "app server auto-approves MCP tool approval prompts when approval policy is never" do
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
        description: "Ensure app tool approval prompts continue automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-717",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle tool approval prompt", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
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
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      remote_workspace = "/remote/workspaces/MT-REMOTE"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

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

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [remote_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace
                 end)
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end
end
