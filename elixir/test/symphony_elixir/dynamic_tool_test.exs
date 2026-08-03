defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises only the default dynamic input contracts" do
    specs = DynamicTool.tool_specs()

    assert %{
             "description" => linear_description,
             "inputSchema" => %{
               "properties" => %{
                 "query" => _,
                 "variables" => _
               },
               "required" => ["query"],
               "type" => "object"
             }
           } = Enum.find(specs, &(&1["name"] == "linear_graphql"))

    assert linear_description =~ "Linear"

    refute Enum.any?(specs, &(&1["name"] == "local_shell"))

    assert %{
             "description" => artifact_description,
             "inputSchema" => %{
               "properties" => %{
                 "content" => _,
                 "overwrite" => _,
                 "path" => _
               },
               "required" => ["path", "content"],
               "type" => "object"
             }
           } = Enum.find(specs, &(&1["name"] == "write_run_artifact"))

    assert artifact_description =~ "issue workspace runs directory"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql", "write_run_artifact"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "local_shell is denied by default without executing the command" do
    test_root = Path.join(System.tmp_dir!(), "symphony-local-shell-denied-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      marker = Path.join(workspace, "must-not-exist")
      File.mkdir_p!(workspace)

      response =
        DynamicTool.execute(
          "local_shell",
          %{"command" => "git init must-not-exist"},
          workspace: workspace
        )

      assert response["success"] == false

      assert Jason.decode!(response["output"]) == %{
               "error" => %{
                 "message" => "`local_shell` is disabled for issue agents; use hosted sandboxed `shell_command`."
               }
             }

      refute File.exists?(marker)
    after
      File.rm_rf(test_root)
    end
  end

  test "local_shell cannot be enabled through tool arguments" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-local-shell-tool-args-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      marker = Path.join(workspace, "must-not-exist")
      File.mkdir_p!(workspace)

      response =
        DynamicTool.execute(
          "local_shell",
          %{"allow_local_shell" => true, "command" => "git init must-not-exist"},
          workspace: workspace
        )

      assert response["success"] == false
      refute File.exists?(marker)
    after
      File.rm_rf(test_root)
    end
  end

  test "local_shell runs only with the explicit internal host capability" do
    test_root = Path.join(System.tmp_dir!(), "symphony-local-shell-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      response =
        DynamicTool.execute(
          "local_shell",
          %{"command" => "echo local-shell-ok", "timeout_ms" => 10_000},
          workspace: workspace,
          allow_local_shell: true
        )

      assert response["success"] == true

      payload = Jason.decode!(response["output"])
      assert payload["exit_code"] == 0
      assert payload["workdir"] == Path.expand(workspace)
      assert payload["stdout"] =~ "local-shell-ok"
    after
      File.rm_rf(test_root)
    end
  end

  test "local_shell ignores an empty hidden launcher env var" do
    test_root = Path.join(System.tmp_dir!(), "symphony-local-shell-empty-launcher-#{System.unique_integer([:positive])}")
    original_launcher = System.get_env("CODEX_HIDDEN_STDIO_LAUNCHER")
    System.put_env("CODEX_HIDDEN_STDIO_LAUNCHER", "")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      response =
        DynamicTool.execute(
          "local_shell",
          %{"command" => "echo empty-launcher-ok", "timeout_ms" => 10_000},
          workspace: workspace,
          allow_local_shell: true
        )

      assert response["success"] == true

      payload = Jason.decode!(response["output"])
      assert payload["exit_code"] == 0
      assert payload["stdout"] =~ "empty-launcher-ok"
    after
      restore_env("CODEX_HIDDEN_STDIO_LAUNCHER", original_launcher)
      File.rm_rf(test_root)
    end
  end

  test "local_shell ignores workspace-local hidden launcher candidates" do
    test_root = Path.join(System.tmp_dir!(), "symphony-local-shell-hijack-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join([test_root, "manafuel", "worktrees", "symphony", "MAN-1"])
      fake_launcher = Path.join([workspace, ".codex", "bin", "codex-hidden-stdio-launcher.exe"])
      File.mkdir_p!(Path.dirname(fake_launcher))
      File.write!(fake_launcher, "not an executable launcher")

      response =
        DynamicTool.execute(
          "local_shell",
          %{"command" => "echo trusted-launcher-ok", "timeout_ms" => 10_000},
          workspace: workspace,
          allow_local_shell: true
        )

      assert response["success"] == true

      payload = Jason.decode!(response["output"])
      assert payload["exit_code"] == 0
      assert payload["stdout"] =~ "trusted-launcher-ok"
    after
      File.rm_rf(test_root)
    end
  end

  test "local_shell fails closed for unsafe commands" do
    test_root = Path.join(System.tmp_dir!(), "symphony-local-shell-unsafe-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      response =
        DynamicTool.execute(
          "local_shell",
          %{"command" => "echo no > out.txt"},
          workspace: workspace,
          allow_local_shell: true
        )

      assert response["success"] == false

      assert Jason.decode!(response["output"]) == %{
               "error" => %{
                 "message" => "`local_shell.command` was blocked by the MANAfuel command guard.",
                 "reason" => "shell redirection is not allowed"
               }
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "local_shell rejects workdirs outside allowed roots" do
    test_root = Path.join(System.tmp_dir!(), "symphony-local-shell-workdir-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      outside = Path.join(test_root, "outside")
      File.mkdir_p!(workspace)
      File.mkdir_p!(outside)

      response =
        DynamicTool.execute(
          "local_shell",
          %{"command" => "echo no", "workdir" => outside},
          workspace: workspace,
          allow_local_shell: true
        )

      assert response["success"] == false

      assert get_in(Jason.decode!(response["output"]), ["error", "message"]) ==
               "`local_shell.workdir` must be under the issue workspace, MANAfuel worktrees root, or MANAfuel control root."
    after
      File.rm_rf(test_root)
    end
  end

  test "local_shell rejects stale product coordination checkout workdirs" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-local-shell-coordination-#{System.unique_integer([:positive])}")

    try do
      manafuel_root = Path.join(test_root, "manafuel")
      workspace = Path.join([manafuel_root, "worktrees", "symphony", "MAN-1"])
      coordination_one = Path.join([manafuel_root, "development", "one"])
      File.mkdir_p!(workspace)
      File.mkdir_p!(coordination_one)

      response =
        DynamicTool.execute(
          "local_shell",
          %{"command" => "echo no", "workdir" => coordination_one},
          workspace: workspace,
          allow_local_shell: true
        )

      assert response["success"] == false

      assert get_in(Jason.decode!(response["output"]), ["error", "message"]) ==
               "`local_shell` must use product worktrees under manafuel.worktree_root, not stale product coordination checkouts under development."
    after
      File.rm_rf(test_root)
    end
  end

  test "write_run_artifact writes bounded evidence under issue workspace runs" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-artifact-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      response =
        DynamicTool.execute(
          "write_run_artifact",
          %{
            "path" => "runs/MAN-118/validation.md",
            "content" => "# Validation\n\nPASS\n"
          },
          workspace: workspace
        )

      assert response["success"] == true
      artifact_path = Path.join([workspace, "runs", "MAN-118", "validation.md"])
      assert File.read!(artifact_path) == "# Validation\n\nPASS\n"

      payload = Jason.decode!(response["output"])
      assert payload["path"] == Path.expand(artifact_path)
      assert payload["bytes"] == byte_size("# Validation\n\nPASS\n")
      assert payload["overwritten"] == false
    after
      File.rm_rf(test_root)
    end
  end

  test "write_run_artifact rejects inherited credential values without persisting or echoing them" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-run-artifact-secret-#{System.unique_integer([:positive])}"
      )

    secret_name = "MANAFUEL_TEST_API_KEY"
    secret_value = "mf_test_#{System.unique_integer([:positive])}_credential_value"
    previous_secret = System.get_env(secret_name)

    try do
      workspace = Path.join(test_root, "workspace")
      artifact_path = Path.join([workspace, "runs", "credential-proof.md"])
      File.mkdir_p!(Path.dirname(artifact_path))
      File.write!(artifact_path, "preserved\n")
      System.put_env(secret_name, secret_value)

      response =
        DynamicTool.execute(
          "write_run_artifact",
          %{
            "path" => "runs/credential-proof.md",
            "content" => "credential=#{secret_value}\n"
          },
          workspace: workspace
        )

      assert response["success"] == false
      assert File.read!(artifact_path) == "preserved\n"
      refute response["output"] =~ secret_value

      assert get_in(Jason.decode!(response["output"]), ["error", "code"]) ==
               "unsafe_run_artifact_content"

      assert get_in(Jason.decode!(response["output"]), ["error", "message"]) ==
               "`write_run_artifact.content` contains credential material and was rejected; use redacted or presence-only evidence."
    after
      if is_binary(previous_secret) do
        System.put_env(secret_name, previous_secret)
      else
        System.delete_env(secret_name)
      end

      File.rm_rf(test_root)
    end
  end

  test "write_run_artifact rejects recognized credential forms not present in the environment" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-artifact-shapes-#{System.unique_integer([:positive])}")

    credential_forms = [
      "-----BEGIN PRIVATE KEY-----\nZmFrZQ==\n-----END PRIVATE KEY-----",
      "AKIAABCDEFGHIJKLMNOP",
      "sk-proj-abcdefghijklmnopqrstuvwxyz123456",
      "github_pat_abcdefghijklmnopqrstuvwxyz123456",
      "xoxb-123456789012345678901234",
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.signature_value",
      "Authorization: Bearer fabricated-token-value-123456",
      "DATABASE_URL=https://user:fabricated-password@example.test/db",
      "client_secret=fabricated-client-secret-value"
    ]

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      Enum.with_index(credential_forms, fn credential, index ->
        artifact_path = Path.join([workspace, "runs", "credential-#{index}.md"])

        response =
          DynamicTool.execute(
            "write_run_artifact",
            %{"path" => "runs/credential-#{index}.md", "content" => credential},
            workspace: workspace
          )

        assert response["success"] == false
        assert get_in(Jason.decode!(response["output"]), ["error", "code"]) == "unsafe_run_artifact_content"
        refute response["output"] =~ credential
        refute File.exists?(artifact_path)
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "write_run_artifact accepts redacted references and presence-only evidence" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-artifact-safe-#{System.unique_integer([:positive])}")

    safe_content = """
    LINEAR_API_KEY_PRESENT=true
    Authorization: Bearer <redacted>
    api_key=${LINEAR_API_KEY}
    client_secret=$env:CLIENT_SECRET
    password=%DATABASE_PASSWORD%
    endpoint=https://example.test/api
    commit=0123456789abcdef0123456789abcdef01234567
    sha256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    """

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      response =
        DynamicTool.execute(
          "write_run_artifact",
          %{"path" => "runs/sanitized-proof.md", "content" => safe_content},
          workspace: workspace
        )

      assert response["success"] == true
      assert File.read!(Path.join([workspace, "runs", "sanitized-proof.md"])) == safe_content
    after
      File.rm_rf(test_root)
    end
  end

  test "write_run_artifact rejects absolute paths even under the issue runs directory" do
    test_root = Path.join(System.tmp_dir!(), "symphony-absolute-run-artifact-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      artifact_path = Path.join([workspace, "runs", "handoff.md"])
      File.mkdir_p!(workspace)

      response =
        DynamicTool.execute(
          "write_run_artifact",
          %{
            "path" => artifact_path,
            "content" => "handoff\n"
          },
          workspace: workspace
        )

      assert response["success"] == false
      refute File.exists?(artifact_path)
    after
      File.rm_rf(test_root)
    end
  end

  test "write_run_artifact rejects relative traversal outside issue runs" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-artifact-outside-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      response =
        DynamicTool.execute(
          "write_run_artifact",
          %{
            "path" => Path.join("..", "outside.md"),
            "content" => "no\n"
          },
          workspace: workspace
        )

      assert response["success"] == false

      assert get_in(Jason.decode!(response["output"]), ["error", "message"]) ==
               "`write_run_artifact.path` must stay under the issue workspace `runs` directory."

      refute File.exists?(Path.join(test_root, "outside.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "write_run_artifact rejects cross-issue workspace paths" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-artifact-cross-issue-#{System.unique_integer([:positive])}")

    try do
      issue_root = Path.join(test_root, "issues")
      workspace = Path.join(issue_root, "MAN-118")
      other_workspace = Path.join(issue_root, "MAN-119")
      other_artifact = Path.join([other_workspace, "runs", "proof.md"])
      File.mkdir_p!(workspace)
      File.mkdir_p!(other_workspace)

      response =
        DynamicTool.execute(
          "write_run_artifact",
          %{
            "path" => Path.join(["..", "MAN-119", "runs", "proof.md"]),
            "content" => "no\n"
          },
          workspace: workspace
        )

      assert response["success"] == false
      refute File.exists?(other_artifact)
    after
      File.rm_rf(test_root)
    end
  end

  test "write_run_artifact rejects a runs-root directory reparse escape" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-artifact-reparse-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    runs_root = Path.join(workspace, "runs")
    outside = Path.join(test_root, "outside")

    try do
      File.mkdir_p!(workspace)
      File.mkdir_p!(outside)
      assert :ok = create_directory_link(outside, runs_root)

      response =
        DynamicTool.execute(
          "write_run_artifact",
          %{"path" => "runs/proof.md", "content" => "no\n"},
          workspace: workspace
        )

      assert response["success"] == false
      refute File.exists?(Path.join(outside, "proof.md"))
    after
      remove_directory_link(runs_root)
      File.rm_rf(test_root)
    end
  end

  test "write_run_artifact honors overwrite false" do
    test_root = Path.join(System.tmp_dir!(), "symphony-run-artifact-overwrite-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      artifact_path = Path.join([workspace, "runs", "MAN-118", "plan.md"])
      File.mkdir_p!(Path.dirname(artifact_path))
      File.write!(artifact_path, "original\n")

      response =
        DynamicTool.execute(
          "write_run_artifact",
          %{
            "path" => "runs/MAN-118/plan.md",
            "content" => "new\n",
            "overwrite" => false
          },
          workspace: workspace
        )

      assert response["success"] == false

      assert get_in(Jason.decode!(response["output"]), ["error", "message"]) ==
               "`write_run_artifact` failed to write the artifact."

      assert File.read!(artifact_path) == "original\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end

  defp create_directory_link(target, link_path) do
    if windows?() do
      case System.cmd(
             "cmd.exe",
             ["/d", "/c", "mklink", "/J", windows_path(link_path), windows_path(target)],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {status, output}}
      end
    else
      File.ln_s(target, link_path)
    end
  end

  defp remove_directory_link(link_path) do
    if File.exists?(link_path) do
      if windows?() do
        System.cmd("cmd.exe", ["/d", "/c", "rmdir", windows_path(link_path)], stderr_to_stdout: true)
      else
        File.rm(link_path)
      end
    end
  end

  defp windows?, do: match?({:win32, _}, :os.type())
  defp windows_path(path), do: String.replace(path, "/", "\\")
end
