defmodule SymphonyElixir.Manafuel.AppServerPortClient do
  @moduledoc """
  A bounded, owner-isolated JSONL Port transport for the MANAfuel runtime adapter.

  The supplied executable is started directly. Standard output and standard error
  are one untrusted bounded stream because OTP ports cannot preserve their
  provenance when stderr is captured. Valid duplicate-free JSON is returned
  unchanged; non-JSON diagnostics are represented only by a fixed sentinel.
  """

  alias SymphonyElixir.Manafuel.RuntimeAdapter

  @call_tag :manafuel_app_server_port_call
  @handoff_tag :manafuel_app_server_port_handoff
  @noise_sentinel "[non-json-output]"
  @open_keys [:argv, :cwd, :env, :max_frame_bytes, :max_noise_frames]
  @max_frame_bytes 1_048_576
  @max_noise_frames 256
  @max_timeout_ms 60_000
  @reply_grace_ms 25

  @spec client() :: RuntimeAdapter.client()
  def client do
    %{
      open_runtime: &open_runtime/3,
      request: &request/5,
      close_runtime: &close_runtime/2
    }
  end

  @doc false
  @spec handoff(term(), pos_integer()) :: {:ok, port(), map()} | {:error, :handoff_failed}
  def handoff(transport, timeout) do
    with {:ok, owner, token} <- transport_parts(transport),
         true <- valid_timeout?(timeout),
         true <- Process.alive?(owner),
         {:ok, port, metadata} <- owner_call(owner, token, {:handoff, self()}, timeout, :handoff),
         true <- is_port(port),
         true <- valid_handoff_metadata?(metadata) do
      {:ok, port, metadata}
    else
      _other -> {:error, :handoff_failed}
    end
  end

  @doc false
  @spec claim_handoff(port(), map(), pos_integer()) :: :ok | {:error, :handoff_failed}
  def claim_handoff(port, metadata, timeout) when is_port(port) do
    with true <- valid_timeout?(timeout),
         true <- valid_handoff_metadata?(metadata),
         true <- port_connected_to?(port, self()),
         true <- Process.alive?(metadata.handoff_owner),
         :ok <- claim_handoff_owner(metadata.handoff_owner, metadata.handoff_token, self(), timeout) do
      :ok
    else
      _other -> {:error, :handoff_failed}
    end
  end

  def claim_handoff(_port, _metadata, _timeout), do: {:error, :handoff_failed}

  defp open_runtime(executable, options, timeout) do
    case validate_open(executable, options, timeout) do
      {:ok, config} -> start_owner(config, timeout)
      _other -> {:error, :open_failed}
    end
  end

  defp request(transport, id, method, params, timeout) do
    case transport_parts(transport) do
      {:ok, owner, token} ->
        case encode_request(id, method, params, timeout) do
          {:ok, kind, wire} -> owner_call(owner, token, {:request, kind, wire}, timeout, :request)
          :error -> poison(owner, {:error, :transport_failed})
        end

      :error ->
        {:error, :transport_failed}
    end
  end

  defp close_runtime(transport, timeout) do
    case transport_parts(transport) do
      {:ok, owner, token} ->
        cond do
          not valid_timeout?(timeout) -> poison(owner, {:error, :close_failed})
          not Process.alive?(owner) -> :ok
          true -> owner_call(owner, token, :close, timeout, :close)
        end

      :error ->
        {:error, :close_failed}
    end
  end

  defp validate_open(executable, options, timeout) do
    with true <- is_binary(executable) and is_map(options),
         true <- exact_open_keys?(options),
         true <- valid_timeout?(timeout),
         true <- Path.type(executable) == :absolute,
         true <- valid_argv?(options.argv),
         true <- valid_cwd?(options.cwd),
         true <- valid_environment?(options.env),
         true <- valid_frame_limit?(options.max_frame_bytes),
         true <- valid_noise_limit?(options.max_noise_frames) do
      {:ok,
       %{
         executable: executable,
         argv: options.argv,
         cwd: options.cwd,
         env: options.env,
         max_frame_bytes: options.max_frame_bytes,
         max_noise_frames: options.max_noise_frames
       }}
    else
      _other -> :error
    end
  end

  defp exact_open_keys?(options),
    do: map_size(options) == length(@open_keys) and Enum.sort(Map.keys(options)) == Enum.sort(@open_keys)

  defp valid_argv?(argv), do: proper_list?(argv, &valid_argv_entry?/1)

  defp valid_argv_entry?(entry) when is_binary(entry), do: not String.contains?(entry, <<0>>)
  defp valid_argv_entry?(_entry), do: false

  defp valid_cwd?(cwd),
    do: is_binary(cwd) and Path.type(cwd) == :absolute and File.dir?(cwd) and not String.contains?(cwd, <<0>>)

  defp valid_environment?(environment) when is_map(environment) do
    entries = Map.to_list(environment)

    if Enum.all?(entries, &valid_environment_entry?/1) do
      normalized_names = Enum.map(entries, fn {name, _value} -> normalize_env_name(name) end)
      length(normalized_names) == length(Enum.uniq(normalized_names))
    else
      false
    end
  end

  defp valid_environment?(_environment), do: false

  defp valid_environment_entry?({name, value}) when is_binary(name) and is_binary(value) do
    String.valid?(name) and name != "" and value != "" and not String.contains?(name, ["=", <<0>>]) and
      not String.contains?(value, <<0>>)
  end

  defp valid_environment_entry?(_entry), do: false

  defp normalize_env_name(name) when is_binary(name) do
    if match?({:win32, _family}, :os.type()), do: String.downcase(name), else: name
  end

  defp valid_frame_limit?(limit), do: is_integer(limit) and limit > 0 and limit <= @max_frame_bytes
  defp valid_noise_limit?(limit), do: is_integer(limit) and limit >= 0 and limit <= @max_noise_frames
  defp valid_timeout?(timeout), do: is_integer(timeout) and timeout > 0 and timeout <= @max_timeout_ms

  defp start_owner(config, timeout) do
    caller = self()
    open_ref = make_ref()
    owner = spawn(fn -> owner_boot(caller, open_ref, config) end)
    monitor = Process.monitor(owner)

    receive do
      {^open_ref, {:ok, transport}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, transport}

      {^open_ref, {:error, :open_failed}} ->
        Process.demonitor(monitor, [:flush])
        {:error, :open_failed}
    after
      timeout ->
        terminate_process(owner)
        Process.demonitor(monitor, [:flush])
        {:error, :timeout}
    end
  end

  defp owner_boot(caller, open_ref, config) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)

    case open_port(config) do
      {:ok, port} ->
        token = make_ref()
        send(caller, {open_ref, {:ok, {__MODULE__, self(), token}}})

        owner_loop(%{
          port: port,
          caller: caller,
          caller_monitor: caller_monitor,
          token: token,
          max_frame_bytes: config.max_frame_bytes,
          max_noise_frames: config.max_noise_frames,
          pending: <<>>,
          noise_count: 0,
          queued_frame: :none
        })

      {:error, :open_failed} ->
        send(caller, {open_ref, {:error, :open_failed}})
    end
  end

  defp open_port(config) do
    options = [
      :binary,
      :exit_status,
      :eof,
      :hide,
      :stderr_to_stdout,
      {:args, Enum.map(config.argv, &String.to_charlist/1)},
      {:cd, String.to_charlist(config.cwd)},
      {:env, port_environment(config.env)},
      {:line, config.max_frame_bytes}
    ]

    {:ok, Port.open({:spawn_executable, String.to_charlist(config.executable)}, options)}
  catch
    _kind, _reason -> {:error, :open_failed}
  end

  defp port_environment(supplied) do
    allowed = supplied |> Map.keys() |> Enum.map(&normalize_env_name/1) |> MapSet.new()

    removed =
      System.get_env()
      |> Map.keys()
      |> Enum.reject(&(normalize_env_name(&1) in allowed))
      |> Enum.sort_by(&normalize_env_name/1)
      |> Enum.map(&{String.to_charlist(&1), false})

    added =
      supplied
      |> Enum.sort_by(fn {name, _value} -> normalize_env_name(name) end)
      |> Enum.map(fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)

    removed ++ added
  end

  defp owner_loop(state) do
    receive do
      {:DOWN, monitor, :process, caller, _reason}
      when monitor == state.caller_monitor and caller == state.caller ->
        stop_owner(state)

      {@call_tag, token, from, call_ref, {:request, kind, wire}, timeout}
      when token == state.token ->
        handle_request_call(state, from, call_ref, kind, wire, timeout)

      {@call_tag, token, from, call_ref, :close, _timeout} when token == state.token ->
        send(from, {call_ref, :ok})
        stop_owner(state)

      {@call_tag, token, from, call_ref, {:handoff, target}, _timeout}
      when token == state.token and from == state.caller and target == from ->
        handoff_port(state, from, call_ref)

      {port, {:data, {flag, chunk}}} when port == state.port and flag in [:eol, :noeol] ->
        case ingest(state, flag, chunk) do
          {:ok, next_state} -> owner_loop(next_state)
          :error -> stop_owner(state)
        end

      {port, :eof} when port == state.port ->
        stop_owner(state)

      {port, {:exit_status, _status}} when port == state.port ->
        stop_owner(state)

      {:EXIT, port, _reason} when port == state.port ->
        stop_owner(state)

      _other ->
        owner_loop(state)
    end
  end

  defp handle_request_call(state, from, call_ref, :notification, wire, _timeout) do
    Port.command(state.port, wire)
    send(from, {call_ref, :ok})
    owner_loop(state)
  end

  defp handle_request_call(state, from, call_ref, :numeric, wire, timeout) do
    Port.command(state.port, wire)
    await_response(state, from, call_ref, timeout)
  end

  defp await_response(%{queued_frame: {:frame, frame}} = state, from, call_ref, _timeout) do
    send(from, {call_ref, {:ok, envelope([frame], state.noise_count, false, false)}})
    owner_loop(reset_ingress(state))
  end

  defp await_response(state, from, call_ref, timeout) do
    receive do
      {:DOWN, monitor, :process, caller, _reason}
      when monitor == state.caller_monitor and caller == state.caller ->
        stop_owner(state)

      {@call_tag, token, other_from, other_ref, action, _other_timeout}
      when token == state.token ->
        send(other_from, {other_ref, concurrent_error(action)})
        send_and_stop(state, from, call_ref, {:error, :transport_failed})

      {port, {:data, {flag, chunk}}} when port == state.port and flag in [:eol, :noeol] ->
        case ingest(state, flag, chunk) do
          {:ok, %{queued_frame: {:frame, frame}} = next_state} ->
            send(from, {call_ref, {:ok, envelope([frame], next_state.noise_count, false, false)}})
            owner_loop(reset_ingress(next_state))

          {:ok, next_state} ->
            await_response(next_state, from, call_ref, timeout)

          :error ->
            send_and_stop(state, from, call_ref, {:error, :transport_failed})
        end

      {port, :eof} when port == state.port ->
        {eof, exited} = terminal_flags(port, true, false)
        send_and_stop(state, from, call_ref, {:ok, envelope([], state.noise_count, eof, exited)})

      {port, {:exit_status, _status}} when port == state.port ->
        {eof, exited} = terminal_flags(port, false, true)
        send_and_stop(state, from, call_ref, {:ok, envelope([], state.noise_count, eof, exited)})

      {:EXIT, port, _reason} when port == state.port ->
        {eof, exited} = terminal_flags(port, false, true)
        send_and_stop(state, from, call_ref, {:ok, envelope([], state.noise_count, eof, exited)})

      _other ->
        await_response(state, from, call_ref, timeout)
    after
      timeout ->
        send_and_stop(state, from, call_ref, {:error, :timeout})
    end
  end

  defp concurrent_error(:close), do: {:error, :close_failed}
  defp concurrent_error(:handoff), do: {:error, :handoff_failed}
  defp concurrent_error(_action), do: {:error, :transport_failed}

  defp terminal_flags(port, eof, exited) do
    receive do
      {^port, :eof} -> terminal_flags(port, true, exited)
      {^port, {:exit_status, _status}} -> terminal_flags(port, eof, true)
      {:EXIT, ^port, _reason} -> terminal_flags(port, eof, true)
    after
      5 -> {eof, exited}
    end
  end

  defp ingest(state, flag, chunk) when is_binary(chunk) do
    pending_size = byte_size(state.pending)

    if byte_size(chunk) > state.max_frame_bytes - pending_size do
      :error
    else
      next_pending = state.pending <> chunk

      case flag do
        :noeol -> {:ok, %{state | pending: next_pending}}
        :eol -> ingest_complete_line(%{state | pending: <<>>}, next_pending)
      end
    end
  end

  defp ingest(_state, _flag, _chunk), do: :error

  defp ingest_complete_line(state, line) do
    case decode_unique_json(line) do
      {:ok, frame} ->
        if state.queued_frame == :none,
          do: {:ok, %{state | queued_frame: {:frame, frame}}},
          else: :error

      :noise ->
        if state.noise_count < state.max_noise_frames,
          do: {:ok, %{state | noise_count: state.noise_count + 1}},
          else: :error

      :error ->
        :error
    end
  end

  defp decode_unique_json(line) do
    case Jason.decode(line, objects: :ordered_objects) do
      {:ok, value} -> normalize_json(value)
      {:error, _reason} -> if json_looking?(line), do: :error, else: :noise
    end
  end

  defp normalize_json(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(keys) == length(Enum.uniq(keys)) do
      Enum.reduce_while(pairs, {:ok, %{}}, &normalize_json_pair/2)
    else
      :error
    end
  end

  defp normalize_json(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized} ->
      case normalize_json(value) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp normalize_json(value) when is_binary(value) or is_boolean(value) or is_nil(value) or is_number(value),
    do: {:ok, value}

  defp normalize_json_pair({key, value}, {:ok, object}) do
    case normalize_json(value) do
      {:ok, normalized} -> {:cont, {:ok, Map.put(object, key, normalized)}}
      :error -> {:halt, :error}
    end
  end

  defp json_looking?(line) do
    String.match?(String.trim_leading(line), ~r/\A(?:[\{\[\"\-0-9]|true(?:\s|\z)|false(?:\s|\z)|null(?:\s|\z))/)
  end

  defp encode_request(id, method, params, timeout)
       when is_integer(id) and id > 0 and is_binary(method) and method != "" and is_map(params) do
    with true <- valid_timeout?(timeout),
         true <- json_input?(params),
         {:ok, encoded_method} <- Jason.encode(method),
         {:ok, encoded_params} <- Jason.encode(params) do
      wire = ["{\"id\":", Integer.to_string(id), ",\"method\":", encoded_method, ",\"params\":", encoded_params, "}\n"]
      {:ok, :numeric, IO.iodata_to_binary(wire)}
    else
      _other -> :error
    end
  end

  defp encode_request(:notification, "initialized", :omit, timeout) do
    if valid_timeout?(timeout),
      do: {:ok, :notification, "{\"method\":\"initialized\"}\n"},
      else: :error
  end

  defp encode_request(_id, _method, _params, _timeout), do: :error

  defp json_input?(value) when is_binary(value) or is_boolean(value) or is_nil(value) or is_number(value), do: true
  defp json_input?([]), do: true
  defp json_input?([_value | _rest] = values), do: proper_list?(values, &json_input?/1)

  defp json_input?(value) when is_map(value),
    do: Enum.all?(value, fn {key, nested} -> is_binary(key) and json_input?(nested) end)

  defp json_input?(_value), do: false

  defp proper_list?([], _validator), do: true

  defp proper_list?([value | rest], validator),
    do: validator.(value) and proper_list?(rest, validator)

  defp proper_list?(_not_a_proper_list, _validator), do: false

  defp owner_call(owner, token, action, timeout, kind) do
    monitor = Process.monitor(owner)
    call_ref = make_ref()
    send(owner, {@call_tag, token, self(), call_ref, action, timeout})

    receive do
      {^call_ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        down_result(kind)
    after
      timeout + @reply_grace_ms ->
        terminate_process(owner)
        Process.demonitor(monitor, [:flush])
        timeout_result(kind)
    end
  end

  defp down_result(:close), do: :ok
  defp down_result(:request), do: {:error, :transport_failed}
  defp down_result(:handoff), do: {:error, :handoff_failed}
  defp timeout_result(:close), do: {:error, :close_failed}
  defp timeout_result(:request), do: {:error, :timeout}
  defp timeout_result(:handoff), do: {:error, :handoff_failed}

  defp envelope(frames, noise_count, eof, exited) do
    %{
      "frames" => frames,
      "noise" => List.duplicate(@noise_sentinel, noise_count),
      "eof" => eof,
      "exited" => exited
    }
  end

  defp reset_ingress(state),
    do: %{state | pending: <<>>, noise_count: 0, queued_frame: :none}

  defp send_and_stop(state, recipient, call_ref, result) do
    send(recipient, {call_ref, result})
    stop_owner(state)
  end

  defp stop_owner(state) do
    close_port(state.port)
    :ok
  end

  defp close_port(port) do
    if :erlang.port_info(port) != :undefined, do: Port.close(port)
    :ok
  end

  defp poison(owner, result) do
    terminate_process(owner)
    result
  end

  defp terminate_process(owner) when is_pid(owner) do
    if Process.alive?(owner), do: Process.exit(owner, :kill)

    :ok
  end

  defp transport_parts({__MODULE__, owner, token}) when is_pid(owner) and is_reference(token),
    do: {:ok, owner, token}

  defp transport_parts(_transport), do: :error

  defp handoff_port(state, caller, call_ref) do
    if quiescent?(state) do
      handoff_token = make_ref()

      try do
        true = Port.connect(state.port, caller)
        _ = Process.unlink(state.port)

        metadata = %{handoff_owner: self(), handoff_token: handoff_token}
        send(caller, {call_ref, {:ok, state.port, metadata}})
        handoff_loop(Map.put(state, :handoff_token, handoff_token))
      rescue
        _error ->
          send_and_stop(state, caller, call_ref, {:error, :handoff_failed})
      catch
        _kind, _reason ->
          send_and_stop(state, caller, call_ref, {:error, :handoff_failed})
      end
    else
      send(caller, {call_ref, {:error, :handoff_failed}})
      owner_loop(state)
    end
  end

  defp handoff_loop(state) do
    receive do
      {:DOWN, monitor, :process, caller, _reason}
      when monitor == state.caller_monitor and caller == state.caller ->
        close_port(state.port)

      {@handoff_tag, token, caller, call_ref}
      when token == state.handoff_token and caller == state.caller ->
        result = if port_connected_to?(state.port, caller), do: :ok, else: {:error, :handoff_failed}
        send(caller, {call_ref, result})

        if result == :ok do
          :ok
        else
          close_port(state.port)
        end

      _other ->
        handoff_loop(state)
    end
  end

  defp claim_handoff_owner(owner, token, caller, timeout)
       when is_pid(owner) and is_reference(token) and is_pid(caller) do
    monitor = Process.monitor(owner)
    call_ref = make_ref()
    send(owner, {@handoff_tag, token, caller, call_ref})

    receive do
      {^call_ref, :ok} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {^call_ref, _other} ->
        Process.demonitor(monitor, [:flush])
        {:error, :handoff_failed}

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        {:error, :handoff_failed}
    after
      timeout + @reply_grace_ms ->
        Process.demonitor(monitor, [:flush])
        {:error, :handoff_failed}
    end
  end

  defp claim_handoff_owner(_owner, _token, _caller, _timeout), do: {:error, :handoff_failed}

  defp quiescent?(state) do
    state.pending == <<>> and state.noise_count == 0 and state.queued_frame == :none
  end

  defp valid_handoff_metadata?(%{handoff_owner: owner, handoff_token: token} = metadata) do
    map_size(metadata) == 2 and is_pid(owner) and is_reference(token)
  end

  defp valid_handoff_metadata?(_metadata), do: false

  defp port_connected_to?(port, pid) when is_port(port) and is_pid(pid) do
    case :erlang.port_info(port, :connected) do
      {:connected, ^pid} -> true
      _other -> false
    end
  end

  defp port_connected_to?(_port, _pid), do: false
end
