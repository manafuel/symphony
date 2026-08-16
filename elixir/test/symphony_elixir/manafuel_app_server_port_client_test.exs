defmodule SymphonyElixir.Manafuel.AppServerPortClientTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Manafuel.AppServerPortClient
  alias SymphonyElixir.Manafuel.RuntimeAdapter

  @noise "[non-json-output]"
  @skills ["manafuel-control", "implementation-system", "frontend-system", "fullstack-api", "testing"]

  test "client exposes only the three frozen RuntimeAdapter callbacks and rejects invalid input" do
    client = AppServerPortClient.client()

    assert Map.keys(client) |> Enum.sort() == [:close_runtime, :open_runtime, :request]
    assert is_function(client.open_runtime, 3)
    assert is_function(client.request, 5)
    assert is_function(client.close_runtime, 2)

    assert {:error, :open_failed} = client.open_runtime.("relative", %{}, 100)
    assert {:error, :open_failed} = client.open_runtime.(erl_executable(), valid_options(ok_script()) |> Map.put(:extra, true), 100)
    assert {:error, :open_failed} = client.open_runtime.(erl_executable(), valid_options(ok_script()), 0)
    assert {:error, :open_failed} = client.open_runtime.(erl_executable(), valid_options(ok_script()) |> Map.put(:env, %{1 => "value"}), 100)
    assert {:error, :open_failed} = client.open_runtime.(erl_executable(), valid_options(ok_script()) |> Map.put(:env, []), 100)
    assert {:error, :open_failed} = client.open_runtime.(erl_executable(), valid_options(ok_script()) |> Map.put(:env, %{<<0xFF>> => "value"}), 100)

    assert {:error, :open_failed} =
             client.open_runtime.(erl_executable(), valid_options(ok_script()) |> Map.put(:argv, ["-noshell" | :invalid_tail]), 100)

    assert {:error, :open_failed} =
             client.open_runtime.(erl_executable(), valid_options(ok_script()) |> Map.put(:argv, [1]), 100)

    assert {:error, :open_failed} = client.open_runtime.(Path.join(System.tmp_dir!(), "missing-executable"), valid_options(ok_script()), 100)
    timeout_options = valid_options(silent_script()) |> Map.put(:env, startup_timeout_environment())
    assert {:error, :timeout} = client.open_runtime.(erl_executable(), timeout_options, 1)
    assert {:error, :transport_failed} = client.request.(:not_a_transport, 1, "probe", %{}, 100)
    assert {:error, :transport_failed} = client.request.(:not_a_transport, :notification, "initialized", :omit, 100)
    assert {:error, :close_failed} = client.close_runtime.(:not_a_transport, 100)

    {:ok, transport} = open_fixture(silent_script())
    owner = owner_pid(transport)

    assert {:error, :transport_failed} = client.request.(transport, -1, "probe", %{}, 100)
    assert_owner_stops(owner)
    assert {:error, :transport_failed} = client.request.(transport, 1, "probe", %{}, 100)
    assert :ok = client.close_runtime.(transport, 100)

    {:ok, transport} = open_fixture(silent_script())
    owner = owner_pid(transport)
    assert {:error, :close_failed} = client.close_runtime.(transport, 0)
    assert_owner_stops(owner)
    assert :ok = client.close_runtime.(transport, 100)
  end

  test "opens the supplied executable directly with exact argv cwd and an allowlisted environment" do
    old_canary = System.get_env("MANAFUEL_AMBIENT_CANARY")
    System.put_env("MANAFUEL_AMBIENT_CANARY", "must-not-cross-port")

    on_exit(fn ->
      if old_canary do
        System.put_env("MANAFUEL_AMBIENT_CANARY", old_canary)
      else
        System.delete_env("MANAFUEL_AMBIENT_CANARY")
      end
    end)

    cwd = Path.join(System.tmp_dir!(), "manafuel port cwd #{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf(cwd) end)

    script = ~S"""
    Args = init:get_plain_arguments(),
    {ok, Cwd} = file:get_cwd(),
    Ambient = os:getenv("MANAFUEL_AMBIENT_CANARY"),
    Supplied = os:getenv("MANAFUEL_SUPPLIED"),
    _ = io:get_line(""),
    Encoded = base64:encode(term_to_binary({Args, Cwd, Ambient, Supplied})),
    io:format("{\"id\":1,\"result\":\"~s\"}~n", [Encoded]),
    timer:sleep(20),
    halt().
    """

    argv = ["-noshell", "-eval", script, "-extra", "alpha", "two words"]
    env = fixture_env(%{"MANAFUEL_SUPPLIED" => "present"})
    {:ok, transport} = open_fixture(script, argv: argv, cwd: cwd, env: env)

    assert {:ok, envelope} = request(transport, 1, "probe", %{})
    assert %{"frames" => [%{"id" => 1, "result" => encoded}], "noise" => [], "eof" => false, "exited" => false} = envelope

    assert {[~c"alpha", ~c"two words"], cwd_chars, false, ~c"present"} =
             encoded |> Base.decode64!() |> :erlang.binary_to_term([:safe])

    assert List.to_string(cwd_chars) == cwd
    assert :ok = close(transport)
  end

  test "writes exact numeric and method-only initialized JSONL frames" do
    script = ~S"""
    Notification = unicode:characters_to_binary(io:get_line("")),
    Request = unicode:characters_to_binary(io:get_line("")),
    N = base64:encode(Notification),
    R = base64:encode(Request),
    io:format("{\"id\":7,\"result\":[\"~s\",\"~s\"]}~n", [N, R]),
    timer:sleep(20),
    halt().
    """

    {:ok, transport} = open_fixture(script)
    client = AppServerPortClient.client()

    assert :ok = client.request.(transport, :notification, "initialized", :omit, 500)

    assert {:ok, %{"frames" => [%{"id" => 7, "result" => [notification, numeric]}]}} =
             client.request.(transport, 7, "probe", %{"z" => [1]}, 5_000)

    assert Base.decode64!(notification) == "{\"method\":\"initialized\"}\n"
    assert Base.decode64!(numeric) == "{\"id\":7,\"method\":\"probe\",\"params\":{\"z\":[1]}}\n"
    assert :ok = close(transport)
  end

  test "queues an unsolicited frame, bounds its diagnostics, and ignores unrelated owner messages" do
    {:ok, transport} = open_fixture(silent_script())
    owner = owner_pid(transport)
    port = child_port(transport)

    send(owner, :unrelated_message)
    send(owner, {port, {:data, {:eol, "diagnostic"}}})
    send(owner, {port, {:data, {:eol, ~S|{"id":1,"result":"queued"}|}}})

    assert {:ok,
            %{
              "frames" => [%{"id" => 1, "result" => "queued"}],
              "noise" => [@noise],
              "eof" => false,
              "exited" => false
            }} = request(transport, 1, "probe", %{})

    assert :ok = close(transport)
  end

  test "invalid idle port data and every idle terminal signal tear the owner down" do
    {:ok, transport} = open_fixture(silent_script())
    owner = owner_pid(transport)
    send(owner, {child_port(transport), {:data, {:eol, :not_binary}}})
    assert_owner_stops(owner)

    for terminal <- [:eof, {:exit_status, 7}, {:exit, :synthetic}] do
      {:ok, transport} = open_fixture(silent_script())
      owner = owner_pid(transport)
      port = child_port(transport)

      message =
        case terminal do
          {:exit, reason} -> {:EXIT, port, reason}
          other -> {port, other}
        end

      send(owner, message)
      assert_owner_stops(owner)
      assert {:error, :transport_failed} = request(transport, 1, "probe", %{})
      assert :ok = close(transport)
    end
  end

  test "waits for a complete newline-terminated frame across partial writes" do
    script = ~S"""
    _ = io:get_line(""),
    io:put_chars("{\"id\":1,\"result\":{"),
    timer:sleep(25),
    io:put_chars("\"complete\":true}}\n"),
    timer:sleep(20),
    halt().
    """

    {:ok, transport} = open_fixture(script)

    assert {:ok,
            %{
              "frames" => [%{"id" => 1, "result" => %{"complete" => true}}],
              "noise" => [],
              "eof" => false,
              "exited" => false
            }} = request(transport, 1, "probe", %{})

    assert :ok = close(transport)
  end

  test "redacts bounded stdout and stderr diagnostics before returning the first JSON frame" do
    script = ~S"""
    _ = io:get_line(""),
    io:put_chars(standard_error, "TOP-SECRET-STDERR\n"),
    io:put_chars("TOP-SECRET-STDOUT\n"),
    io:put_chars("{\"id\":1,\"result\":true}\n"),
    timer:sleep(20),
    halt().
    """

    {:ok, transport} = open_fixture(script)
    assert {:ok, envelope} = request(transport, 1, "probe", %{})
    assert envelope == %{"frames" => [%{"id" => 1, "result" => true}], "noise" => [@noise, @noise], "eof" => false, "exited" => false}
    refute inspect(envelope) =~ "TOP-SECRET"
    assert :ok = close(transport)
  end

  test "treats duplicate-free valid JSON from the merged stderr stream as a frame" do
    script = ~S"""
    _ = io:get_line(""),
    io:put_chars(standard_error, "diagnostic-before-frame\n"),
    io:put_chars(standard_error, "{\"id\":1,\"result\":{\"stream\":\"merged\"}}\n"),
    timer:sleep(20),
    halt().
    """

    {:ok, transport} = open_fixture(script)

    assert {:ok,
            %{
              "frames" => [%{"id" => 1, "result" => %{"stream" => "merged"}}],
              "noise" => [@noise],
              "eof" => false,
              "exited" => false
            }} = request(transport, 1, "probe", %{})

    assert :ok = close(transport)
  end

  test "passes scalar list wrong-id error and extra-field JSON through unchanged" do
    variants = [
      {output_script("42"), 42},
      {output_script(~S|[1,{"nested":true}]|), [1, %{"nested" => true}]},
      {stderr_output_script(~S|{"id":99,"result":{}}|), %{"id" => 99, "result" => %{}}},
      {output_script(~S|{"id":1,"error":{"message":"redacted-by-adapter"}}|), %{"id" => 1, "error" => %{"message" => "redacted-by-adapter"}}},
      {stderr_output_script(~S|{"id":1,"result":{},"extra":true}|), %{"id" => 1, "result" => %{}, "extra" => true}}
    ]

    for {script, expected} <- variants do
      {:ok, transport} = open_fixture(script)
      assert {:ok, %{"frames" => [^expected], "noise" => [], "eof" => false, "exited" => false}} = request(transport, 1, "probe", %{})
      assert :ok = close(transport)
    end
  end

  test "RuntimeAdapter rejects wrong-id and extra-field frames received through merged stderr" do
    fixture = runtime_adapter_fixture()

    for json <- [
          ~S|{"id":99,"result":{}}|,
          ~S|{"id":1,"result":{},"extra":true}|
        ] do
      client = runtime_port_client(stderr_output_script(json))

      assert {:error, :runtime_protocol_error} =
               RuntimeAdapter.open_validated(fixture.admitted_run, fixture.context, client)
    end
  end

  test "malformed JSON-looking and recursive duplicate-key frames terminate without leaking bytes" do
    variants = [
      "{TOP-SECRET-malformed",
      "{\"id\":1,\"result\":{\"dup\":1,\"dup\":2}}",
      "{\"id\":1,\"result\":[{\"nested\":{\"dup\":1,\"dup\":2}}]}"
    ]

    for json <- variants do
      {:ok, transport} = open_fixture(stderr_output_script(json))
      owner = owner_pid(transport)
      result = request(transport, 1, "probe", %{})

      assert result == {:error, :transport_failed}
      refute inspect(result) =~ "TOP-SECRET"
      refute inspect(result) =~ "dup"
      assert_owner_stops(owner)
      assert {:error, :transport_failed} = request(transport, 2, "probe", %{})
      assert :ok = close(transport)
    end
  end

  test "enforces the frame limit before buffering oversized stdout or stderr lines" do
    for device <- [:stdout, :stderr] do
      target = if device == :stderr, do: "standard_error, ", else: ""

      script = "_ = io:get_line(\"\"), io:put_chars(#{target}lists:duplicate(129, $x)), timer:sleep(5000), halt()."
      {:ok, transport} = open_fixture(script, max_frame_bytes: 64)
      owner = owner_pid(transport)

      assert {:error, :transport_failed} = request(transport, 1, "probe", %{})
      assert_owner_stops(owner)
      assert :ok = close(transport)
    end
  end

  test "enforces the diagnostic count without retaining diagnostic content" do
    script = ~S"""
    _ = io:get_line(""),
    io:put_chars(standard_error, "secret-one\nsecret-two\nsecret-three\n"),
    timer:sleep(20),
    halt().
    """

    {:ok, transport} = open_fixture(script, max_noise_frames: 2)
    owner = owner_pid(transport)
    result = request(transport, 1, "probe", %{})

    assert result == {:error, :transport_failed}
    refute inspect(result) =~ "secret"
    assert_owner_stops(owner)
    assert :ok = close(transport)
  end

  test "a silent request times out within a bounded tolerance and poisons the transport" do
    {:ok, transport} = open_fixture(silent_script())
    owner = owner_pid(transport)
    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} = request(transport, 1, "probe", %{}, 75)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 50
    assert elapsed < 750
    assert_owner_stops(owner)
    assert {:error, :transport_failed} = request(transport, 2, "probe", %{})
    assert :ok = close(transport)
  end

  test "EOF and child exit return a terminal envelope and make the transport unusable" do
    script = ~S"""
    _ = io:get_line(""),
    halt(7).
    """

    {:ok, transport} = open_fixture(script)
    owner = owner_pid(transport)

    assert {:ok, %{"frames" => [], "noise" => [], "eof" => eof, "exited" => exited}} =
             request(transport, 1, "probe", %{}, 5_000)

    assert eof or exited
    assert_owner_stops(owner)
    assert {:error, :transport_failed} = request(transport, 2, "probe", %{})
    assert :ok = close(transport)
  end

  test "active requests ignore unrelated messages and accept the next complete frame" do
    {:ok, transport} = open_fixture(silent_script())
    {task, owner, port} = start_traced_request(transport)

    send(owner, :unrelated_message)
    send(owner, {port, {:data, {:eol, ~S|{"id":1,"result":"after-unrelated"}|}}})

    assert {:ok,
            %{
              "frames" => [%{"id" => 1, "result" => "after-unrelated"}],
              "noise" => [],
              "eof" => false,
              "exited" => false
            }} = Task.await(task, 1_000)

    assert :ok = close(transport)
  end

  test "active terminal signals return exact terminal envelopes and drain queued terminal state" do
    terminal_cases = [
      {fn port -> [{port, :eof}, {port, {:exit_status, 7}}] end, true, true},
      {fn port -> [{port, :eof}, {:EXIT, port, :synthetic}] end, true, true},
      {fn port -> [{port, {:exit_status, 7}}] end, false, true},
      {fn port -> [{:EXIT, port, :synthetic}] end, false, true}
    ]

    for {messages, expected_eof, expected_exited} <- terminal_cases do
      {:ok, transport} = open_fixture(silent_script())
      {task, owner, port} = start_traced_request(transport)

      for message <- messages.(port), do: send(owner, message)

      assert {:ok,
              %{
                "frames" => [],
                "noise" => [],
                "eof" => ^expected_eof,
                "exited" => ^expected_exited
              }} = Task.await(task, 1_000)

      assert_owner_stops(owner)
      assert {:error, :transport_failed} = request(transport, 2, "probe", %{})
      assert :ok = close(transport)
    end
  end

  test "supports sequential requests but a callback timeout never permits reuse" do
    script = ~S"""
    _ = io:get_line(""),
    io:put_chars("{\"id\":1,\"result\":\"first\"}\n"),
    _ = io:get_line(""),
    io:put_chars("{\"id\":2,\"result\":\"second\"}\n"),
    timer:sleep(1000),
    halt().
    """

    {:ok, transport} = open_fixture(script)
    assert {:ok, %{"frames" => [%{"id" => 1, "result" => "first"}]}} = request(transport, 1, "one", %{})
    assert {:ok, %{"frames" => [%{"id" => 2, "result" => "second"}]}} = request(transport, 2, "two", %{})
    assert :ok = close(transport)
    assert :ok = close(transport)
  end

  test "caller death directly tears down the dedicated owner and child" do
    test_pid = self()
    client = AppServerPortClient.client()
    options = valid_options(silent_script())

    caller =
      spawn(fn ->
        result = client.open_runtime.(erl_executable(), options, 5_000)
        send(test_pid, {:opened_by_caller, result})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:opened_by_caller, {:ok, transport}}, 2_000
    owner = owner_pid(transport)
    monitor = Process.monitor(caller)
    send(caller, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
    assert_owner_stops(owner)
    assert {:error, :transport_failed} = request(transport, 1, "probe", %{})
    assert :ok = close(transport)
  end

  test "caller death during an in-flight request tears down the owner and child" do
    test_pid = self()
    client = AppServerPortClient.client()
    options = valid_options(silent_script())

    caller =
      spawn(fn ->
        {:ok, transport} = client.open_runtime.(erl_executable(), options, 5_000)
        send(test_pid, {:opened_for_active_request, transport})

        receive do
          :request -> client.request.(transport, 1, "probe", %{}, 5_000)
        end
      end)

    assert_receive {:opened_for_active_request, transport}, 2_000
    {AppServerPortClient, owner, token} = transport
    assert 1 = :erlang.trace(owner, true, [:receive])
    send(caller, :request)

    assert_receive {
                     :trace,
                     ^owner,
                     :receive,
                     {:manafuel_app_server_port_call, ^token, ^caller, _call_ref, {:request, :numeric, _wire}, 5_000}
                   },
                   1_000

    assert 1 = :erlang.trace(owner, false, [:receive])
    caller_monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    assert_owner_stops(owner)
    assert {:error, :transport_failed} = request(transport, 2, "probe", %{})
    assert :ok = close(transport)
  end

  test "explicit and repeated close are bounded and contain closed-port exits" do
    {:ok, transport} = open_fixture(silent_script())
    owner = owner_pid(transport)

    assert :ok = close(transport, 500)
    assert_owner_stops(owner)
    assert :ok = close(transport, 500)
    assert {:error, :transport_failed} = request(transport, 1, "probe", %{})
  end

  test "concurrent callbacks cannot create a second in-flight request" do
    {:ok, transport} = open_fixture(silent_script())
    {first, owner, _port} = start_traced_request(transport, 1_000)
    second = Task.async(fn -> request(transport, 2, "second", %{}, 150) end)

    assert {:error, :transport_failed} = Task.await(second, 1_000)
    assert {:error, :transport_failed} = Task.await(first, 1_000)
    assert_owner_stops(owner)
    assert :ok = close(transport)
  end

  test "close cannot race an in-flight request" do
    {:ok, transport} = open_fixture(silent_script())
    {request_task, owner, _port} = start_traced_request(transport, 1_000)

    assert {:error, :close_failed} = close(transport, 500)
    assert {:error, :transport_failed} = Task.await(request_task, 1_000)
    assert_owner_stops(owner)
    assert :ok = close(transport)
  end

  test "outer callback timeouts and owner exits remain bounded for shape-valid transports" do
    request_owner = unresponsive_owner()
    request_transport = {AppServerPortClient, request_owner, make_ref()}
    assert {:error, :timeout} = request(request_transport, 1, "probe", %{}, 25)
    assert_owner_stops(request_owner)

    close_owner = unresponsive_owner()
    close_transport = {AppServerPortClient, close_owner, make_ref()}
    assert {:error, :close_failed} = close(close_transport, 25)
    assert_owner_stops(close_owner)

    down_owner = spawn(fn -> receive do: (_message -> :ok) end)
    down_transport = {AppServerPortClient, down_owner, make_ref()}
    assert :ok = close(down_transport, 500)
    assert_owner_stops(down_owner)
  end

  test "encoding errors and owner exits remain stable atoms and never escape" do
    for invalid_params <- [
          %{"bad" => [1 | :invalid_tail]},
          %{"bad" => {:not, :json}}
        ] do
      {:ok, transport} = open_fixture(silent_script())
      owner = owner_pid(transport)

      assert {:error, :transport_failed} = request(transport, 1, "probe", invalid_params)
      assert_owner_stops(owner)
      assert :ok = close(transport)
    end

    {:ok, transport} = open_fixture(silent_script())
    owner = owner_pid(transport)
    Process.exit(owner, :kill)
    assert_owner_stops(owner)
    assert {:error, :transport_failed} = request(transport, 1, "probe", %{})
    assert :ok = close(transport)
  end

  defp request(transport, id, method, params, timeout \\ 5_000) do
    AppServerPortClient.client().request.(transport, id, method, params, timeout)
  end

  defp close(transport, timeout \\ 500) do
    AppServerPortClient.client().close_runtime.(transport, timeout)
  end

  defp open_fixture(script, overrides \\ []) do
    options = valid_options(script, overrides)
    timeout = Keyword.get(overrides, :open_timeout, 5_000)
    AppServerPortClient.client().open_runtime.(erl_executable(), options, timeout)
  end

  defp valid_options(script, overrides \\ []) do
    %{
      argv: Keyword.get(overrides, :argv, ["-noshell", "-eval", script]),
      cwd: Keyword.get(overrides, :cwd, File.cwd!()),
      env: Keyword.get(overrides, :env, fixture_env()),
      max_frame_bytes: Keyword.get(overrides, :max_frame_bytes, 4_096),
      max_noise_frames: Keyword.get(overrides, :max_noise_frames, 8)
    }
  end

  defp fixture_env(extra \\ %{}) do
    ["PATH", "HOME", "SystemRoot", "WINDIR", "TEMP", "TMP", "LANG"]
    |> Enum.reduce(%{}, fn name, env ->
      case System.get_env(name) do
        value when is_binary(value) and value != "" -> Map.put(env, name, value)
        _other -> env
      end
    end)
    |> Map.merge(extra)
  end

  defp startup_timeout_environment do
    Map.new(1..10_000, fn index -> {"MANAFUEL_TIMEOUT_#{index}", "x"} end)
  end

  defp runtime_port_client(script) do
    port_client = AppServerPortClient.client()

    %{
      open_runtime: fn _executable, _options, timeout ->
        port_client.open_runtime.(erl_executable(), valid_options(script), timeout)
      end,
      request: port_client.request,
      close_runtime: port_client.close_runtime
    }
  end

  defp runtime_adapter_fixture do
    root = Path.join(System.tmp_dir!(), "port-client-runtime-adapter-#{System.unique_integer([:positive])}") |> Path.expand()
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

    %{
      context: %{
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
      },
      admitted_run: runtime_admitted_run()
    }
  end

  defp runtime_admitted_run do
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
    }
  end

  defp sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp erl_executable do
    System.find_executable("erl") || System.find_executable("erl.exe") || flunk("erl/erl.exe fixture executable is unavailable")
  end

  defp owner_pid({AppServerPortClient, owner, token}) when is_pid(owner) and is_reference(token), do: owner

  defp child_port(transport) do
    owner = owner_pid(transport)
    {:links, links} = Process.info(owner, :links)
    Enum.find(links, &is_port/1) || flunk("Port owner has no linked child port")
  end

  defp start_traced_request(transport, timeout \\ 5_000) do
    {AppServerPortClient, owner, token} = transport
    port = child_port(transport)
    assert 1 = :erlang.trace(owner, true, [:receive])
    task = Task.async(fn -> request(transport, 1, "probe", %{}, timeout) end)

    assert_receive {
                     :trace,
                     ^owner,
                     :receive,
                     {:manafuel_app_server_port_call, ^token, _from, _call_ref, {:request, :numeric, _wire}, ^timeout}
                   },
                   1_000

    assert 1 = :erlang.trace(owner, false, [:receive])
    {task, owner, port}
  end

  defp unresponsive_owner do
    spawn(fn ->
      receive do
        _message ->
          receive do
            :never -> :ok
          end
      end
    end)
  end

  defp assert_owner_stops(owner) do
    monitor = Process.monitor(owner)

    receive do
      {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
    after
      1_000 -> flunk("Port owner remained alive")
    end
  end

  defp ok_script, do: output_script(~S|{"id":1,"result":true}|)

  defp silent_script do
    ~S"""
    _ = io:get_line(""),
    timer:sleep(5000),
    halt().
    """
  end

  defp output_script(json) do
    encoded = Base.encode64(json <> "\n")

    "_ = io:get_line(\"\"), io:put_chars(base64:decode(\"#{encoded}\")), timer:sleep(20), halt()."
  end

  defp stderr_output_script(json) do
    encoded = Base.encode64(json <> "\n")

    "_ = io:get_line(\"\"), io:put_chars(standard_error, base64:decode(\"#{encoded}\")), timer:sleep(20), halt()."
  end
end
