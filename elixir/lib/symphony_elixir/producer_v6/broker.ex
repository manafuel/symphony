defmodule SymphonyElixir.ProducerV6.Broker do
  @moduledoc """
  Bound client for the reviewed Windows producer-v6 file transaction broker.

  The executable and script locations are fixed by the producer contract. Before
  every action, the tracked script and JCS provider are compared with the exact
  target-source Git objects named by the immutable launch receipt.
  """

  alias SymphonyElixir.ProducerV6.{BrokerGuardian, Format}
  alias SymphonyElixir.Rfc8785Jcs

  @broker_relative ".codex/scripts/codex-symphony-file-transaction-broker.ps1"
  @jcs_relative ".codex/scripts/codex-rfc8785-jcs.ps1"
  @powershell "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
  @request_schema "manafuel.symphony_file_transaction_broker_request.v1"
  @result_schema "manafuel.symphony_file_transaction_broker_result.v1"
  @result_keys ~w(schema_version action request_sha256 deadline_at_utc completed_at_utc decision error_code result)

  @type authority :: %{required(:launch) => %{required(:document) => map()}, required(:contract) => map()}

  @spec inspect(Path.t(), Path.t(), authority()) :: {:ok, map()} | {:error, term()}
  def inspect(path, workspace_root, authority) do
    invoke("Inspect", %{"path" => Path.expand(path)}, workspace_root, authority, deadline_after(30))
  end

  @spec verify_reference(map(), Path.t(), authority()) :: {:ok, map()} | {:error, term()}
  def verify_reference(reference, workspace_root, authority) when is_map(reference) do
    invoke(
      "VerifyReference",
      %{"reference" => stringify_keys(reference)},
      workspace_root,
      authority,
      deadline_after(30)
    )
  end

  @spec publish_cas(map(), String.t(), Path.t(), authority(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def publish_cas(document, root_name, workspace_root, authority, deadline_at_utc)
      when is_map(document) and is_binary(root_name) do
    with {:ok, destination, maximum_bytes} <-
           cas_contract(root_name, workspace_root, authority),
         {:ok, bytes} <- Rfc8785Jcs.encode(stringify_keys(document)),
         true <- byte_size(bytes) <= maximum_bytes,
         digest = sha256(bytes),
         {:ok, source_path} <- publish_broker_input(workspace_root, digest, bytes),
         {:ok, identity} <-
           invoke(
             "PublishCas",
             %{
               "source_path" => source_path,
               "destination_directory" => destination,
               "maximum_bytes" => maximum_bytes
             },
             workspace_root,
             authority,
             deadline_at_utc
           ),
         {:ok, reference} <-
           immutable_reference(identity, workspace_root, digest, byte_size(bytes)) do
      {:ok, reference}
    else
      false -> {:error, {:producer_cas_limit_exceeded, root_name}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec publish_bytes(binary(), String.t(), Path.t(), authority(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def publish_bytes(bytes, root_name, workspace_root, authority, deadline_at_utc)
      when is_binary(bytes) and is_binary(root_name) do
    with {:ok, destination, maximum_bytes} <-
           cas_contract(root_name, workspace_root, authority),
         true <- byte_size(bytes) <= maximum_bytes,
         digest = sha256(bytes),
         {:ok, source_path} <- publish_broker_input(workspace_root, digest, bytes),
         {:ok, identity} <-
           invoke(
             "CaptureFileToCas",
             %{
               "source_path" => source_path,
               "destination_directory" => destination,
               "maximum_bytes" => maximum_bytes
             },
             workspace_root,
             authority,
             deadline_at_utc
           ),
         {:ok, reference} <-
           immutable_reference(identity, workspace_root, digest, byte_size(bytes)) do
      {:ok, reference}
    else
      false -> {:error, {:producer_cas_limit_exceeded, root_name}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec publish_cas_at(map(), String.t(), pos_integer(), Path.t(), authority(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def publish_cas_at(
        document,
        relative_root,
        maximum_bytes,
        workspace_root,
        authority,
        deadline_at_utc
      )
      when is_map(document) and is_binary(relative_root) and is_integer(maximum_bytes) and
             maximum_bytes > 0 do
    with true <- String.starts_with?(relative_root, ".symphony-state/"),
         true <- String.ends_with?(relative_root, "/sha256"),
         {:ok, bytes} <- Rfc8785Jcs.encode(stringify_keys(document)),
         true <- byte_size(bytes) <= maximum_bytes,
         digest = sha256(bytes),
         {:ok, source_path} <- publish_broker_input(workspace_root, digest, bytes),
         {:ok, identity} <-
           invoke(
             "PublishCas",
             %{
               "source_path" => source_path,
               "destination_directory" => Path.join(workspace_root, windows_relative(relative_root)),
               "maximum_bytes" => maximum_bytes
             },
             workspace_root,
             authority,
             deadline_at_utc
           ),
         {:ok, reference} <-
           immutable_reference(identity, workspace_root, digest, byte_size(bytes)) do
      {:ok, reference}
    else
      false -> {:error, :producer_arbitrary_cas_contract_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec allocate_dispatch(
          map(),
          pos_integer(),
          pos_integer(),
          String.t(),
          Path.t(),
          authority(),
          String.t()
        ) ::
          {:ok, %{allocation: map(), reference: map(), replay: boolean()}} | {:error, term()}
  def allocate_dispatch(
        issue,
        dispatch_sequence,
        retry_attempt,
        allocated_at_utc,
        workspace_root,
        authority,
        deadline_at_utc
      )
      when is_map(issue) and is_integer(dispatch_sequence) and dispatch_sequence > 0 and
             is_integer(retry_attempt) and retry_attempt > 0 do
    with {:ok, result} <-
           invoke(
             "AllocateDispatch",
             %{
               "issue" => stringify_keys(issue),
               "dispatch_sequence" => dispatch_sequence,
               "retry_attempt" => retry_attempt,
               "allocated_at_utc" => allocated_at_utc
             },
             workspace_root,
             authority,
             deadline_at_utc
           ),
         allocation when is_map(allocation) <- result["allocation"],
         identity when is_map(identity) <- result["reference"],
         {:ok, allocation_bytes} <- Rfc8785Jcs.encode(allocation),
         digest = sha256(allocation_bytes),
         {:ok, reference} <- immutable_reference(identity, workspace_root, digest, nil),
         replay when is_boolean(replay) <- result["replay"] do
      {:ok, %{allocation: allocation, reference: reference, replay: replay}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :dispatch_allocation_broker_result_invalid}
    end
  end

  @spec acquire_lock(String.t(), pos_integer(), String.t(), Path.t(), authority()) ::
          {:ok, %{lock: map(), reference: map()}} | {:error, term()}
  def acquire_lock(process_epoch_id, owner_os_pid, deadline_at_utc, workspace_root, authority)
      when is_binary(process_epoch_id) and is_integer(owner_os_pid) and owner_os_pid > 0 do
    with {:ok, result} <-
           invoke(
             "AcquireLedgerWriteLock",
             %{
               "owner_process_epoch_id" => process_epoch_id,
               "owner_os_pid" => owner_os_pid,
               "acquired_at_utc" => producer_now(),
               "authority_deadline_at_utc" => deadline_at_utc
             },
             workspace_root,
             authority,
             deadline_at_utc
           ),
         lock when is_map(lock) <- result["lock"],
         identity when is_map(identity) <- result["reference"],
         {:ok, reference} <- immutable_reference(identity, workspace_root, nil, nil) do
      {:ok, %{lock: lock, reference: reference}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :ledger_lock_broker_result_invalid}
    end
  end

  @spec ensure_ledger_pair(Path.t(), authority()) :: :ok | {:error, term()}
  def ensure_ledger_pair(workspace_root, authority)
      when is_binary(workspace_root) and is_map(authority) do
    current = Path.join(workspace_root, ".symphony-state\\execution.json")
    previous = Path.join(workspace_root, ".symphony-state\\execution.previous.json")

    case {File.exists?(current), File.exists?(previous)} do
      {true, true} -> :ok
      {false, false} -> bootstrap_empty_ledger(workspace_root, authority, current, previous)
      _ -> {:error, :producer_v6_initial_ledger_pair_split}
    end
  end

  def ensure_ledger_pair(_workspace_root, _authority),
    do: {:error, :producer_v6_initial_ledger_authority_invalid}

  @spec release_lock(map(), String.t(), Path.t(), authority()) :: :ok | {:error, term()}
  def release_lock(reference, deadline_at_utc, workspace_root, authority) when is_map(reference) do
    with {:ok, result} <-
           invoke(
             "ReleaseLedgerWriteLockCas",
             %{"expected_lock" => absolute_reference(reference, workspace_root)},
             workspace_root,
             authority,
             deadline_at_utc
           ),
         true <- result["released"] do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :ledger_lock_release_failed}
    end
  end

  @spec invoke(String.t(), map(), Path.t(), authority(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def invoke(action, parameters, workspace_root, authority, deadline_at_utc) do
    with {:ok, response} <-
           invoke_receipt(action, parameters, workspace_root, authority, deadline_at_utc) do
      {:ok, response["result"]}
    end
  end

  @spec invoke_receipt(String.t(), map(), Path.t(), authority(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def invoke_receipt(action, parameters, workspace_root, authority, deadline_at_utc)
      when is_binary(action) and is_map(parameters) and is_binary(workspace_root) and
             is_map(authority) and is_binary(deadline_at_utc) do
    with {:ok, binding} <- resolve_binding(authority),
         :ok <- exact_workspace_root(workspace_root, authority),
         {:ok, request} <- build_request(action, parameters, workspace_root, deadline_at_utc),
         {:ok, request_bytes} <- Rfc8785Jcs.encode(request),
         request_sha256 = sha256(request_bytes),
         {:ok, request_path} <- publish_request(workspace_root, request_sha256, request_bytes),
         {:ok, stdout} <-
           run_broker(binding, action, workspace_root, request_path, request_sha256, deadline_at_utc),
         {:ok, response} <- Rfc8785Jcs.validate_canonical(stdout),
         :ok <- validate_response(response, action, request_sha256, deadline_at_utc) do
      {:ok, response}
    end
  end

  def invoke_receipt(_action, _parameters, _workspace_root, _authority, _deadline_at_utc),
    do: {:error, :invalid_broker_invocation}

  defp resolve_binding(%{launch: %{document: launch}}) when is_map(launch) do
    source = launch["source"]

    with root when is_binary(root) <- source["git_root"],
         source_sha when is_binary(source_sha) <- source["head_sha"],
         :ok <- exact_source_head(source),
         broker_path = Path.join(root, windows_relative(@broker_relative)),
         jcs_path = Path.join(root, windows_relative(@jcs_relative)),
         :ok <- tracked_file(root, source_sha, @broker_relative, broker_path),
         :ok <- tracked_file(root, source_sha, @jcs_relative, jcs_path),
         true <- File.regular?(@powershell) do
      {:ok, %{broker_path: Path.expand(broker_path), powershell_path: @powershell}}
    else
      false -> {:error, :trusted_powershell_missing}
      nil -> {:error, :broker_source_binding_missing}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :broker_source_binding_invalid}
    end
  end

  defp resolve_binding(_authority), do: {:error, :invalid_broker_authority}

  defp exact_source_head(%{
         "head_sha" => head_sha,
         "protected_ref" => "origin/main",
         "protected_ref_sha" => head_sha
       }),
       do: :ok

  defp exact_source_head(_source), do: {:error, :broker_source_head_not_protected}

  defp tracked_file(root, source_sha, relative, path) do
    with true <- File.regular?(path),
         {:ok, bytes} <- File.read(path),
         {:ok, expected_blob} <- git(root, ["rev-parse", "#{source_sha}:#{relative}"]),
         {:ok, installed_blob} <- git(root, ["hash-object", "--no-filters", path]),
         true <- expected_blob == installed_blob,
         true <- Format.lower_hex?(sha256(bytes), 64) do
      :ok
    else
      false -> {:error, {:tracked_broker_file_drift, relative}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git(root, arguments) do
    case System.cmd("git", ["-C", root | arguments], stderr_to_stdout: true) do
      {output, 0} ->
        value = String.trim(output)

        if value == "" or String.contains?(value, ["\r", "\n"]),
          do: {:error, :git_binding_output_invalid},
          else: {:ok, value}

      {_output, _status} ->
        {:error, :git_binding_failed}
    end
  rescue
    _ -> {:error, :git_binding_failed}
  end

  defp exact_workspace_root(workspace_root, %{contract: %{document: contract}}) do
    expected = get_in(contract, ["constants", "workspace_root_windows"])

    if comparable_path(workspace_root) == comparable_path(expected),
      do: :ok,
      else: {:error, :broker_workspace_root_mismatch}
  end

  defp exact_workspace_root(_workspace_root, _authority),
    do: {:error, :broker_contract_authority_missing}

  defp build_request(action, parameters, workspace_root, deadline_at_utc) do
    with true <- Format.producer_datetime?(deadline_at_utc) do
      {:ok,
       %{
         "schema_version" => @request_schema,
         "action" => action,
         "request_id" => request_id(System.unique_integer([:positive, :monotonic])),
         "authority_root" => Path.expand(workspace_root),
         "deadline_at_utc" => deadline_at_utc,
         "parameters" => stringify_keys(parameters)
       }}
    else
      _ -> {:error, :broker_deadline_invalid}
    end
  end

  defp request_id(integer) do
    integer
    |> :binary.encode_unsigned()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp publish_request(workspace_root, digest, bytes) do
    directory = Path.join(workspace_root, ".symphony-state\\broker-requests\\sha256")
    path = Path.join(directory, digest <> ".json")

    with :ok <- File.mkdir_p(directory),
         :ok <- create_or_verify(path, bytes) do
      {:ok, Path.expand(path)}
    end
  end

  defp publish_broker_input(workspace_root, digest, bytes) do
    directory =
      Path.join(
        workspace_root,
        ".symphony-state\\broker-inputs\\sha256\\#{binary_part(digest, 0, 2)}"
      )

    path = Path.join(directory, digest <> ".json")

    with :ok <- File.mkdir_p(directory),
         :ok <- create_or_verify(path, bytes) do
      {:ok, Path.expand(path)}
    end
  end

  defp cas_contract(root_name, workspace_root, %{contract: %{document: contract}}) do
    relative = get_in(contract, ["path_roots", root_name])
    maximum = get_in(contract, ["cas_limits", root_name])

    if is_binary(relative) and String.starts_with?(relative, ".symphony-state/") and
         is_integer(maximum) and maximum > 0 do
      {:ok, Path.join(workspace_root, windows_relative(relative)), maximum}
    else
      {:error, {:producer_cas_contract_invalid, root_name}}
    end
  end

  defp cas_contract(root_name, _workspace_root, _authority),
    do: {:error, {:producer_cas_contract_invalid, root_name}}

  defp immutable_reference(identity, workspace_root, expected_sha, expected_length)
       when is_map(identity) do
    absolute_path = identity["path"]

    relative =
      absolute_path
      |> Path.relative_to(Path.expand(workspace_root))
      |> String.replace("\\", "/")

    with true <- Path.type(relative) == :relative,
         false <- String.starts_with?(relative, "../"),
         "regular" <- identity["file_type"],
         1 <- identity["link_count"],
         true <- is_nil(expected_sha) or identity["sha256"] == expected_sha,
         true <- is_nil(expected_length) or identity["length"] == expected_length do
      {:ok,
       %{
         "path" => relative,
         "physical_path" => identity["physical_path"],
         "volume_id" => identity["volume_id"],
         "file_id" => identity["file_id"],
         "file_type" => "regular",
         "link_count" => 1,
         "sha256" => identity["sha256"],
         "length" => identity["length"]
       }}
    else
      _ -> {:error, :broker_identity_not_an_immutable_reference}
    end
  end

  defp immutable_reference(_identity, _workspace_root, _expected_sha, _expected_length),
    do: {:error, :broker_identity_not_an_immutable_reference}

  defp absolute_reference(reference, workspace_root) do
    string_reference = stringify_keys(reference)

    Map.put(
      string_reference,
      "path",
      Path.join(workspace_root, windows_relative(string_reference["path"]))
    )
  end

  defp create_or_verify(path, bytes) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        result = with :ok <- IO.binwrite(io, bytes), do: :file.sync(io)
        File.close(io)
        result

      {:error, :eexist} ->
        case File.read(path) do
          {:ok, ^bytes} -> :ok
          {:ok, _foreign} -> {:error, :foreign_broker_request_digest_path}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_broker(binding, action, workspace_root, request_path, request_sha256, deadline) do
    arguments = [
      "-NoLogo",
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      binding.broker_path,
      "-Action",
      action,
      "-AuthorityRoot",
      Path.expand(workspace_root),
      "-RequestPath",
      request_path,
      "-ExpectedRequestSha256",
      request_sha256,
      "-DeadlineAtUtc",
      deadline
    ]

    with :ok <-
           BrokerGuardian.ensure(
             binding.powershell_path,
             binding.broker_path,
             workspace_root
           ) do
      case System.cmd(binding.powershell_path, arguments, stderr_to_stdout: true) do
        {stdout, 0} when byte_size(stdout) <= 1_048_576 -> {:ok, stdout}
        {_stdout, 0} -> {:error, :broker_stdout_limit_exceeded}
        {_stdout, status} -> {:error, {:broker_process_failed, status}}
      end
    end
  rescue
    _ -> {:error, :broker_process_failed}
  end

  defp bootstrap_empty_ledger(workspace_root, authority, current, previous) do
    deadline = deadline_after(120)
    process_epoch_id = "symboot-" <> random_hex(16)

    with {:ok, lock} <-
           acquire_lock(process_epoch_id, owner_os_pid(), deadline, workspace_root, authority) do
      case {File.exists?(current), File.exists?(previous)} do
        {true, true} ->
          release_lock(lock.reference, deadline, workspace_root, authority)

        {false, false} ->
          bootstrap_under_lock(
            workspace_root,
            authority,
            current,
            previous,
            deadline,
            lock
          )

        _ ->
          {:error, {:producer_v6_initial_ledger_pair_split_lock_retained, lock.reference}}
      end
    end
  end

  defp bootstrap_under_lock(workspace_root, authority, current, previous, deadline, lock) do
    ledger = %{
      "schema_version" => "symphony.execution_ledger.v6",
      "generation_id" => random_hex(16),
      "generated_at" => producer_now(),
      "blocked" => [],
      "retrying" => [],
      "effects" => []
    }

    result =
      with {:ok, target} <-
             publish_cas(ledger, "ledger_snapshot", workspace_root, authority, deadline),
           {:ok, receipt} <-
             invoke_receipt(
               "InstallDualLedgerAndReadback",
               %{
                 "lock" => absolute_reference(lock.reference, workspace_root),
                 "target_ledger_path" => Path.join(workspace_root, windows_relative(target["path"])),
                 "maximum_bytes" => 20_000,
                 "expected_previous" => nil,
                 "expected_current" => nil,
                 "previous_path" => previous,
                 "current_path" => current
               },
               workspace_root,
               authority,
               deadline
             ),
           :ok <- validate_bootstrap_result(receipt["result"], target) do
        :ok
      end

    case result do
      :ok ->
        release_lock(lock.reference, deadline, workspace_root, authority)

      {:error, reason} ->
        {:error, {:producer_v6_initial_ledger_install_blocked_lock_retained, reason, lock.reference}}
    end
  end

  defp validate_bootstrap_result(
         %{"destination_results" => [previous, current]},
         target
       ) do
    previous_reference = previous["reference"]
    current_reference = current["reference"]

    with "PREVIOUS" <- previous["role"],
         "CURRENT" <- current["role"],
         true <- previous_reference["sha256"] == target["sha256"],
         true <- current_reference["sha256"] == target["sha256"],
         true <- previous_reference["length"] == target["length"],
         true <- current_reference["length"] == target["length"],
         false <-
           previous_reference["volume_id"] == current_reference["volume_id"] and
             previous_reference["file_id"] == current_reference["file_id"] do
      :ok
    else
      _ -> {:error, :producer_v6_initial_ledger_broker_result_invalid}
    end
  end

  defp validate_bootstrap_result(_result, _target),
    do: {:error, :producer_v6_initial_ledger_broker_result_invalid}

  defp validate_response(response, action, request_sha256, deadline) when is_map(response) do
    with :ok <- exact_keys(response, @result_keys),
         :ok <- exact_value(response, "schema_version", @result_schema),
         :ok <- exact_value(response, "action", action),
         :ok <- exact_value(response, "request_sha256", request_sha256),
         :ok <- exact_value(response, "deadline_at_utc", deadline),
         :ok <- exact_value(response, "decision", "PASS"),
         :ok <- exact_value(response, "error_code", nil),
         true <- is_map(response["result"]) do
      :ok
    else
      false -> {:error, :broker_result_not_an_object}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_response(_response, _action, _request_sha256, _deadline),
    do: {:error, :broker_response_not_an_object}

  defp exact_keys(map, keys) do
    if Enum.sort(Map.keys(map)) == Enum.sort(keys),
      do: :ok,
      else: {:error, :broker_response_property_set_mismatch}
  end

  defp exact_value(map, key, expected) do
    if Map.get(map, key, :missing) === expected,
      do: :ok,
      else: {:error, {:broker_response_value_mismatch, key}}
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp producer_now do
    DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.%3fZ")
  end

  defp deadline_after(seconds) do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.%3fZ")
  end

  defp owner_os_pid, do: System.pid() |> String.to_integer()
  defp random_hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp windows_relative(relative), do: String.replace(relative, "/", "\\")

  defp comparable_path(path) when is_binary(path) do
    path
    |> Path.expand()
    |> String.replace("/", "\\")
    |> String.trim_trailing("\\")
    |> String.downcase()
  end

  defp comparable_path(_path), do: nil
end
