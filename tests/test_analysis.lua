-- Run with: Aseprite.exe -b --script tests/test_analysis.lua
local M = dofile("color-usage.lua")
local failures = 0
local function check(name, cond, detail)
  if cond then print("ok   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. " " .. tostring(detail or "")) end
end

-- RGB sprite 10x10: 50 red, 30 blue, 10 half-transparent green, 10 transparent
local spr = Sprite(10, 10, ColorMode.RGB)
local img = spr.cels[1].image
for y = 0, 9 do
  for x = 0, 9 do
    local i = y * 10 + x
    local c
    if i < 50 then c = Color{ r = 255, g = 0, b = 0 }
    elseif i < 80 then c = Color{ r = 0, g = 0, b = 255 }
    elseif i < 90 then c = Color{ r = 0, g = 255, b = 0, a = 128 }
    else c = Color{ r = 0, g = 0, b = 0, a = 0 } end
    img:drawPixel(x, y, c)
  end
end

local frames = { 1 }
local entries, opaque, transparent = M.analyze(spr, { frames = frames })
check("rgb opaque count", opaque == 90, opaque)
check("rgb transparent count", transparent == 10, transparent)
check("rgb entry count", #entries == 3, #entries)
local byHex = {}
for _, e in ipairs(entries) do byHex[e.hex] = e end
check("red 50px", byHex["#FF0000"] and byHex["#FF0000"].count == 50)
check("blue 30px", byHex["#0000FF"] and byHex["#0000FF"].count == 30)
check("semi green 10px", byHex["#00FF0080"] and byHex["#00FF0080"].count == 10,
      byHex["#00FF0080"] and byHex["#00FF0080"].hex)
check("red pct", math.abs(byHex["#FF0000"].pct - 50 * 100 / 90) < 1e-9)
check("families", byHex["#FF0000"].family == "Red" and byHex["#0000FF"].family == "Blue"
                  and byHex["#00FF0080"].family == "Green")

-- Active layer scope gives the same result on a single layer
local e2, o2 = M.analyze(spr, { frames = frames, layer = spr.layers[1] })
check("layer scope", o2 == 90 and #e2 == 3, o2)

-- Sorting
local base = { sort = "count", desc = true, group = false, onlyRare = false, threshold = 1, collapsed = {} }
local rows = M.arrange(entries, base)
check("sort usage desc", rows[1].e.hex == "#FF0000" and rows[3].e.hex == "#00FF0080")
base.desc = false
rows = M.arrange(entries, base)
check("sort usage asc", rows[1].e.hex == "#00FF0080" and rows[3].e.hex == "#FF0000")
base.sort, base.desc = "hue", false
rows = M.arrange(entries, base)
check("sort hue asc (red, green, blue)", rows[1].e.family == "Red" and rows[2].e.family == "Green"
                                          and rows[3].e.family == "Blue")
base.group, base.desc = true, true
rows = M.arrange(entries, base)
check("group headers", #rows == 6 and rows[1].kind == "header" and rows[1].fam == "Red")
base.collapsed = { Red = true }
rows = M.arrange(entries, base)
check("collapsed group hides rows", #rows == 5)
base.group, base.collapsed, base.threshold, base.onlyRare = false, {}, 20, true
rows = M.arrange(entries, base)
check("only rare (<20%)", #rows == 1 and rows[1].e.hex == "#00FF0080", #rows)

-- Multi-frame accumulation
spr:newFrame()
local e3, o3 = M.analyze(spr, { frames = { 1, 2 } })
check("all frames", o3 >= 90, o3)

-- Indexed sprite
local ispr = Sprite(4, 4, ColorMode.INDEXED)
ispr.palettes[1]:resize(4)
ispr.palettes[1]:setColor(1, Color{ r = 10, g = 20, b = 30 })
ispr.palettes[1]:setColor(2, Color{ r = 200, g = 100, b = 50 })
local iimg = ispr.cels[1].image
for y = 0, 3 do for x = 0, 3 do iimg:drawPixel(x, y, (x < 3) and 1 or 2) end end
local ie, io = M.analyze(ispr, { frames = { 1 } })
local idx = {}
for _, e in ipairs(ie) do idx[e.index] = e end
check("indexed opaque", io == 16, io)
check("indexed counts", idx[1] and idx[1].count == 12 and idx[2] and idx[2].count == 4)
check("indexed color lookup", idx[2] and idx[2].r == 200 and idx[2].g == 100 and idx[2].b == 50)

-- Grayscale sprite
local gspr = Sprite(2, 2, ColorMode.GRAY)
local gimg = gspr.cels[1].image
gimg:drawPixel(0, 0, Color{ gray = 50 })
gimg:drawPixel(1, 0, Color{ gray = 50 })
gimg:drawPixel(0, 1, Color{ gray = 200 })
gimg:drawPixel(1, 1, Color{ gray = 200 })
local ge, go = M.analyze(gspr, { frames = { 1 } })
check("gray opaque", go == 4 and #ge == 2, go)
check("gray neutral", ge[1].neutral and ge[1].family == "Gray")

---------------------------------------------------------------------------
-- Near-duplicate detection, merge and replacement
---------------------------------------------------------------------------

local function fill(image, list)
  -- list: { {color, count}, ... } painted row-major
  local i = 0
  for _, item in ipairs(list) do
    for _ = 1, item[2] do
      image:drawPixel(i % image.width, i // image.width, item[1]); i = i + 1
    end
  end
end

local function hexAt(s, x, y, frame)
  local img = Image(s.spec); img:drawSprite(s, frame or 1)
  local c = img:getPixel(x, y)
  return string.format("#%02X%02X%02X", app.pixelColor.rgbaR(c), app.pixelColor.rgbaG(c), app.pixelColor.rgbaB(c))
end

local sim = Sprite(10, 10, ColorMode.RGB)
fill(sim.cels[1].image, {
  { Color{ r = 200, g = 30, b = 30 }, 60 },   -- main red
  { Color{ r = 202, g = 31, b = 29 }, 10 },   -- almost the same red
  { Color{ r = 30, g = 30, b = 200 }, 29 },   -- blue, far from red
  { Color{ r = 201, g = 30, b = 30, a = 100 }, 1 }, -- same red but much more transparent: not similar
})
local se = M.analyze(sim, { frames = { 1 } })
local n = M.markSimilar(se, 4)
local H = {}
for _, e in ipairs(se) do H[e.hex] = e end
check("similar count", n == 2, n)
check("close reds flagged", H["#C81E1E"].simTo == H["#CA1F1D"] and H["#CA1F1D"].simTo == H["#C81E1E"])
check("dE is small", H["#C81E1E"].simDist < 2, H["#C81E1E"].simDist)
check("blue not flagged", H["#1E1EC8"].simTo == nil)
check("alpha gap prevents match", H["#C91E1E64"].simTo == nil)
check("tolerance 0.5 flags nothing", M.markSimilar(se, 0.5) == 0)
M.markSimilar(se, 4)

local rows = M.arrange(se, { sort = "count", desc = true, group = false, onlyRare = false,
                             onlySimilar = true, threshold = 1, collapsed = {} })
check("similar-only filter", #rows == 2, #rows)

local map, merged = M.planMerge(se, 4)
check("merge plan", merged == 1 and map[H["#CA1F1D"].key] == H["#C81E1E"].key, merged)

-- Replacement with undo
local changed = M.replaceColors(sim, map, { 1 }, nil)
check("merge changed 10 px", changed == 10, changed)
check("pixels now merged", hexAt(sim, 0, 6) == "#C81E1E" and hexAt(sim, 9, 6) == "#C81E1E")
app.undo()
check("undo restores", hexAt(sim, 0, 5) == "#C81E1E" and hexAt(sim, 0, 6) == "#CA1F1D")

-- FG -> BG style single replacement, key built from Color
local from = Color{ r = 30, g = 30, b = 200 }
local to = Color{ r = 0, g = 255, b = 0 }
local ch = M.replaceColors(sim, { [M.colorToKey(ColorMode.RGB, from)] = M.colorToKey(ColorMode.RGB, to) }, { 1 }, nil)
check("replace blue by green", ch == 29, ch)
check("green present, reds untouched", hexAt(sim, 0, 7) == "#00FF00" and hexAt(sim, 5, 8) == "#00FF00"
                                       and hexAt(sim, 0, 6) == "#CA1F1D", hexAt(sim, 0, 7))

-- Layer handling: hidden layer skipped, locked layer reported, layer scope
local ls = Sprite(2, 1, ColorMode.RGB)
ls.cels[1].image:clear(Color{ r = 255, g = 0, b = 0 })
local top = ls:newLayer()
ls:newCel(top, 1, Image(2, 1, ColorMode.RGB), Point(0, 0))
top.cels[1].image:clear(Color{ r = 255, g = 0, b = 0 })
local redKey = M.colorToKey(ColorMode.RGB, Color{ r = 255, g = 0, b = 0 })
local blueKey = M.colorToKey(ColorMode.RGB, Color{ r = 0, g = 0, b = 255 })
top.isVisible = false
local c1 = M.replaceColors(ls, { [redKey] = blueKey }, { 1 }, nil)
local redPixel = app.pixelColor.rgba(255, 0, 0, 255)
check("hidden layer untouched", c1 == 2 and top.cels[1].image:getPixel(0, 0) == redPixel, c1)
top.isVisible = true
ls.layers[1].isEditable = false
local c2, locked = M.replaceColors(ls, { [redKey] = blueKey }, { 1 }, nil)
check("locked layer skipped", locked == 1 and c2 == 2, tostring(c2) .. "/" .. tostring(locked))
local c3 = M.replaceColors(ls, { [blueKey] = redKey }, { 1 }, top)
local bluePixel = app.pixelColor.rgba(0, 0, 255, 255)
check("layer scope only touches that layer", c3 == 2 and top.cels[1].image:getPixel(0, 0) == redPixel
                                             and ls.layers[1].cels[1].image:getPixel(0, 0) == bluePixel, c3)

-- Indexed and gray replacement
local ri = M.replaceColors(ispr, { [1] = 2 }, { 1 }, nil)
local ie2 = M.analyze(ispr, { frames = { 1 } })
check("indexed replace", ri == 12 and #ie2 == 1 and ie2[1].index == 2, ri)
local rg = M.replaceColors(gspr, { [M.colorToKey(ColorMode.GRAY, Color{ gray = 50 })] =
                                   M.colorToKey(ColorMode.GRAY, Color{ gray = 200 }) }, { 1 }, nil)
local ge2 = M.analyze(gspr, { frames = { 1 } })
check("gray replace", rg == 2 and #ge2 == 1 and ge2[1].r == 200, rg)

---------------------------------------------------------------------------
-- Selection by color (magic wand)
---------------------------------------------------------------------------

local ws = Sprite(6, 4, ColorMode.RGB)
local wimg = ws.cels[1].image
wimg:clear(Color{ r = 0, g = 0, b = 255 })
for _, p in ipairs{ {1,1}, {2,1}, {1,2}, {2,2}, {5,0} } do wimg:drawPixel(p[1], p[2], Color{ r = 255, g = 0, b = 0 }) end
local wRed = M.colorToKey(ColorMode.RGB, Color{ r = 255, g = 0, b = 0 })
local wBlue = M.colorToKey(ColorMode.RGB, Color{ r = 0, g = 0, b = 255 })

local wr = M.matchRects(wimg, ColorMode.RGB, wRed)
local block = nil
for _, r in ipairs(wr) do if r.w == 2 then block = r end end
check("2x2 block stays a single rectangle", #wr == 2 and block and block.h == 2 and block.x == 1 and block.y == 1, #wr)
local n = M.selectColors(ws, { wRed }, 1, nil, "replace")
local sel = ws.selection
check("select red: 5 px", n == 5 and sel:contains(Point(1, 1)) and sel:contains(Point(2, 2))
      and sel:contains(Point(5, 0)) and not sel:contains(Point(0, 0)), n)
n = M.selectColors(ws, { wBlue }, 1, nil, "replace")
check("replace swaps the selection", n == 19 and not ws.selection:contains(Point(1, 1)) and ws.selection:contains(Point(0, 0)), n)
M.selectColors(ws, { wRed }, 1, nil, "replace")
M.selectColors(ws, { wBlue }, 1, nil, "add")
check("add keeps previous selection", ws.selection:contains(Point(1, 1)) and ws.selection:contains(Point(0, 0)))
M.selectColors(ws, { wRed }, 1, nil, "subtract")
check("subtract removes it", not ws.selection:contains(Point(1, 1)) and ws.selection:contains(Point(0, 0)))
n = M.selectColors(ws, { wRed, wBlue }, 1, nil, "replace")
check("several colors at once", n == 24, n)

-- A key must not match across two neighboring pixels
local xs = Sprite(3, 1, ColorMode.RGB)
local ximg = xs.cels[1].image
ximg:putPixel(0, 0, Color{ r = 1, g = 2, b = 10, a = 10 })
ximg:putPixel(1, 0, Color{ r = 10, g = 255, b = 3, a = 4 })
ximg:putPixel(2, 0, Color{ r = 10, g = 10, b = 10 })
local xk = M.colorToKey(ColorMode.RGB, Color{ r = 10, g = 10, b = 10 })
check("no match across pixel boundaries", M.selectColors(xs, { xk }, 1, nil, "replace") == 1
      and xs.selection:contains(Point(2, 0)) and not xs.selection:contains(Point(0, 0)))

-- Active layer: cel offset is taken into account
local os_ = Sprite(8, 4, ColorMode.RGB)
local lay = os_:newLayer()
local cimg = Image(2, 1, ColorMode.RGB)
cimg:clear(Color{ r = 255, g = 0, b = 0 })
os_:newCel(lay, 1, cimg, Point(3, 2))
n = M.selectColors(os_, { wRed }, 1, lay, "replace")
check("layer cel offset", n == 2 and os_.selection:contains(Point(3, 2)) and os_.selection:contains(Point(4, 2))
      and not os_.selection:contains(Point(0, 0)), n)
n = M.selectColors(os_, { wRed }, 1, nil, "replace")
check("composite selection matches visible pixels", n == 2 and os_.selection:contains(Point(4, 2)), n)

-- Indexed and gray
local isel = Sprite(4, 4, ColorMode.INDEXED)
isel.palettes[1]:resize(3)
isel.palettes[1]:setColor(1, Color{ r = 9, g = 9, b = 9 })
local iimg2 = isel.cels[1].image
iimg2:clear(0)
iimg2:putPixel(1, 1, 1)
iimg2:putPixel(2, 3, 1)
check("indexed selection", M.selectColors(isel, { 1 }, 1, nil, "replace") == 2
      and isel.selection:contains(Point(2, 3)) and not isel.selection:contains(Point(0, 0)))
local gsel = Sprite(3, 1, ColorMode.GRAY)
gsel.cels[1].image:putPixel(0, 0, Color{ gray = 80 })
gsel.cels[1].image:putPixel(2, 0, Color{ gray = 80 })
gsel.cels[1].image:putPixel(1, 0, Color{ gray = 81 })
check("gray selection", M.selectColors(gsel, { M.colorToKey(ColorMode.GRAY, Color{ gray = 80 }) }, 1, nil, "replace") == 2
      and gsel.selection:contains(Point(2, 0)) and not gsel.selection:contains(Point(1, 0)))

print(failures == 0 and "ALL PASSED" or (failures .. " FAILED"))
