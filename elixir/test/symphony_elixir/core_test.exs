defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  defmodule RedactedSnapshotServer do
    use GenServer

    def start_link(snapshot) do
      GenServer.start_link(__MODULE__, snapshot, name: __MODULE__)
    end

    @impl true
    def init(snapshot), do: {:ok, snapshot}

    @impl true
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.poll_scope == "project"
    assert config.tracker.team_key == nil
    assert config.tracker.auto_project_admission == false
    assert config.tracker.assignee == nil
    assert config.agent.max_turns == 20

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: "project",
      tracker_poll_scope: "TEAM",
      tracker_team_key: nil
    )

    assert Config.settings!().tracker.poll_scope == "team"
    assert {:error, :missing_linear_team_key} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      tracker_poll_scope: "team",
      tracker_team_key: "MAN",
      tracker_auto_project_admission: true
    )

    assert Config.settings!().tracker.team_key == "MAN"
    assert Config.settings!().tracker.auto_project_admission
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "current WORKFLOW.md file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.clear_workflow_file_path()

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "linear"
    assert is_binary(Map.get(tracker, "project_slug"))
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)
    assert Map.get(hooks, "after_create") =~ "git clone --depth 1 https://github.com/openai/symphony ."
    assert Map.get(hooks, "after_create") =~ "cd elixir && mise trust"
    assert Map.get(hooks, "after_create") =~ "mise exec -- mix deps.get"
    assert Map.get(hooks, "before_remove") =~ "cd elixir && mise exec -- mix workspace.before_remove"

    assert String.trim(prompt) != ""
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace_root = String.replace(test_root, "\\", "/")
    workspace = Path.join(workspace_root, issue_identifier)
    terminal_marker = Path.join(test_root, "terminal-hook.log")
    hook_script = Path.join(test_root, "terminal-pass.exs")

    try do
      File.mkdir_p!(test_root)
      File.write!(hook_script, "File.write!(#{inspect(terminal_marker)}, \"verified\\n\")\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        hook_before_terminal: "elixir \"#{hook_script}\""
      )

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            workspace_path: workspace,
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
      assert File.read!(terminal_marker) == "verified\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal hook failure preserves claim and workspace then recovers on a bounded retry" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-hook-block-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-terminal-hook-block"
    issue_identifier = "MT-TERMINAL-BLOCK"
    workspace_root = String.replace(test_root, "\\", "/")
    workspace = Path.join(workspace_root, issue_identifier)
    hook_script = Path.join(test_root, "terminal-block.exs")
    recovery_marker = Path.join(test_root, "terminal-recovered.log")
    secret_sentinel = "sk_live_MAN176_SENTINEL"

    try do
      File.mkdir_p!(test_root)

      File.write!(
        hook_script,
        "IO.write(String.duplicate(#{inspect(secret_sentinel)}, 1024)); System.halt(19)\n"
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Done"],
        hook_before_terminal: "elixir \"#{hook_script}\""
      )

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            workspace_path: workspace,
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      terminal_issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Done",
        title: "Missing terminal proof",
        updated_at: ~U[2026-07-13 13:00:00Z]
      }

      blocked_log =
        ExUnit.CaptureLog.capture_log(fn ->
          blocked_state = Orchestrator.reconcile_issue_states_for_test([terminal_issue], state)
          send(self(), {:terminal_blocked_state, blocked_state})
        end)

      assert_receive {:terminal_blocked_state, blocked_state}

      refute Map.has_key?(blocked_state.running, issue_id)
      assert MapSet.member?(blocked_state.claimed, issue_id)
      assert blocked_state.blocked[issue_id].block_kind == :before_terminal

      assert blocked_state.blocked[issue_id].error ==
               "before_terminal acceptance failed: hook_failed_status_19"

      refute Process.alive?(agent_pid)
      assert File.dir?(workspace)
      refute blocked_log =~ secret_sentinel
      refute inspect(blocked_state) =~ secret_sentinel

      {:reply, snapshot, _state} =
        Orchestrator.handle_call(:snapshot, {self(), make_ref()}, blocked_state)

      refute inspect(snapshot) =~ secret_sentinel

      {:ok, snapshot_server} = RedactedSnapshotServer.start_link(snapshot)

      on_exit(fn ->
        if Process.alive?(snapshot_server), do: Process.exit(snapshot_server, :normal)
      end)

      api_payload =
        SymphonyElixirWeb.Presenter.state_payload(RedactedSnapshotServer, 1_000)

      refute inspect(api_payload) =~ secret_sentinel

      reopened_state =
        Orchestrator.reconcile_blocked_issue_states_for_test(
          [%{terminal_issue | state: "In Progress"}],
          blocked_state
        )

      refute MapSet.member?(reopened_state.claimed, issue_id)
      refute Map.has_key?(reopened_state.blocked, issue_id)
      assert File.dir?(workspace)

      still_blocked =
        Orchestrator.reconcile_blocked_issue_states_for_test([terminal_issue], blocked_state)

      assert MapSet.member?(still_blocked.claimed, issue_id)
      assert Map.has_key?(still_blocked.blocked, issue_id)
      assert still_blocked.blocked[issue_id].terminal_retry_attempt == 1
      assert File.dir?(workspace)

      File.write!(
        hook_script,
        "File.write!(#{inspect(recovery_marker)}, \"recovered\\n\")\n"
      )

      retry_due_state =
        put_in(
          still_blocked.blocked[issue_id].terminal_retry_at_ms,
          System.monotonic_time(:millisecond) - 1
        )

      recovered_state =
        Orchestrator.reconcile_blocked_issue_states_for_test([terminal_issue], retry_due_state)

      refute MapSet.member?(recovered_state.claimed, issue_id)

      refute Map.has_key?(recovered_state.blocked, issue_id)
      refute File.exists?(workspace)
      assert File.read!(recovery_marker) == "recovered\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal acceptance blocks survive empty and partial tracker refreshes" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_terminal_states: ["Done"])

    issue_a = %Issue{id: "terminal-a", identifier: "MT-TERMINAL-A", state: "Done"}
    issue_b = %Issue{id: "terminal-b", identifier: "MT-TERMINAL-B", state: "Done"}
    retry_at_ms = System.monotonic_time(:millisecond) + 60_000

    state = %Orchestrator.State{
      blocked: %{
        issue_a.id => %{
          issue: issue_a,
          identifier: issue_a.identifier,
          block_kind: :before_terminal,
          terminal_retry_attempt: 1,
          terminal_retry_at_ms: retry_at_ms
        },
        issue_b.id => %{
          issue: issue_b,
          identifier: issue_b.identifier,
          block_kind: :before_terminal,
          terminal_retry_attempt: 1,
          terminal_retry_at_ms: retry_at_ms
        }
      },
      claimed: MapSet.new([issue_a.id, issue_b.id]),
      retry_attempts: %{}
    }

    partial_state =
      Orchestrator.reconcile_blocked_issue_states_for_test([issue_a], state)

    assert MapSet.equal?(partial_state.claimed, state.claimed)
    assert Map.has_key?(partial_state.blocked, issue_a.id)
    assert Map.has_key?(partial_state.blocked, issue_b.id)

    empty_state = Orchestrator.reconcile_blocked_issue_states_for_test([], partial_state)

    assert MapSet.equal?(empty_state.claimed, state.claimed)
    assert Map.has_key?(empty_state.blocked, issue_a.id)
    assert Map.has_key?(empty_state.blocked, issue_b.id)
  end

  test "scheduled retry fetches terminal issue by id and gates failure and success" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-retry-block-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-terminal-retry-block"
    issue_identifier = "MT-TERMINAL-RETRY"
    workspace_root = String.replace(test_root, "\\", "/")
    workspace = Path.join(workspace_root, issue_identifier)
    hook_script = Path.join(test_root, "terminal-retry-block.exs")
    success_marker = Path.join(test_root, "terminal-retry-success.log")
    previous_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    on_exit(fn ->
      if is_nil(previous_issues) do
        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      else
        Application.put_env(:symphony_elixir, :memory_tracker_issues, previous_issues)
      end

      if is_nil(previous_recipient) do
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      else
        Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_recipient)
      end
    end)

    try do
      File.mkdir_p!(test_root)
      File.write!(hook_script, "System.halt(23)\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        tracker_terminal_states: ["Done"],
        hook_before_terminal: "elixir \"#{hook_script}\""
      )

      File.mkdir_p!(workspace)

      terminal_issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Done",
        title: "Retry terminal verification",
        updated_at: ~U[2026-07-13 13:01:00Z]
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [terminal_issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      retry_entry = fn retry_token ->
        %{
          attempt: 1,
          retry_token: retry_token,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: issue_identifier,
          workspace_path: workspace,
          worker_host: nil
        }
      end

      blocked_token = make_ref()

      blocked_input = %Orchestrator.State{
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{issue_id => retry_entry.(blocked_token)}
      }

      assert {:noreply, blocked_state} =
               Orchestrator.handle_info(
                 {:retry_issue, issue_id, blocked_token},
                 blocked_input
               )

      assert_receive {:memory_tracker_fetch_by_ids, [^issue_id]}
      assert MapSet.member?(blocked_state.claimed, issue_id)
      assert blocked_state.blocked[issue_id].block_kind == :before_terminal
      assert File.dir?(workspace)

      File.write!(
        hook_script,
        "File.write!(#{inspect(success_marker)}, \"accepted\\n\")\n"
      )

      accepted_token = make_ref()

      accepted_input = %Orchestrator.State{
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{issue_id => retry_entry.(accepted_token)}
      }

      assert {:noreply, accepted_state} =
               Orchestrator.handle_info(
                 {:retry_issue, issue_id, accepted_token},
                 accepted_input
               )

      assert_receive {:memory_tracker_fetch_by_ids, [^issue_id]}
      refute MapSet.member?(accepted_state.claimed, issue_id)
      refute Map.has_key?(accepted_state.blocked, issue_id)
      refute File.exists?(workspace)
      assert File.read!(success_marker) == "accepted\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "startup terminal cleanup reconstructs a claim and recovers after restart failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-startup-terminal-block-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-startup-terminal-block"
    issue_identifier = "MT-STARTUP-TERMINAL"
    workspace_root = String.replace(test_root, "\\", "/")
    workspace = Path.join(workspace_root, issue_identifier)
    hook_script = Path.join(test_root, "startup-terminal.exs")
    recovery_marker = Path.join(test_root, "startup-terminal-recovered.log")

    try do
      File.mkdir_p!(test_root)
      File.write!(hook_script, "System.halt(31)\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        poll_interval_ms: 1_000,
        tracker_terminal_states: ["Done"],
        hook_before_terminal: "elixir \"#{hook_script}\""
      )

      File.mkdir_p!(workspace)

      terminal_issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Done",
        title: "Restart terminal verification",
        updated_at: ~U[2026-07-13 13:02:00Z]
      }

      startup_state =
        Orchestrator.recover_startup_terminal_issues_for_test(
          [terminal_issue],
          %Orchestrator.State{retry_attempts: %{}}
        )

      assert MapSet.member?(startup_state.claimed, issue_id)
      assert startup_state.blocked[issue_id].block_kind == :before_terminal
      assert startup_state.blocked[issue_id].terminal_retry_attempt == 1
      assert File.dir?(workspace)

      File.write!(
        hook_script,
        "File.write!(#{inspect(recovery_marker)}, \"recovered\\n\")\n"
      )

      retry_due_state =
        put_in(
          startup_state.blocked[issue_id].terminal_retry_at_ms,
          System.monotonic_time(:millisecond) - 1
        )

      recovered_state =
        Orchestrator.reconcile_blocked_issue_states_for_test([terminal_issue], retry_due_state)

      refute MapSet.member?(recovered_state.claimed, issue_id)
      refute Map.has_key?(recovered_state.blocked, issue_id)
      refute File.exists?(workspace)
      assert File.read!(recovery_marker) == "recovered\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "reconcile stops running issue when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "issue-unlabeled"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-562",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-562",
            state: "In Progress",
            labels: ["symphony"]
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-562",
      state: "In Progress",
      title: "Opted out active issue",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "reconcile releases a blocked issue when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "blocked-unlabeled"

    state = %Orchestrator.State{
      blocked: %{
        issue_id => %{
          identifier: "MT-564",
          error: "operator input required",
          worker_host: nil
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-564",
      title: "Blocked but opted out",
      state: "In Progress",
      labels: []
    }

    updated_state = Orchestrator.reconcile_blocked_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.blocked, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
  end

  test "retry releases its claim when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "retry-unlabeled"

    state = %Orchestrator.State{
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-565",
      title: "Retry opted out",
      state: "In Progress",
      labels: []
    }

    updated_state =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, issue_id, 1, %{
        identifier: issue.identifier,
        error: "agent exited"
      })

    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
  end

  test "agent runner does not continue after a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue = %Issue{
      id: "issue-label-continuation",
      identifier: "MT-563",
      title: "Stop after opt-out",
      state: "In Progress",
      labels: ["symphony"]
    }

    refreshed_issue = %{issue | labels: []}
    fetcher = fn ["issue-label-continuation"] -> {:ok, [refreshed_issue]} end

    assert {:done, ^refreshed_issue} =
             AgentRunner.continue_with_issue_for_test(issue, fetcher)
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, 500, 1_100)
  end

  test "typed transient worker exit increments the execution attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(
      pid,
      {:DOWN, ref, :process, self(), {:shutdown, {:classified_failure, :transient_transport, "transport unavailable"}}}
    )

    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{
             attempt: 3,
             due_at_ms: due_at_ms,
             identifier: "MT-559",
             error: "agent exited with transient_transport",
             failure_class: :transient_transport
           } =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 19_500, 20_500)
  end

  test "first typed transient worker exit schedules execution attempt two" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(
      pid,
      {:DOWN, ref, :process, self(), {:shutdown, {:classified_failure, :transient_transport, "transport unavailable"}}}
    )

    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{
             attempt: 2,
             due_at_ms: due_at_ms,
             identifier: "MT-560",
             error: "agent exited with transient_transport",
             failure_class: :transient_transport
           } =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 9_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-a"
  end

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert remaining_ms >= min_remaining_ms
    assert remaining_ms <= max_remaining_ms
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder exposes empty issue comments by default" do
    workflow_prompt = "Ticket {{ issue.identifier }} comments={% for comment in issue.comments %}{{ comment.body }}{% else %}none{% endfor %}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-698",
      title: "Render comments",
      description: "Prompt should expose comments as an empty list",
      state: "Todo",
      url: "https://example.org/issues/MT-698",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-698 comments=none"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "You are working on a Linear ticket `MT-616`"
    assert prompt =~ "Issue context:"
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "Title: Use rich templates for WORKFLOW.md"
    assert prompt =~ "Current status: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "This is an unattended orchestration session."
    assert prompt =~ "Only stop early for a true blocker"
    assert prompt =~ "Do not include \"next steps for user\""
    assert prompt =~ "open and follow `.codex/skills/land/SKILL.md`"
    assert prompt =~ "Do not call `gh pr merge` directly"
    assert prompt =~ "Continuation context:"
    assert prompt =~ "retry attempt #2"
  end

  test "prompt builder compacts oversized MANAfuel workflow prompts" do
    long_omitted_section = String.duplicate("grok-lane-detail ", 4_000)
    long_comment = String.duplicate("historical workpad note ", 900)

    workflow_prompt = """
    # MANAfuel Symphony Workflow

    ## App-Server Tool Execution Contract

    Keep every shell command simple and use `write_run_artifact` for run evidence.

    ## Issue Context

    Identifier: {{ issue.identifier }}
    Title: {{ issue.title }}
    Current status: {{ issue.state }}
    URL: {{ issue.url }}
    Labels: {{ issue.labels }}

    Description:
    {{ issue.description }}

    Recent Linear comments fetched by the harness:
    {% for comment in issue.comments %}
    Comment created_at={{ comment.created_at }}

    {{ comment.body }}
    {% endfor %}

    ## Immediate Required First Actions

    Post the `symphony:plan:{{ issue.identifier }}` marker before product edits.

    ## Board Contract

    Only `Ready for Codex`, `In Progress`, or `Rework` tickets with `codex-agent-ready` are dispatch-eligible.

    ## Ticket Notes And Delivery Goal

    Continue until the PR is merged and `symphony:final:{{ issue.identifier }}` evidence exists.

    ## Bounded Delivery Loop

    Token-runaway blockers require a reviewed guard or narrowed execution packet before requeue.

    ## Worktree Rule

    Product-code reads and writes require a clean named product worktree under `manafuel.worktree_root`.

    ## Run Folder Contract

    Required plan, validation, committee, reviewer, and proof artifacts must land in the run folder.

    ## MCP Policy

    Missing required MCPs move the ticket to Human Review only after documented fallback attempts.

    ## Noninteractive Command Safety

    Do not run inline scripts, shell redirection, or multi-step orchestration through shell tools.

    ## Validation

    Run the ticket-provided validation and record proof.

    ## Completion

    Do not mark Done without merge and final evidence.

    ## Grok Candidate Lane (runtime-owner:grok)

    #{long_omitted_section}
    """

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MAN-153",
      title: "Fix Growth page regression",
      description: "Keep the actionable issue body in the first turn.",
      state: "Rework",
      url: "https://linear.app/manafuel/issue/MAN-153",
      labels: ["codex-agent-ready", "owner:growth-marketing-system"],
      comments: [
        %{
          created_at: "2026-07-06T10:00:00Z",
          body: long_comment
        }
      ]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert String.length(prompt) <= 35_000
    assert prompt =~ "compacted for token budget"
    assert prompt =~ ".codex/workflows/symphony-manafuel/WORKFLOW.md"
    assert prompt =~ "Keep every shell command simple"
    assert prompt =~ "Identifier: MAN-153"
    assert prompt =~ "Fix Growth page regression"
    assert prompt =~ "Ready for Codex"
    assert prompt =~ "symphony:final:MAN-153"
    assert prompt =~ "Compacted prompt omitted"
    assert prompt =~ "## Grok Candidate Lane"
    refute prompt =~ String.duplicate("grok-lane-detail ", 100)
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", Enum.join([test_root, previous_path || ""], path_separator()))
      write_workspace_prepare_fake_ssh!(test_root, trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert {:shutdown, {:classified_failure, :unknown_fail_closed, reason}} =
               catch_exit(AgentRunner.run(issue, nil, worker_host: "worker-a"))

      assert reason =~ "workspace_prepare_failed"

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
      assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
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
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
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
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
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
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
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

      codex_command = write_custom_args_fake_codex!(test_root, codex_binary, trace_file)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_command} --config 'model=\"gpt-5.5\"' app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--config model=\"gpt-5.5\" app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
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
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
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

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
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

  defp write_workspace_prepare_fake_ssh!(test_root, trace_file) do
    if windows?() do
      python = System.find_executable("python.exe") || System.find_executable("python") || "python"
      script = Path.join(test_root, "ssh.py")
      command = Path.join(test_root, "ssh.cmd")

      File.write!(script, """
      import sys

      trace_path = #{inspect(trace_file)}
      args = " ".join(sys.argv[1:])

      with open(trace_path, "a", encoding="utf-8") as trace:
          trace.write("ARGV:" + args + "\\n")

      if "worker-a" in args and "__SYMPHONY_WORKSPACE__" in args:
          print("worker-a prepare failed", file=sys.stderr)
          sys.exit(75)

      if "worker-b" in args and "__SYMPHONY_WORKSPACE__" in args:
          print("__SYMPHONY_WORKSPACE__\\t1\\t/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER")
          sys.exit(0)

      sys.exit(0)
      """)

      File.write!(
        command,
        """
        @echo off
        "#{python}" "#{script}" %*
        exit /b %ERRORLEVEL%
        """
      )
    else
      fake_ssh = Path.join(test_root, "ssh")

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)
    end
  end

  defp write_custom_args_fake_codex!(test_root, codex_binary, trace_file) do
    if windows?() do
      python = System.find_executable("python.exe") || System.find_executable("python") || "python"
      script = Path.join(test_root, "fake-codex-custom-args.py")

      File.write!(script, """
      import os
      import sys

      trace_path = os.environ.get("SYMP_TEST_CODex_TRACE") or #{inspect(trace_file)}

      with open(trace_path, "a", encoding="utf-8") as trace:
          trace.write("ARGV:" + " ".join(sys.argv[1:]) + "\\n")

      count = 0
      for _line in sys.stdin:
          count += 1
          if count == 1:
              print('{"id":1,"result":{}}', flush=True)
          elif count == 2:
              print('{"id":2,"result":{"thread":{"id":"thread-88"}}}', flush=True)
          elif count == 3:
              print('{"id":3,"result":{"turn":{"id":"turn-88"}}}', flush=True)
          elif count == 4:
              print('{"method":"turn/completed"}', flush=True)
              sys.exit(0)

      sys.exit(0)
      """)

      "#{String.replace(python, "\\", "/")} #{String.replace(script, "\\", "/")}"
    else
      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
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
      codex_binary
    end
  end

  defp windows? do
    match?({:win32, _}, :os.type())
  end

  defp path_separator do
    if windows?(), do: ";", else: ":"
  end

  test "failure classification is typed and unknown outcomes fail closed" do
    alias SymphonyElixir.FailureSemantics

    assert FailureSemantics.classify({:rate_limit, %{retry_after_ms: 1_000}}).class ==
             :transient_capacity

    assert FailureSemantics.classify({:workspace_hook_timeout, "before_run", 60_000}).class ==
             :transient_transport

    assert FailureSemantics.classify({:workspace_hook_failed, "before_run", 20}).class ==
             :permanent_admission

    assert FailureSemantics.classify({:approval_required, %{request_id: "approval-1"}}).class ==
             :approval_required

    assert FailureSemantics.classify({:authority_denied, :policy}).class == :authority_denied
    assert FailureSemantics.classify({:unexpected_shape, %{free_text: "rate limit"}}).class == :unknown_fail_closed

    refute FailureSemantics.classify({:unexpected_shape, %{free_text: "rate limit"}}).retryable
  end

  test "failure classification exhaustively maps reviewed structural inputs" do
    alias SymphonyElixir.FailureSemantics

    classifications = [
      {{:shutdown, {:classified_failure, :transient_transport, :closed}}, :transient_transport},
      {{:classified_failure, :transient_capacity, :busy}, :transient_capacity},
      {{:classified_failure, :not_reviewed, :invalid}, :unknown_fail_closed},
      {{:rate_limit, %{retry_after_ms: 10}}, :transient_capacity},
      {{:capacity_exhausted, :worker_pool}, :transient_capacity},
      {:rate_limit, :transient_capacity},
      {:capacity_exhausted, :transient_capacity},
      {{:workspace_hook_timeout, "before_run", 1_000}, :transient_transport},
      {{:response_timeout, :codex}, :transient_transport},
      {{:port_exit, 75}, :transient_transport},
      {:epipe, :transient_transport},
      {:port_exit, :transient_transport},
      {:response_timeout, :transient_transport},
      {:timeout, :transient_transport},
      {{:workspace_hook_failed, "before_run", 20}, :permanent_admission},
      {{:workspace_hook_failed, "before_run", 21}, :permanent_contract},
      {{:workspace_hook_failed, "before_run", 22}, :approval_required},
      {{:workspace_hook_failed, "before_run", 23}, :authority_denied},
      {{:workspace_hook_failed, "before_run", 24}, :operator_decision_required},
      {{:workspace_hook_failed, "before_run", 70}, :transient_capacity},
      {{:workspace_hook_failed, "before_run", 71}, :transient_transport},
      {{:workspace_hook_failed, "before_run", 999}, :unknown_fail_closed},
      {{:approval_required, :tool}, :approval_required},
      {:approval_required, :approval_required},
      {{:authority_denied, :policy}, :authority_denied},
      {:authority_denied, :authority_denied},
      {{:operator_decision_required, :ambiguous}, :operator_decision_required},
      {:operator_decision_required, :operator_decision_required},
      {{:permanent_admission, :policy}, :permanent_admission},
      {{:permanent_contract, :schema}, :permanent_contract},
      {{:unclassified, :shape}, :unknown_fail_closed}
    ]

    for {reason, expected_class} <- classifications do
      classification = FailureSemantics.classify(reason)
      assert classification.class == expected_class
      assert classification.retryable == expected_class in [:transient_capacity, :transient_transport]
    end

    assert FailureSemantics.classes() == [
             :transient_capacity,
             :transient_transport,
             :permanent_admission,
             :permanent_contract,
             :approval_required,
             :authority_denied,
             :operator_decision_required,
             :unknown_fail_closed
           ]

    assert FailureSemantics.valid_class?(:permanent_contract)
    refute FailureSemantics.valid_class?(:not_reviewed)
    assert FailureSemantics.disposition(:transient_capacity) == :retry
    assert FailureSemantics.disposition(:approval_required) == :held
    assert FailureSemantics.disposition(:permanent_contract) == :permanent

    assert {:shutdown, {:classified_failure, :unknown_fail_closed, safe_reason}} =
             FailureSemantics.exit_reason({:unexpected, String.duplicate("x", 4_000)})

    assert safe_reason == "unexpected"

    secret_sentinel = "sk_live_R2_SHOULD_NOT_SURVIVE"

    assert {:shutdown, {:classified_failure, :unknown_fail_closed, "unexpected"}} =
             FailureSemantics.exit_reason({:unexpected, secret_sentinel})

    refute FailureSemantics.safe_diagnostic({:unexpected, secret_sentinel}) =~ secret_sentinel
  end

  test "permanent, approval, and authority failures execute once and enter terminal state" do
    issue = %Issue{
      id: "issue-terminal-failure",
      identifier: "MT-R2-PERM",
      title: "Permanent failure",
      state: "In Progress",
      url: "https://example.org/issues/MT-R2-PERM"
    }

    base_state = %Orchestrator.State{max_retry_attempts: 3}

    for {failure_class, terminal_state} <- [
          {:permanent_admission, :permanent},
          {:permanent_contract, :permanent},
          {:approval_required, :held},
          {:authority_denied, :held},
          {:operator_decision_required, :held},
          {:unknown_fail_closed, :permanent}
        ] do
      state =
        Orchestrator.transition_failure_for_test(
          base_state,
          issue,
          failure_class,
          1,
          "typed test failure"
        )

      assert state.retry_attempts == %{}
      assert state.blocked[issue.id].attempt == 1
      assert state.blocked[issue.id].failure_class == failure_class
      assert state.blocked[issue.id].terminal_state == terminal_state
      assert state.blocked[issue.id].transition == :terminal
    end
  end

  test "transient failures cannot schedule an attempt beyond the configured ceiling" do
    issue = %Issue{
      id: "issue-transient-failure",
      identifier: "MT-R2-TRANSIENT",
      title: "Transient failure",
      state: "In Progress",
      url: "https://example.org/issues/MT-R2-TRANSIENT"
    }

    state = %Orchestrator.State{max_retry_attempts: 3}

    state =
      Orchestrator.transition_failure_for_test(
        state,
        issue,
        :transient_transport,
        1,
        "transport unavailable"
      )

    assert state.retry_attempts[issue.id].attempt == 2
    assert state.retry_attempts[issue.id].failure_class == :transient_transport
    assert state.retry_attempts[issue.id].transition == :retrying

    exhausted =
      Orchestrator.transition_failure_for_test(
        %{state | retry_attempts: %{}},
        issue,
        :transient_transport,
        3,
        "transport unavailable"
      )

    assert exhausted.retry_attempts == %{}
    assert exhausted.blocked[issue.id].terminal_state == :held
    assert exhausted.blocked[issue.id].attempt == 3
    assert exhausted.blocked[issue.id].retry_exhausted
  end

  test "failed retry revalidation remains represented and obeys the retry ceiling" do
    issue = %Issue{
      id: "issue-revalidation-failure",
      identifier: "MT-R2-REVALIDATE",
      title: "Retry revalidation failure",
      state: "In Progress",
      url: "https://example.org/issues/MT-R2-REVALIDATE"
    }

    metadata = %{
      identifier: issue.identifier,
      issue_url: issue.url,
      issue: issue,
      failure_class: :transient_transport,
      delay_type: :backoff
    }

    state = %Orchestrator.State{
      max_retry_attempts: 3,
      claimed: MapSet.new([issue.id])
    }

    retrying =
      Orchestrator.recover_dispatch_revalidation_for_test(
        {:error, :transport_unavailable},
        state,
        issue,
        1,
        metadata
      )

    assert retrying.retry_attempts[issue.id].attempt == 2
    assert retrying.retry_attempts[issue.id].failure_class == :transient_transport
    assert MapSet.member?(retrying.claimed, issue.id)
    Process.cancel_timer(retrying.retry_attempts[issue.id].timer_ref)

    exhausted =
      Orchestrator.recover_dispatch_revalidation_for_test(
        {:error, :transport_unavailable},
        %{state | max_retry_attempts: 1},
        issue,
        1,
        metadata
      )

    assert exhausted.retry_attempts == %{}
    assert exhausted.blocked[issue.id].terminal_state == :held
    assert exhausted.blocked[issue.id].retry_exhausted

    released =
      Orchestrator.recover_dispatch_revalidation_for_test(
        :missing,
        state,
        issue,
        1,
        metadata
      )

    refute MapSet.member?(released.claimed, issue.id)
  end

  test "durable failure state survives restart and a prepared effect cannot execute twice" do
    alias SymphonyElixir.ExecutionLedger

    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-r2-execution-ledger-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{
      id: "issue-idempotent",
      identifier: "MT-R2-IDEMPOTENT",
      title: "Idempotent effect",
      state: "In Progress",
      url: "https://example.org/issues/MT-R2-IDEMPOTENT"
    }

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
    end)

    terminal = %{
      issue.id => %{
        issue: issue,
        identifier: issue.identifier,
        issue_url: issue.url,
        error: "permanent admission failure",
        failure_class: :permanent_admission,
        terminal_state: :permanent,
        transition: :terminal,
        attempt: 1,
        blocked_at: DateTime.utc_now()
      }
    }

    due_at = DateTime.add(DateTime.utc_now(), 60, :second)

    retrying = %{
      issue.id => %{
        identifier: issue.identifier,
        attempt: 2,
        failure_class: :transient_transport,
        delay_type: :backoff,
        transition: :retrying,
        due_at: due_at
      },
      "issue-restart-transient" => %{
        identifier: "MT-R2-RESTART-TRANSIENT",
        attempt: 2,
        failure_class: :transient_transport,
        delay_type: :backoff,
        transition: :retrying,
        due_at: due_at
      },
      "issue-restart-continuation" => %{
        identifier: "MT-R2-RESTART-CONTINUATION",
        attempt: 1,
        failure_class: nil,
        delay_type: :continuation,
        transition: :retrying,
        due_at: due_at
      }
    }

    assert {:ok, effects, prepared} = ExecutionLedger.reserve_effect(%{}, issue, 1)
    assert prepared.status == :prepared
    assert :ok = ExecutionLedger.persist(root, terminal, retrying, effects)

    assert {:ok, restored} = ExecutionLedger.load(root)
    assert restored.blocked[issue.id].failure_class == :permanent_admission
    assert restored.blocked[issue.id].terminal_state == :permanent
    assert restored.retrying["issue-restart-transient"].attempt == 2
    assert restored.retrying["issue-restart-transient"].failure_class == :transient_transport
    assert restored.retrying["issue-restart-transient"].delay_type == :backoff
    assert restored.retrying["issue-restart-continuation"].failure_class == nil
    assert restored.retrying["issue-restart-continuation"].delay_type == :continuation

    assert {:duplicate, duplicate} =
             ExecutionLedger.reserve_effect(restored.effects, issue, 1)

    assert duplicate.idempotency_key == prepared.idempotency_key

    recovered = Orchestrator.recover_ambiguous_effects_for_test(restored)
    assert recovered.blocked[issue.id].failure_class == :operator_decision_required
    assert recovered.blocked[issue.id].terminal_state == :held
    refute Map.has_key?(recovered.retrying, issue.id)
    assert Map.has_key?(recovered.retrying, "issue-restart-transient")
    assert Map.has_key?(recovered.retrying, "issue-restart-continuation")
  end

  test "execution ledger persists structural identity without issue body or raw failure text" do
    alias SymphonyElixir.ExecutionLedger

    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-r2-execution-ledger-redaction-#{System.unique_integer([:positive])}"
      )

    secret_sentinel = "sk_live_R2_LEDGER_SENTINEL"

    issue = %Issue{
      id: "issue-ledger-redaction",
      identifier: "MT-R2-LEDGER-REDACTION",
      title: "Title #{secret_sentinel}",
      description: "Description #{secret_sentinel}",
      state: "In Progress",
      url: "https://example.org/issues/MT-R2-LEDGER-REDACTION",
      labels: ["symphony", secret_sentinel],
      assigned_to_worker: true
    }

    terminal = %{
      issue.id => %{
        issue: issue,
        identifier: issue.identifier,
        issue_url: issue.url,
        error: "transport response #{secret_sentinel}",
        failure_class: :permanent_contract,
        terminal_state: :permanent,
        transition: :terminal,
        attempt: 1,
        blocked_at: DateTime.utc_now()
      }
    }

    retrying = %{
      "issue-retry-redaction" => %{
        identifier: "MT-R2-RETRY-REDACTION",
        error: "retry response #{secret_sentinel}",
        attempt: 2,
        failure_class: :transient_transport,
        delay_type: :backoff,
        transition: :retrying,
        due_at: DateTime.add(DateTime.utc_now(), 60, :second)
      }
    }

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, effects, _prepared} = ExecutionLedger.reserve_effect(%{}, issue, 1)
    assert :ok = ExecutionLedger.persist(root, terminal, retrying, effects)

    ledger_path = Path.join([root, ".symphony-state", "execution.json"])
    raw_ledger = File.read!(ledger_path)

    refute raw_ledger =~ secret_sentinel
    refute raw_ledger =~ "\"description\""
    refute raw_ledger =~ "\"title\""
    refute raw_ledger =~ "\"labels\""
    assert raw_ledger =~ "execution_terminal:permanent_contract"
    assert raw_ledger =~ "execution_backoff:transient_transport"

    assert {:ok, restored} = ExecutionLedger.load(root)
    refute inspect(restored) =~ secret_sentinel
    assert restored.blocked[issue.id].error == "execution_terminal:permanent_contract"

    assert restored.retrying["issue-retry-redaction"].error ==
             "execution_backoff:transient_transport"
  end

  test "dispatch reservation write failure blocks before any worker starts" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-r2-ledger-write-failure-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{
      id: "issue-ledger-write-failure",
      identifier: "MT-R2-LEDGER-WRITE-FAILURE",
      title: "Do not launch without a durable reservation",
      state: "In Progress",
      assigned_to_worker: true
    }

    File.write!(root, "this path is deliberately a file")
    on_exit(fn -> File.rm_rf(root) end)

    state = %Orchestrator.State{
      workspace_root: root,
      execution_ledger_healthy: true,
      max_retry_attempts: 3
    }

    blocked =
      Orchestrator.spawn_issue_on_worker_host_for_test(
        state,
        issue,
        1,
        nil
      )

    assert blocked.running == %{}
    assert [prepared_effect] = Map.values(blocked.effects)
    assert prepared_effect.issue_id == issue.id
    assert prepared_effect.status == :prepared
    assert blocked.execution_ledger_healthy == false
    assert blocked.blocked[issue.id].failure_class == :unknown_fail_closed
    assert blocked.blocked[issue.id].terminal_state == :permanent
    assert blocked.blocked[issue.id].error == "unable to durably reserve dispatch"
    assert MapSet.member?(blocked.claimed, issue.id)
  end

  test "execution ledger recovers valid generations and fails closed when both are invalid" do
    alias SymphonyElixir.ExecutionLedger

    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-r2-execution-ledger-generations-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{
      id: "issue-generation-safety",
      identifier: "MT-R2-GENERATION",
      title: "Generation safety",
      state: "In Progress"
    }

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, effects, prepared} = ExecutionLedger.reserve_effect(%{}, issue, 1)
    assert :ok = ExecutionLedger.persist(root, %{}, %{}, effects)
    assert {:ok, started_effects} = ExecutionLedger.mark_effect_started(effects, prepared.idempotency_key)
    assert :ok = ExecutionLedger.persist(root, %{}, %{}, started_effects)

    assert {:ok, completed_effects} =
             ExecutionLedger.mark_effect_completed(started_effects, prepared.idempotency_key)

    terminal = %{
      issue.id => %{
        issue: issue,
        identifier: issue.identifier,
        failure_class: :permanent_contract,
        terminal_state: :permanent,
        transition: :terminal,
        attempt: 1,
        blocked_at: DateTime.utc_now()
      }
    }

    assert :ok = ExecutionLedger.persist(root, terminal, %{}, completed_effects)

    state_root = Path.join(root, ".symphony-state")
    current = Path.join(state_root, "execution.json")
    previous = Path.join(state_root, "execution.previous.json")

    valid_previous = File.read!(previous)
    payload = Jason.decode!(valid_previous)
    [effect] = payload["effects"]

    invalid_current_generations = [
      {"corrupt JSON", "{"},
      {"truncated JSON", binary_part(valid_previous, 0, div(byte_size(valid_previous), 2))},
      {"schema-invalid JSON", Jason.encode!(%{"schema_version" => "unknown"})},
      {"duplicate execution entry", payload |> Map.put("effects", [effect, effect]) |> Jason.encode!()},
      {"invalid legacy entry",
       Jason.encode!(%{
         "schema_version" => "symphony.execution_ledger.v1",
         "blocked" => [
           %{
             "issue_id" => issue.id,
             "attempt" => "not-an-integer",
             "blocked_at" => DateTime.to_iso8601(DateTime.utc_now())
           }
         ]
       })}
    ]

    for {kind, invalid_current} <- invalid_current_generations do
      File.write!(current, invalid_current)
      assert {:ok, restored} = ExecutionLedger.load(root), kind
      assert restored.effects[prepared.idempotency_key].status == :started

      recovered = Orchestrator.recover_ambiguous_effects_for_test(restored)
      assert recovered.blocked[issue.id].terminal_state == :held
      assert recovered.blocked[issue.id].failure_class == :operator_decision_required
    end

    File.rm!(current)
    File.mkdir!(current)
    assert {:ok, restored_from_unreadable_current} = ExecutionLedger.load(root)
    assert restored_from_unreadable_current.effects[prepared.idempotency_key].status == :started
    File.rmdir!(current)

    File.write!(current, "{")
    File.write!(previous, "{")

    assert {:error, {:invalid_execution_generations, {:invalid_execution_ledger, _current_reason}, {:invalid_execution_ledger, _previous_reason}}} = ExecutionLedger.load(root)

    File.write!(previous, valid_previous)

    invalid_legacy_payload = %{
      "schema_version" => "symphony.execution_ledger.v1",
      "blocked" => [
        %{
          "issue_id" => issue.id,
          "attempt" => "not-an-integer",
          "blocked_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
      ]
    }

    File.write!(current, Jason.encode!(invalid_legacy_payload))
    assert {:ok, _restored_from_previous} = ExecutionLedger.load(root)
  end

  test "execution ledger generation transitions preserve a recoverable synced state" do
    alias SymphonyElixir.ExecutionLedger

    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-r2-execution-ledger-crash-states-#{System.unique_integer([:positive])}"
      )

    issue = %Issue{
      id: "issue-crash-state-safety",
      identifier: "MT-R2-CRASH-STATE",
      title: "Generation crash state",
      state: "In Progress"
    }

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, effects, prepared} = ExecutionLedger.reserve_effect(%{}, issue, 1)
    assert :ok = ExecutionLedger.persist(root, %{}, %{}, effects)
    assert {:ok, started_effects} = ExecutionLedger.mark_effect_started(effects, prepared.idempotency_key)
    assert :ok = ExecutionLedger.persist(root, %{}, %{}, started_effects)

    state_root = Path.join(root, ".symphony-state")
    current = Path.join(state_root, "execution.json")
    previous = Path.join(state_root, "execution.previous.json")
    temporary = Path.join(state_root, "execution.json.tmp-crash-simulation")
    valid_current = File.read!(current)
    valid_previous = File.read!(previous)

    # Crash after syncing the new temporary generation but before rotation.
    File.write!(temporary, valid_current)
    assert {:ok, before_rotation} = ExecutionLedger.load(root)
    assert before_rotation.effects[prepared.idempotency_key].status == :started

    # Crash after removing an older previous generation but before rotating current.
    File.rm!(previous)
    assert {:ok, after_previous_removal} = ExecutionLedger.load(root)
    assert after_previous_removal.effects[prepared.idempotency_key].status == :started

    # Crash after rotating current to previous but before installing the temporary generation.
    File.rename!(current, previous)
    assert {:ok, after_rotation} = ExecutionLedger.load(root)
    assert after_rotation.effects[prepared.idempotency_key].status == :started

    # Crash after installing a new current but before its directory-sync boundary.
    File.rename!(temporary, current)
    assert {:ok, after_install} = ExecutionLedger.load(root)
    assert after_install.effects[prepared.idempotency_key].status == :started

    # A torn installed current still recovers the last synced previous generation.
    File.write!(current, "{")
    assert {:ok, after_torn_install} = ExecutionLedger.load(root)
    assert after_torn_install.effects[prepared.idempotency_key].status == :started

    # Restore the older generation to prove the fixture itself retained both states.
    File.write!(previous, valid_previous)
    assert {:ok, _restored} = ExecutionLedger.load(root)
  end

  test "an ambiguous dispatch effect remains held and cannot receive a new sequence" do
    alias SymphonyElixir.ExecutionLedger

    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue = %Issue{
      id: "issue-ambiguous-effect",
      identifier: "MT-R2-AMBIGUOUS",
      title: "Ambiguous dispatch effect",
      state: "In Progress",
      labels: ["symphony"],
      assigned_to_worker: true
    }

    assert {:ok, effects, prepared} = ExecutionLedger.reserve_effect(%{}, issue, 1)

    hidden_state = %Orchestrator.State{
      max_concurrent_agents: 1,
      effects: effects,
      claimed: MapSet.new(),
      blocked: %{},
      running: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, hidden_state)

    blocked_state = %{
      hidden_state
      | claimed: MapSet.new([issue.id]),
        blocked: %{
          issue.id => %{
            issue: issue,
            identifier: issue.identifier,
            failure_class: :operator_decision_required,
            terminal_state: :held,
            idempotency_key: prepared.idempotency_key,
            blocked_at: DateTime.utc_now()
          }
        }
    }

    opted_out_issue = %{issue | labels: []}

    reconciled =
      Orchestrator.reconcile_blocked_issue_states_for_test([opted_out_issue], blocked_state)

    assert MapSet.member?(reconciled.claimed, issue.id)
    assert reconciled.blocked[issue.id].idempotency_key == prepared.idempotency_key

    agent_pid = spawn(fn -> Process.sleep(:infinity) end)
    agent_ref = Process.monitor(agent_pid)

    running_state = %{
      hidden_state
      | claimed: MapSet.new([issue.id]),
        running: %{
          issue.id => %{
            pid: agent_pid,
            ref: agent_ref,
            issue: issue,
            identifier: issue.identifier,
            retry_attempt: 1,
            idempotency_key: prepared.idempotency_key,
            started_at: DateTime.utc_now()
          }
        }
    }

    stopped = Orchestrator.reconcile_issue_states_for_test([opted_out_issue], running_state)

    refute Process.alive?(agent_pid)
    assert stopped.blocked[issue.id].failure_class == :operator_decision_required
    assert stopped.blocked[issue.id].terminal_state == :held
    assert MapSet.member?(stopped.claimed, issue.id)
  end

  test "execution ledger refuses a state-directory symlink escape" do
    if match?({:win32, _name}, :os.type()) do
      :ok
    else
      alias SymphonyElixir.ExecutionLedger

      root =
        Path.join(
          System.tmp_dir!(),
          "symphony-r2-execution-ledger-root-#{System.unique_integer([:positive])}"
        )

      outside =
        Path.join(
          System.tmp_dir!(),
          "symphony-r2-execution-ledger-outside-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(root, ".symphony-state"))

      on_exit(fn ->
        File.rm_rf(root)
        File.rm_rf(outside)
      end)

      assert {:error, {:execution_ledger_outside_workspace, _path}} =
               ExecutionLedger.load(root)
    end
  end

  test "crash before a dispatch receipt preserves the idempotency reservation" do
    alias SymphonyElixir.ExecutionLedger

    issue = %Issue{
      id: "issue-crash-before-receipt",
      identifier: "MT-R2-CRASH-RECEIPT",
      title: "Preserve ambiguous dispatch",
      state: "In Progress",
      url: "https://example.org/issues/MT-R2-CRASH-RECEIPT"
    }

    assert {:ok, effects, prepared} = ExecutionLedger.reserve_effect(%{}, issue, 1)
    assert {:ok, started_effects} = ExecutionLedger.mark_effect_started(effects, prepared.idempotency_key)

    orchestrator_name = Module.concat(__MODULE__, :CrashBeforeReceiptOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    ref = make_ref()

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      retry_attempt: 1,
      idempotency_key: prepared.idempotency_key,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{issue.id => running_entry},
          claimed: MapSet.put(state.claimed, issue.id),
          effects: started_effects
      }
    end)

    send(pid, {:DOWN, ref, :process, self(), :untyped_crash})
    assert is_map(Orchestrator.snapshot(orchestrator_name, 5_000))

    state = :sys.get_state(pid)
    assert state.effects[prepared.idempotency_key].status == :started
    refute Map.has_key?(state.retry_attempts, issue.id)
    assert state.blocked[issue.id].failure_class == :unknown_fail_closed
    assert state.blocked[issue.id].terminal_state == :permanent

    assert {:duplicate, duplicate} =
             ExecutionLedger.reserve_effect(state.effects, issue, prepared.attempt)

    assert duplicate.idempotency_key == prepared.idempotency_key
  end
end
