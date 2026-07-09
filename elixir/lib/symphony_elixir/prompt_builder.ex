defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]
  @max_manafuel_prompt_chars 35_000
  @manafuel_prompt_marker "# MANAfuel Symphony Workflow"
  @manafuel_full_workflow_path ".codex/workflows/symphony-manafuel/WORKFLOW.md"
  @compact_section_limits [
    {"__preamble__", 1_200, :head},
    {"## App-Server Tool Execution Contract", 3_500, :head},
    {"## Issue Context", 8_000, :middle},
    {"## Immediate Required First Actions", 3_500, :head},
    {"## Board Contract", 4_500, :head},
    {"## Ticket Notes And Delivery Goal", 4_500, :head},
    {"## Bounded Delivery Loop", 5_000, :head},
    {"## Worktree Rule", 2_500, :head},
    {"## Run Folder Contract", 2_500, :head},
    {"## MCP Policy", 3_000, :head},
    {"## Noninteractive Command Safety", 2_000, :head},
    {"## Validation", 2_500, :head},
    {"## Completion", 2_500, :head}
  ]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
    |> compact_prompt()
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp compact_prompt(prompt) when is_binary(prompt) do
    if String.length(prompt) > @max_manafuel_prompt_chars and String.contains?(prompt, @manafuel_prompt_marker) do
      compact_manafuel_prompt(prompt)
    else
      prompt
    end
  end

  defp compact_manafuel_prompt(prompt) do
    sections = markdown_sections(prompt)
    selected_headings = @compact_section_limits |> Enum.map(fn {heading, _limit, _mode} -> heading end) |> MapSet.new()

    section_text =
      @compact_section_limits
      |> Enum.flat_map(fn {heading, limit, mode} ->
        case Map.get(sections, heading) do
          section when is_binary(section) and section != "" ->
            [truncate_section(section, limit, mode)]

          _ ->
            []
        end
      end)

    omitted_headings =
      sections
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(selected_headings, &1))
      |> Enum.reject(&(&1 == "__preamble__"))
      |> Enum.sort()

    compacted =
      [
        "# MANAfuel Symphony Workflow (compacted for token budget)",
        "The full policy remains authoritative at `#{@manafuel_full_workflow_path}`. This prompt includes the always-needed execution rules and current issue context; read only the relevant full-policy section when a scoped surface applies.",
        section_text,
        omitted_sections_note(omitted_headings)
      ]
      |> List.flatten()
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    if String.length(compacted) > @max_manafuel_prompt_chars do
      truncate_middle(compacted, @max_manafuel_prompt_chars)
    else
      compacted
    end
  end

  defp markdown_sections(prompt) do
    {sections, heading, lines} =
      prompt
      |> String.split("\n", trim: false)
      |> Enum.reduce({%{}, "__preamble__", []}, fn line, {sections, heading, lines} ->
        if String.starts_with?(line, "## ") do
          {Map.put(sections, heading, lines_to_section(lines)), String.trim(line), [line]}
        else
          {sections, heading, [line | lines]}
        end
      end)

    Map.put(sections, heading, lines_to_section(lines))
  end

  defp lines_to_section(lines) do
    lines
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.trim()
  end

  defp truncate_section(section, limit, :middle), do: truncate_middle(section, limit)
  defp truncate_section(section, limit, _mode), do: truncate_head(section, limit)

  defp truncate_head(section, limit) do
    if String.length(section) > limit do
      String.slice(section, 0, limit) <>
        "\n[section compacted after #{limit} characters; read `#{@manafuel_full_workflow_path}` if this section applies]"
    else
      section
    end
  end

  defp truncate_middle(section, limit) do
    if String.length(section) > limit do
      marker =
        "\n[section compacted to stay under the child-agent token budget; read `#{@manafuel_full_workflow_path}` if omitted detail applies]\n"

      keep = max(limit - String.length(marker), 0)
      head = div(keep, 2)
      tail = keep - head

      String.slice(section, 0, head) <> marker <> String.slice(section, -tail, tail)
    else
      section
    end
  end

  defp omitted_sections_note([]), do: ""

  defp omitted_sections_note(headings) do
    [
      "Compacted prompt omitted these full-policy sections from the first turn:",
      headings |> Enum.map(&("- " <> &1)) |> Enum.join("\n"),
      "If the current ticket touches one of those surfaces, inspect that section from `#{@manafuel_full_workflow_path}` before making scoped changes."
    ]
    |> Enum.join("\n")
  end
end
