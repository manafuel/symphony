defmodule SymphonyElixir.ProducerV6.TerminalTracker do
  @moduledoc """
  Captures final Linear state, comments, and issue history from complete bounded
  pagination after the raw AppServer terminal event.
  """

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.ProducerV6.Broker

  @page_size 100
  @max_pages 100
  @comments_query """
  query SymphonyProducerV6Comments($id: String!, $after: String) {
    issue(id: $id) {
      comments(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { id createdAt body user { id } }
      }
    }
  }
  """
  @history_query """
  query SymphonyProducerV6History($id: String!, $after: String) {
    issue(id: $id) {
      history(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { id createdAt actorId fromStateId toStateId }
      }
    }
  }
  """
  @state_query """
  query SymphonyProducerV6State($id: String!) {
    issue(id: $id) { id identifier updatedAt state { id name type } }
  }
  """

  @spec capture(map(), map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def capture(context, effect, server_event, deadline)
      when is_map(context) and is_map(effect) and is_map(server_event) and is_map(deadline) do
    capture_with(context, effect, server_event, deadline, &Client.graphql/2, Broker)
  end

  @doc false
  @spec capture_with(map(), map(), map(), map(), function(), module()) ::
          {:ok, map()} | {:error, term()}
  def capture_with(context, effect, server_event, deadline, graphql, broker)
      when is_function(graphql, 2) and is_atom(broker) do
    document = effect.document
    identifier = document["identifier"]
    issue_id = document["issue_id"]
    viewer_id = get_in(context, [:launch, :document, "authenticated_identities", "linear_worker_actor_id"])
    turn = List.last(document["turns"])
    marker_text = marker_text(document, deadline)

    with true <- is_binary(viewer_id) and viewer_id != "",
         true <- is_map(turn),
         {:ok, state_body} <- graphql.(@state_query, %{id: identifier}),
         {:ok, state_ref} <- publish(state_body, "tracker_page", context, deadline, broker),
         {:ok, issue, state} <- terminal_state(state_body, issue_id, identifier),
         {:ok, comments, comment_proof} <-
           paginate(identifier, :comments, @comments_query, context, deadline, graphql, broker),
         {:ok, history, history_proof} <-
           paginate(identifier, :history, @history_query, context, deadline, graphql, broker),
         {:ok, comment} <- exact_comment(comments, marker_text, viewer_id),
         {:ok, done} <- exact_done(history, state["id"], viewer_id),
         {:ok, refreshed_at} <- producer_now(),
         :ok <- chronology(turn, comment, done, server_event, refreshed_at, deadline) do
      {:ok,
       tracker_document(document, deadline, %{
         identifier: identifier,
         issue_id: issue_id,
         viewer_id: viewer_id,
         marker_text: marker_text,
         state_ref: state_ref,
         issue: issue,
         state: state,
         comment: comment,
         done: done,
         comment_proof: comment_proof,
         history_proof: history_proof,
         server_event: server_event,
         refreshed_at: refreshed_at
       })}
    else
      false -> {:error, :producer_terminal_tracker_identity_invalid}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :producer_terminal_tracker_invalid}
    end
  end

  defp tracker_document(document, deadline, attrs) do
    %{
      "issue_id" => attrs.issue_id,
      "identifier" => attrs.identifier,
      "deadline_at_utc" => deadline.deadline_at_utc,
      "deadline_sha256" => deadline.deadline_sha256,
      "refreshed_at_utc" => attrs.refreshed_at,
      "state_readback" => attrs.state_ref,
      "state" => %{
        "id" => attrs.state["id"],
        "name" => "Done",
        "type" => "completed",
        "updated_at_utc" => normalize_time(attrs.issue["updatedAt"])
      },
      "final_worker_comment" => %{
        "id" => attrs.comment["id"],
        "author_id" => attrs.viewer_id,
        "created_at_utc" => normalize_time(attrs.comment["createdAt"]),
        "marker" => %{
          "prefix" => "symphony:final:",
          "identifier" => attrs.identifier,
          "deadline_at_utc" => deadline.deadline_at_utc,
          "deadline_sha256" => deadline.deadline_sha256,
          "claim_session_id" => document["claim_session_id"],
          "idempotency_key" => document["idempotency_key"],
          "occurrences" => 1
        },
        "body_sha256" => sha256(attrs.marker_text)
      },
      "done_transition" => %{
        "history_id" => attrs.done["id"],
        "from_state_id" => attrs.done["fromStateId"],
        "to_state_id" => attrs.done["toStateId"],
        "actor_id" => attrs.done["actorId"],
        "created_at_utc" => normalize_time(attrs.done["createdAt"])
      },
      "comment_pagination" => %{attrs.comment_proof | "match_count" => 1},
      "history_pagination" => %{attrs.history_proof | "match_count" => 1},
      "server_turn_terminal_event" => attrs.server_event.reference
    }
  end

  @spec marker_text(map(), map()) :: String.t()
  def marker_text(%{"identifier" => identifier, "claim_session_id" => claim, "idempotency_key" => key}, deadline) do
    "symphony:final:" <>
      identifier <>
      "|deadline_at_utc=" <>
      deadline.deadline_at_utc <>
      "|deadline_sha256=" <>
      deadline.deadline_sha256 <>
      "|claim_session_id=" <> claim <> "|idempotency_key=" <> key
  end

  defp terminal_state(%{"data" => %{"issue" => issue}}, issue_id, identifier) when is_map(issue) do
    state = issue["state"]

    if issue["id"] == issue_id and issue["identifier"] == identifier and is_map(state) and
         state["name"] == "Done" and state["type"] == "completed" and is_binary(state["id"]) and
         match?({:ok, _}, parse_time(issue["updatedAt"])) do
      {:ok, issue, state}
    else
      {:error, :producer_terminal_state_not_done}
    end
  end

  defp terminal_state(_body, _issue_id, _identifier),
    do: {:error, :producer_terminal_state_response_invalid}

  defp paginate(identifier, kind, query, context, deadline, graphql, broker) do
    do_paginate(%{
      identifier: identifier,
      kind: kind,
      query: query,
      context: context,
      deadline: deadline,
      graphql: graphql,
      broker: broker,
      after_cursor: nil,
      ordinal: 1,
      rows: [],
      pages: [],
      seen: %{},
      seen_cursors: %{}
    })
  end

  defp do_paginate(%{ordinal: ordinal, kind: kind}) when ordinal > @max_pages,
    do: {:error, {:producer_terminal_pagination_limit, kind}}

  defp do_paginate(state) do
    with {:ok, body} <-
           state.graphql.(state.query, %{id: state.identifier, after: state.after_cursor}),
         {:ok, reference} <-
           publish(body, root_name(state.kind), state.context, state.deadline, state.broker),
         {:ok, nodes, page_info} <- connection(body, state.kind),
         :ok <- bounded_unique_nodes(nodes, state.seen),
         has_next when is_boolean(has_next) <- page_info["hasNextPage"],
         end_cursor <- page_info["endCursor"],
         :ok <- cursor_rule(has_next, end_cursor, state.after_cursor, state.seen_cursors) do
      continue_pagination(state, nodes, reference, has_next, end_cursor)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:producer_terminal_page_invalid, state.kind}}
    end
  end

  defp continue_pagination(state, nodes, reference, has_next, end_cursor) do
    page = %{
      "ordinal" => state.ordinal,
      "requested_after" => state.after_cursor,
      "end_cursor" => end_cursor,
      "has_next_page" => has_next,
      "node_count" => length(nodes),
      "raw_response" => reference
    }

    next_state = %{
      state
      | after_cursor: end_cursor,
        ordinal: state.ordinal + 1,
        rows: state.rows ++ nodes,
        pages: state.pages ++ [page],
        seen: Enum.reduce(nodes, state.seen, &Map.put(&2, &1["id"], true)),
        seen_cursors: maybe_add_cursor(state.seen_cursors, end_cursor)
    }

    if has_next,
      do: do_paginate(next_state),
      else: {:ok, next_state.rows, pagination_proof(state.kind, next_state.pages)}
  end

  defp connection(%{"data" => %{"issue" => issue}}, kind) when is_map(issue) do
    key = if(kind == :comments, do: "comments", else: "history")

    case issue[key] do
      %{"nodes" => nodes, "pageInfo" => page_info}
      when is_list(nodes) and is_map(page_info) and length(nodes) <= @page_size ->
        {:ok, nodes, page_info}

      _ ->
        {:error, {:producer_terminal_connection_invalid, kind}}
    end
  end

  defp connection(_body, kind), do: {:error, {:producer_terminal_connection_invalid, kind}}

  defp bounded_unique_nodes(nodes, seen) do
    ids = Enum.map(nodes, & &1["id"])

    if Enum.all?(ids, &(is_binary(&1) and &1 != "")) and
         length(ids) == length(Enum.uniq(ids)) and Enum.all?(ids, &(not Map.has_key?(seen, &1))) do
      :ok
    else
      {:error, :producer_terminal_stable_id_invalid}
    end
  end

  defp cursor_rule(false, nil, _after, _seen), do: :ok
  defp cursor_rule(false, cursor, _after, _seen) when is_binary(cursor), do: :ok

  defp cursor_rule(true, cursor, after_cursor, seen)
       when is_binary(cursor) and cursor != "" and cursor != after_cursor do
    if Map.has_key?(seen, cursor),
      do: {:error, :producer_terminal_cursor_repeated},
      else: :ok
  end

  defp cursor_rule(_has_next, _cursor, _after, _seen),
    do: {:error, :producer_terminal_cursor_invalid}

  defp maybe_add_cursor(seen, cursor) when is_binary(cursor), do: Map.put(seen, cursor, true)
  defp maybe_add_cursor(seen, _cursor), do: seen

  defp pagination_proof(kind, pages) do
    %{
      "resource" => if(kind == :comments, do: "linear_comments", else: "linear_issue_history"),
      "method" => if(kind == :comments, do: "Issue.comments(first/after)", else: "Issue.history(first/after)"),
      "history_mode" => "paginated",
      "requested_page_size" => @page_size,
      "pages" => pages,
      "pagination_complete" => true,
      "stable_ids_unique" => true,
      "match_count" => 0
    }
  end

  defp exact_comment(rows, marker_text, viewer_id) do
    matches =
      Enum.filter(rows, fn row ->
        row["body"] == marker_text and get_in(row, ["user", "id"]) == viewer_id and
          is_binary(row["createdAt"])
      end)

    case matches do
      [comment] -> {:ok, comment}
      [] -> {:error, :producer_terminal_comment_missing}
      _ -> {:error, :producer_terminal_comment_ambiguous}
    end
  end

  defp exact_done(rows, state_id, viewer_id) do
    matches =
      Enum.filter(rows, fn row ->
        row["toStateId"] == state_id and row["actorId"] == viewer_id and
          is_binary(row["fromStateId"]) and is_binary(row["createdAt"])
      end)

    case matches do
      [done] -> {:ok, done}
      [] -> {:error, :producer_terminal_done_history_missing}
      _ -> {:error, :producer_terminal_done_history_ambiguous}
    end
  end

  defp chronology(turn, comment, done, server_event, refreshed_at, deadline) do
    with {:ok, started} <- parse_time(turn["started_at_utc"]),
         {:ok, comment_at} <- parse_time(comment["createdAt"]),
         {:ok, done_at} <- parse_time(done["createdAt"]),
         {:ok, terminal_at} <- parse_time(server_event.terminal_at_utc),
         {:ok, refreshed} <- parse_time(refreshed_at),
         {:ok, deadline_at} <- parse_time(deadline.deadline_at_utc),
         true <- at_or_before?(started, comment_at) and at_or_before?(started, done_at),
         true <- at_or_before?(comment_at, terminal_at) and at_or_before?(done_at, terminal_at),
         true <- at_or_before?(terminal_at, refreshed) and before?(refreshed, deadline_at) do
      :ok
    else
      false -> {:error, :producer_terminal_chronology_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp at_or_before?(left, right), do: DateTime.compare(left, right) in [:lt, :eq]
  defp before?(left, right), do: DateTime.compare(left, right) == :lt

  defp publish(body, root_name, context, deadline, broker) do
    broker.publish_cas(body, root_name, workspace_root(context), context, deadline.deadline_at_utc)
  end

  defp root_name(:comments), do: "tracker_page"
  defp root_name(:history), do: "app_server_history_page"

  defp normalize_time(value) do
    case parse_time(value) do
      {:ok, datetime} -> Calendar.strftime(datetime, "%Y-%m-%dT%H:%M:%S.%3fZ")
      _ -> nil
    end
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _ -> {:error, :producer_terminal_timestamp_invalid}
    end
  end

  defp parse_time(_value), do: {:error, :producer_terminal_timestamp_invalid}

  defp producer_now do
    {:ok, DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.%3fZ")}
  end

  defp workspace_root(%{contract: %{document: contract}}),
    do: get_in(contract, ["constants", "workspace_root_windows"])

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
