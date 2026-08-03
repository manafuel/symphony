defmodule SymphonyElixir.ProducerV6.BrokerGuardian do
  @moduledoc """
  Owns the persistent PowerShell broker-authority port for a production epoch.

  The guardian keeps the named mutex object and a non-inheritable handle to the
  frozen workspace root alive. Bounded transaction actions still use their exact
  reviewed argument arrays and are serialized by that named mutex.
  """

  use GenServer

  @name __MODULE__
  @ready "READY"
  @startup_timeout 15_000

  @spec ensure(Path.t(), Path.t()) :: :ok | {:error, term()}
  def ensure(powershell_path, broker_path)
      when is_binary(powershell_path) and is_binary(broker_path) do
    authority_root =
      Application.get_env(:symphony_elixir, :producer_v6_guardian_authority_root)

    ensure(powershell_path, broker_path, authority_root)
  end

  @spec ensure(Path.t(), Path.t(), Path.t()) :: :ok | {:error, term()}
  def ensure(powershell_path, broker_path, authority_root)
      when is_binary(powershell_path) and is_binary(broker_path) and is_binary(authority_root) do
    request = {Path.expand(powershell_path), Path.expand(broker_path), Path.expand(authority_root)}

    case Process.whereis(@name) do
      nil -> start(request)
      _pid -> GenServer.call(@name, {:ensure, request}, @startup_timeout)
    end
  end

  def ensure(_powershell_path, _broker_path, _authority_root),
    do: {:error, :invalid_broker_guardian_binding}

  @impl true
  def init({_powershell_path, broker_path, _authority_root} = binding) do
    guardian_path =
      broker_path
      |> Path.dirname()
      |> Path.join("..\\bin\\codex-symphony-broker-guardian.exe")
      |> Path.expand()

    if not File.regular?(guardian_path) do
      raise ArgumentError, "broker guardian executable is absent"
    end

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(guardian_path)},
        [:binary, :exit_status, :use_stdio, :stderr_to_stdout]
      )

    receive do
      {^port, {:data, @ready}} -> {:ok, %{binding: binding, port: port}}
      {^port, {:exit_status, status}} -> {:stop, {:broker_guardian_exit, status}}
      {^port, {:data, _foreign}} -> {:stop, :broker_guardian_ready_protocol_invalid}
    after
      @startup_timeout ->
        Port.close(port)
        {:stop, :broker_guardian_ready_timeout}
    end
  rescue
    error -> {:stop, {:broker_guardian_start_failed, error}}
  end

  @impl true
  def handle_call({:ensure, binding}, _from, %{binding: binding} = state),
    do: {:reply, :ok, state}

  def handle_call({:ensure, _different}, _from, state),
    do: {:reply, {:error, :broker_guardian_binding_drift}, state}

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:broker_guardian_exit, status}, state}

  def handle_info({_port, {:data, _unexpected}}, state),
    do: {:stop, :broker_guardian_unexpected_stdout, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start(binding) do
    case GenServer.start(__MODULE__, binding, name: @name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> GenServer.call(@name, {:ensure, binding}, @startup_timeout)
      {:error, reason} -> {:error, reason}
    end
  end
end
