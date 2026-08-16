defmodule SymphonyElixir.Manafuel.RuntimeAdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Manafuel.RuntimeAdapter

  @skills ["manafuel-control", "implementation-system", "frontend-system", "fullstack-api", "testing"]

  test "validates the bounded protocol in order and returns a sanitized session" do
    fixture = fixture()
    workspace_root = fixture.workspace_root
    {client_pid, client} = fake_client(successful_transcript(fixture))

    assert {:ok, session} = RuntimeAdapter.open_validated(fixture.admitted_run, fixture.context, client)

    assert session.transport == :fake_transport
    assert session.thread_id == "018f47c4-2a31-7c8b-9c23-17c05e5678ab"
    assert session.repository == "one"
    assert session.workspace_root == fixture.workspace_root

    assert session.effective_runtime.attestation == %{
             kind: "source_derived",
             codex_version: "0.147.0",
             tool_mode: "code_mode_only",
             tools: ["exec", "wait"],
             nested_tools: ["shell_command", "apply_patch"],
             credential_profile: "none",
             no_auto_subagents: true
           }

    assert session.effective_runtime.sandbox == %{
             type: "workspaceWrite",
             network_access: false,
             writable_roots: [],
             exclude_tmpdir_env_var: false,
             exclude_slash_tmp: false
           }

    assert session.effective_runtime.service_tier == nil

    refute Map.has_key?(session, :env)
    refute inspect(session) =~ "runtime-secret"

    assert [
             {:open, executable, launch_options, 10_000},
             {:request, :fake_transport, 1, "initialize", initialize, 10_000},
             {:request, :fake_transport, :notification, "initialized", :omit, 10_000},
             {:request, :fake_transport, 2, "account/read", %{"refreshToken" => false}, 10_000},
             {:request, :fake_transport, 3, "model/list", %{"includeHidden" => true, "limit" => 100}, 10_000},
             {:request, :fake_transport, 4, "environment/status", %{"environmentId" => "local"}, 10_000},
             {:request, :fake_transport, 5, "environment/info", %{"environmentId" => "local"}, 10_000},
             {:request, :fake_transport, 6, "skills/list", %{"cwds" => [^workspace_root], "forceReload" => true}, 10_000},
             {:request, :fake_transport, 7, "hooks/list", %{"cwds" => [^workspace_root]}, 10_000},
             {:request, :fake_transport, 8, "permissionProfile/list", %{"cwd" => ^workspace_root, "limit" => 100}, 10_000},
             {:request, :fake_transport, 9, "thread/start", thread_params, 10_000},
             {:request, :fake_transport, 10, "experimentalFeature/list", %{"limit" => 100, "threadId" => "018f47c4-2a31-7c8b-9c23-17c05e5678ab"}, 10_000},
             {:request, :fake_transport, 11, "mcpServerStatus/list", %{"limit" => 100, "threadId" => "018f47c4-2a31-7c8b-9c23-17c05e5678ab"}, 10_000}
           ] = events(client_pid)

    assert executable == fixture.context.codex_executable

    assert launch_options == %{
             argv: ["-c", "skills.bundled.enabled=false", "app-server", "--listen", "stdio://"],
             cwd: fixture.workspace_root,
             env: fixture.context.env,
             max_frame_bytes: 1_048_576,
             max_noise_frames: 256
           }

    assert initialize == initialize_params()
    assert thread_params == thread_start_params(fixture)

    assert :ok = RuntimeAdapter.close(session, client)
    assert one_close?(client_pid)
  end

  test "rejects v2 admission drifts before opening a transport" do
    fixture = fixture()

    drifts = [
      :invalid,
      Map.put(fixture.admitted_run, :linear_issue_id, "4C3DFDE2-8C4D-4D46-8DC6-E633BB0ED226"),
      Map.put(fixture.admitted_run, :experiment_key, ""),
      Map.put(fixture.admitted_run, :agent_id, "implementation-debugger"),
      Map.put(fixture.admitted_run, :repository, "development"),
      Map.put(fixture.admitted_run, :repository_artifact, %{"authority" => "github", "kind" => "repository", "native_id" => "manafuel/development"}),
      Map.put(fixture.admitted_run, :status, "complete"),
      Map.delete(fixture.admitted_run, :status),
      Map.put(fixture.admitted_run, :extra, true),
      Map.put(fixture.admitted_run, :manifest, Map.put(fixture.admitted_run.manifest, "version", "manafuel.agent-manifest.v1")),
      Map.put(fixture.admitted_run, :manifest, Map.delete(fixture.admitted_run.manifest, "tool_mode")),
      Map.put(fixture.admitted_run, :manifest, Map.put(fixture.admitted_run.manifest, "tool_mode", "code-mode-only")),
      Map.put(fixture.admitted_run, :manifest, Map.put(fixture.admitted_run.manifest, "tools", ["shell_command", "apply_patch"])),
      Map.put(fixture.admitted_run, :manifest, Map.put(fixture.admitted_run.manifest, "tools", ["wait", "exec"])),
      Map.put(fixture.admitted_run, :manifest, Map.put(fixture.admitted_run.manifest, "tools", ["exec"])),
      Map.put(fixture.admitted_run, :manifest, Map.put(fixture.admitted_run.manifest, "tools", ["exec", "wait", "shell_command"])),
      Map.put(fixture.admitted_run, :manifest, Map.put(fixture.admitted_run.manifest, "code_mode_nested_tools", nil)),
      Map.put(fixture.admitted_run, :manifest, Map.put(fixture.admitted_run.manifest, "code_mode_nested_tools", "shell_command")),
      Map.put(fixture.admitted_run, :manifest, Map.put(fixture.admitted_run.manifest, "code_mode_nested_tools", ["apply_patch", "shell_command"])),
      Map.put(fixture.admitted_run, :manifest, Map.put(fixture.admitted_run.manifest, "unknown", true))
    ]

    every_manifest_field =
      Enum.map(fixture.admitted_run.manifest, fn {key, _value} ->
        Map.put(fixture.admitted_run, :manifest, Map.put(fixture.admitted_run.manifest, key, {:drift, key}))
      end)

    for admitted_run <- drifts ++ every_manifest_field do
      {client_pid, client} = fake_client([])
      assert {:error, :invalid_admission} = RuntimeAdapter.open_validated(admitted_run, fixture.context, client)
      refute Enum.any?(events(client_pid), &match?({:open, _, _, _}, &1))
    end
  end

  test "maps bounded open and callback failures without raw failures" do
    fixture = fixture()

    for {open_result, expected} <- [
          {{:error, :timeout}, :runtime_timeout},
          {{:error, :launch_failed}, :runtime_open_failed},
          {:unexpected, :runtime_open_failed}
        ] do
      {client_pid, client} = fake_client([], open_result: open_result)
      assert {:error, ^expected} = RuntimeAdapter.open_validated(fixture.admitted_run, fixture.context, client)
      refute one_close?(client_pid)
    end

    {client_pid, client} = fake_client([{:raise, RuntimeError.exception("runtime-secret")}])
    assert {:error, :runtime_protocol_error} = open_run(fixture, client)
    assert one_close?(client_pid)

    {client_pid, client} = fake_client([{:throw, :runtime_secret}])
    assert {:error, :runtime_protocol_error} = open_run(fixture, client)
    assert one_close?(client_pid)

    notification_failure =
      successful_transcript(fixture)
      |> List.replace_at(1, {:raise, RuntimeError.exception("notification-secret")})

    {client_pid, client} = fake_client(notification_failure)
    assert {:error, :runtime_protocol_error} = open_run(fixture, client)
    assert one_close?(client_pid)
  end

  test "rejects closed runtime-context substitutions before opening a transport" do
    fixture = fixture()
    outside_instruction = Path.join(fixture.root, "outside.md")
    inner_home = Path.join(fixture.workspace_root, "inner-home")
    direct_child_skill = Path.join(fixture.context.codex_home, "manafuel-control")
    system_skill = Path.join(fixture.skills_home, ".system")
    substitute_skill = Path.join(fixture.skills_home, "substitute")
    duplicated_instructions = List.duplicate(hd(fixture.instruction_paths), 2)
    invalid_timeouts = %{open: 1, request: 10_000, close: 5_000, total: 60_000}
    File.write!(outside_instruction, "outside")
    File.mkdir_p!(inner_home)

    Enum.each([direct_child_skill, system_skill, substitute_skill], fn skill_root ->
      File.mkdir_p!(skill_root)
      File.write!(Path.join(skill_root, "SKILL.md"), "skill")
    end)

    variants = [
      {%{fixture.context | repository: "development"}, :invalid_runtime_context},
      {Map.delete(fixture.context, :env), :invalid_runtime_context},
      {Map.put(fixture.context, :extra, true), :invalid_runtime_context},
      {%{fixture.context | workspace_root: nil}, :unsafe_path},
      {%{fixture.context | workspace_root: Path.join(fixture.root, "missing")}, :unsafe_path},
      {%{fixture.context | codex_home: fixture.workspace_root}, :unsafe_path},
      {%{fixture.context | codex_home: inner_home}, :unsafe_path},
      {%{fixture.context | codex_executable: nil}, :unsafe_path},
      {%{fixture.context | codex_executable: fixture.workspace_root}, :unsafe_path},
      {%{fixture.context | codex_executable: Path.join(fixture.context.codex_install_root, "wrapper.cmd")}, :unsafe_path},
      {%{fixture.context | codex_install_root: fixture.workspace_root}, :unsafe_path},
      {%{fixture.context | expected_sha256: "ABC"}, :invalid_runtime_context},
      {%{fixture.context | expected_sha256: String.duplicate("0", 64)}, :unsafe_path},
      {%{fixture.context | argv: ["app-server"]}, :invalid_runtime_context},
      {%{fixture.context | env: %{"CODEX_HOME" => fixture.context.codex_home, "OPENAI_API_KEY" => "runtime-secret"}}, :forbidden_launch_environment},
      {%{fixture.context | env: %{"CODEX_HOME" => fixture.context.codex_home, "HTTP_PROXY" => "http://proxy"}}, :forbidden_launch_environment},
      {%{fixture.context | env: %{"CODEX_HOME" => fixture.context.codex_home, "UNLISTED" => "value"}}, :forbidden_launch_environment},
      {%{fixture.context | env: %{"CODEX_HOME" => fixture.workspace_root}}, :forbidden_launch_environment},
      {%{fixture.context | env: :not_a_map}, :forbidden_launch_environment},
      {%{fixture.context | skill_roots: Enum.take(fixture.skill_roots, 4)}, :invalid_runtime_context},
      {%{fixture.context | skill_roots: List.duplicate(hd(fixture.skill_roots), 5)}, :invalid_runtime_context},
      {%{fixture.context | skill_roots: [Path.join(fixture.root, "missing-skill") | tl(fixture.skill_roots)]}, :unsafe_path},
      {%{fixture.context | skill_roots: [direct_child_skill | tl(fixture.skill_roots)]}, :unsafe_path},
      {%{fixture.context | skill_roots: [system_skill | tl(fixture.skill_roots)]}, :unsafe_path},
      {%{fixture.context | skill_roots: [substitute_skill | tl(fixture.skill_roots)]}, :unsafe_path},
      {%{fixture.context | skill_roots: :not_a_list}, :invalid_runtime_context},
      {%{fixture.context | instruction_paths: []}, :invalid_runtime_context},
      {%{fixture.context | instruction_paths: duplicated_instructions}, :invalid_runtime_context},
      {%{fixture.context | instruction_paths: [outside_instruction]}, :unsafe_path},
      {%{fixture.context | instruction_paths: [Path.join(fixture.workspace_root, "missing.md")]}, :unsafe_path},
      {%{fixture.context | instruction_paths: :not_a_list}, :invalid_runtime_context},
      {%{fixture.context | timeouts: invalid_timeouts}, :invalid_runtime_context}
    ]

    for {context, expected} <- variants do
      {client_pid, client} = fake_client([])
      assert {:error, ^expected} = RuntimeAdapter.open_validated(fixture.admitted_run, context, client)
      refute Enum.any?(events(client_pid), &match?({:open, _, _, _}, &1))
    end

    {client_pid, _client} = fake_client([])

    assert {:error, :invalid_runtime_context} =
             open_run(fixture.admitted_run, :not_a_map, :not_a_client)

    refute Enum.any?(events(client_pid), &match?({:open, _, _, _}, &1))

    {client_pid, _client} = fake_client([])

    assert {:error, :invalid_runtime_context} =
             open_run(fixture.admitted_run, fixture.context, :not_a_client)

    refute Enum.any?(events(client_pid), &match?({:open, _, _, _}, &1))
  end

  test "maps each protocol stage mismatch and closes an opened transport once" do
    fixture = fixture()

    failures = [
      {0, response(1, %{}), :runtime_version_mismatch},
      {1, {:error, :timeout}, :runtime_timeout},
      {2, response(2, %{"requiresOpenaiAuth" => false, "type" => "api"}), :auth_mismatch},
      {3, response(3, page("models", [], nil)), :model_mismatch},
      {4, response(4, %{"environmentId" => "local", "status" => "failed", "error" => nil}), :environment_mismatch},
      {5, response(5, %{"environmentId" => "local", "cwd" => "relative", "shell" => "shell"}), :environment_mismatch},
      {6, response(6, %{"cwd" => fixture.workspace_root, "errors" => [], "skills" => []}), :skill_mismatch},
      {7, response(7, %{"cwd" => fixture.workspace_root, "hooks" => ["surprise"], "warnings" => [], "errors" => []}), :extension_mismatch},
      {8, response(8, page("profiles", [], nil)), :permission_profile_mismatch},
      {9, response(9, %{"threadId" => "thread-01"}), :effective_runtime_mismatch},
      {10, response(10, page("features", [%{"name" => "surprise"}], nil)), :extension_mismatch},
      {11, response(11, page("servers", [%{"name" => "surprise"}], nil)), :extension_mismatch}
    ]

    for {index, replacement, expected} <- failures do
      {client_pid, client} = fake_client(List.replace_at(successful_transcript(fixture), index, replacement))
      assert {:error, ^expected} = RuntimeAdapter.open_validated(fixture.admitted_run, fixture.context, client)
      assert one_close?(client_pid)
    end
  end

  test "rejects malformed envelopes, wrong or duplicate ids, oversized frames, noise, EOF and child exit" do
    fixture = fixture()

    envelopes = [
      {:ok, %{}},
      {:ok, %{"frames" => [], "noise" => [], "eof" => false, "exited" => false}},
      {:ok, %{"frames" => [%{"jsonrpc" => "2.0", "id" => 2, "result" => %{}}], "noise" => [], "eof" => false, "exited" => false}},
      {:ok, %{"frames" => List.duplicate(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}, 2), "noise" => [], "eof" => false, "exited" => false}},
      {:ok, %{"frames" => [%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}, "error" => %{"message" => "secret"}}], "noise" => [], "eof" => false, "exited" => false}},
      {:ok, %{"frames" => [%{"jsonrpc" => "2.0", "id" => 1, "result" => {:not_json, :value}}], "noise" => [], "eof" => false, "exited" => false}},
      {:ok, %{"frames" => [%{"id" => 1, "result" => {:not_json, :value}}], "noise" => [], "eof" => false, "exited" => false}},
      {:ok, %{"frames" => [%{"id" => 1, "result" => :not_json}], "noise" => [], "eof" => false, "exited" => false}},
      {:ok,
       %{
         "frames" => [
           %{"jsonrpc" => "2.0", "id" => 1, "result" => String.duplicate("x", 1_048_577)}
         ],
         "noise" => [],
         "eof" => false,
         "exited" => false
       }},
      {:ok, %{"frames" => [%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}], "noise" => List.duplicate("noise", 257), "eof" => false, "exited" => false}},
      {:ok, %{"frames" => [%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}], "noise" => [], "eof" => true, "exited" => false}},
      {:ok, %{"frames" => [%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}], "noise" => [], "eof" => false, "exited" => true}},
      {:error, :timeout},
      {:error, :eof}
    ]

    for envelope <- envelopes do
      {client_pid, client} = fake_client(List.replace_at(successful_transcript(fixture), 0, envelope))
      expected = if envelope === {:error, :timeout}, do: :runtime_timeout, else: :runtime_protocol_error
      assert {:error, ^expected} = RuntimeAdapter.open_validated(fixture.admitted_run, fixture.context, client)
      assert one_close?(client_pid)
    end
  end

  test "rejects pagination cursor loops, malformed cursors, excessive pages and excessive entries" do
    fixture = fixture()
    transcript = successful_transcript(fixture)

    cursor_loop =
      transcript
      |> List.replace_at(3, response(3, page("models", [model()], "next")))
      |> List.insert_at(4, response(4, page("models", [model()], "next")))

    {client_pid, client} = fake_client(cursor_loop)
    assert {:error, :runtime_protocol_error} = open_run(fixture, client)
    assert one_close?(client_pid)

    {client_pid, client} = fake_client(List.replace_at(transcript, 3, response(3, page("models", [model()], ""))))
    assert {:error, :runtime_protocol_error} = open_run(fixture, client)
    assert one_close?(client_pid)

    excessive_pages =
      Enum.take(transcript, 3) ++
        for index <- 0..99 do
          response(index + 3, page("models", [model()], "cursor-#{index}"))
        end

    {client_pid, client} = fake_client(excessive_pages)
    assert {:error, :runtime_protocol_error} = open_run(fixture, client)
    assert one_close?(client_pid)

    too_many = response(3, page("models", List.duplicate(model(), 10_001), nil))
    {client_pid, client} = fake_client(List.replace_at(transcript, 3, too_many))
    assert {:error, :runtime_protocol_error} = open_run(fixture, client)
    assert one_close?(client_pid)
  end

  test "rejects reparse workspace paths when the platform permits creating a symlink" do
    fixture = fixture()
    link = Path.join(fixture.root, "workspace-link")

    case File.ln_s(fixture.workspace_root, link) do
      :ok ->
        {client_pid, client} = fake_client([])
        linked_context = %{fixture.context | workspace_root: link}
        assert {:error, :unsafe_path} = open_run(fixture.admitted_run, linked_context, client)
        refute Enum.any?(events(client_pid), &match?({:open, _, _, _}, &1))

      {:error, _reason} ->
        assert true
    end
  end

  test "closes only sanitized sessions and maps close failures" do
    fixture = fixture()
    {client_pid, client} = fake_client(successful_transcript(fixture), close_result: {:error, :closed})
    assert {:ok, session} = RuntimeAdapter.open_validated(fixture.admitted_run, fixture.context, client)
    assert {:error, :runtime_close_failed} = RuntimeAdapter.close(session, client)
    assert one_close?(client_pid)

    {_client_pid, client} = fake_client([])
    assert {:error, :runtime_close_failed} = RuntimeAdapter.close(%{}, client)
    assert {:error, :runtime_close_failed} = RuntimeAdapter.close(:not_a_session, client)
    assert {:error, :runtime_close_failed} = RuntimeAdapter.close(session, %{})
  end

  test "rejects raw model, skill, permission, and Thread substitutions" do
    fixture = fixture()
    transcript = successful_transcript(fixture)

    model_drifts = [
      page([Map.put(model(), "model", "gpt-5.6-terra-alias")], nil),
      page([model(), model()], nil),
      page([Map.put(model(), "supportedReasoningEfforts", [])], nil),
      page(
        [
          Map.put(model(), "supportedReasoningEfforts", [
            %{"reasoningEffort" => "medium", "description" => "First valid medium description"},
            %{"reasoningEffort" => "medium", "description" => "Second valid medium description"}
          ])
        ],
        nil
      )
    ]

    for drift <- model_drifts do
      {client_pid, client} = fake_client(List.replace_at(transcript, 3, response(3, drift)))
      assert {:error, :model_mismatch} = RuntimeAdapter.open_validated(fixture.admitted_run, fixture.context, client)
      assert one_close?(client_pid)
    end

    skill_drifts = [
      List.delete_at(skills(fixture), 0),
      skills(fixture) ++ [hd(skills(fixture))],
      List.update_at(skills(fixture), 0, &Map.put(&1, "enabled", false)),
      List.update_at(skills(fixture), 0, &Map.put(&1, "name", "manafuel-control-alias")),
      List.update_at(skills(fixture), 0, &Map.put(&1, "name", ".system")),
      List.update_at(skills(fixture), 0, &Map.put(&1, "shortDescription", true)),
      List.update_at(skills(fixture), 0, &Map.put(&1, "interface", true)),
      List.update_at(skills(fixture), 0, &Map.put(&1, "dependencies", %{"mcp" => ["surprise"], "env" => [], "credentials" => []})),
      List.update_at(skills(fixture), 0, &Map.put(&1, "dependencies", %{"tools" => ["surprise"]})),
      List.update_at(skills(fixture), 0, &Map.put(&1, "path", hd(fixture.instruction_paths)))
    ]

    for drift <- skill_drifts do
      skills_result = %{"data" => [%{"cwd" => fixture.workspace_root, "errors" => [], "skills" => drift}]}
      {client_pid, client} = fake_client(List.replace_at(transcript, 6, response(6, skills_result)))
      assert {:error, :skill_mismatch} = RuntimeAdapter.open_validated(fixture.admitted_run, fixture.context, client)
      assert one_close?(client_pid)
    end

    profiles = permission_profiles()

    for profile_drift <- [
          Enum.reverse(profiles),
          List.update_at(profiles, 0, &Map.put(&1, "id", ":workspace")),
          List.update_at(profiles, 1, &Map.put(&1, "allowed", false)),
          List.update_at(profiles, 2, &Map.put(&1, "id", ":custom")),
          List.update_at(profiles, 2, &Map.put(&1, "unexpected", true))
        ] do
      {client_pid, client} = fake_client(List.replace_at(transcript, 8, response(8, page(profile_drift, nil))))

      assert {:error, :permission_profile_mismatch} =
               RuntimeAdapter.open_validated(fixture.admitted_run, fixture.context, client)

      assert one_close?(client_pid)
    end

    thread_result = thread_result(fixture)
    thread = thread_result["thread"]

    thread_drifts = [
      Map.put(thread_result, "thread", %{"id" => thread["id"]}),
      put_in(thread_result, ["thread", "sessionId"], "018f47c4-2a31-7c8b-9c23-17c05e5678ac"),
      put_in(thread_result, ["thread", "status"], %{"type" => "notLoaded"}),
      put_in(thread_result, ["thread", "source"], "vscode"),
      put_in(thread_result, ["thread", "cwd"], fixture.context.codex_home),
      put_in(thread_result, ["thread", "cliVersion"], "0.148.0"),
      put_in(thread_result, ["thread", "ephemeral"], false),
      put_in(thread_result, ["thread", "historyMode"], "full"),
      Map.update!(thread_result, "thread", &Map.delete(&1, "turns")),
      Map.put(thread_result, "serviceTier", "default"),
      put_in(thread_result, ["sandbox", "type"], "workspace-write"),
      put_in(thread_result, ["sandbox", "writableRoots"], [fixture.workspace_root]),
      Map.update!(thread_result, "sandbox", &Map.delete(&1, "excludeSlashTmp")),
      put_in(thread_result, ["sandbox", "networkAccess"], true)
    ]

    for thread_drift <- thread_drifts do
      {client_pid, client} = fake_client(List.replace_at(transcript, 9, response(9, thread_drift)))
      assert {:error, :effective_runtime_mismatch} = open_run(fixture, client)
      assert one_close?(client_pid)
    end
  end

  test "rejects raw nested protocol substitutions and closes once" do
    fixture = fixture()
    transcript = successful_transcript(fixture)

    malformed_feature = %{
      "name" => "surprise",
      "stage" => "stable",
      "displayName" => nil,
      "description" => nil,
      "enabled" => false,
      "defaultEnabled" => false,
      "unexpected" => true
    }

    valid_skills_wrapper = %{
      "data" => [%{"cwd" => fixture.workspace_root, "errors" => [], "skills" => [true | tl(skills(fixture))]}]
    }

    invalid_thread_id = put_in(thread_result(fixture), ["thread", "id"], 7)
    non_map_thread = Map.put(thread_result(fixture), "thread", true)

    failures = [
      {2, response(2, %{"requiresOpenaiAuth" => true, "account" => %{"type" => "apiKey"}}), :auth_mismatch},
      {3, response(3, page([Map.put(model(), "supportedReasoningEfforts", %{})], nil)), :model_mismatch},
      {3, response(3, page([Map.put(model(), "supportedReasoningEfforts", [%{"reasoningEffort" => "medium", "description" => "Valid medium reasoning description"}, true])], nil)), :model_mismatch},
      {6, response(6, valid_skills_wrapper), :skill_mismatch},
      {8, response(8, page(List.replace_at(permission_profiles(), 0, true), nil)), :permission_profile_mismatch},
      {10, response(10, page([malformed_feature], nil)), :extension_mismatch},
      {10, response(10, page([true], nil)), :extension_mismatch},
      {9, response(9, invalid_thread_id), :effective_runtime_mismatch},
      {9, response(9, non_map_thread), :effective_runtime_mismatch}
    ]

    for {index, replacement, expected} <- failures do
      {client_pid, client} = fake_client(List.replace_at(transcript, index, replacement))
      assert {:error, ^expected} = open_run(fixture, client)
      assert one_close?(client_pid)
    end
  end

  test "accepts unordered canonical skill roots and omitted optional skill metadata" do
    fixture = fixture()
    context = %{fixture.context | skill_roots: Enum.reverse(fixture.skill_roots)}

    transcript =
      successful_transcript(fixture)
      |> List.replace_at(
        6,
        response(6, %{
          "data" => [%{"cwd" => fixture.workspace_root, "errors" => [], "skills" => Enum.reverse(skills(fixture))}]
        })
      )

    {client_pid, client} = fake_client(transcript)
    assert {:ok, session} = RuntimeAdapter.open_validated(fixture.admitted_run, context, client)
    assert :ok = RuntimeAdapter.close(session, client)
    assert one_close?(client_pid)
  end

  test "validates present optional raw skill metadata" do
    fixture = fixture()
    transcript = successful_transcript(fixture)
    icon_path = Path.join(fixture.root, "skill-icon.svg")

    optional_skill =
      hd(skills(fixture))
      |> Map.put("shortDescription", "Pinned runtime skill")
      |> Map.put("interface", %{"displayName" => "Pinned skill", "iconSmall" => icon_path})
      |> Map.put("dependencies", %{"tools" => []})

    optional_skills = [optional_skill | tl(skills(fixture))]
    skills_response = %{"data" => [%{"cwd" => fixture.workspace_root, "errors" => [], "skills" => optional_skills}]}
    {client_pid, client} = fake_client(List.replace_at(transcript, 6, response(6, skills_response)))
    assert {:ok, session} = open_run(fixture, client)
    assert :ok = RuntimeAdapter.close(session, client)
    assert one_close?(client_pid)

    for malformed_interface <- [%{"iconSmall" => "relative.svg"}, %{"unexpected" => "value"}] do
      malformed_skill = Map.put(optional_skill, "interface", malformed_interface)

      malformed_response = %{
        "data" => [%{"cwd" => fixture.workspace_root, "errors" => [], "skills" => [malformed_skill | tl(skills(fixture))]}]
      }

      {client_pid, client} = fake_client(List.replace_at(transcript, 6, response(6, malformed_response)))
      assert {:error, :skill_mismatch} = open_run(fixture, client)
      assert one_close?(client_pid)
    end
  end

  test "rejects generated user-agent aliases and unsafe control characters" do
    fixture = fixture()

    for user_agent <- [
          "codex_cli_rs/0.147.0",
          "manafuel-symphony/0.148.0 (Windows; x64) terminal (manafuel-symphony; 0.1.0)",
          "other-client/0.147.0 (Windows; x64) terminal (manafuel-symphony; 0.1.0)",
          "manafuel-symphony/0.147.0 (Windows; x64) terminal (other-client; 0.1.0)",
          "manafuel-symphony/0.147.0 (Windows\n; x64) terminal (manafuel-symphony; 0.1.0)"
        ] do
      initialize = %{
        "userAgent" => user_agent,
        "codexHome" => fixture.context.codex_home,
        "platformFamily" => "windows",
        "platformOs" => "windows"
      }

      {client_pid, client} = fake_client(List.replace_at(successful_transcript(fixture), 0, response(1, initialize)))
      assert {:error, :runtime_version_mismatch} = open_run(fixture, client)
      assert one_close?(client_pid)
    end
  end

  test "uses URL PATH_SEGMENT canonical Windows and UNC file URIs" do
    assert RuntimeAdapter.file_uri_for_test("C:\\dir with spaces\\100%#?\\ü") == "file:///C:/dir%20with%20spaces/100%25%23%3F/%C3%BC"
    assert RuntimeAdapter.file_uri_for_test("\\\\server\\share\\dir with spaces\\100%#?\\ü") == "file://server/share/dir%20with%20spaces/100%25%23%3F/%C3%BC"
    assert RuntimeAdapter.file_uri_for_test("/tmp/dir with spaces/100%#?/ü") == "file:///tmp/dir%20with%20spaces/100%25%23%3F/%C3%BC"
    assert RuntimeAdapter.file_uri_for_test("C:\\work\\a+b;=@[x]^!$.txt") == "file:///C:/work/a+b;=@[x]^!$.txt"
    assert RuntimeAdapter.file_uri_for_test("\\\\SERVER\\share\\a+b") == "file://server/share/a+b"
    assert RuntimeAdapter.file_uri_for_test("\\\\LOCALHOST\\share\\a+b") == "file:///share/a+b"
    assert RuntimeAdapter.file_uri_for_test("\\\\0177.0.0.1\\share") == "file://127.0.0.1/share"
    assert RuntimeAdapter.file_uri_for_test("\\\\2130706433\\share") == "file://127.0.0.1/share"
    assert RuntimeAdapter.file_uri_for_test("\\\\127.1\\share") == "file://127.0.0.1/share"
    assert RuntimeAdapter.file_uri_for_test("\\\\127.0.1\\share") == "file://127.0.0.1/share"
    assert RuntimeAdapter.file_uri_for_test("\\\\0x\\share") == "file://0.0.0.0/share"
    assert RuntimeAdapter.file_uri_for_test("\\\\0X\\share") == "file://0.0.0.0/share"
    assert RuntimeAdapter.file_uri_for_test("\\\\0x7f.1\\share") == "file://127.0.0.1/share"
    assert RuntimeAdapter.file_uri_for_test("\\\\0X7F.1\\share") == "file://127.0.0.1/share"
    assert RuntimeAdapter.file_uri_for_test("\\\\0xg\\share") == "file://0xg/share"
    assert RuntimeAdapter.file_uri_for_test("\\\\08\\share") == nil
    assert RuntimeAdapter.file_uri_for_test("\\\\1.2.3.4.5\\share") == nil
    assert RuntimeAdapter.file_uri_for_test("\\\\bad host\\share") == nil
    assert RuntimeAdapter.file_uri_for_test("relative/path") == nil
    assert RuntimeAdapter.file_uri_for_test(7) == nil

    fixture = fixture()
    canonical_cwd = RuntimeAdapter.file_uri_for_test(fixture.workspace_root)
    assert String.contains?(canonical_cwd, "+")

    {canonical_client_pid, canonical_client} = fake_client(successful_transcript(fixture))
    assert {:ok, session} = open_run(fixture, canonical_client)
    assert :ok = RuntimeAdapter.close(session, canonical_client)
    assert one_close?(canonical_client_pid)

    raw_cwd = "file:///" <> String.replace(fixture.workspace_root, "\\", "/")
    replacement = response(5, %{"cwd" => raw_cwd, "shell" => %{"name" => "powershell", "path" => Path.join(fixture.root, "shell.exe")}})
    {client_pid, client} = fake_client(List.replace_at(successful_transcript(fixture), 5, replacement))
    assert {:error, :environment_mismatch} = open_run(fixture, client)
    assert one_close?(client_pid)

    overencoded_cwd = String.replace(canonical_cwd, "+", "%2B")
    overencoded = response(5, %{"cwd" => overencoded_cwd, "shell" => %{"name" => "powershell", "path" => Path.join(fixture.root, "shell.exe")}})
    {client_pid, client} = fake_client(List.replace_at(successful_transcript(fixture), 5, overencoded))
    assert {:error, :environment_mismatch} = open_run(fixture, client)
    assert one_close?(client_pid)
  end

  test "fails closed for non-map protocol values and notification substitution" do
    fixture = fixture()
    transcript = successful_transcript(fixture)

    variants = [
      {1, :unexpected, :runtime_protocol_error},
      {3, response(3, []), :runtime_protocol_error},
      {3, response(3, page("models", [model()], 123)), :runtime_protocol_error},
      {5, response(5, []), :environment_mismatch},
      {6, response(6, []), :skill_mismatch},
      {6, response(6, %{"cwd" => fixture.workspace_root, "errors" => [], "skills" => [true | tl(skills(fixture))]}), :skill_mismatch},
      {9, response(9, []), :effective_runtime_mismatch}
    ]

    for {index, replacement, expected} <- variants do
      {client_pid, client} = fake_client(List.replace_at(transcript, index, replacement))
      assert {:error, ^expected} = RuntimeAdapter.open_validated(fixture.admitted_run, fixture.context, client)
      assert one_close?(client_pid)
    end

    non_map_frame = {:ok, %{"frames" => [1], "noise" => [], "eof" => false, "exited" => false}}
    {client_pid, client} = fake_client(List.replace_at(transcript, 0, non_map_frame))
    assert {:error, :runtime_protocol_error} = open_run(fixture, client)
    assert one_close?(client_pid)
  end

  defp fixture do
    root = Path.join(System.tmp_dir!(), "runtime adapter +;=@[x]^!$ % # ü-#{System.unique_integer([:positive])}") |> Path.expand()
    workspace_root = Path.join(root, "workspace")
    codex_home = Path.join(root, "codex-home")
    skills_home = Path.join(codex_home, "skills")
    install_root = Path.join(root, "codex-install")
    executable = Path.join(install_root, "codex.exe")
    instruction_paths = [Path.join(workspace_root, "AGENTS.md"), Path.join(workspace_root, "WORKFLOW.md")]
    skill_roots = Enum.map(@skills, &Path.join([skills_home, &1]))

    File.mkdir_p!(workspace_root)
    File.mkdir_p!(codex_home)
    File.mkdir_p!(skills_home)
    File.mkdir_p!(install_root)
    File.write!(executable, "fake-codex-runtime")
    Enum.each(instruction_paths, &File.write!(&1, "instruction"))

    Enum.each(skill_roots, fn skill_root ->
      File.mkdir_p!(skill_root)
      File.write!(Path.join(skill_root, "SKILL.md"), "skill")
    end)

    on_exit(fn -> File.rm_rf(root) end)

    context = %{
      repository: "one",
      workspace_root: workspace_root,
      codex_home: codex_home,
      codex_executable: executable,
      codex_install_root: install_root,
      expected_sha256: sha256(executable),
      argv: ["-c", "skills.bundled.enabled=false", "app-server", "--listen", "stdio://"],
      env: %{"CODEX_HOME" => codex_home, "SystemRoot" => "C:\\Windows"},
      skill_roots: skill_roots,
      instruction_paths: instruction_paths,
      timeouts: %{open: 10_000, request: 10_000, close: 5_000, total: 60_000}
    }

    %{
      root: root,
      workspace_root: workspace_root,
      skills_home: skills_home,
      instruction_paths: instruction_paths,
      skill_roots: skill_roots,
      context: context,
      admitted_run: admitted_run()
    }
  end

  defp admitted_run do
    %{
      linear_issue_id: "4c3dfde2-8c4d-4d46-8dc6-e633bb0ed226",
      experiment_key: "growth-experiment-1",
      agent_id: "implementation-worker",
      repository: "one",
      repository_artifact: %{"authority" => "github", "kind" => "repository", "native_id" => "manafuel/one"},
      status: "proposed",
      manifest: %{
        "version" => "manafuel.agent-manifest.v2",
        "agent_id" => "implementation-worker",
        "model" => "gpt-5.6-terra",
        "reasoning_effort" => "medium",
        "sandbox" => %{"mode" => "workspace-write", "network_access" => false},
        "approval_policy" => "never",
        "tool_mode" => "code_mode_only",
        "tools" => ["exec", "wait"],
        "code_mode_nested_tools" => ["shell_command", "apply_patch"],
        "skills" => @skills,
        "capabilities" => ["repo-write", "repository.patch", "local-validation.run"],
        "credential_profile" => "none",
        "repository_roots" => [%{"token" => "ASSIGNED_REPOSITORY", "access" => "task-tracked", "allowlist" => "task-tracked-allowlist"}],
        "output_contract" => %{"format" => "json", "schema_path" => "output-contracts/implementation-result.v1.schema.json"},
        "concurrency" => 1,
        "no_auto_subagents" => true
      }
    }
  end

  defp successful_transcript(fixture) do
    [
      response(1, %{"userAgent" => generated_user_agent(), "codexHome" => fixture.context.codex_home, "platformFamily" => "windows", "platformOs" => "windows"}),
      :ok,
      response(2, %{"requiresOpenaiAuth" => true, "account" => %{"type" => "chatgpt", "email" => nil, "planType" => "pro"}}),
      response(3, page([model()], nil)),
      response(4, %{"status" => "ready"}),
      response(5, %{"cwd" => RuntimeAdapter.file_uri_for_test(fixture.workspace_root), "shell" => %{"name" => "powershell", "path" => Path.join(fixture.root, "shell.exe")}}),
      response(6, %{"data" => [%{"cwd" => fixture.workspace_root, "errors" => [], "skills" => skills(fixture)}]}),
      response(7, %{"data" => [%{"cwd" => fixture.workspace_root, "hooks" => [], "warnings" => [], "errors" => []}]}),
      response(8, page(permission_profiles(), nil)),
      response(9, thread_result(fixture)),
      response(10, page(features(), nil)),
      response(11, page([], nil))
    ]
  end

  defp response(id, result) do
    {:ok, %{"frames" => [%{"id" => id, "result" => result}], "noise" => [], "eof" => false, "exited" => false}}
  end

  defp page(entries, next_cursor), do: %{"data" => entries, "nextCursor" => next_cursor}
  defp page(_legacy_entries_key, entries, next_cursor), do: page(entries, next_cursor)

  defp model,
    do: %{
      "id" => "gpt-5.6-terra",
      "model" => "gpt-5.6-terra",
      "upgrade" => nil,
      "upgradeInfo" => nil,
      "availabilityNux" => nil,
      "displayName" => "GPT-5.6 Terra",
      "description" => "Pinned worker model",
      "modelSpecialty" => nil,
      "hidden" => false,
      "supportedReasoningEfforts" => [%{"reasoningEffort" => "medium", "description" => "Balances speed and reasoning depth for everyday tasks"}],
      "defaultReasoningEffort" => "medium",
      "inputModalities" => ["text"],
      "supportsPersonality" => false,
      "additionalSpeedTiers" => [],
      "serviceTiers" => [],
      "defaultServiceTier" => "default",
      "isDefault" => false
    }

  defp skills(fixture) do
    Enum.zip(@skills, fixture.skill_roots)
    |> Enum.map(fn {name, root} ->
      %{
        "name" => name,
        "description" => "Pinned skill",
        "path" => Path.join(root, "SKILL.md"),
        "scope" => "user",
        "enabled" => true
      }
    end)
  end

  defp thread_result(fixture) do
    thread_id = "018f47c4-2a31-7c8b-9c23-17c05e5678ab"

    %{
      "thread" => %{
        "id" => thread_id,
        "extra" => nil,
        "sessionId" => thread_id,
        "forkedFromId" => nil,
        "parentThreadId" => nil,
        "preview" => "",
        "ephemeral" => true,
        "section" => nil,
        "sectionEnteredAt" => nil,
        "historyMode" => "legacy",
        "modelProvider" => "openai",
        "createdAt" => 1_725_000_000,
        "updatedAt" => 1_725_000_001,
        "recencyAt" => 1_725_000_002,
        "status" => %{"type" => "idle"},
        "path" => nil,
        "cwd" => fixture.workspace_root,
        "cliVersion" => "0.147.0",
        "source" => "appServer",
        "canAcceptDirectInput" => true,
        "threadSource" => nil,
        "agentNickname" => nil,
        "agentRole" => nil,
        "gitInfo" => nil,
        "name" => nil,
        "turns" => []
      },
      "model" => "gpt-5.6-terra",
      "modelProvider" => "openai",
      "reasoningEffort" => "medium",
      "serviceTier" => nil,
      "cwd" => fixture.workspace_root,
      "runtimeWorkspaceRoots" => [fixture.workspace_root],
      "approvalPolicy" => "never",
      "approvalsReviewer" => "user",
      "activePermissionProfile" => %{"id" => ":workspace", "extends" => nil},
      "sandbox" => %{
        "type" => "workspaceWrite",
        "writableRoots" => [],
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      },
      "instructionSources" => fixture.instruction_paths,
      "multiAgentMode" => "explicitRequestOnly"
    }
  end

  defp initialize_params do
    %{
      "clientInfo" => %{"name" => "manafuel-symphony", "version" => "0.1.0"},
      "capabilities" => %{
        "experimentalApi" => true,
        "requestAttestation" => false,
        "mcpServerOpenaiFormElicitation" => false,
        "optOutNotificationMethods" => [],
        "extensions" => %{}
      }
    }
  end

  defp thread_start_params(fixture) do
    %{
      "model" => "gpt-5.6-terra",
      "modelProvider" => "openai",
      "allowProviderModelFallback" => false,
      "serviceTier" => "default",
      "cwd" => fixture.workspace_root,
      "runtimeWorkspaceRoots" => [fixture.workspace_root],
      "approvalPolicy" => "never",
      "approvalsReviewer" => "user",
      "permissions" => ":workspace",
      "serviceName" => "manafuel-symphony",
      "ephemeral" => true,
      "sessionStartSource" => "startup",
      "environments" => [%{"environmentId" => "local", "cwd" => fixture.workspace_root, "runtimeWorkspaceRoots" => [fixture.workspace_root]}],
      "dynamicTools" => [],
      "selectedCapabilityRoots" => [],
      "config" => runtime_config()
    }
  end

  defp runtime_config do
    disabled = [
      "unified_exec",
      "code_mode_buffered_exec",
      "view_image",
      "hooks",
      "deferred_executor",
      "request_permissions_tool",
      "web_search_request",
      "web_search_cached",
      "standalone_web_search",
      "memories",
      "network_proxy",
      "multi_agent",
      "multi_agent_v2",
      "apps",
      "enable_mcp_apps",
      "tool_suggest",
      "recommended_plugins",
      "plugins",
      "executor_capability_discovery",
      "in_app_browser",
      "browser_use",
      "browser_use_full_cdp_access",
      "browser_use_external",
      "computer_use",
      "remote_plugin",
      "plugin_sharing",
      "image_generation",
      "skill_mcp_dependency_install",
      "skill_search",
      "default_mode_request_user_input",
      "guardian_approval",
      "guardianv2",
      "goals",
      "token_budget",
      "rollout_budget",
      "current_time_reminder",
      "tool_call_mcp_elicitation",
      "auth_elicitation",
      "artifact",
      "fast_mode",
      "use_agent_identity",
      "workspace_dependencies"
    ]

    %{
      "model_reasoning_effort" => "medium",
      "forced_login_method" => "chatgpt",
      "service_tier" => "default",
      "web_search" => "disabled",
      "mcp_servers" => %{},
      "skills" => %{"bundled" => %{"enabled" => false}},
      "tools" => %{"experimental_request_user_input" => %{"enabled" => false}, "update_plan" => %{"enabled" => false}},
      "features" =>
        Map.merge(Map.new(disabled, &{&1, false}), %{
          "shell_tool" => true,
          "code_mode" => %{"enabled" => true, "excluded_tool_namespaces" => [], "direct_only_tool_namespaces" => []},
          "code_mode_host" => %{"enabled" => true, "disable_in_process_fallback" => true},
          "code_mode_only" => true,
          "tool_registry" => %{"error_on_tool_collisions" => true}
        })
    }
  end

  defp features do
    runtime_config()["features"]
    |> Enum.flat_map(fn {name, enabled} ->
      enabled = if(is_boolean(enabled), do: enabled, else: enabled["enabled"])

      if is_boolean(enabled) do
        [
          %{
            "name" => name,
            "stage" => "stable",
            "displayName" => nil,
            "description" => nil,
            "announcement" => nil,
            "enabled" => enabled,
            "defaultEnabled" => false
          }
        ]
      else
        []
      end
    end)
  end

  defp permission_profiles do
    [
      %{"id" => ":read-only", "description" => nil, "allowed" => true},
      %{"id" => ":workspace", "description" => nil, "allowed" => true},
      %{"id" => ":danger-full-access", "description" => nil, "allowed" => true}
    ]
  end

  defp generated_user_agent, do: "manafuel-symphony/0.147.0 (Windows 11; x64) terminal/1.0 (manafuel-symphony; 0.1.0)"

  defp fake_client(responses, options \\ []) do
    open_result = Keyword.get(options, :open_result, {:ok, :fake_transport})
    close_result = Keyword.get(options, :close_result, :ok)
    {:ok, client_pid} = Agent.start(fn -> %{responses: responses, events: []} end)
    on_exit(fn -> if Process.alive?(client_pid), do: Agent.stop(client_pid) end)

    client = %{
      open_runtime: fn executable, launch_options, timeout ->
        record(client_pid, {:open, executable, launch_options, timeout})
        open_result
      end,
      request: fn transport, id, method, params, timeout ->
        record(client_pid, {:request, transport, id, method, params, timeout})

        case next_response(client_pid) do
          {:raise, exception} -> raise exception
          {:throw, reason} -> throw(reason)
          response -> response
        end
      end,
      close_runtime: fn transport, timeout ->
        record(client_pid, {:close, transport, timeout})
        close_result
      end
    }

    {client_pid, client}
  end

  defp record(client_pid, event), do: Agent.update(client_pid, fn state -> %{state | events: [event | state.events]} end)

  defp next_response(client_pid) do
    Agent.get_and_update(client_pid, fn
      %{responses: [response | responses]} = state -> {response, %{state | responses: responses}}
      state -> {{:error, :eof}, state}
    end)
  end

  defp events(client_pid), do: Agent.get(client_pid, fn state -> Enum.reverse(state.events) end)
  defp one_close?(client_pid), do: Enum.count(events(client_pid), &match?({:close, _, _}, &1)) == 1

  defp open_run(fixture, client) do
    open_run(fixture.admitted_run, fixture.context, client)
  end

  defp open_run(admitted_run, context, client) do
    RuntimeAdapter.open_validated(admitted_run, context, client)
  end

  defp sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
