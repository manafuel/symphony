defmodule SymphonyElixir.ProducerV6TerminalTrackerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProducerV6.TerminalTracker

  defmodule BrokerStub do
    def publish_cas(body, root_name, _workspace_root, _context, _deadline) do
      bytes = :erlang.term_to_binary(body)
      digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

      {:ok,
       %{
         "path" => ".symphony-state/#{root_name}/sha256/#{digest}.json",
         "physical_path" => "test://#{root_name}/#{digest}",
         "volume_id" => "test-volume",
         "file_id" => digest,
         "file_type" => "regular",
         "link_count" => 1,
         "sha256" => digest,
         "length" => byte_size(bytes)
       }}
    end
  end

  test "captures one exact worker marker and one exact Done history transition" do
    now = DateTime.utc_now()
    started = at(now, -300)
    comment_at = at(now, -240)
    done_at = at(now, -180)
    terminal_at = at(now, -120)
    deadline_at = at(now, 3_600)
    document = effect_document(started)
    deadline = deadline(deadline_at)
    marker = TerminalTracker.marker_text(document, deadline)

    graphql = fn query, _variables ->
      cond do
        String.contains?(query, "ProducerV6State") ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "id" => "issue-1",
                 "identifier" => "MAN-900",
                 "updatedAt" => done_at,
                 "state" => %{"id" => "state-done", "name" => "Done", "type" => "completed"}
               }
             }
           }}

        String.contains?(query, "ProducerV6Comments") ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "comments" => %{
                   "nodes" => [
                     %{
                       "id" => "comment-1",
                       "createdAt" => comment_at,
                       "body" => marker,
                       "user" => %{"id" => "worker-1"}
                     }
                   ],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }}

        String.contains?(query, "ProducerV6History") ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "history" => %{
                   "nodes" => [
                     %{
                       "id" => "history-1",
                       "createdAt" => done_at,
                       "actorId" => "worker-1",
                       "fromStateId" => "state-progress",
                       "toStateId" => "state-done"
                     }
                   ],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }}
      end
    end

    assert {:ok, tracker} =
             TerminalTracker.capture_with(
               context(),
               %{document: document},
               %{reference: reference("terminal"), terminal_at_utc: terminal_at},
               deadline,
               graphql,
               BrokerStub
             )

    assert tracker["state"]["type"] == "completed"
    assert tracker["final_worker_comment"]["id"] == "comment-1"
    assert tracker["final_worker_comment"]["marker"]["occurrences"] == 1
    assert tracker["done_transition"]["history_id"] == "history-1"
    assert tracker["comment_pagination"]["match_count"] == 1
    assert tracker["history_pagination"]["match_count"] == 1
    assert tracker["server_turn_terminal_event"]["sha256"] == reference("terminal")["sha256"]
  end

  test "rejects a caller-authored or missing closeout marker" do
    now = DateTime.utc_now()
    document = effect_document(at(now, -300))
    deadline = deadline(at(now, 3_600))

    graphql = fn query, _variables ->
      cond do
        String.contains?(query, "ProducerV6State") ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "id" => "issue-1",
                 "identifier" => "MAN-900",
                 "updatedAt" => at(now, -180),
                 "state" => %{"id" => "state-done", "name" => "Done", "type" => "completed"}
               }
             }
           }}

        String.contains?(query, "ProducerV6Comments") ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "comments" => %{
                   "nodes" => [
                     %{
                       "id" => "comment-1",
                       "createdAt" => at(now, -240),
                       "body" => "PASS",
                       "user" => %{"id" => "worker-1"}
                     }
                   ],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }}

        String.contains?(query, "ProducerV6History") ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "history" => %{
                   "nodes" => [],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }}
      end
    end

    assert {:error, :producer_terminal_comment_missing} =
             TerminalTracker.capture_with(
               context(),
               %{document: document},
               %{reference: reference("terminal"), terminal_at_utc: at(now, -120)},
               deadline,
               graphql,
               BrokerStub
             )
  end

  defp context do
    %{
      launch: %{document: %{"authenticated_identities" => %{"linear_worker_actor_id" => "worker-1"}}},
      contract: %{document: %{"constants" => %{"workspace_root_windows" => System.tmp_dir!()}}}
    }
  end

  defp effect_document(started_at) do
    %{
      "issue_id" => "issue-1",
      "identifier" => "MAN-900",
      "claim_session_id" => "symcs-" <> String.duplicate("a", 32),
      "idempotency_key" => String.duplicate("b", 64),
      "turns" => [%{"turn_number" => 1, "started_at_utc" => started_at}]
    }
  end

  defp deadline(deadline_at) do
    %{
      deadline_at_utc: deadline_at,
      deadline_sha256: String.duplicate("c", 64),
      deadline_artifact_path: "C:\\test\\deadline.json",
      originator_cycle_index: 1
    }
  end

  defp reference(label) do
    digest = :crypto.hash(:sha256, label) |> Base.encode16(case: :lower)

    %{
      "path" => ".symphony-state/test/#{digest}.json",
      "physical_path" => "test://#{digest}",
      "volume_id" => "test-volume",
      "file_id" => digest,
      "file_type" => "regular",
      "link_count" => 1,
      "sha256" => digest,
      "length" => 1
    }
  end

  defp at(now, seconds) do
    now
    |> DateTime.add(seconds, :second)
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.%3fZ")
  end
end
