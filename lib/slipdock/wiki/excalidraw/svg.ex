defmodule Slipdock.Wiki.Excalidraw.SVG do
  @moduledoc """
  An Excalidraw scene drawn as SVG on the server, for the preview a page
  shows where it embeds a drawing (W-103 R5.1).

  It is a preview, not Excalidraw's own export: strokes are clean rather than
  rough.js's hand-drawn wobble, and text is set in the nearest font the
  reader has (an SVG shown as an image cannot fetch Excalifont). Shapes,
  lines, arrows and their heads, freehand strokes, text, frames and images
  are drawn where Excalidraw puts them, with their colours, fills, stroke
  styles, opacity and rotation. A dark-theme drawing gets the filter
  Excalidraw's own dark export applies.

  Every value from the scene is escaped or checked before it is written, and
  an image is only ever a raster `data:` URL, so a drawing cannot carry
  script into the page that serves it.
  """

  @padding 10

  @doc """
  The scene as an SVG document. `files` maps an image element's `fileId` to
  a `data:` URL, for images the scene's own `files` do not carry (the
  plugin keeps them as separate files).
  """
  @spec render(map, %{String.t() => String.t()}) :: String.t()
  def render(scene, files \\ %{}) do
    elements =
      scene
      |> Map.get("elements", [])
      |> List.wrap()
      |> Enum.filter(&(is_map(&1) and &1["isDeleted"] != true))

    files = Map.merge(scene_files(scene), files)
    app_state = if is_map(scene["appState"]), do: scene["appState"], else: %{}
    {min_x, min_y, max_x, max_y} = bounds(elements)
    width = max_x - min_x + 2 * @padding
    height = max_y - min_y + 2 * @padding
    background = color(app_state["viewBackgroundColor"], "#ffffff")
    dark? = app_state["theme"] == "dark"
    {patterns, body} = elements |> Enum.map_reduce(%{}, &element(&1, &2, files)) |> swap()

    IO.iodata_to_binary([
      ~s|<svg xmlns="http://www.w3.org/2000/svg" viewBox="#{num(min_x - @padding)} #{num(min_y - @padding)} #{num(width)} #{num(height)}" |,
      ~s|width="#{num(width)}" height="#{num(height)}"|,
      if(dark?, do: ~s| style="filter: invert(93%) hue-rotate(180deg)"|, else: ""),
      ">",
      "<defs>",
      Enum.map(patterns, fn {color, id} -> hatch(id, color) end),
      "</defs>",
      ~s|<rect x="#{num(min_x - @padding)}" y="#{num(min_y - @padding)}" width="#{num(width)}" height="#{num(height)}" fill="#{background}"/>|,
      body,
      "</svg>"
    ])
  end

  defp swap({body, patterns}), do: {patterns, body}

  defp scene_files(%{"files" => files}) when is_map(files) do
    for {id, %{"dataURL" => url}} <- files, is_binary(url), into: %{}, do: {id, url}
  end

  defp scene_files(_), do: %{}

  ## Bounds -------------------------------------------------------------------

  defp bounds([]), do: {0, 0, 100, 100}

  defp bounds(elements) do
    elements
    |> Enum.flat_map(&corners/1)
    |> case do
      [] ->
        {0, 0, 100, 100}

      points ->
        {xs, ys} = Enum.unzip(points)
        {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
    end
  end

  defp corners(element) do
    {x, y, w, h} = box(element)
    {cx, cy} = {x + w / 2, y + h / 2}
    angle = number(element["angle"], 0)

    # A curve stays inside its control points, so they bound it.
    points =
      case points(element) do
        [] -> [{x, y}, {x + w, y}, {x, y + h}, {x + w, y + h}]
        pts -> pts |> Enum.map(fn {px, py} -> {x + px, y + py} end) |> with_controls(element)
      end

    stroke = number(element["strokeWidth"], 1) / 2

    points
    |> Enum.map(&rotate(&1, {cx, cy}, angle))
    |> Enum.flat_map(fn {px, py} -> [{px - stroke, py - stroke}, {px + stroke, py + stroke}] end)
  end

  defp with_controls(pts, element) do
    if curved?(element) and length(pts) > 2,
      do: pts ++ Enum.flat_map(segments(pts), fn {c1, c2, _} -> [c1, c2] end),
      else: pts
  end

  defp curved?(element),
    do: match?(%{"type" => 2}, element["roundness"]) and element["elbowed"] != true

  defp rotate(point, _center, angle) when angle == 0, do: point

  defp rotate({px, py}, {cx, cy}, angle) do
    {dx, dy} = {px - cx, py - cy}

    {cx + dx * :math.cos(angle) - dy * :math.sin(angle),
     cy + dx * :math.sin(angle) + dy * :math.cos(angle)}
  end

  defp box(element) do
    {number(element["x"], 0), number(element["y"], 0), number(element["width"], 0),
     number(element["height"], 0)}
  end

  defp points(%{"points" => points}) when is_list(points) do
    for [px, py | _] <- points, is_number(px) and is_number(py), do: {px, py}
  end

  defp points(_), do: []

  ## Elements -----------------------------------------------------------------

  defp element(%{"type" => type} = el, patterns, files) do
    {fill, patterns} = fill(el, patterns)
    inner = shape(type, el, fill, files)

    if inner == "" do
      {"", patterns}
    else
      {x, y, w, h} = box(el)
      angle = number(el["angle"], 0)
      opacity = number(el["opacity"], 100)

      attrs = [
        if(angle != 0,
          do:
            ~s| transform="rotate(#{num(angle * 180 / :math.pi())} #{num(x + w / 2)} #{num(y + h / 2)})"|,
          else: ""
        ),
        if(opacity < 100, do: ~s| opacity="#{num(max(opacity, 0) / 100)}"|, else: "")
      ]

      {["<g", attrs, ">", inner, "</g>"], patterns}
    end
  end

  defp element(_el, patterns, _files), do: {"", patterns}

  defp shape("rectangle", el, fill, _files) do
    {x, y, w, h} = normalised_box(el)
    r = if el["roundness"], do: min(min(w, h) * 0.25, 32), else: 0

    ~s|<rect x="#{num(x)}" y="#{num(y)}" width="#{num(w)}" height="#{num(h)}" rx="#{num(r)}"#{fill}#{stroke(el)}/>|
  end

  defp shape("ellipse", el, fill, _files) do
    {x, y, w, h} = normalised_box(el)

    ~s|<ellipse cx="#{num(x + w / 2)}" cy="#{num(y + h / 2)}" rx="#{num(w / 2)}" ry="#{num(h / 2)}"#{fill}#{stroke(el)}/>|
  end

  defp shape("diamond", el, fill, _files) do
    {x, y, w, h} = normalised_box(el)

    points =
      [{x + w / 2, y}, {x + w, y + h / 2}, {x + w / 2, y + h}, {x, y + h / 2}]
      |> Enum.map_join(" ", fn {px, py} -> num(px) <> "," <> num(py) end)

    ~s|<polygon points="#{points}" stroke-linejoin="round"#{fill}#{stroke(el)}/>|
  end

  defp shape(type, el, fill, _files) when type in ["line", "arrow"] do
    {x, y, _, _} = box(el)
    pts = el |> points() |> Enum.map(fn {px, py} -> {x + px, y + py} end)

    if length(pts) < 2 do
      ""
    else
      closed? = type == "line" and (el["polygon"] == true or closed?(pts))
      d = path(pts, curved?(el) and type in ["line", "arrow"]) <> if(closed?, do: " Z", else: "")
      fill = if closed?, do: fill, else: ~s| fill="none"|

      [
        ~s|<path d="#{d}" stroke-linecap="round" stroke-linejoin="round"#{fill}#{stroke(el)}/>|,
        if(type == "arrow", do: arrowheads(el, pts), else: "")
      ]
    end
  end

  defp shape("freedraw", el, _fill, _files) do
    {x, y, _, _} = box(el)
    pts = el |> points() |> Enum.map(fn {px, py} -> {x + px, y + py} end)

    case pts do
      [] ->
        ""

      [{px, py}] ->
        ~s|<circle cx="#{num(px)}" cy="#{num(py)}" r="#{num(number(el["strokeWidth"], 1))}" fill="#{stroke_color(el)}"/>|

      _ ->
        width = number(el["strokeWidth"], 1) * 1.5

        ~s|<path d="#{path(pts, false)}" fill="none" stroke="#{stroke_color(el)}" stroke-width="#{num(width)}" stroke-linecap="round" stroke-linejoin="round"/>|
    end
  end

  defp shape("text", el, _fill, _files), do: text(el)

  defp shape("image", el, _fill, files) do
    {x, y, w, h} = normalised_box(el)

    case files[el["fileId"]] do
      url when is_binary(url) ->
        if safe_image?(url),
          do:
            ~s|<image href="#{escape(url)}" x="#{num(x)}" y="#{num(y)}" width="#{num(w)}" height="#{num(h)}" preserveAspectRatio="none"/>|,
          else: placeholder(x, y, w, h)

      _ ->
        placeholder(x, y, w, h)
    end
  end

  defp shape(type, el, _fill, _files) when type in ["frame", "magicframe"] do
    {x, y, w, h} = normalised_box(el)
    name = if is_binary(el["name"]), do: el["name"], else: "Frame"

    [
      ~s|<rect x="#{num(x)}" y="#{num(y)}" width="#{num(w)}" height="#{num(h)}" rx="8" fill="none" stroke="#bbbbbb" stroke-width="1"/>|,
      ~s|<text x="#{num(x)}" y="#{num(y - 6)}" font-family="sans-serif" font-size="14" fill="#999999">#{escape(name)}</text>|
    ]
  end

  defp shape(type, el, _fill, _files) when type in ["embeddable", "iframe"] do
    {x, y, w, h} = normalised_box(el)
    link = if is_binary(el["link"]), do: el["link"], else: ""

    [
      ~s|<rect x="#{num(x)}" y="#{num(y)}" width="#{num(w)}" height="#{num(h)}" fill="#f1f3f5"#{stroke(el)}/>|,
      ~s|<text x="#{num(x + w / 2)}" y="#{num(y + h / 2)}" text-anchor="middle" dominant-baseline="central" font-family="sans-serif" font-size="14" fill="#868e96">#{escape(link)}</text>|
    ]
  end

  defp shape(_type, _el, _fill, _files), do: ""

  # Excalidraw lets a shape's width and height go negative while it is drawn.
  defp normalised_box(el) do
    {x, y, w, h} = box(el)
    {min(x, x + w), min(y, y + h), abs(w), abs(h)}
  end

  defp closed?([first | _] = pts) do
    {fx, fy} = first
    {lx, ly} = List.last(pts)
    length(pts) > 2 and abs(fx - lx) < 1 and abs(fy - ly) < 1
  end

  defp placeholder(x, y, w, h),
    do:
      ~s|<rect x="#{num(x)}" y="#{num(y)}" width="#{num(w)}" height="#{num(h)}" fill="#f1f3f5" stroke="#ced4da" stroke-dasharray="6 4"/>|

  defp safe_image?(url),
    do: Regex.match?(~r{\Adata:image/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/=\s]+\z}, url)

  ## Paths --------------------------------------------------------------------

  defp path([{x0, y0} | rest] = pts, curved?) do
    start = "M" <> num(x0) <> " " <> num(y0)

    if curved? and length(pts) > 2 do
      start <> catmull_rom(pts)
    else
      start <> Enum.map_join(rest, fn {x, y} -> " L" <> num(x) <> " " <> num(y) end)
    end
  end

  # A smooth curve through every point, as Excalidraw's rounded lines are.
  defp catmull_rom(pts) do
    Enum.map_join(segments(pts), fn {c1, c2, to} ->
      " C" <> pair(c1) <> " " <> pair(c2) <> " " <> pair(to)
    end)
  end

  # Each stretch of the curve as a cubic Bézier: two control points and the
  # point it ends on.
  defp segments(pts) do
    ([hd(pts) | pts] ++ [List.last(pts)])
    |> Enum.chunk_every(4, 1, :discard)
    |> Enum.map(fn [{x0, y0}, {x1, y1}, {x2, y2}, {x3, y3}] ->
      {{x1 + (x2 - x0) / 6, y1 + (y2 - y0) / 6}, {x2 - (x3 - x1) / 6, y2 - (y3 - y1) / 6},
       {x2, y2}}
    end)
  end

  defp pair({x, y}), do: num(x) <> " " <> num(y)

  defp arrowheads(el, pts) do
    [
      head(el["endArrowhead"], List.last(pts), Enum.at(pts, -2), el),
      head(el["startArrowhead"], hd(pts), Enum.at(pts, 1), el)
    ]
  end

  defp head(nil, _tip, _from, _el), do: ""

  defp head(kind, {tx, ty} = tip, {fx, fy}, el) when is_binary(kind) do
    angle = :math.atan2(ty - fy, tx - fx)
    size = 10 + number(el["strokeWidth"], 1) * 3
    color = stroke_color(el)
    at = fn distance, spread -> point_back(tip, angle, distance, spread) end

    case kind do
      k when k in ["triangle", "triangle_outline"] ->
        fill = if k == "triangle", do: color, else: "none"

        ~s|<polygon points="#{pts([tip, at.(size, 0.45), at.(size, -0.45)])}" fill="#{fill}"#{stroke(el)}/>|

      k when k in ["dot", "circle", "circle_outline"] ->
        fill = if k == "circle_outline", do: "none", else: color
        {cx, cy} = at.(size / 3, 0)

        ~s|<circle cx="#{num(cx)}" cy="#{num(cy)}" r="#{num(size / 3)}" fill="#{fill}"#{stroke(el)}/>|

      k when k in ["diamond", "diamond_outline"] ->
        fill = if k == "diamond", do: color, else: "none"

        ~s|<polygon points="#{pts([tip, at.(size / 2, 0.5), at.(size, 0), at.(size / 2, -0.5)])}" fill="#{fill}"#{stroke(el)}/>|

      "bar" ->
        {ax, ay} = point_side(tip, angle, size / 2)
        {bx, by} = point_side(tip, angle, -size / 2)
        ~s|<path d="M#{pair({ax, ay})} L#{pair({bx, by})}" fill="none"#{stroke(el)}/>|

      _ ->
        ~s|<path d="M#{pair(at.(size, 0.45))} L#{pair(tip)} L#{pair(at.(size, -0.45))}" fill="none" stroke-linecap="round" stroke-linejoin="round"#{stroke(el)}/>|
    end
  end

  defp head(_kind, _tip, _from, _el), do: ""

  defp point_back({tx, ty}, angle, distance, spread) do
    a = angle + :math.pi() + spread
    {tx + distance * :math.cos(a), ty + distance * :math.sin(a)}
  end

  defp point_side({tx, ty}, angle, offset) do
    a = angle + :math.pi() / 2
    {tx + offset * :math.cos(a), ty + offset * :math.sin(a)}
  end

  defp pts(points), do: Enum.map_join(points, " ", fn {x, y} -> num(x) <> "," <> num(y) end)

  ## Text ---------------------------------------------------------------------

  defp text(el) do
    {x, y, w, h} = box(el)
    size = number(el["fontSize"], 20)
    line_height = size * number(el["lineHeight"], 1.25)
    lines = (el["text"] || "") |> to_string() |> String.split("\n")
    block = line_height * length(lines)

    top =
      case el["verticalAlign"] do
        "middle" -> y + (h - block) / 2
        "bottom" -> y + h - block
        _ -> y
      end

    {anchor, tx} =
      case el["textAlign"] do
        "center" -> {"middle", x + w / 2}
        "right" -> {"end", x + w}
        _ -> {"start", x}
      end

    [
      ~s|<text font-family="#{font(el["fontFamily"])}" font-size="#{num(size)}" fill="#{stroke_color(el)}" text-anchor="#{anchor}" dominant-baseline="central" xml:space="preserve">|,
      lines
      |> Enum.with_index()
      |> Enum.map(fn {line, i} ->
        ~s|<tspan x="#{num(tx)}" y="#{num(top + line_height * (i + 0.5))}">#{escape(line)}</tspan>|
      end),
      "</text>"
    ]
  end

  # Excalidraw's font ids, as the nearest the reader will have. The
  # hand-drawn ones end in sans-serif, not `cursive`, which is a script face
  # on some systems and a serif on others.
  defp font(family) when family in [1, 5, 8],
    do: "Excalifont, Virgil, 'Comic Sans MS', 'Comic Neue', 'Segoe Print', sans-serif"

  defp font(3), do: "'Cascadia Code', Consolas, Menlo, monospace"
  defp font(7), do: "'Lilita One', Impact, sans-serif"
  defp font(_), do: "Nunito, Helvetica, Arial, sans-serif"

  ## Colours, fills and strokes -----------------------------------------------

  defp stroke(el) do
    width = number(el["strokeWidth"], 1)

    dash =
      case el["strokeStyle"] do
        "dashed" ->
          ~s| stroke-dasharray="#{num(width * 4)} #{num(width * 4 + 4)}"|

        "dotted" ->
          ~s| stroke-dasharray="#{num(width * 0.1)} #{num(width * 3 + 3)}" stroke-linecap="round"|

        _ ->
          ""
      end

    ~s| stroke="#{stroke_color(el)}" stroke-width="#{num(width)}"#{dash}|
  end

  defp stroke_color(el), do: color(el["strokeColor"], "#1e1e1e")

  defp fill(el, patterns) do
    case color(el["backgroundColor"], "transparent") do
      "transparent" ->
        {~s| fill="none"|, patterns}

      background ->
        if el["fillStyle"] in [nil, "solid"] do
          {~s| fill="#{background}"|, patterns}
        else
          id = Map.get(patterns, background, "hatch-#{map_size(patterns)}")
          {~s| fill="url(##{id})"|, Map.put(patterns, background, id)}
        end
    end
  end

  defp hatch(id, color) do
    ~s|<pattern id="#{id}" patternUnits="userSpaceOnUse" width="8" height="8" patternTransform="rotate(-45)">| <>
      ~s|<line x1="0" y1="0" x2="0" y2="8" stroke="#{color}" stroke-width="2"/></pattern>|
  end

  # A colour is a hex code, a CSS colour name or `transparent`; anything else
  # is the default, so nothing from the file reaches an attribute unchecked.
  defp color(value, default) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A(#[0-9a-fA-F]{3,8}|[a-zA-Z]{3,20})\z/, value), do: value, else: default
  end

  defp color(_value, default), do: default

  ## Numbers and escaping -----------------------------------------------------

  defp number(value, _default) when is_number(value), do: value
  defp number(_value, default), do: default

  defp num(value) when is_integer(value), do: Integer.to_string(value)

  defp num(value) when is_float(value) do
    rounded = Float.round(value, 2)

    if rounded == trunc(rounded),
      do: Integer.to_string(trunc(rounded)),
      else: :erlang.float_to_binary(rounded, [:compact, decimals: 2])
  end

  defp escape(text),
    do: text |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
