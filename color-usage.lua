-- Color Usage Panel for Aseprite (1.3+)
-- Floating panel listing every color used in the sprite with its share of pixels.
-- Left click on a color sets the foreground color, right click sets the background color.

local SORT_OPTS   = { "Usage", "Hue", "Lightness", "Saturation" }
local SORT_MODE   = { ["Usage"] = "count", ["Hue"] = "hue", ["Lightness"] = "lum", ["Saturation"] = "sat" }
local ORDER_OPTS  = { "Descending", "Ascending" }
local SCOPE_OPTS  = { "Current frame", "All frames" }
local SOURCE_OPTS = { "Visible sprite", "Active layer" }
-- Absolute: the full bar is 100% of the pixels. Relative: the full bar is the most used color.
local BAR_OPTS    = { "Absolute (100%)", "Relative (most used)" }

-- Hue families, in display order. Neutrals (grays) always come last.
local FAMILIES = { "Red", "Orange", "Yellow", "Green", "Cyan", "Blue", "Purple", "Pink", "Gray" }

local ROW_H, HEAD_H, SWATCH = 22, 20, 16
local NEUTRAL_CHROMA = 0.08
local BAR_H = 10
local BAR_GAP, MIN_BAR = 8, 20 -- spacing around the usage bar; narrower than MIN_BAR it is hidden
local SIM_ALPHA = 8 -- colors whose alpha differs by more than this are never "similar"

local PLUGIN = nil
local S = nil -- panel state, nil while the panel is closed

---------------------------------------------------------------------------
-- Analysis
---------------------------------------------------------------------------

local function rgbToHsl(r, g, b)
  r, g, b = r / 255, g / 255, b / 255
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local l, d = (mx + mn) / 2, mx - mn
  local h, s = 0, 0
  if d > 0 then
    s = d / (1 - math.abs(2 * l - 1))
    if mx == r then h = ((g - b) / d) % 6
    elseif mx == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    h = h * 60
  end
  return h, s, l, d
end

local LINEAR = {}
for i = 0, 255 do
  local c = i / 255
  LINEAR[i] = c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end

-- sRGB -> CIE Lab (D65). Distances in this space (Delta E) follow perceived difference.
local function rgbToLab(r, g, b)
  local lr, lg, lb = LINEAR[r], LINEAR[g], LINEAR[b]
  local x = (0.4124564 * lr + 0.3575761 * lg + 0.1804375 * lb) / 0.95047
  local y = 0.2126729 * lr + 0.7151522 * lg + 0.0721750 * lb
  local z = (0.0193339 * lr + 0.1191920 * lg + 0.9503041 * lb) / 1.08883
  local function f(t) return t > 0.008856 and t ^ (1 / 3) or 7.787 * t + 16 / 116 end
  local fx, fy, fz = f(x), f(y), f(z)
  return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)
end

local function familyOf(h, neutral)
  if neutral then return "Gray" end
  if h < 15 or h >= 345 then return "Red"
  elseif h < 45 then return "Orange"
  elseif h < 70 then return "Yellow"
  elseif h < 165 then return "Green"
  elseif h < 200 then return "Cyan"
  elseif h < 255 then return "Blue"
  elseif h < 290 then return "Purple"
  else return "Pink" end
end

-- Adds the pixels of `img` to `counts` (key -> number of pixels) and returns
-- the number of fully transparent pixels it skipped.
local function countImage(img, counts, transparentIndex)
  local bytes, mode = img.bytes, img.colorMode
  local unpack, byte = string.unpack, string.byte
  local n, transparent = #bytes, 0
  if mode == ColorMode.RGB then
    for i = 1, n, 4 do
      local v = unpack("<I4", bytes, i)
      if v >> 24 == 0 then transparent = transparent + 1
      else counts[v] = (counts[v] or 0) + 1 end
    end
  elseif mode == ColorMode.GRAY then
    for i = 1, n, 2 do
      local v = unpack("<I2", bytes, i)
      if v >> 8 == 0 then transparent = transparent + 1
      else counts[v] = (counts[v] or 0) + 1 end
    end
  else
    for i = 1, n do
      local v = byte(bytes, i)
      if v == transparentIndex then transparent = transparent + 1
      else counts[v] = (counts[v] or 0) + 1 end
    end
  end
  return transparent
end

