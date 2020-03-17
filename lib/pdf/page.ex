defmodule Pdf.Page do
  defstruct size: :a4,
            stream: nil,
            fonts: nil,
            current_font: nil,
            current_font_size: 0,
            fill_color: :black,
            leading: nil,
            cursor: 0

  import Pdf.Utils
  alias Pdf.{Image, Fonts, Stream, Text}

  def new(opts \\ [size: :a4]), do: init(opts, %__MODULE__{stream: Stream.new()})

  defp init([], page), do: page
  defp init([{:fonts, fonts} | tail], page), do: init(tail, %{page | fonts: fonts})

  defp init([{:size, size} | tail], page), do: init(tail, %{page | size: size})

  defp init([{:compress, false} | tail], page),
    do: init(tail, %{page | stream: Stream.new(compress: false)})

  defp init([{:compress, true} | tail], page),
    do: init(tail, %{page | stream: Stream.new(compress: 6)})

  defp init([{:compress, level} | tail], page),
    do: init(tail, %{page | stream: Stream.new(compress: level)})

  defp init([_ | tail], page), do: init(tail, page)

  def push(page, command), do: %{page | stream: Stream.push(page.stream, command)}

  def set_fill_color(%{fill_color: color} = page, color), do: page

  def set_fill_color(page, color) do
    push(%{page | fill_color: color}, color_command(color, fill_command(color)))
  end

  def set_stroke_color(page, color) do
    push(page, color_command(color, stroke_command(color)))
  end

  def set_line_width(page, width) do
    push(page, [width, "w"])
  end

  def rectangle(page, {x, y}, {w, h}) do
    push(page, [x, y, w, h, "re"])
  end

  def line(page, {x, y}, {x2, y2}) do
    page
    |> move_to({x, y})
    |> line_append({x2, y2})
  end

  def move_to(page, {x, y}) do
    push(page, [x, y, "m"])
  end

  def line_append(page, {x, y}) do
    push(page, [x, y, "l"])
  end

  def stroke(page) do
    push(page, ["S"])
  end

  def set_font(%{fonts: fonts} = page, name, size, opts \\ []) do
    font = Fonts.get_font(fonts, name, opts)

    if page.current_font == font && page.current_font_size == size do
      page
    else
      push(%{page | current_font: font, current_font_size: size}, [font.name, size, "Tf"])
    end
  end

  def set_text_leading(page, leading) do
    %{page | leading: leading}
  end

  def text_at(page, xy, text, opts \\ [])

  def text_at(page, {x, y}, attributed_text, opts) when is_list(attributed_text) do
    attributed_text = annotate_attributed_text(attributed_text, page, opts)

    page
    |> push("BT")
    |> push([x, y, "Td"])
    |> print_attributed_line(attributed_text)
    |> push("ET")
    |> set_cursor(y - line_height(page, attributed_text))
  end

  def text_at(%{current_font: %{module: font}} = page, {x, y}, text, opts) do
    page
    |> push("BT")
    |> push([x, y, "Td"])
    |> push(kerned_text(font, text, Keyword.get(opts, :kerning, false)))
    |> push("ET")
  end

  defp merge_same_opts([]), do: []

  defp merge_same_opts([{text, width, opts}, {text2, width2, opts} | tail]) do
    merge_same_opts([{text <> text2, width + width2, opts} | tail])
  end

  defp merge_same_opts([chunk | tail]) do
    [chunk | merge_same_opts(tail)]
  end

  defp annotate_attributed_text(
         attributed_text,
         %{fonts: fonts, current_font: %{module: font}} = page,
         overall_opts
       ) do
    attributed_text
    |> Enum.map(fn
      str when is_binary(str) -> {str, []}
      {str} -> {str, []}
      {str, opts} -> {str, opts}
    end)
    |> Enum.map(fn {text, opts} ->
      # TODO: This overrides the default font with the non-bold version
      opts = Keyword.merge(overall_opts, opts)

      font =
        if Enum.any?([:bold, :italic], &Keyword.has_key?(opts, &1)) do
          Fonts.get_font(fonts, font.family_name, Keyword.take(opts, [:bold, :italic]))
        else
          Fonts.get_font(fonts, font.name, [])
        end

      font_size = Keyword.get(opts, :size, page.current_font_size)
      color = Keyword.get(opts, :color, page.fill_color)

      height = font_size
      ascender = font.module.ascender * font_size / 1000

      width = font.module.text_width(text, font_size, opts)

      {text, width,
       Keyword.merge(
         overall_opts,
         Keyword.merge(opts,
           ascender: ascender,
           color: color,
           font: font,
           height: height,
           size: font_size
         )
       )}
    end)
  end

  def text_wrap(page, xy, wh, text, opts \\ [])

  def text_wrap(page, {x, y}, {w, h}, text, opts)
      when is_binary(text) do
    {page, remaining} = text_wrap(page, {x, y}, {w, h}, [text], opts)
    {page, chunks_to_text(remaining)}
  end

  def text_wrap(page, {x, y}, {w, h}, attributed_text, opts) when is_list(attributed_text) do
    attributed_text = annotate_attributed_text(attributed_text, page, opts)

    chunks =
      attributed_text
      |> Enum.flat_map(fn {text, _width, text_opts} ->
        text
        |> Text.chunk_text(
          Keyword.get(text_opts, :font).module,
          Keyword.get(text_opts, :size),
          Keyword.merge(opts, text_opts)
        )
      end)

    page = push(page, "BT")

    {page, remaining} =
      page
      |> set_cursor(0)
      |> print_attributed_chunks(chunks, x, y + h, w, h, opts)

    page = push(page, "ET")
    {page, remaining}
  end

  defp chunks_to_text(chunks) do
    chunks
    |> List.flatten()
    |> Enum.map(&elem(&1, 0))
    |> Enum.join()
  end

  defp line_height(page, attributed_text) do
    line_height = attributed_text |> Enum.map(&Keyword.get(elem(&1, 2), :height)) |> Enum.max()
    Enum.max(Enum.filter([page.leading, line_height], & &1))
  end

  defp print_attributed_chunks(page, chunks, x, y, width, height, opts)

  defp print_attributed_chunks(page, [], _, _, _, _, _), do: {page, []}

  defp print_attributed_chunks(page, chunks, x, y, width, height, opts) do
    {line, tail} =
      case Text.wrap_chunks(chunks, width) do
        {[], [line | tail]} ->
          {[line], tail}

        other ->
          other
      end

    line_width = Enum.reduce(line, 0, fn {_, width, _}, acc -> width + acc end)

    line_height = line |> Enum.map(&Keyword.get(elem(&1, 2), :height)) |> Enum.max()
    line_height = Enum.max(Enum.filter([page.leading, line_height], & &1))

    if line_height > height do
      # No available vertical space to print the line so return remaining lines
      {page, [line | tail]}
    else
      x_offset =
        case Keyword.get(opts, :align, :left) do
          :left -> x
          :center -> x + (width - line_width) / 2
          :right -> x + (width - line_width)
        end

      y_offset = y - line_height

      page
      |> push([x_offset, y_offset, "Td"])
      |> print_attributed_line(line)
      |> move_cursor(y_offset)
      |> print_attributed_chunks(
        tail,
        x - x_offset,
        y - y,
        width,
        height - line_height,
        opts
      )
    end
  end

  defp print_attributed_line(page, attributed_text) do
    attributed_text
    |> merge_same_opts
    |> Enum.reduce(page, fn {text, _width, opts}, page ->
      page
      |> set_font(opts[:font].module.name, opts[:size], opts)
      |> set_fill_color(opts[:color])
      |> push(kerned_text(opts[:font], text, Keyword.get(opts, :kerning, false)))
    end)
  end

  def text_lines(page, {x, y}, lines, opts \\ []) do
    leading = page.leading || page.current_font_size

    page
    |> push("BT")
    |> push([x, y, "Td"])
    |> push([leading, "TL"])
    |> draw_lines(lines, opts)
    |> push("ET")
  end

  def add_image(page, {x, y}, %{name: image_name, image: %Image{width: width, height: height}}) do
    page
    |> push("q")
    |> push([width, 0, 0, height, x, y, "cm"])
    |> push([image_name, "Do"])
    |> push("Q")
  end

  def size(%{size: size}) do
    [_bottom, _left, width, height] = Pdf.Paper.size(size)
    %{width: width, height: height}
  end

  def set_cursor(page, y) do
    %{page | cursor: y}
  end

  def move_cursor(%{cursor: cursor} = page, y) do
    %{page | cursor: cursor + y}
  end

  def move_down(page, amount) do
    move_cursor(page, -amount)
  end

  def cursor(%{cursor: cursor}) do
    cursor
  end

  defp kerned_text(_font, text, false) do
    [s(Text.normalize_string(text)), "Tj"]
  end

  defp kerned_text(font, text, true) do
    text =
      text
      |> Text.normalize_string()
      |> font.kern_text()
      |> Enum.map(fn
        str when is_binary(str) -> s(str)
        num -> num
      end)

    [Pdf.Array.new(text), "TJ"]
  end

  defp draw_lines(%{current_font: %{module: font}} = page, [line], opts) do
    push(page, kerned_text(font, line, Keyword.get(opts, :kerning, false)))
  end

  defp draw_lines(%{current_font: %{module: font}} = page, [line | tail], opts) do
    text = kerned_text(font, line, Keyword.get(opts, :kerning, false))
    draw_lines(push(page, text ++ ["T*"]), tail, opts)
  end

  defp color_command(color_name, command) when is_atom(color_name) do
    color = Pdf.Color.color(color_name)
    color_command(color, command)
  end

  defp color_command({r, g, b}, command) when is_integer(r) and is_integer(g) and is_integer(b) do
    [r / 255.0, g / 255.0, b / 255.0, command]
  end

  defp color_command({r, g, b}, command) when is_float(r) and is_float(g) and is_float(b) do
    [r, g, b, command]
  end

  defp color_command({r, g, b}, command) when is_float(r) and is_float(g) and is_float(b) do
    [r, g, b, command]
  end

  defp color_command({c, m, y, k}, command)
       when is_float(c) and is_float(m) and is_float(y) and is_float(k) do
    [c, m, y, k, command]
  end

  defp fill_command(color_name) when is_atom(color_name), do: "rg"
  defp fill_command({_r, _g, _b}), do: "rg"
  defp fill_command({_c, _m, _y, _k}), do: "k"

  defp stroke_command(color_name) when is_atom(color_name), do: "RG"
  defp stroke_command({_r, _g, _b}), do: "RG"
  defp stroke_command({_c, _m, _y, _k}), do: "K"

  defimpl Pdf.Size do
    def size_of(%Pdf.Page{} = page), do: Pdf.Size.size_of(page.stream)
  end

  defimpl Pdf.Export do
    def to_iolist(%Pdf.Page{} = page), do: Pdf.Export.to_iolist(page.stream)
  end
end
