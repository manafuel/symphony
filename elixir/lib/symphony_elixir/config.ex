defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.{ModelRouting, Schema}
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          model: String.t(),
          model_role: String.t(),
          reasoning_effort: String.t(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings(timeout()) :: {:ok, Schema.t()} | {:error, term()}
  def settings(timeout \\ 5_000) do
    case Workflow.current(timeout) do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!(timeout()) :: Schema.t()
  def settings!(timeout \\ 5_000) do
    case settings(timeout) do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings(),
         {:ok, route} <- ModelRouting.resolve(Keyword.get(opts, :issue)),
         {:ok, turn_sandbox_policy} <-
           resolve_route_turn_sandbox_policy(route, settings, workspace, opts) do
      {:ok,
       %{
         approval_policy: settings.codex.approval_policy,
         model: route.model,
         model_role: route.role,
         reasoning_effort: route.reasoning_effort,
         thread_sandbox: route.thread_sandbox,
         turn_sandbox_policy: turn_sandbox_policy
       }}
    end
  end

  defp resolve_route_turn_sandbox_policy(
         %{turn_sandbox_policy: %{"type" => "workspaceWrite"}},
         settings,
         workspace,
         opts
       ) do
    Schema.resolve_workspace_write_turn_sandbox_policy(settings, workspace, opts)
  end

  defp resolve_route_turn_sandbox_policy(%{turn_sandbox_policy: %{} = policy}, _settings, _workspace, _opts),
    do: {:ok, policy}

  defp validate_semantics(settings) do
    with :ok <- validate_tracker_kind(settings.tracker.kind) do
      validate_linear_tracker(settings.tracker)
    end
  end

  defp validate_tracker_kind(nil), do: {:error, :missing_tracker_kind}

  defp validate_tracker_kind(kind) when kind not in ["linear", "memory"] do
    {:error, {:unsupported_tracker_kind, kind}}
  end

  defp validate_tracker_kind(_kind), do: :ok

  defp validate_linear_tracker(%{kind: "linear"} = tracker) do
    cond do
      not is_binary(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      not is_binary(tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      tracker.poll_scope == "team" and not is_binary(tracker.team_key) ->
        {:error, :missing_linear_team_key}

      true ->
        :ok
    end
  end

  defp validate_linear_tracker(_tracker), do: :ok

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
