defmodule SymphonyElixir.FailureSemantics do
  @moduledoc """
  Structural failure classification for orchestration transitions.

  Classification is based on typed tuples, atoms, and reviewed hook exit codes.
  Free text is retained only as redacted diagnostics and never controls retry.
  """

  @typed_classes [
    :transient_capacity,
    :transient_transport,
    :permanent_admission,
    :permanent_contract,
    :approval_required,
    :authority_denied,
    :operator_decision_required,
    :unknown_fail_closed
  ]

  @transient_classes [:transient_capacity, :transient_transport]
  @held_classes [:approval_required, :authority_denied, :operator_decision_required]

  @hook_exit_classes %{
    20 => :permanent_admission,
    21 => :permanent_contract,
    22 => :approval_required,
    23 => :authority_denied,
    24 => :operator_decision_required,
    70 => :transient_capacity,
    71 => :transient_transport
  }

  @type failure_class ::
          :transient_capacity
          | :transient_transport
          | :permanent_admission
          | :permanent_contract
          | :approval_required
          | :authority_denied
          | :operator_decision_required
          | :unknown_fail_closed

  @type classification :: %{
          class: failure_class(),
          retryable: boolean(),
          terminal_state: :held | :permanent | nil,
          reason: term()
        }

  @spec classes() :: [failure_class()]
  def classes, do: @typed_classes

  @spec valid_class?(term()) :: boolean()
  def valid_class?(class), do: class in @typed_classes

  @spec classify(term()) :: classification()
  def classify({:shutdown, {:classified_failure, class, reason}}),
    do: classified(class, reason)

  def classify({:classified_failure, class, reason}), do: classified(class, reason)
  def classify({:rate_limit, reason}), do: classified(:transient_capacity, reason)
  def classify({:capacity_exhausted, reason}), do: classified(:transient_capacity, reason)
  def classify(:rate_limit), do: classified(:transient_capacity, :rate_limit)
  def classify(:capacity_exhausted), do: classified(:transient_capacity, :capacity_exhausted)

  def classify({:workspace_hook_timeout, _hook_name, _timeout_ms} = reason),
    do: classified(:transient_transport, reason)

  def classify({:response_timeout, _details} = reason),
    do: classified(:transient_transport, reason)

  def classify({:port_exit, _details} = reason),
    do: classified(:transient_transport, reason)

  def classify(reason) when reason in [:epipe, :port_exit, :response_timeout, :timeout],
    do: classified(:transient_transport, reason)

  def classify({:workspace_hook_failed, "before_run", status} = reason)
      when is_integer(status) do
    classified(Map.get(@hook_exit_classes, status, :unknown_fail_closed), reason)
  end

  def classify({:approval_required, _details} = reason),
    do: classified(:approval_required, reason)

  def classify(:approval_required), do: classified(:approval_required, :approval_required)

  def classify({:authority_denied, _details} = reason),
    do: classified(:authority_denied, reason)

  def classify(:authority_denied), do: classified(:authority_denied, :authority_denied)

  def classify({:operator_decision_required, _details} = reason),
    do: classified(:operator_decision_required, reason)

  def classify(:operator_decision_required),
    do: classified(:operator_decision_required, :operator_decision_required)

  def classify({:permanent_admission, _details} = reason),
    do: classified(:permanent_admission, reason)

  def classify({:permanent_contract, _details} = reason),
    do: classified(:permanent_contract, reason)

  def classify(_reason), do: classified(:unknown_fail_closed, :unclassified_failure)

  @spec exit_reason(term()) :: {:shutdown, {:classified_failure, failure_class(), term()}}
  def exit_reason(reason) do
    classification = classify(reason)
    {:shutdown, {:classified_failure, classification.class, bounded_reason(reason)}}
  end

  @spec disposition(failure_class()) :: :retry | :held | :permanent
  def disposition(class) when class in @transient_classes, do: :retry
  def disposition(class) when class in @held_classes, do: :held
  def disposition(_class), do: :permanent

  defp classified(class, reason) when class in @typed_classes do
    disposition = disposition(class)

    %{
      class: class,
      retryable: disposition == :retry,
      terminal_state: if(disposition == :retry, do: nil, else: disposition),
      reason: reason
    }
  end

  defp classified(_class, reason), do: classified(:unknown_fail_closed, reason)

  defp bounded_reason(reason) do
    reason
    |> inspect(limit: 30, printable_limit: 2_000, width: 80)
    |> String.slice(0, 2_000)
  end
end