-- opts: { frames = {frameNumber, ...}, layer = Layer | nil }
-- layer == nil analyzes the visible composite of each frame.
-- Returns entries, opaquePixels, transparentPixels.
local function analyze(spr, opts)
  local mode = spr.colorMode
  local counts, transparent = {}, 0
  local transparentIndex = nil
  if mode == ColorMode.INDEXED and spr.backgroundLayer == nil then
    transparentIndex = spr.transparentColor
  end

  for _, f in ipairs(opts.frames) do
    local img = nil
    if opts.layer then
      local layer = opts.layer
      if not layer.isGroup and not layer.isTilemap then
        local cel = layer:cel(f)
        if cel then img = cel.image end
      end
    else
      img = Image(spr.spec)
      img:drawSprite(spr, f)
    end
    if img then transparent = transparent + countImage(img, counts, transparentIndex) end
  end

  local palette = spr.palettes[1]
  local entries, opaque = {}, 0
  for key, n in pairs(counts) do
    local r, g, b, a, index
    if mode == ColorMode.RGB then
      r, g, b, a = key & 255, (key >> 8) & 255, (key >> 16) & 255, key >> 24
    elseif mode == ColorMode.GRAY then
      r = key & 255; g, b, a = r, r, key >> 8
    else
      index = key
      if key < #palette then
        local c = palette:getColor(key)
        r, g, b, a = c.red, c.green, c.blue, c.alpha
      else
        r, g, b, a = 0, 0, 0, 255
      end
    end
    local h, s, _, chroma = rgbToHsl(r, g, b)
    local neutral = chroma < NEUTRAL_CHROMA
    local labL, labA, labB = rgbToLab(r, g, b)
    entries[#entries + 1] = {
      key = key, count = n, r = r, g = g, b = b, a = a, index = index,
      labL = labL, labA = labA, labB = labB,
      hex = a < 255 and string.format("#%02X%02X%02X%02X", r, g, b, a)
                     or string.format("#%02X%02X%02X", r, g, b),
      hue = h, sat = s, lum = 0.299 * r + 0.587 * g + 0.114 * b,
      neutral = neutral, family = familyOf(h, neutral),
    }
    opaque = opaque + n
  end
  for _, e in ipairs(entries) do e.pct = e.count * 100 / opaque end
  return entries, opaque, transparent
end

---------------------------------------------------------------------------
-- Near-duplicate detection
---------------------------------------------------------------------------

-- Entries are bucketed in a Lab grid whose cells are `size` wide, so a lookup
-- only has to look at the 27 cells around a color instead of every color.
local function cellOf(v, size) return math.floor(v / size) + 600 end
local function gridKey(cx, cy, cz) return (cx * 2000 + cy) * 2000 + cz end

