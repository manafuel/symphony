defmodule SymphonyElixir.ExecutionLedgerRouter do
  @moduledoc """
  Selects exactly one durable execution implementation before the orchestrator starts.

  Preview runs retain the legacy v5 ledger. A command-line-authorized production run
  can use only the producer-v6 ledger and never falls through to preview behavior.
  """

  alias SymphonyElixir.{ExecutionLedger, ProducerV6}
  alias SymphonyElixir.ProducerV6.{Authority, Execution}

  @spec load(Path.t()) ::
          {:ok, :preview | map(), %{blocked: map(), retrying: map(), effects: map()}}
          | {:error, term()}
  def load(workspace_root) do
    with {:ok, context} <- Authority.resolve(),
         {:ok, state} <- load_context(context, workspace_root) do
      {:ok, context, state}
    end
  end

  @spec persist(:preview | map(), Path.t(), map(), map(), map()) :: :ok | {:error, term()}
  def persist(:preview, workspace_root, blocked, retrying, effects),
    do: ExecutionLedger.persist(workspace_root, blocked, retrying, effects)

  def persist(%{kind: :producer_v6} = context, workspace_root, blocked, retrying, effects)
      when blocked == %{} and retrying == %{},
      do: Execution.verify_state(workspace_root, context, effects)

  def persist(_context, _workspace_root, _blocked, _retrying, _effects),
    do: {:error, :invalid_execution_ledger_context}

  @spec reserve_effect(:preview | map(), map(), term(), pos_integer()) ::
          {:ok, map(), map()} | {:duplicate, map()} | {:error, term()}
  def reserve_effect(:preview, effects, issue, attempt),
    do: ExecutionLedger.reserve_effect(effects, issue, attempt)

  def reserve_effect(%{kind: :producer_v6} = context, effects, issue, dispatch_sequence),
    do: Execution.reserve(context, effects, issue, dispatch_sequence, dispatch_sequence)

  def reserve_effect(_context, _effects, _issue, _attempt),
    do: {:error, :invalid_execution_ledger_context}

  @spec reserve_effect(:preview | map(), map(), term(), pos_integer(), pos_integer()) ::
          {:ok, map(), map()} | {:duplicate, map()} | {:error, term()}
  def reserve_effect(:preview, effects, issue, _dispatch_sequence, retry_attempt),
    do: ExecutionLedger.reserve_effect(effects, issue, retry_attempt)

  def reserve_effect(%{kind: :producer_v6} = context, effects, issue, dispatch_sequence, retry_attempt),
    do: Execution.reserve(context, effects, issue, dispatch_sequence, retry_attempt)

  def reserve_effect(_context, _effects, _issue, _dispatch_sequence, _retry_attempt),
    do: {:error, :invalid_execution_ledger_context}

  @spec mark_effect_started(:preview | map(), map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def mark_effect_started(:preview, effects, idempotency_key),
    do: ExecutionLedger.mark_effect_started(effects, idempotency_key)

  def mark_effect_started(%{kind: :producer_v6}, _effects, _idempotency_key),
    do: {:error, :producer_v6_worker_identity_required}

  def mark_effect_started(_context, _effects, _idempotency_key),
    do: {:error, :invalid_execution_ledger_context}

  @spec mark_effect_started(:preview | map(), map(), String.t(), pid() | String.t()) ::
          {:ok, map()} | {:error, term()}
  def mark_effect_started(:preview, effects, idempotency_key, _worker_pid),
    do: ExecutionLedger.mark_effect_started(effects, idempotency_key)

  def mark_effect_started(%{kind: :producer_v6} = context, effects, idempotency_key, worker_pid),
    do: Execution.mark_worker_registered(context, effects, idempotency_key, worker_pid)

  def mark_effect_started(_context, _effects, _idempotency_key, _worker_pid),
    do: {:error, :invalid_execution_ledger_context}

  @spec mark_workspace_ready(:preview | map(), map(), String.t(), Path.t()) ::
          {:ok, map()} | {:error, term()}
  def mark_workspace_ready(:preview, effects, _idempotency_key, _workspace_path), do: {:ok, effects}

  def mark_workspace_ready(%{kind: :producer_v6} = context, effects, idempotency_key, workspace_path),
    do: Execution.mark_workspace_ready(context, effects, idempotency_key, workspace_path)

  def mark_workspace_ready(_context, _effects, _idempotency_key, _workspace_path),
    do: {:error, :invalid_execution_ledger_context}

  @spec mark_claim_ready(:preview | map(), map(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def mark_claim_ready(:preview, effects, _idempotency_key, _claim), do: {:ok, effects}

  def mark_claim_ready(%{kind: :producer_v6} = context, effects, idempotency_key, claim),
    do: Execution.mark_claim_ready(context, effects, idempotency_key, claim)

  def mark_claim_ready(_context, _effects, _idempotency_key, _claim),
    do: {:error, :invalid_execution_ledger_context}

  @spec mark_admission_passed(:preview | map(), map(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def mark_admission_passed(:preview, effects, _idempotency_key, _admission), do: {:ok, effects}

  def mark_admission_passed(%{kind: :producer_v6} = context, effects, idempotency_key, admission),
    do: Execution.mark_admission_passed(context, effects, idempotency_key, admission)

  def mark_admission_passed(_context, _effects, _idempotency_key, _admission),
    do: {:error, :invalid_execution_ledger_context}

  @spec mark_thread_ready(:preview | map(), map(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def mark_thread_ready(:preview, effects, _idempotency_key, _thread), do: {:ok, effects}

  def mark_thread_ready(%{kind: :producer_v6} = context, effects, idempotency_key, thread),
    do: Execution.mark_thread_ready(context, effects, idempotency_key, thread)

  def mark_thread_ready(_context, _effects, _idempotency_key, _thread),
    do: {:error, :invalid_execution_ledger_context}

  @spec mark_turn_start_intent(:preview | map(), map(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def mark_turn_start_intent(:preview, effects, _idempotency_key, _intent), do: {:ok, effects}

  def mark_turn_start_intent(%{kind: :producer_v6} = context, effects, idempotency_key, intent),
    do: Execution.mark_turn_start_intent(context, effects, idempotency_key, intent)

  def mark_turn_start_intent(_context, _effects, _idempotency_key, _intent),
    do: {:error, :invalid_execution_ledger_context}

  @spec mark_turn_started(:preview | map(), map(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def mark_turn_started(:preview, effects, _idempotency_key, _started), do: {:ok, effects}

  def mark_turn_started(%{kind: :producer_v6} = context, effects, idempotency_key, started),
    do: Execution.mark_turn_started(context, effects, idempotency_key, started)

  def mark_turn_started(_context, _effects, _idempotency_key, _started),
    do: {:error, :invalid_execution_ledger_context}

  @spec mark_turn_terminal(:preview | map(), map(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def mark_turn_terminal(:preview, effects, _idempotency_key, _terminal), do: {:ok, effects}

  def mark_turn_terminal(%{kind: :producer_v6} = context, effects, idempotency_key, terminal),
    do: Execution.mark_turn_terminal(context, effects, idempotency_key, terminal)

  def mark_turn_terminal(_context, _effects, _idempotency_key, _terminal),
    do: {:error, :invalid_execution_ledger_context}

  @spec mark_effect_completed(:preview | map(), map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def mark_effect_completed(:preview, effects, idempotency_key),
    do: ExecutionLedger.mark_effect_completed(effects, idempotency_key)

  def mark_effect_completed(%{kind: :producer_v6}, effects, idempotency_key)
      when is_map(effects) and is_binary(idempotency_key) do
    case Map.get(effects, idempotency_key) do
      %{status: :completed} -> {:ok, effects}
      nil -> {:error, :missing_effect}
      _active -> {:error, :producer_v6_terminal_completion_evidence_required}
    end
  end

  def mark_effect_completed(_context, _effects, _idempotency_key),
    do: {:error, :invalid_execution_ledger_context}

  @spec mark_effect_completed(:preview | map(), map(), String.t(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def mark_effect_completed(:preview, effects, idempotency_key, _tracker, _seal),
    do: ExecutionLedger.mark_effect_completed(effects, idempotency_key)

  def mark_effect_completed(
        %{kind: :producer_v6} = context,
        effects,
        idempotency_key,
        terminal_tracker,
        completion_seal
      ),
      do:
        Execution.mark_completed(
          context,
          effects,
          idempotency_key,
          terminal_tracker,
          completion_seal
        )

  def mark_effect_completed(_context, _effects, _idempotency_key, _tracker, _seal),
    do: {:error, :invalid_execution_ledger_context}

  defp load_context(:preview, workspace_root), do: ExecutionLedger.load(workspace_root)

  defp load_context(%{kind: :producer_v6} = context, workspace_root),
    do: ProducerV6.Ledger.load(workspace_root, context)

  defp load_context(_context, _workspace_root),
    do: {:error, :invalid_execution_ledger_context}
end
