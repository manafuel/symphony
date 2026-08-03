defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, banner} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "defaults to WORKFLOW.md when workflow path is missing" do
    deps = %{
      file_regular?: fn path -> Path.basename(path) == "WORKFLOW.md" end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
  end

  test "production mode accepts only the exact bound CLI sequence" do
    parent = self()
    launch_path = Path.expand("launch.json")
    contract_path = Path.expand("contract.json")
    workflow_path = Path.expand("runtime-workflow.md")
    launch_sha = String.duplicate("a", 64)
    contract_sha = String.duplicate("b", 64)
    launch = %{document: %{}}
    contract = %{document: %{}}

    deps = %{
      file_regular?: fn path -> path == workflow_path end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end,
      load_launch_receipt: fn path, digest ->
        send(parent, {:launch_reopened, path, digest})
        {:ok, launch}
      end,
      load_producer_contract: fn path, digest ->
        send(parent, {:contract_reopened, path, digest})
        {:ok, contract}
      end,
      validate_production_authority: fn actual_launch, actual_contract, path ->
        send(parent, {:authority_validated, actual_launch, actual_contract, path})
        :ok
      end,
      validate_runtime_binding: fn actual_launch, actual_contract, path ->
        send(parent, {:runtime_binding_validated, actual_launch, actual_contract, path})
        :ok
      end,
      install_production_authority: fn actual_launch, actual_contract, path ->
        send(parent, {:authority_installed, actual_launch, actual_contract, path})
        :ok
      end
    }

    args = [
      "--production-mode",
      "--production-launch-receipt",
      launch_path,
      "--expected-launch-receipt-sha256",
      launch_sha,
      "--producer-contract-manifest",
      contract_path,
      "--expected-producer-contract-sha256",
      contract_sha,
      workflow_path
    ]

    assert :ok = CLI.evaluate(args, deps)
    assert_received {:launch_reopened, ^launch_path, ^launch_sha}
    assert_received {:contract_reopened, ^contract_path, ^contract_sha}
    assert_received {:authority_validated, ^launch, ^contract, ^workflow_path}
    assert_received {:runtime_binding_validated, ^launch, ^contract, ^workflow_path}
    assert_received {:authority_installed, ^launch, ^contract, ^workflow_path}
    assert_received {:workflow_set, ^workflow_path}
    assert_received :started

    refute match?(
             :ok,
             CLI.evaluate(
               List.replace_at(args, 1, "--expected-launch-receipt-sha256"),
               deps
             )
           )
  end
end