local function gridAdd(grid, e, size)
  local k = gridKey(cellOf(e.labL, size), cellOf(e.labA, size), cellOf(e.labB, size))
  local cell = grid[k]
  if not cell then cell = {}; grid[k] = cell end
  cell[#cell + 1] = e
end

-- Closest entry to `e` (other than itself) strictly under `limit2` (squared Delta E).
local function nearest(grid, e, size, limit2)
  local cx, cy, cz = cellOf(e.labL, size), cellOf(e.labA, size), cellOf(e.labB, size)
  local best, bd = nil, limit2
  for dx = -1, 1 do
    for dy = -1, 1 do
      for dz = -1, 1 do
        local cell = grid[gridKey(cx + dx, cy + dy, cz + dz)]
        if cell then
          for _, o in ipairs(cell) do
            if o ~= e and math.abs(o.a - e.a) <= SIM_ALPHA then
              local dL, dA, dB = o.labL - e.labL, o.labA - e.labA, o.labB - e.labB
              local d = dL * dL + dA * dA + dB * dB
              if d < bd then best, bd = o, d end
            end
          end
        end
      end
    end
  end
  return best, bd
end

-- Flags each color that has another color within `tol` Delta E: sets e.simTo
-- (closest such color) and e.simDist. Returns how many colors are flagged.
local function markSimilar(entries, tol)
  tol = math.max(tol, 0.5)
  local grid = {}
  for _, e in ipairs(entries) do gridAdd(grid, e, tol) end
  local n = 0
  for _, e in ipairs(entries) do
    local best, d = nearest(grid, e, tol, tol * tol)
    e.simTo, e.simDist = best, best and math.sqrt(d) or nil
    if best then n = n + 1 end
  end
  return n
end

-- Greedy clustering: colors are visited from most to least used; a color close
-- to an already kept one is mapped onto it. Returns map (key -> key) and its size.
local function planMerge(entries, tol)
  tol = math.max(tol, 0.5)
  local sorted = {}
  for i, e in ipairs(entries) do sorted[i] = e end
  table.sort(sorted, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.key < b.key
  end)
  local grid, map, n = {}, {}, 0
  for _, e in ipairs(sorted) do
    local keep = nearest(grid, e, tol, tol * tol)
    if keep then map[e.key] = keep.key; n = n + 1 else gridAdd(grid, e, tol) end
  end
  return map, n
end

---------------------------------------------------------------------------
-- Replacement
---------------------------------------------------------------------------

local function packKey(mode, key)
  if mode == ColorMode.RGB then return string.pack("<I4", key)
  elseif mode == ColorMode.GRAY then return string.pack("<I2", key)
  else return string.char(key) end
end

-- Key of `color` in the same space as analyze() entries for this color mode.
local function colorToKey(mode, color)
  if mode == ColorMode.RGB then
    return color.red | (color.green << 8) | (color.blue << 16) | (color.alpha << 24)
  elseif mode == ColorMode.GRAY then
    return math.floor(color.gray + 0.5) | (color.alpha << 8)
  end
  return color.index
end

-- Returns a modified copy of `img` (or nil if nothing matched) and the number of pixels changed.
local function remapImage(img, mode, packed)
  local width = mode == ColorMode.RGB and 4 or (mode == ColorMode.GRAY and 2 or 1)
  local changed = 0
  local out = img.bytes:gsub(string.rep(".", width), function(m)
    local to = packed[m]
    if to then changed = changed + 1; return to end
  end)
  if changed == 0 then return nil, 0 end
  local copy = Image(img)
  copy.bytes = out
  return copy, changed
end

-- Rewrites pixels according to keyMap (key -> key) in every cel covered by
-- `frames` and by `layer` (nil = every visible layer). One undo step.
-- Returns changed pixels and the number of locked layers that were skipped.
local function replaceColors(spr, keyMap, frames, layer)
  local mode = spr.colorMode
  local packed = {}
  for from, to in pairs(keyMap) do packed[packKey(mode, from)] = packKey(mode, to) end
  local frameSet = {}
  for _, f in ipairs(frames) do frameSet[f] = true end

  local changed, locked = 0, 0
  local function visit(layers, parentVisible)
    for _, l in ipairs(layers) do
      if l.isGroup then
        visit(l.layers, parentVisible and l.isVisible)
      elseif not l.isTilemap then
        local covered
        if layer then covered = (l == layer) else covered = parentVisible and l.isVisible end
        if covered then
          if not l.isEditable then
            locked = locked + 1
          else
            for _, cel in ipairs(l.cels) do
              if frameSet[cel.frameNumber] then
                local copy, n = remapImage(cel.image, mode, packed)
                if copy then cel.image = copy; changed = changed + n end
              end
            end
          end
        end
      end
    end
  end

  app.transaction("Replace colors", function() visit(spr.layers, true) end)
  return changed, locked
end

---------------------------------------------------------------------------
-- Pixel selection (magic wand by color)
---------------------------------------------------------------------------

-- Rectangles {x, y, w, h} covering every pixel of `img` whose key is `key`.
-- Horizontal runs are merged vertically so that big flat areas stay a few rectangles.
local function matchRects(img, mode, key)
  local bpp = mode == ColorMode.RGB and 4 or (mode == ColorMode.GRAY and 2 or 1)
  local needle = packKey(mode, key)
  local bytes, w = img.bytes, img.width

  -- Horizontal runs, found by jumping from match to match.
  local runs, cur, pos = {}, nil, 1
  while true do
    local i = bytes:find(needle, pos, true)
    if not i then break end
    if (i - 1) % bpp ~= 0 then
      pos = i + 1 -- matched across two pixels: not a real match
    else
      local idx = (i - 1) // bpp
      local x, y = idx % w, idx // w
      if cur and cur.y == y and cur.x + cur.w == x then
        cur.w = cur.w + 1
      else
        cur = { x = x, y = y, w = 1, h = 1 }
        runs[#runs + 1] = cur
      end
      pos = i + bpp
    end
  end

  -- Stack runs with the same x and width on consecutive rows.
  local rects, open = {}, {}
  for _, r in ipairs(runs) do
    local k = r.x * 100000 + r.w
    local o = open[k]
    if o and o.y + o.h == r.y then
      o.h = o.h + 1
    else
      open[k] = r
      rects[#rects + 1] = r
    end
  end
  return rects
end

-- Selects the pixels whose color key is in `keys`, in the given frame. `layer` nil
-- uses the visible composite, otherwise only that layer's cel. how: "replace",
-- "add" or "subtract". Returns how many pixels of those colors were found.
local function selectColors(spr, keys, frame, layer, how)
  local img, ox, oy
  if layer then
    if layer.isGroup or layer.isTilemap then return 0 end
    local cel = layer:cel(frame)
    if not cel then return 0 end
    img, ox, oy = cel.image, cel.position.x, cel.position.y
  else
    img = Image(spr.spec)
    img:drawSprite(spr, frame)
    ox, oy = 0, 0
  end

  local sel, count = Selection(), 0
  for _, key in ipairs(keys) do
    for _, r in ipairs(matchRects(img, spr.colorMode, key)) do
      sel:add(Rectangle(r.x + ox, r.y + oy, r.w, r.h))
      count = count + r.w * r.h
    end
  end
  if how == "add" then spr.selection:add(sel)
  elseif how == "subtract" then spr.selection:subtract(sel)
  else spr.selection = sel end
  return count
end

local function comparator(mode, desc)
  return function(a, b)
    if mode == "hue" and a.neutral ~= b.neutral then return b.neutral end
    local ka, kb
    if mode == "hue" then
      if a.neutral then ka, kb = a.lum, b.lum else ka, kb = a.hue, b.hue end
    else
      ka, kb = a[mode], b[mode]
    end
    if ka ~= kb then
      if desc then return ka > kb else return ka < kb end
    end
    if a.count ~= b.count then return a.count > b.count end
    return a.key < b.key
  end
end

-- Turns entries into the list of display rows (headers + colors) with y offsets.
-- o: { sort, desc, group, onlyRare, threshold, collapsed }
local function arrange(entries, o)
  local list = {}
  for _, e in ipairs(entries) do
    if (not o.onlyRare or e.pct < o.threshold) and (not o.onlySimilar or e.simTo) then
      list[#list + 1] = e
    end
  end
  local cmp = comparator(o.sort, o.desc)
  local rows = {}

  if o.group then
    local byFamily = {}
    for _, e in ipairs(list) do
      local t = byFamily[e.family]
      if not t then t = {}; byFamily[e.family] = t end
      t[#t + 1] = e
    end
    for _, fam in ipairs(FAMILIES) do
      local t = byFamily[fam]
      if t then
        table.sort(t, cmp)
        local pct = 0
        for _, e in ipairs(t) do pct = pct + e.pct end
        local collapsed = o.collapsed[fam] == true
        rows[#rows + 1] = { kind = "header", fam = fam, n = #t, pct = pct, collapsed = collapsed, h = HEAD_H, entries = t }
        if not collapsed then
          for _, e in ipairs(t) do rows[#rows + 1] = { kind = "color", e = e, h = ROW_H } end
        end
      end
    end
  else
    table.sort(list, cmp)
    for _, e in ipairs(list) do rows[#rows + 1] = { kind = "color", e = e, h = ROW_H } end
  end

  local y = 0
  for _, row in ipairs(rows) do row.y = y; y = y + row.h end
  return rows, y
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

local function options()
  local d = S.dlg.data
  return {
    sort = SORT_MODE[d.sort] or "count",
    desc = d.order ~= "Ascending",
    group = d.group == true,
    onlyRare = d.onlyrare == true,
    onlySimilar = d.onlysimilar == true,
    threshold = S.opts.threshold,
    tolerance = S.opts.tolerance,
    collapsed = S.collapsed,
  }
end

-- Frames and layer covered by the panel's "Scope" setting.
local function scopeTarget(spr)
  local frames = {}
  if S.opts.scope == SCOPE_OPTS[2] then
    for i = 1, #spr.frames do frames[i] = i end
  else
    frames[1] = app.frame and app.frame.frameNumber or 1
  end
  local layer = nil
  if S.opts.source == SOURCE_OPTS[2] then layer = app.layer end
  return frames, layer
end

local function formatPct(p)
  if p < 0.01 then return "<0.01%" end
  return string.format("%.2f%%", p)
end

local function clampScroll()
  local maxScroll = math.max(0, S.totalH - S.viewH)
  S.scroll = math.max(0, math.min(S.scroll, maxScroll))
end

-- The two status lines drawn at the bottom of the canvas.
local function statusLines()
  if not S.sprite then return "No sprite open", "" end
  local head = string.format("%d colors, %d rare, %d similar", #S.entries, S.rareCount or 0, S.simCount or 0)
  local detail = S.flash
  if not detail and S.hover then
    local row = S.hover
    if row.kind == "color" then
      local e = row.e
      detail = string.format("%s  %s  %d px", e.hex, formatPct(e.pct), e.count)
      if e.simTo then detail = detail .. string.format("  ~ %s (dE %.1f)", e.simTo.hex, e.simDist) end
    else
      detail = string.format("%s: %d colors, %s", row.fam, row.n, formatPct(row.pct))
    end
  end
  return head, detail or "Click: FG/BG  Ctrl+click: select"
end

local function rebuild()
  if not S then return end
  local o = options()
  if S.simTol ~= o.tolerance then
    S.simCount = markSimilar(S.entries, o.tolerance)
    S.simTol = o.tolerance
  end
  S.rareCount = 0
  for _, e in ipairs(S.entries) do
    if e.pct < o.threshold then S.rareCount = S.rareCount + 1 end
  end
  S.rows, S.totalH = arrange(S.entries, o)
  S.hover = nil
  clampScroll()
  S.dlg:repaint()
end

local function refresh()
  if not S then return end
  S.dirty = false
  local spr = app.sprite
  local t0 = os.clock()
  S.sprite = spr
  S.entries, S.opaque, S.transparent = {}, 0, 0
  S.maxPct, S.simTol, S.simCount, S.hover = 0, nil, 0, nil
  if spr then
    local frames, layer = scopeTarget(spr)
    local ok, entries, opaque, transparent = pcall(analyze, spr, { frames = frames, layer = layer })
    if ok then
      S.entries, S.opaque, S.transparent = entries, opaque, transparent
      for _, e in ipairs(entries) do S.maxPct = math.max(S.maxPct, e.pct) end
    end
  end
  -- Back off on big sprites so that drawing stays smooth.
  if S.timer then S.timer.interval = math.max(0.25, (os.clock() - t0) * 4) end
  rebuild()
end

local function unhookSprite()
  if S.hooked and S.spriteListener then
    local spr, id = S.hooked, S.spriteListener
    pcall(function() spr.events:off(id) end)
  end
  S.hooked, S.spriteListener = nil, nil
end

local function hookSprite(spr)
  unhookSprite()
  if spr then
    local ok, id = pcall(function()
      return spr.events:on("change", function() if S then S.dirty = true end end)
    end)
    if ok then S.hooked, S.spriteListener, S.sprite = spr, id, spr end
  end
end

local function onSiteChange()
  if not S then return end
  local spr = app.sprite
  local frame = app.frame and app.frame.frameNumber or 0
  local sameSprite = (spr ~= nil and spr == S.hooked)
  if not sameSprite then
    hookSprite(spr)
    S.dirty = true
  end
  if S.opts.scope == SCOPE_OPTS[1] and frame ~= S.frame then S.dirty = true end
  if S.opts.source == SOURCE_OPTS[2] and app.layer ~= S.layer then S.dirty = true end
  S.frame, S.layer = frame, app.layer
end

local function themeColors()
  local t = app.theme and app.theme.color or {}
  local function pick(name, r, g, b)
    local ok, c = pcall(function() return t[name] end)
    if ok and c then return c end
    return Color{ r = r, g = g, b = b }
  end
  local text = pick("textbox_text", 0, 0, 0)
  local function tint(c, a) return Color{ r = c.red, g = c.green, b = c.blue, a = a } end
  return {
    bg = pick("textbox_face", 255, 255, 255),
    text = text,
    track = tint(text, 38),
    outline = tint(text, 120),
    tick = tint(text, 80),
    bar = Color{ r = 64, g = 150, b = 230 },
    hot = pick("hot_face", 250, 240, 230),
    header = pick("window_face", 211, 203, 190),
    selected = pick("selected", 255, 85, 85),
    muted = pick("disabled", 150, 130, 117),
    rare = Color{ r = 224, g = 138, b = 46 },
  }
end

local function firstVisibleRow(y)
  local rows = S.rows
  local lo, hi = 1, #rows
  local found = #rows + 1
  while lo <= hi do
    local mid = (lo + hi) // 2
    if rows[mid].y + rows[mid].h > y then found = mid; hi = mid - 1 else lo = mid + 1 end
  end
  return found
end

local function drawSwatch(gc, e, x, y)
  local rect = Rectangle(x, y, SWATCH, SWATCH)
  if e.a < 255 then
    local half = SWATCH // 2
    for cy = 0, 1 do
      for cx = 0, 1 do
        local v = ((cx + cy) % 2 == 0) and 200 or 130
        gc.color = Color{ r = v, g = v, b = v }
        gc:fillRect(Rectangle(x + cx * half, y + cy * half, half, half))
      end
    end
  end
  gc.color = Color{ r = e.r, g = e.g, b = e.b, a = e.a }
  gc:fillRect(rect)
  gc.color = Color{ r = 0, g = 0, b = 0, a = 90 }
  gc:strokeRect(rect)
end

-- Status strip under the list (covers any row that overflows the list area).
local function drawStatus(gc, C, W, listH, th, statusH)
  gc.color = C.header
  gc:fillRect(Rectangle(0, listH, W, statusH))
  gc.color = C.text
  local head, detail = statusLines()
  gc:fillText(head, 4, listH + 3)
  gc.color = C.muted
  gc:fillText(detail, 4, listH + 5 + th)
end

local function onPaint(ev)
  local gc = ev.context
  local W, H = gc.width, gc.height
  local C = themeColors()
  local th = gc:measureText("Ag").height
  local statusH = 2 * th + 8
  H = H - statusH -- from here on H is the height of the list area
  S.viewH = H
  clampScroll()

  gc.color = C.bg
  gc:fillRect(Rectangle(0, 0, W, H))

  if #S.rows == 0 then
    local msg
    if not S.sprite then msg = "No sprite open"
    elseif #S.entries == 0 then msg = "No opaque pixels"
    else msg = "No colors to show" end
    gc.color = C.muted
    gc:fillText(msg, (W - gc:measureText(msg).width) // 2, H // 2 - th // 2)
    drawStatus(gc, C, W, H, th, statusH)
    return
  end

  local fg = app.fgColor
  local fr, fgc, fb, fa = fg.red, fg.green, fg.blue, fg.alpha
  local threshold = S.opts.threshold
  local sb = S.totalH > H and 6 or 0
  -- Columns: swatch | hex | similar swatch | bar | percentage. Text columns keep their
  -- width; only the bar shrinks when the window gets narrower, and it disappears
  -- (then the percentage) rather than ever getting close to the hex code.
  local hexX = 26
  local hexEnd = hexX + gc:measureText("#RRGGBBAA").width
  local simX = hexEnd + 6
  local barX = simX + 10 + BAR_GAP
  local pctX = W - sb - 6 - gc:measureText("100.00%").width
  local barW = pctX - BAR_GAP - barX
  local showBar = barW >= MIN_BAR
  local showPct = pctX >= hexEnd + 6
  local relativeBar = S.opts.barScale == BAR_OPTS[2]

  for i = firstVisibleRow(S.scroll), #S.rows do
    local row = S.rows[i]
    local y = row.y - S.scroll
    if y >= H then break end
    local ty = y + (row.h - th) // 2

    if row.kind == "header" then
      gc.color = C.header
      gc:fillRect(Rectangle(0, y, W - sb, row.h))
      gc.color = C.text
      local title = (row.collapsed and "+ " or "- ") .. row.fam .. " (" .. row.n .. ")"
      gc:fillText(title, 6, ty)
      local txt = formatPct(row.pct)
      local txtX = W - sb - 6 - gc:measureText(txt).width
      if txtX >= 6 + gc:measureText(title).width + 8 then gc:fillText(txt, txtX, ty) end
    else
      local e = row.e
      local isRare = e.pct < threshold
      if row == S.hover then
        gc.color = C.hot
        gc:fillRect(Rectangle(0, y, W - sb, row.h))
      end
      drawSwatch(gc, e, 4, y + (row.h - SWATCH) // 2)
      if e.r == fr and e.g == fgc and e.b == fb and e.a == fa then
        gc.color = C.selected
        gc:strokeRect(Rectangle(1, y, W - sb - 2, row.h))
      end
      gc.color = C.text
      gc:fillText(e.hex, hexX, ty)

      -- A small swatch of the closest similar color marks near-duplicates.
      if e.simTo and simX + 10 <= (showPct and pctX or W - sb) - 4 then
        local s = e.simTo
        local rect = Rectangle(simX, y + (row.h - 10) // 2, 10, 10)
        gc.color = Color{ r = s.r, g = s.g, b = s.b, a = s.a }
        gc:fillRect(rect)
        gc.color = C.rare
        gc:strokeRect(rect)
      end

      if showBar then
        local top = y + row.h // 2 - BAR_H // 2
        local full = relativeBar and math.max(S.maxPct, 0.01) or 100
        local fill = math.min(barW, math.floor(barW * e.pct / full + 0.5))
        if e.pct > 0 then fill = math.max(fill, 2) end
        gc.color = C.track
        gc:fillRect(Rectangle(barX, top, barW, BAR_H))
        gc.color = isRare and C.rare or C.bar
        gc:fillRect(Rectangle(barX, top, fill, BAR_H))
        -- Ticks every quarter of the scale make the length readable at a glance.
        gc.color = C.tick
        for q = 1, 3 do
          gc:fillRect(Rectangle(barX + barW * q // 4, top, 1, BAR_H))
        end
        gc.color = C.outline
        gc:strokeRect(Rectangle(barX, top, barW, BAR_H))
      end

      if showPct then
        gc.color = isRare and C.rare or C.text
        local txt = formatPct(e.pct)
        gc:fillText(txt, W - sb - 6 - gc:measureText(txt).width, ty)
      end
    end
  end

  if sb > 0 then
    local maxScroll = S.totalH - H
    local thumb = math.max(16, H * H // S.totalH)
    local ty = math.floor((H - thumb) * S.scroll / maxScroll)
    gc.color = C.muted
    gc:fillRect(Rectangle(W - 4, ty, 3, thumb))
  end
  drawStatus(gc, C, W, H, th, statusH)
end

local function rowAt(y)
  if y >= S.viewH then return nil end
  local i = firstVisibleRow(y + S.scroll)
  local row = S.rows[i]
  if row and y + S.scroll >= row.y then return row end
  return nil
end

local function pickColor(e, button)
  local c
  if e.index ~= nil then c = Color{ index = e.index }
  elseif S.sprite and S.sprite.colorMode == ColorMode.GRAY then c = Color{ gray = e.r, alpha = e.a }
  else c = Color{ r = e.r, g = e.g, b = e.b, a = e.a } end
  if button == MouseButton.RIGHT then app.bgColor = c else app.fgColor = c end
end

local function flash(msg)
  S.flash = msg
  S.dlg:repaint()
end

-- Ctrl+click selects the pixels of a color (or of a whole group) on the canvas,
-- like the magic wand; Ctrl+Shift adds to the selection, Ctrl+Alt subtracts.
local function selectEntries(entries, ev)
  local spr = app.sprite
  if not spr then return end
  local how = ev.altKey and "subtract" or (ev.shiftKey and "add" or "replace")
  local keys = {}
  for i, e in ipairs(entries) do keys[i] = e.key end
  local _, layer = scopeTarget(spr)
  local frame = app.frame and app.frame.frameNumber or 1
  local ok, n = pcall(selectColors, spr, keys, frame, layer, how)
  if not ok then return flash("Selection failed") end
  flash(n > 0 and string.format("%d px selected", n) or "Not in this frame")
  app.refresh()
end

local function onMouseDown(ev)
  local row = rowAt(ev.y)
  if not row then return end
  local wand = ev.ctrlKey or ev.metaKey
  if row.kind == "header" then
    if wand then
      selectEntries(row.entries, ev)
    else
      S.collapsed[row.fam] = not S.collapsed[row.fam]
      rebuild()
    end
  else
    pickColor(row.e, ev.button)
    if wand then selectEntries({ row.e }, ev) end
    S.dlg:repaint()
  end
end

local function onMouseMove(ev)
  local row = rowAt(ev.y)
  if row == S.hover then return end
  S.hover = row
  S.flash = nil
  S.dlg:repaint()
end

local function onWheel(ev)
  local dy = ev.deltaY or 0
  if dy == 0 then return end
  S.scroll = S.scroll + (dy > 0 and 1 or -1) * ROW_H * 3
  clampScroll()
  S.dlg:repaint()
end

-- Applies a replacement map over the panel's scope and reports the outcome.
local function applyReplacement(spr, map)
  local frames, layer = scopeTarget(spr)
  local changed, locked = replaceColors(spr, map, frames, layer)
  local msg = changed > 0 and string.format("%d px replaced (Ctrl+Z to undo)", changed)
                          or "No pixels to replace in scope"
  if locked > 0 then msg = msg .. string.format(", %d locked", locked) end
  S.dirty = true
  app.refresh()
  flash(msg)
end

-- Replaces the foreground color by the background color.
local function onReplace()
  local spr = app.sprite
  if not spr then return end
  local from, to = app.fgColor, app.bgColor
  if from.alpha == 0 then return flash("FG is transparent") end
  local fromKey, toKey = colorToKey(spr.colorMode, from), colorToKey(spr.colorMode, to)
  if fromKey == toKey then return flash("FG and BG are identical") end
  applyReplacement(spr, { [fromKey] = toKey })
end

-- Merges every group of near-identical colors into its most used color.
local function onMerge()
  local spr = app.sprite
  if not spr then return end
  if S.dirty then refresh() end
  local tol = options().tolerance
  local map, n = planMerge(S.entries, tol)
  if n == 0 then return flash("No similar colors") end
  local choice = app.alert{
    title = "Merge similar colors",
    text = string.format("%d colors will be replaced by the most used similar color (dE < %.1f).", n, tol),
    buttons = { "Merge", "Cancel" },
  }
  if choice == 1 then applyReplacement(spr, map) end
end

local function cleanup()
  if not S then return end
  local state = S
  if state.timer then pcall(function() state.timer:stop() end) end
  if state.optDlg then
    local od = state.optDlg
    state.optDlg = nil
    pcall(function() od:close() end)
  end
  unhookSprite()
  for _, id in ipairs(state.appListeners) do pcall(function() app.events:off(id) end) end

  local prefs = PLUGIN.preferences
  pcall(function()
    local d = state.dlg.data
    prefs.sort, prefs.order = d.sort, d.order
    prefs.group, prefs.onlyrare, prefs.onlysimilar = d.group, d.onlyrare, d.onlysimilar
    local o = state.opts
    prefs.scope, prefs.source, prefs.threshold, prefs.tolerance = o.scope, o.source, o.threshold, o.tolerance
    prefs.barScale = o.barScale
    local b = state.dlg.bounds
    prefs.x, prefs.y = b.x, b.y
  end)
  S = nil
end

local function oneOf(value, list, default)
  for _, v in ipairs(list) do if v == value then return value end end
  return default
end

-- Rarely used settings live in their own small dialog to keep the panel compact.
local function openOptions()
  if S.optDlg then return end
  local o = S.opts
  local dlg = Dialog{ title = "Options", onclose = function() if S then S.optDlg = nil end end }
  S.optDlg = dlg
  dlg:combobox{ id = "scope", label = "Scope", options = SCOPE_OPTS, option = o.scope,
                onchange = function() o.scope = dlg.data.scope; refresh() end }
  dlg:combobox{ id = "source", label = "Source", options = SOURCE_OPTS, option = o.source,
                onchange = function() o.source = dlg.data.source; refresh() end }
  dlg:combobox{ id = "barScale", label = "Bar scale", options = BAR_OPTS, option = o.barScale,
                onchange = function() o.barScale = dlg.data.barScale; S.dlg:repaint() end }
  dlg:number{ id = "threshold", label = "Rare threshold (%)", text = tostring(o.threshold), decimals = 1,
              onchange = function() o.threshold = tonumber(dlg.data.threshold) or 1; rebuild() end }
  dlg:number{ id = "tolerance", label = "Tolerance (dE)", text = tostring(o.tolerance), decimals = 1,
              onchange = function() o.tolerance = tonumber(dlg.data.tolerance) or 4; rebuild() end }
  dlg:show{ wait = false }
  -- Open it next to the panel.
  pcall(function()
    local main, b = S.dlg.bounds, dlg.bounds
    dlg.bounds = Rectangle(main.x + main.width + 8, main.y, b.width, b.height)
  end)
end

local function openPanel()
  if S then -- toggle: a second invocation closes the panel
    S.dlg:close()
    return
  end

  local prefs = PLUGIN.preferences
  S = {
    entries = {}, rows = {}, totalH = 0, viewH = 300, scroll = 0, maxPct = 0,
    opaque = 0, transparent = 0, collapsed = {}, appListeners = {}, dirty = true,
    opts = {
      scope = oneOf(prefs.scope, SCOPE_OPTS, SCOPE_OPTS[1]),
      source = oneOf(prefs.source, SOURCE_OPTS, SOURCE_OPTS[1]),
      threshold = tonumber(prefs.threshold) or 1,
      tolerance = tonumber(prefs.tolerance) or 4,
      barScale = oneOf(prefs.barScale, BAR_OPTS, BAR_OPTS[1]),
    },
  }

  local dlg = Dialog{ title = "Color Usage", onclose = cleanup }
  S.dlg = dlg

  dlg:combobox{ id = "sort", options = SORT_OPTS,
                option = oneOf(prefs.sort, SORT_OPTS, SORT_OPTS[1]), onchange = rebuild }
  dlg:combobox{ id = "order", options = ORDER_OPTS,
                option = oneOf(prefs.order, ORDER_OPTS, ORDER_OPTS[1]), onchange = rebuild }
  dlg:newrow()
  dlg:check{ id = "group", text = "Group", selected = prefs.group == true, onclick = rebuild }
  dlg:check{ id = "onlyrare", text = "Rare", selected = prefs.onlyrare == true, onclick = rebuild }
  dlg:check{ id = "onlysimilar", text = "Similar", selected = prefs.onlysimilar == true, onclick = rebuild }
  dlg:newrow()
  dlg:button{ id = "replace", text = "Replace", onclick = onReplace }
  dlg:button{ id = "merge", text = "Merge", onclick = onMerge }
  dlg:button{ id = "options", text = "Options", onclick = openOptions }
  dlg:newrow()
  dlg:canvas{ id = "list", width = 230, height = 230, autoscaling = true, focus = true,
              onpaint = onPaint, onmousedown = onMouseDown, onmousemove = onMouseMove, onwheel = onWheel }

  dlg:show{ wait = false }

  if prefs.x and prefs.y and prefs.x >= 0 and prefs.y >= 0 then
    pcall(function()
      local b = dlg.bounds
      dlg.bounds = Rectangle(prefs.x, prefs.y, b.width, b.height)
    end)
  end

  -- Keep the list in sync with the document and the selected color.
  local ids = S.appListeners
  ids[#ids + 1] = app.events:on("sitechange", onSiteChange)
  pcall(function()
    ids[#ids + 1] = app.events:on("fgcolorchange", function() if S then S.dlg:repaint() end end)
  end)
  hookSprite(app.sprite)
  S.frame = app.frame and app.frame.frameNumber or 0
  S.layer = app.layer

  S.timer = Timer{ interval = 0.25, ontick = function()
    if S and S.dirty then refresh() end
  end }
  S.timer:start()
  refresh()
end

function init(plugin)
  PLUGIN = plugin
  plugin:newCommand{
    id = "ColorUsagePanel",
    title = "Color Usage",
    group = "view_extras",
    onclick = openPanel,
  }
end

function exit(plugin)
  if S then S.dlg:close() end
end

-- Exposed for tests run through `aseprite -b --script`.
return {
  analyze = analyze, arrange = arrange, rgbToHsl = rgbToHsl, familyOf = familyOf,
  markSimilar = markSimilar, planMerge = planMerge, replaceColors = replaceColors, colorToKey = colorToKey,
  selectColors = selectColors, matchRects = matchRects, openOptions = openOptions,
}
