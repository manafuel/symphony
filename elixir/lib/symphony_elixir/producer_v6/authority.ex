defmodule SymphonyElixir.ProducerV6.Authority do
  @moduledoc """
  Process-local, command-line-derived authority for the reviewed producer-v6 runtime.

  The CLI stores only absolute paths and expected digests. The orchestrator reopens
  every authority document before it selects a durable ledger implementation, so
  application environment state cannot substitute documents or bypass byte binding.
  """

  alias SymphonyElixir.ProducerContract

  @application :symphony_elixir
  @key :producer_v6_authority
  @authority_keys ~w(launch_path launch_sha256 contract_path contract_sha256 workflow_path)a

  @type t :: %{
          launch_path: String.t(),
          launch_sha256: String.t(),
          contract_path: String.t(),
          contract_sha256: String.t(),
          workflow_path: String.t()
        }

  @spec install(map(), map(), String.t()) :: :ok | {:error, term()}
  def install(
        %{path: launch_path, sha256: launch_sha256},
        %{path: contract_path, sha256: contract_sha256},
        workflow_path
      )
      when is_binary(workflow_path) do
    authority = %{
      launch_path: Path.expand(launch_path),
      launch_sha256: launch_sha256,
      contract_path: Path.expand(contract_path),
      contract_sha256: contract_sha256,
      workflow_path: Path.expand(workflow_path)
    }

    case Application.get_env(@application, @key) do
      nil ->
        Application.put_env(@application, @key, authority, persistent: true)
        :ok

      ^authority ->
        :ok

      _different ->
        {:error, :production_authority_already_installed}
    end
  end

  def install(_launch, _contract, _workflow_path),
    do: {:error, :invalid_production_authority_install}

  @spec resolve() :: {:ok, :preview | map()} | {:error, term()}
  def resolve do
    case Application.get_env(@application, @key) do
      nil ->
        {:ok, :preview}

      authority when is_map(authority) ->
        reopen(authority)

      _invalid ->
        {:error, :invalid_production_authority_state}
    end
  end

  @doc false
  @spec restore_for_test(term()) :: :ok
  def restore_for_test(nil) do
    Application.delete_env(@application, @key, persistent: true)
    :ok
  end

  def restore_for_test(value) do
    Application.put_env(@application, @key, value, persistent: true)
    :ok
  end

  @doc false
  @spec current_for_test() :: term()
  def current_for_test, do: Application.get_env(@application, @key)

  defp reopen(authority) do
    with :ok <- exact_keys(authority),
         {:ok, launch} <-
           ProducerContract.validate_launch_receipt(
             authority.launch_path,
             authority.launch_sha256
           ),
         {:ok, contract} <-
           ProducerContract.load(authority.contract_path, authority.contract_sha256),
         :ok <-
           ProducerContract.validate_production_authority(
             launch,
             contract,
             authority.workflow_path
           ) do
      {:ok,
       %{
         kind: :producer_v6,
         launch: launch,
         contract: contract,
         workflow_path: authority.workflow_path
       }}
    end
  end

  defp exact_keys(authority) do
    if Enum.sort(Map.keys(authority)) == Enum.sort(@authority_keys),
      do: :ok,
      else: {:error, :invalid_production_authority_property_set}
  end
end
