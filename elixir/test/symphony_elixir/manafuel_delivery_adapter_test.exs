defmodule SymphonyElixir.Manafuel.DeliveryAdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Manafuel.DeliveryAdapter
  alias SymphonyElixir.Tracker.Issue

  @issue_id "8c37d4b2-7cb3-4e6f-9af0-87b410b74a23"
  @initial_head String.duplicate("a", 40)
  @model_head String.duplicate("b", 40)
  @workspace_root Path.join(System.tmp_dir!(), "manafuel-delivery-adapter")

  test "prepares one clean issue-local repository without running a candidate or mutating it" do
    assert {:ok, delivery_run} =
             DeliveryAdapter.prepare(admitted_run(), issue(), @workspace_root, 0, client())

    assert delivery_run == %{
             linear_issue_id: @issue_id,
             issue_identifier: "MT-42",
             experiment_key: "growth-experiment-42",
             repository: "development",
             repository_full_name: "manafuel/development",
             issue_root: Path.join(@workspace_root, "MT-42"),
             repository_path: Path.join([@workspace_root, "MT-42", "development"]),
             branch: "codex/mt-42",
             base_sha: @initial_head,
             initial_head_sha: @initial_head,
             attempt: 0
           }

    assert_received {:delivery_call, :prepare_repository, "manafuel/development", "codex/mt-42", @workspace_root, 0}
    assert_received {:delivery_call, :list_pull_requests, "manafuel/development", "codex/mt-42"}
    refute_received {:delivery_call, :candidate, _}
    refute_received {:delivery_call, :commit, _}
    refute_received {:delivery_call, :push, _, _}
  end

  test "returns waiting before runtime when one matching open pull request already exists" do
    matching_pr = %{
      number: 42,
      head_sha: @initial_head,
      base: "main",
      state: "open",
      url: "https://github.com/manafuel/development/pull/42"
    }

    client = client(list_pull_requests: fn _repository, _branch -> {:ok, [matching_pr]} end)

    assert {:waiting, %{pull_request: ^matching_pr, delivery_run: delivery_run}} =
             DeliveryAdapter.prepare(admitted_run(), issue(), @workspace_root, 0, client)

    assert delivery_run.initial_head_sha == @initial_head
    refute_received {:delivery_call, :candidate, _}
    refute_received {:delivery_call, :commit, _}
  end

  test "delivers one model-created commit through exactly one push, pull request, artifact, and reconciliation" do
    assert {:ok, delivery_run} =
             DeliveryAdapter.prepare(admitted_run(), issue(), @workspace_root, 0, client())

    assert {:ok, result} = DeliveryAdapter.deliver(delivery_run, client())

    assert result == %{
             pull_request: %{
               number: 42,
               head_sha: @model_head,
               base: "main",
               state: "open",
               url: "https://github.com/manafuel/development/pull/42"
             },
             artifact: %{
               "authority" => "github",
               "kind" => "pull-request",
               "native_id" => "manafuel/development#42",
               "uri" => "https://github.com/manafuel/development/pull/42"
             },
             linear_state: "Merging"
           }

    assert_received {:delivery_call, :candidate, ^delivery_run}
    assert_received {:delivery_call, :commit, ^delivery_run}
    assert_received {:delivery_call, :remote_head, ^delivery_run}
    assert_received {:delivery_call, :push, ^delivery_run, @model_head}
    assert_received {:delivery_call, :list_pull_requests, "manafuel/development", "codex/mt-42"}
    assert_received {:delivery_call, :create_pull_request, ^delivery_run, @model_head}
    assert_received {:delivery_call, :enable_auto_merge, ^delivery_run, 42}

    assert_received {:delivery_call, :attach_growth_initiative_artifact_v1, "growth-experiment-42",
                     %{
                       "authority" => "github",
                       "kind" => "pull-request",
                       "native_id" => "manafuel/development#42",
                       "uri" => "https://github.com/manafuel/development/pull/42"
                     }}

    assert_received {:delivery_call, :reconcile_linear, @issue_id, 42, "Merging"}
  end

  test "fails before push when the remote branch head is stale" do
    assert {:ok, delivery_run} =
             DeliveryAdapter.prepare(admitted_run(), issue(), @workspace_root, 0, client())

    client =
      client(
        remote_head: fn run ->
          send(self(), {:delivery_call, :remote_head, run})
          {:ok, String.duplicate("c", 40)}
        end
      )

    assert {:error, :stale_pr_head} = DeliveryAdapter.deliver(delivery_run, client)
    assert_received {:delivery_call, :candidate, ^delivery_run}
    assert_received {:delivery_call, :commit, ^delivery_run}
    assert_received {:delivery_call, :remote_head, ^delivery_run}
    refute_received {:delivery_call, :push, _, _}
    refute_received {:delivery_call, :create_pull_request, _, _}
  end

  test "rejects an unsafe repository state before candidate or runtime handoff" do
    unsafe = Map.put(repository_state(), :clean, false)
    client = client(prepare_repository: fn _repository, _branch, _workspace_root, _attempt -> {:ok, unsafe} end)

    assert {:error, :unsafe_repository} =
             DeliveryAdapter.prepare(admitted_run(), issue(), @workspace_root, 0, client)

    refute_received {:delivery_call, :candidate, _}
    refute_received {:delivery_call, :commit, _}
  end

  defp admitted_run do
    %{
      linear_issue_id: @issue_id,
      experiment_key: "growth-experiment-42",
      agent_id: "implementation-worker",
      repository: "development",
      repository_artifact: %{"authority" => "github", "kind" => "repository", "native_id" => "manafuel/development"},
      status: "proposed",
      manifest: manifest()
    }
  end

  defp issue do
    %Issue{
      id: @issue_id,
      identifier: "MT-42",
      title: "Deliver an admitted run",
      description: "<!-- manafuel-agent-binding:v1 initiative_id=growth-experiment-42 agent_id=implementation-worker -->",
      state: "In Progress",
      dispatchable: true
    }
  end

  defp repository_state do
    %{
      issue_root: Path.join(@workspace_root, "MT-42"),
      repository_path: Path.join([@workspace_root, "MT-42", "development"]),
      base_sha: @initial_head,
      head_sha: @initial_head,
      origin: "https://github.com/manafuel/development.git",
      origin_main: @initial_head,
      internal_git: true,
      clean: true,
      contained: true,
      nonreparse: true
    }
  end

  defp client(overrides \\ []) do
    defaults = %{
      prepare_repository: fn repository, branch, workspace_root, attempt ->
        send(self(), {:delivery_call, :prepare_repository, repository, branch, workspace_root, attempt})
        {:ok, repository_state()}
      end,
      candidate: fn delivery_run ->
        send(self(), {:delivery_call, :candidate, delivery_run})
        :ok
      end,
      commit: fn delivery_run ->
        send(self(), {:delivery_call, :commit, delivery_run})
        {:ok, @model_head}
      end,
      remote_head: fn delivery_run ->
        send(self(), {:delivery_call, :remote_head, delivery_run})
        {:ok, nil}
      end,
      push: fn delivery_run, head_sha ->
        send(self(), {:delivery_call, :push, delivery_run, head_sha})
        :ok
      end,
      list_pull_requests: fn repository, branch ->
        send(self(), {:delivery_call, :list_pull_requests, repository, branch})
        {:ok, []}
      end,
      create_pull_request: fn delivery_run, head_sha ->
        send(self(), {:delivery_call, :create_pull_request, delivery_run, head_sha})

        {:ok,
         %{
           number: 42,
           head_sha: head_sha,
           base: "main",
           state: "open",
           url: "https://github.com/manafuel/development/pull/42"
         }}
      end,
      enable_auto_merge: fn delivery_run, number ->
        send(self(), {:delivery_call, :enable_auto_merge, delivery_run, number})
        :ok
      end,
      attach_growth_initiative_artifact_v1: fn experiment_key, artifact ->
        send(self(), {:delivery_call, :attach_growth_initiative_artifact_v1, experiment_key, artifact})
        :ok
      end,
      reconcile_linear: fn linear_issue_id, number, state ->
        send(self(), {:delivery_call, :reconcile_linear, linear_issue_id, number, state})
        :ok
      end
    }

    Map.merge(defaults, Map.new(overrides))
  end

  defp manifest do
    %{
      "version" => "manafuel.agent-manifest.v2",
      "agent_id" => "implementation-worker",
      "model" => "gpt-5.6-terra",
      "reasoning_effort" => "medium",
      "sandbox" => %{"mode" => "workspace-write", "network_access" => false},
      "approval_policy" => "never",
      "tool_mode" => "code_mode_only",
      "tools" => ["exec", "wait"],
      "code_mode_nested_tools" => ["shell_command", "apply_patch"],
      "skills" => ["manafuel-control", "implementation-system", "frontend-system", "fullstack-api", "testing"],
      "capabilities" => ["repo-write", "repository.patch", "local-validation.run"],
      "credential_profile" => "none",
      "repository_roots" => [
        %{
          "token" => "ASSIGNED_REPOSITORY",
          "access" => "task-tracked",
          "allowlist" => "task-tracked-allowlist"
        }
      ],
      "output_contract" => %{
        "format" => "json",
        "schema_path" => "output-contracts/implementation-result.v1.schema.json"
      },
      "concurrency" => 1,
      "no_auto_subagents" => true
    }
  end
end
