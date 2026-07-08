defmodule LapsusAgent.Markdown do
  @moduledoc """
  Markdown rendering for model answers, backed by one parser (MDEx) with a single
  GFM extension config shared across surfaces:

    * `to_html/1` — sanitised HTML for the web UI (model output is untrusted).
    * `to_ansi/2` — word-wrapped ANSI for the terminal (`lps chat`/`ask`).

  There is no Markdown→ANSI library for Elixir, so `to_ansi/2` walks the MDEx AST
  itself — but it reuses the same parser and extension set as the HTML path, so both
  cover the same syntax (tables, lists, quotes, code, emphasis, links, strikethrough).
  """

  # GFM extensions — without `table: true` a table parses as a raw-text paragraph.
  @extension [table: true, strikethrough: true, autolink: true, tasklist: true]

  @doc "Shared MDEx extension set (also used by callers that parse directly)."
  def extension, do: @extension

  @doc "Sanitised HTML for the web UI. Returns `{:ok, html}` or `{:error, reason}`."
  def to_html(text), do: MDEx.to_html(text, extension: @extension, sanitize: true)

  @doc "Markdown → ANSI, word-wrapped to `width` columns. Falls back to raw text."
  def to_ansi(text, width) do
    cw = max(width - 4, 24)

    case MDEx.parse_document(text, extension: @extension) do
      {:ok, %MDEx.Document{nodes: nodes}} ->
        nodes
        |> Enum.map(&block(&1, cw))
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")
        |> String.split("\n")
        |> Enum.map_join("\n", fn "" -> ""; line -> "  " <> line end)

      _ ->
        text
    end
  end

  # --- block-level nodes (return content lines, no outer margin) ---

  defp blocks(nodes, cw) do
    nodes |> Enum.map(&block(&1, cw)) |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")
  end

  defp block(%MDEx.Heading{nodes: ns}, cw) do
    ns |> inline() |> wrap(cw) |> Enum.map_join("\n", &bright/1)
  end

  defp block(%MDEx.Paragraph{nodes: ns}, cw) do
    ns |> inline() |> wrap(cw) |> Enum.join("\n")
  end

  defp block(%MDEx.ThematicBreak{}, cw) do
    dim(String.duplicate("─", min(cw, 48)))
  end

  defp block(%MDEx.CodeBlock{literal: code}, _cw) do
    code
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.map_join("\n", &dim("│ " <> &1))
  end

  defp block(%MDEx.BlockQuote{nodes: ns}, cw) do
    ns
    |> blocks(cw - 2)
    |> String.split("\n")
    |> Enum.map_join("\n", &(dim("│ ") <> &1))
  end

  defp block(%MDEx.List{nodes: items, list_type: type, start: start}, cw) do
    {lines, _n} =
      Enum.reduce(items, {[], start || 1}, fn item, {acc, n} ->
        marker = if type == :ordered, do: "#{n}. ", else: "• "
        {[list_item(item, marker, cw) | acc], n + 1}
      end)

    lines |> Enum.reverse() |> Enum.join("\n")
  end

  defp block(%MDEx.Table{nodes: rows, alignments: aligns}, _cw), do: table(rows, aligns)

  # Unknown block: render children if any, else its literal, else drop.
  defp block(%{nodes: ns}, cw) when is_list(ns) and ns != [], do: blocks(ns, cw)
  defp block(%{literal: lit}, cw) when is_binary(lit), do: lit |> wrap(cw) |> Enum.join("\n")
  defp block(_, _), do: ""

  # A list item with a hanging indent so wrapped/nested lines align under the text.
  defp list_item(%{nodes: ns}, marker, cw) do
    avail = max(cw - String.length(marker), 12)
    [first | rest] = String.split(blocks(ns, avail), "\n")
    hang = String.duplicate(" ", String.length(marker))
    Enum.join([marker <> first | Enum.map(rest, &(hang <> &1))], "\n")
  end

  # --- tables ---

  defp table(rows, aligns) do
    matrix =
      Enum.map(rows, fn %MDEx.TableRow{header: h, nodes: cells} ->
        {h, Enum.map(cells, fn %MDEx.TableCell{nodes: ns} -> inline(ns) end)}
      end)

    ncols = Enum.reduce(matrix, 0, fn {_h, cells}, acc -> max(acc, length(cells)) end)

    if ncols == 0 do
      ""
    else
      widths =
        for c <- 0..(ncols - 1) do
          Enum.reduce(matrix, 3, fn {_h, cells}, acc -> max(acc, vlen(Enum.at(cells, c, ""))) end)
        end

      top = border(widths, "┌", "┬", "┐")
      mid = border(widths, "├", "┼", "┤")
      bot = border(widths, "└", "┴", "┘")

      body =
        Enum.map(matrix, fn {header?, cells} ->
          table_row(cells, widths, aligns, header?)
        end)

      # Separator after the header row (first row).
      rendered =
        case body do
          [head | tail] -> [head, mid | tail]
          [] -> []
        end

      Enum.join([top | rendered] ++ [bot], "\n")
    end
  end

  defp table_row(cells, widths, aligns, header?) do
    inner =
      widths
      |> Enum.with_index()
      |> Enum.map_join("│", fn {w, c} ->
        cell = Enum.at(cells, c, "")
        cell = if header?, do: bright(cell), else: cell
        " " <> pad(cell, w, Enum.at(aligns, c, :none)) <> " "
      end)

    "│" <> inner <> "│"
  end

  defp border(widths, l, m, r) do
    l <> Enum.map_join(widths, m, fn w -> String.duplicate("─", w + 2) end) <> r
  end

  defp pad(text, width, align) do
    gap = max(width - vlen(text), 0)

    case align do
      :right ->
        String.duplicate(" ", gap) <> text

      :center ->
        left = div(gap, 2)
        String.duplicate(" ", left) <> text <> String.duplicate(" ", gap - left)

      _ ->
        text <> String.duplicate(" ", gap)
    end
  end

  # --- inline nodes → a single ANSI string ---

  defp inline(nodes) when is_list(nodes), do: Enum.map_join(nodes, "", &inline_node/1)

  defp inline_node(%MDEx.Text{literal: t}), do: t
  defp inline_node(%MDEx.Strong{nodes: ns}), do: bright(inline(ns))
  defp inline_node(%MDEx.Emph{nodes: ns}), do: "\e[3m" <> inline(ns) <> "\e[23m"
  defp inline_node(%MDEx.Strikethrough{nodes: ns}), do: "\e[9m" <> inline(ns) <> "\e[29m"
  defp inline_node(%MDEx.Code{literal: t}), do: bright(t)
  defp inline_node(%MDEx.Link{url: url, nodes: ns}), do: inline(ns) <> dim(" (" <> url <> ")")
  defp inline_node(%MDEx.SoftBreak{}), do: " "
  defp inline_node(%MDEx.LineBreak{}), do: "\n"
  defp inline_node(%{nodes: ns}) when is_list(ns), do: inline(ns)
  defp inline_node(_), do: ""

  # --- ANSI + wrapping helpers ---

  defp bright(s), do: IO.ANSI.bright() <> s <> IO.ANSI.reset()
  defp dim(s), do: IO.ANSI.faint() <> s <> IO.ANSI.reset()

  # Word-wrap ANSI-containing text to `width` *visible* columns → list of lines.
  defp wrap(text, width) do
    {lines, cur} =
      text
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reduce({[], ""}, fn word, {lines, cur} ->
        cond do
          cur == "" -> {lines, word}
          vlen(cur) + 1 + vlen(word) <= width -> {lines, cur <> " " <> word}
          true -> {[cur | lines], word}
        end
      end)

    case Enum.reverse([cur | lines]) do
      [""] -> [""]
      ls -> ls
    end
  end

  defp vlen(s), do: s |> String.replace(~r/\e\[[0-9;]*m/, "") |> String.length()
end
