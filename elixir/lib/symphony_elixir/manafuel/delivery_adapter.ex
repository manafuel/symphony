defmodule SymphonyElixir.Manafuel.DeliveryAdapter do
  @moduledoc """
  Performs the host-owned delivery work surrounding one admitted MANAfuel run.

  The adapter deliberately separates preparing a clean repository from delivery.
  A Codex turn happens between those phases; only the narrow client supplied by
  the host can clone, validate, commit, push, create a pull request, or update
  the initiative and Linear state.
  """

  alias SymphonyElixir.Linear.Client, as: LinearClient
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.Tracker.Issue

  @repositories ["development", "one", "replicator"]
  @repository_artifacts %{
    "development" => %{"authority" => "github", "kind" => "repository", "native_id" => "manafuel/development"},
    "one" => %{"authority" => "github", "kind" => "repository", "native_id" => "manafuel/one"},
    "replicator" => %{"authority" => "github", "kind" => "repository", "native_id" => "manafuel/replicator"}
  }
  @admitted_keys [
    :linear_issue_id,
    :experiment_key,
    :agent_id,
    :repository,
    :repository_artifact,
    :status,
    :manifest
  ]
  @delivery_run_keys [
    :linear_issue_id,
    :issue_identifier,
    :experiment_key,
    :repository,
    :repository_full_name,
    :issue_root,
    :repository_path,
    :branch,
    :base_sha,
    :initial_head_sha,
    :attempt
  ]
  @repository_state_keys [
    :issue_root,
    :repository_path,
    :base_sha,
    :head_sha,
    :origin,
    :origin_main,
    :internal_git,
    :clean,
    :contained,
    :nonreparse
  ]
  @client_keys [
    :prepare_repository,
    :candidate,
    :commit,
    :remote_head,
    :push,
    :list_pull_requests,
    :create_pull_request,
    :enable_auto_merge,
    :attach_growth_initiative_artifact_v1,
    :reconcile_linear
  ]
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  @sha ~r/\A[0-9a-f]{40}\z/
  @branch ~r/\Acodex\/[a-z0-9][a-z0-9._-]*\z/

  @type prepare_result ::
          {:ok, map()}
          | {:waiting, map()}
          | {:complete, map()}
          | {:error, atom()}

  @doc """
  Builds the production delivery client. Tests may continue to inject a client
  map directly; production uses only Git, GitHub, Supabase, and Linear.
  """
  @spec client(map(), Issue.t()) :: map()
  def client(admitted_run, %Issue{} = issue) when is_map(admitted_run) do
    %{
      prepare_repository: &host_prepare_repository(&1, &2, &3, &4, issue.identifier),
      candidate: &host_candidate/1,
      commit: &host_commit/1,
      remote_head: &host_remote_head/1,
      push: &host_push/2,
      list_pull_requests: &host_list_pull_requests/2,
      create_pull_request: &host_create_pull_request/2,
      enable_auto_merge: &host_enable_auto_merge/2,
      attach_growth_initiative_artifact_v1: fn experiment_key, artifact ->
        host_attach_artifact(
          experiment_key,
          artifact,
          admitted_run.agent_id,
          admitted_run.linear_issue_id
        )
      end,
      reconcile_linear: &host_reconcile_linear/3
    }
  end

  @doc """
  Establishes the one safe issue-local repository state before a model can run.
  """
  @spec prepare(map(), Issue.t(), Path.t(), 0 | 1, map()) :: prepare_result()
  def prepare(admitted_run, %Issue{} = issue, workspace_root, attempt, client) do
    with :ok <- validate_admitted_run(admitted_run),
         :ok <- validate_issue(issue, admitted_run),
         :ok <- validate_workspace_root(workspace_root),
         :ok <- validate_attempt(attempt),
         :ok <- validate_client(client),
         repository_full_name <- "manafuel/" <> admitted_run.repository,
         branch <- branch_for(issue.identifier),
         {:ok, repository_state} <-
           invoke(client.prepare_repository, [repository_full_name, branch, workspace_root, attempt]),
         {:ok, delivery_run} <-
           validate_repository_state(repository_state, admitted_run, issue, workspace_root, branch, attempt),
         {:ok, pull_requests} <- invoke(client.list_pull_requests, [repository_full_name, branch]),
         result <- existing_pull_request_result(pull_requests, delivery_run),
         :ok <- reconcile_existing_pull_request(result, client, delivery_run) do
      result
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  end

  def prepare(_admitted_run, _issue, _workspace_root, _attempt, _client), do: {:error, :invalid_delivery_input}

  @doc """
  Commits and delivers a candidate produced by the single admitted Codex turn.
  """
  @spec deliver(map(), map()) :: {:ok, map()} | {:error, atom()}
  def deliver(delivery_run, client) when is_map(delivery_run) and is_map(client) do
    with :ok <- validate_delivery_run(delivery_run),
         :ok <- validate_client(client),
         :ok <- invoke_ok(client.candidate, [delivery_run]),
         {:ok, model_head} <- invoke(client.commit, [delivery_run]),
         :ok <- validate_model_head(model_head, delivery_run.initial_head_sha),
         {:ok, remote_head} <- invoke(client.remote_head, [delivery_run]),
         :ok <- validate_remote_head(remote_head, model_head),
         :ok <- maybe_push(remote_head, client, delivery_run, model_head),
         {:ok, pull_requests} <- invoke(client.list_pull_requests, [delivery_run.repository_full_name, delivery_run.branch]),
         {:ok, pull_request} <- find_or_create_pull_request(pull_requests, client, delivery_run, model_head),
         :ok <- validate_delivery_pull_request(pull_request, model_head),
         :ok <- invoke_ok(client.enable_auto_merge, [delivery_run, pull_request.number]),
         artifact <- pull_request_artifact(delivery_run.repository_full_name, pull_request),
         :ok <- invoke_ok(client.attach_growth_initiative_artifact_v1, [delivery_run.experiment_key, artifact]),
         linear_state <- linear_state(pull_request.state),
         :ok <- invoke_ok(client.reconcile_linear, [delivery_run.linear_issue_id, pull_request.number, linear_state]) do
      {:ok, %{pull_request: pull_request, artifact: artifact, linear_state: linear_state}}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  end

  def deliver(_delivery_run, _client), do: {:error, :invalid_delivery_input}

  defp validate_admitted_run(admitted_run) when is_map(admitted_run) do
    with true <- exact_keys?(admitted_run, @admitted_keys) or {:error, :invalid_admitted_run},
         true <- valid_uuid?(admitted_run.linear_issue_id) or {:error, :invalid_admitted_run},
         true <- valid_nonempty_binary?(admitted_run.experiment_key) or {:error, :invalid_admitted_run},
         true <- admitted_run.agent_id === "implementation-worker" or {:error, :invalid_admitted_run},
         true <- admitted_run.repository in @repositories or {:error, :invalid_admitted_run},
         true <- admitted_run.repository_artifact === Map.fetch!(@repository_artifacts, admitted_run.repository) or {:error, :invalid_admitted_run},
         true <- admitted_run.status in ["proposed", "running"] or {:error, :invalid_admitted_run},
         true <- is_map(admitted_run.manifest) or {:error, :invalid_admitted_run} do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_admitted_run(_admitted_run), do: {:error, :invalid_admitted_run}

  defp validate_issue(%Issue{id: id, identifier: identifier}, admitted_run)
       when id === admitted_run.linear_issue_id and is_binary(identifier) do
    if valid_issue_identifier?(identifier), do: :ok, else: {:error, :invalid_issue}
  end

  defp validate_issue(_issue, _admitted_run), do: {:error, :invalid_issue}

  defp validate_workspace_root(workspace_root) when is_binary(workspace_root) do
    if Path.type(workspace_root) == :absolute and not String.contains?(workspace_root, <<0>>),
      do: :ok,
      else: {:error, :unsafe_workspace}
  end

  defp validate_workspace_root(_workspace_root), do: {:error, :unsafe_workspace}

  defp validate_attempt(attempt) when attempt in [0, 1], do: :ok
  defp validate_attempt(_attempt), do: {:error, :invalid_attempt}

  defp validate_client(client) when is_map(client) do
    functions = [
      prepare_repository: 4,
      candidate: 1,
      commit: 1,
      remote_head: 1,
      push: 2,
      list_pull_requests: 2,
      create_pull_request: 2,
      enable_auto_merge: 2,
      attach_growth_initiative_artifact_v1: 2,
      reconcile_linear: 3
    ]

    if exact_keys?(client, @client_keys) and
         Enum.all?(functions, fn {name, arity} -> is_function(client[name], arity) end) do
      :ok
    else
      {:error, :invalid_delivery_client}
    end
  end

  defp validate_client(_client), do: {:error, :invalid_delivery_client}

  defp validate_repository_state(state, admitted_run, issue, workspace_root, branch, attempt) when is_map(state) do
    repository_full_name = "manafuel/" <> admitted_run.repository
    issue_root = Path.join(workspace_root, issue.identifier)
    repository_path = Path.join(issue_root, admitted_run.repository)

    valid? =
      Enum.all?([
        exact_keys?(state, @repository_state_keys),
        state.issue_root === issue_root,
        state.repository_path === repository_path,
        state.origin === "https://github.com/#{repository_full_name}.git",
        state.internal_git === true,
        state.clean === true,
        state.contained === true,
        state.nonreparse === true,
        valid_sha?(state.base_sha),
        state.head_sha === state.base_sha,
        state.origin_main === state.base_sha
      ])

    if valid? do
      {:ok,
       %{
         linear_issue_id: admitted_run.linear_issue_id,
         issue_identifier: issue.identifier,
         experiment_key: admitted_run.experiment_key,
         repository: admitted_run.repository,
         repository_full_name: repository_full_name,
         issue_root: issue_root,
         repository_path: repository_path,
         branch: branch,
         base_sha: state.base_sha,
         initial_head_sha: state.head_sha,
         attempt: attempt
       }}
    else
      {:error, :unsafe_repository}
    end
  end

  defp validate_repository_state(_state, _admitted_run, _issue, _workspace_root, _branch, _attempt),
    do: {:error, :unsafe_repository}

  defp existing_pull_request_result(pull_requests, delivery_run) when is_list(pull_requests) do
    case pull_requests do
      [] ->
        {:ok, delivery_run}

      [pull_request] ->
        existing_pull_request_status(
          validate_existing_pull_request(pull_request),
          pull_request,
          delivery_run
        )

      _many ->
        {:error, :duplicate_pull_request}
    end
  end

  defp existing_pull_request_result(_pull_requests, _delivery_run), do: {:error, :invalid_pull_request}

  defp existing_pull_request_status(:ok, %{state: "open"} = pull_request, delivery_run),
    do: {:waiting, %{pull_request: pull_request, delivery_run: delivery_run}}

  defp existing_pull_request_status(:ok, %{state: "merged"} = pull_request, delivery_run),
    do: {:complete, %{pull_request: pull_request, delivery_run: delivery_run}}

  defp existing_pull_request_status({:error, _reason} = error, _pull_request, _delivery_run),
    do: error

  defp validate_delivery_run(delivery_run) when is_map(delivery_run) do
    valid? =
      Enum.all?([
        exact_keys?(delivery_run, @delivery_run_keys),
        valid_uuid?(delivery_run.linear_issue_id),
        valid_issue_identifier?(delivery_run.issue_identifier),
        valid_nonempty_binary?(delivery_run.experiment_key),
        delivery_run.repository in @repositories,
        delivery_run.repository_full_name === "manafuel/" <> delivery_run.repository,
        valid_absolute_path?(delivery_run.issue_root),
        valid_absolute_path?(delivery_run.repository_path),
        delivery_run.repository_path ===
          Path.join(delivery_run.issue_root, delivery_run.repository),
        valid_branch?(delivery_run.branch),
        delivery_run.branch === branch_for(delivery_run.issue_identifier),
        valid_sha?(delivery_run.base_sha),
        delivery_run.initial_head_sha === delivery_run.base_sha,
        validate_attempt(delivery_run.attempt) === :ok
      ])

    if valid?, do: :ok, else: {:error, :invalid_delivery_run}
  end

  defp validate_model_head(model_head, initial_head) do
    if valid_sha?(model_head) and model_head !== initial_head,
      do: :ok,
      else: {:error, :model_commit_failed}
  end

  defp validate_remote_head(nil, _model_head), do: :ok
  defp validate_remote_head(remote_head, model_head) when remote_head === model_head, do: :ok
  defp validate_remote_head(remote_head, _model_head) when is_binary(remote_head), do: {:error, :stale_pr_head}
  defp validate_remote_head(_remote_head, _model_head), do: {:error, :remote_head_failed}

  defp maybe_push(nil, client, delivery_run, model_head),
    do: invoke_ok(client.push, [delivery_run, model_head])

  defp maybe_push(_remote_head, _client, _delivery_run, _model_head), do: :ok

  defp find_or_create_pull_request(pull_requests, client, delivery_run, model_head) when is_list(pull_requests) do
    case pull_requests do
      [] ->
        with {:ok, pull_request} <- invoke(client.create_pull_request, [delivery_run, model_head]),
             :ok <- validate_delivery_pull_request(pull_request, model_head) do
          {:ok, pull_request}
        end

      [pull_request] ->
        with :ok <- validate_delivery_pull_request(pull_request, model_head) do
          {:ok, pull_request}
        end

      _many ->
        {:error, :duplicate_pull_request}
    end
  end

  defp find_or_create_pull_request(_pull_requests, _client, _delivery_run, _model_head),
    do: {:error, :invalid_pull_request}

  defp validate_existing_pull_request(pull_request) do
    with :ok <- validate_pull_request_shape(pull_request),
         true <- pull_request.base === "main" or {:error, :invalid_pull_request},
         true <- pull_request.state in ["open", "merged"] or {:error, :invalid_pull_request} do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_delivery_pull_request(pull_request, model_head) do
    with :ok <- validate_existing_pull_request(pull_request),
         true <- pull_request.head_sha === model_head or {:error, :stale_pr_head} do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_pull_request_shape(pull_request) when is_map(pull_request) do
    valid? =
      Enum.all?([
        exact_keys?(pull_request, [:number, :head_sha, :base, :state, :url]),
        is_integer(pull_request.number),
        pull_request.number > 0,
        valid_sha?(pull_request.head_sha),
        is_binary(pull_request.base),
        is_binary(pull_request.state),
        valid_pull_request_url?(pull_request.url)
      ])

    if valid?, do: :ok, else: {:error, :invalid_pull_request}
  end

  defp validate_pull_request_shape(_pull_request), do: {:error, :invalid_pull_request}

  defp pull_request_artifact(repository_full_name, pull_request) do
    %{
      "authority" => "github",
      "kind" => "pull-request",
      "native_id" => "#{repository_full_name}##{pull_request.number}",
      "uri" => pull_request.url
    }
  end

  defp linear_state("merged"), do: "Done"
  defp linear_state("open"), do: "Merging"

  defp invoke(function, args) when is_function(function) and is_list(args) do
    case apply(function, args) do
      {:ok, _value} = result -> result
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :delivery_client_failed}
    end
  rescue
    _error -> {:error, :delivery_client_failed}
  catch
    _kind, _reason -> {:error, :delivery_client_failed}
  end

  defp invoke(_function, _args), do: {:error, :delivery_client_failed}

  defp invoke_ok(function, args) when is_function(function) and is_list(args) do
    case apply(function, args) do
      :ok -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :delivery_client_failed}
    end
  rescue
    _error -> {:error, :delivery_client_failed}
  catch
    _kind, _reason -> {:error, :delivery_client_failed}
  end

  defp invoke_ok(_function, _args), do: {:error, :delivery_client_failed}

  defp exact_keys?(map, keys) when is_map(map), do: Map.keys(map) |> Enum.sort() === Enum.sort(keys)

  defp valid_uuid?(value) when is_binary(value), do: String.match?(value, @uuid)
  defp valid_uuid?(_value), do: false
  defp valid_sha?(value) when is_binary(value), do: String.match?(value, @sha)
  defp valid_sha?(_value), do: false
  defp valid_nonempty_binary?(value) when is_binary(value), do: byte_size(String.trim(value)) > 0
  defp valid_nonempty_binary?(_value), do: false
  defp valid_branch?(value) when is_binary(value), do: String.match?(value, @branch)
  defp valid_branch?(_value), do: false
  defp valid_absolute_path?(value) when is_binary(value), do: Path.type(value) == :absolute and not String.contains?(value, <<0>>)
  defp valid_absolute_path?(_value), do: false
  defp valid_pull_request_url?(value) when is_binary(value), do: String.starts_with?(value, "https://github.com/manafuel/")
  defp valid_pull_request_url?(_value), do: false

  defp reconcile_existing_pull_request({:ok, _result_run}, _client, _delivery_run), do: :ok

  defp reconcile_existing_pull_request({status, %{pull_request: pull_request}}, client, delivery_run)
       when status in [:waiting, :complete] do
    invoke_ok(client.reconcile_linear, [
      delivery_run.linear_issue_id,
      pull_request.number,
      linear_state(pull_request.state)
    ])
  end

  defp reconcile_existing_pull_request({:error, reason}, _client, _delivery_run), do: {:error, reason}
  defp reconcile_existing_pull_request(_result, _client, _delivery_run), do: {:error, :delivery_prepare_failed}

  defp host_prepare_repository(repository_full_name, branch, workspace_root, _attempt, issue_identifier) do
    repository = repository_full_name |> String.split("/", parts: 2) |> List.last()
    issue_root = Path.join(workspace_root, issue_identifier)
    repository_path = Path.join(issue_root, repository)
    origin = "https://github.com/#{repository_full_name}.git"

    with :ok <- File.mkdir_p(issue_root),
         :ok <- ensure_repository(origin, repository_path),
         :ok <- git_ok(repository_path, ["fetch", "--prune", "origin", "main"]),
         :ok <- git_ok(repository_path, ["checkout", "-B", branch, "origin/main"]),
         :ok <- git_ok(repository_path, ["reset", "--hard", "origin/main"]),
         :ok <- git_ok(repository_path, ["clean", "-fd"]),
         {:ok, canonical_root} <- PathSafety.canonicalize(workspace_root),
         {:ok, canonical_repository} <- PathSafety.canonicalize(repository_path),
         true <- contained_path?(canonical_root, canonical_repository) or {:error, :unsafe_repository},
         true <- File.dir?(Path.join(repository_path, ".git")) or {:error, :unsafe_repository},
         {:ok, configured_origin} <- git_value(repository_path, ["remote", "get-url", "origin"]),
         {:ok, base_sha} <- git_value(repository_path, ["rev-parse", "origin/main"]),
         {:ok, head_sha} <- git_value(repository_path, ["rev-parse", "HEAD"]),
         {:ok, status} <- git_value(repository_path, ["status", "--porcelain"]),
         true <- status === "" or {:error, :unsafe_repository} do
      {:ok,
       %{
         issue_root: issue_root,
         repository_path: repository_path,
         base_sha: base_sha,
         head_sha: head_sha,
         origin: configured_origin,
         origin_main: base_sha,
         internal_git: true,
         clean: true,
         contained: true,
         nonreparse: canonical_repository === Path.expand(repository_path)
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :unsafe_repository}
    end
  end

  defp ensure_repository(origin, repository_path) do
    cond do
      File.dir?(Path.join(repository_path, ".git")) ->
        :ok

      File.exists?(repository_path) ->
        {:error, :unsafe_repository}

      true ->
        case command("git", ["clone", "--origin", "origin", "--branch", "main", "--single-branch", origin, repository_path]) do
          {_output, 0} -> :ok
          _other -> {:error, :repository_clone_failed}
        end
    end
  end

  defp host_candidate(delivery_run) do
    case delivery_run.repository do
      "development" ->
        git_ok(delivery_run.repository_path, ["diff", "--check"])

      "one" ->
        command_ok("cmd.exe", ["/d", "/v:off", "/c", "corepack pnpm candidate:local"], cd: delivery_run.repository_path)

      "replicator" ->
        command_ok(
          "powershell.exe",
          [
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            Path.join(delivery_run.repository_path, "scripts/replicator-local.ps1"),
            "candidate:local"
          ],
          cd: delivery_run.repository_path
        )
    end
  end

  defp host_commit(delivery_run) do
    with :ok <- git_ok(delivery_run.repository_path, ["add", "-A"]),
         {_output, status} <- command("git", ["diff", "--cached", "--quiet"], cd: delivery_run.repository_path),
         true <- status === 1 or {:error, :model_commit_failed},
         :ok <-
           git_ok(delivery_run.repository_path, [
             "commit",
             "-m",
             "feat: implement #{delivery_run.issue_identifier}"
           ]),
         {:ok, head} <- git_value(delivery_run.repository_path, ["rev-parse", "HEAD"]) do
      {:ok, head}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
    end
  end

  defp host_remote_head(delivery_run) do
    case command(
           "git",
           ["ls-remote", "--heads", "origin", "refs/heads/#{delivery_run.branch}"],
           cd: delivery_run.repository_path
         ) do
      {output, 0} ->
        case String.split(String.trim(output)) do
          [] -> {:ok, nil}
          [sha, _ref] -> {:ok, sha}
          _other -> {:error, :remote_head_failed}
        end

      _other ->
        {:error, :remote_head_failed}
    end
  end

  defp host_push(delivery_run, model_head) do
    git_ok(delivery_run.repository_path, [
      "push",
      "origin",
      "#{model_head}:refs/heads/#{delivery_run.branch}"
    ])
  end

  defp host_list_pull_requests(repository_full_name, branch) do
    case command("gh", [
           "pr",
           "list",
           "--repo",
           repository_full_name,
           "--head",
           branch,
           "--base",
           "main",
           "--state",
           "all",
           "--json",
           "number,headRefOid,baseRefName,state,url"
         ]) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, entries} when is_list(entries) ->
            {:ok,
             entries
             |> Enum.map(&normalize_pull_request/1)
             |> Enum.reject(&is_nil/1)}

          _other ->
            {:error, :invalid_pull_request}
        end

      _other ->
        {:error, :pull_request_lookup_failed}
    end
  end

  defp normalize_pull_request(entry) when is_map(entry) do
    state = entry["state"] |> to_string() |> String.downcase()

    if state in ["open", "merged"] do
      %{
        number: entry["number"],
        head_sha: entry["headRefOid"],
        base: entry["baseRefName"],
        state: state,
        url: entry["url"]
      }
    end
  end

  defp normalize_pull_request(_entry), do: nil

  defp host_create_pull_request(delivery_run, _model_head) do
    case command("gh", [
           "pr",
           "create",
           "--repo",
           delivery_run.repository_full_name,
           "--head",
           delivery_run.branch,
           "--base",
           "main",
           "--title",
           "#{delivery_run.issue_identifier}: implementation",
           "--body",
           "Automated implementation for #{delivery_run.issue_identifier}."
         ]) do
      {_output, 0} ->
        case host_list_pull_requests(delivery_run.repository_full_name, delivery_run.branch) do
          {:ok, [pull_request]} -> {:ok, pull_request}
          {:ok, _other} -> {:error, :duplicate_pull_request}
          {:error, _reason} = error -> error
        end

      _other ->
        {:error, :pull_request_create_failed}
    end
  end

  defp host_enable_auto_merge(delivery_run, pull_request_number) do
    command_ok("gh", [
      "pr",
      "merge",
      Integer.to_string(pull_request_number),
      "--repo",
      delivery_run.repository_full_name,
      "--auto",
      "--squash"
    ])
  end

  defp host_attach_artifact(experiment_key, artifact, agent_id, linear_issue_id) do
    base_url = System.get_env("SUPABASE_URL") || System.get_env("NEXT_PUBLIC_SUPABASE_URL")
    service_key = System.get_env("SUPABASE_SERVICE_ROLE_KEY")

    if present_env?(base_url) and present_env?(service_key) do
      case Req.post(
             String.trim_trailing(base_url, "/") <>
               "/rest/v1/rpc/attach_growth_initiative_artifact_v1",
             headers: [
               {"apikey", service_key},
               {"authorization", "Bearer #{service_key}"},
               {"content-type", "application/json"}
             ],
             json: %{
               p_experiment_key: experiment_key,
               p_agent_id: agent_id,
               p_linear_issue_id: linear_issue_id,
               p_artifact: artifact
             },
             connect_options: [timeout: 30_000]
           ) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        _other -> {:error, :artifact_attach_failed}
      end
    else
      {:error, :missing_supabase_credentials}
    end
  end

  defp host_reconcile_linear(linear_issue_id, pull_request_number, target_state) do
    query = """
    query ManafuelDeliveryState($id: String!) {
      issue(id: $id) {
        team { states { nodes { id name } } }
        comments { nodes { body } }
      }
    }
    """

    with {:ok, body} <- LinearClient.graphql(query, %{id: linear_issue_id}),
         %{"data" => %{"issue" => issue}} when is_map(issue) <- body,
         {:ok, state_id} <- linear_state_id(issue, target_state),
         :ok <- maybe_create_linear_comment(issue, linear_issue_id, pull_request_number),
         {:ok, update_body} <-
           LinearClient.graphql(
             "mutation ManafuelDeliveryUpdate($id: String!, $stateId: String!) { issueUpdate(id: $id, input: {stateId: $stateId}) { success } }",
             %{id: linear_issue_id, stateId: state_id}
           ),
         true <- get_in(update_body, ["data", "issueUpdate", "success"]) === true do
      :ok
    else
      _other -> {:error, :linear_reconcile_failed}
    end
  end

  defp linear_state_id(issue, target_state) do
    issue
    |> get_in(["team", "states", "nodes"])
    |> case do
      states when is_list(states) ->
        case Enum.find(states, &(Map.get(&1, "name") === target_state)) do
          %{"id" => state_id} when is_binary(state_id) -> {:ok, state_id}
          _other -> {:error, :linear_reconcile_failed}
        end

      _other ->
        {:error, :linear_reconcile_failed}
    end
  end

  defp maybe_create_linear_comment(issue, linear_issue_id, pull_request_number) do
    marker = "<!-- manafuel-delivery:pull-request=#{pull_request_number} -->"
    comments = get_in(issue, ["comments", "nodes"]) || []

    if Enum.any?(comments, &(Map.get(&1, "body") |> to_string() |> String.contains?(marker))) do
      :ok
    else
      create_linear_comment(linear_issue_id, pull_request_number, marker)
    end
  end

  defp create_linear_comment(linear_issue_id, pull_request_number, marker) do
    body = "#{marker}\nDelivery pull request: ##{pull_request_number}"

    result =
      LinearClient.graphql(
        "mutation ManafuelDeliveryComment($issueId: String!, $body: String!) { commentCreate(input: {issueId: $issueId, body: $body}) { success } }",
        %{issueId: linear_issue_id, body: body}
      )

    case result do
      {:ok, response} ->
        require_linear_success(get_in(response, ["data", "commentCreate", "success"]))

      _other ->
        {:error, :linear_reconcile_failed}
    end
  end

  defp require_linear_success(true), do: :ok
  defp require_linear_success(_success), do: {:error, :linear_reconcile_failed}

  defp git_ok(repository_path, args), do: command_ok("git", args, cd: repository_path)

  defp git_value(repository_path, args) do
    case command("git", args, cd: repository_path) do
      {output, 0} -> {:ok, String.trim(output)}
      _other -> {:error, :repository_command_failed}
    end
  end

  defp command_ok(executable, args, opts \\ []) do
    case command(executable, args, opts) do
      {_output, 0} -> :ok
      _other -> {:error, :candidate_failed}
    end
  end

  defp command(executable, args, opts \\ []) do
    System.cmd(executable, args, Keyword.merge([stderr_to_stdout: true], opts))
  rescue
    _error -> {"", 1}
  catch
    _kind, _reason -> {"", 1}
  end

  defp contained_path?(root, candidate) do
    relative = Path.relative_to(candidate, root)
    relative !== candidate and relative !== ".." and not String.starts_with?(relative, "../")
  end

  defp present_env?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_env?(_value), do: false

  defp valid_issue_identifier?(identifier) when is_binary(identifier) do
    String.match?(identifier, ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/)
  end

  defp valid_issue_identifier?(_identifier), do: false
  defp branch_for(identifier), do: "codex/" <> String.downcase(identifier)
end
