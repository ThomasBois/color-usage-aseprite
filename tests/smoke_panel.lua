-- Exercises the panel's UI code path with fake Dialog / Timer / graphics objects
-- (Dialog is nil in batch mode). Catches runtime errors and checks that no widget
-- is modified while the panel is in use: Dialog:modify makes Aseprite re-layout the
-- window, which resets its size and position.
-- Run with: Aseprite.exe -b --script tests/smoke_panel.lua
local failures = 0
local function check(name, cond, detail)
  if cond then print("ok   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. " " .. tostring(detail or "")) end
end

local dialogs = {}
Dialog = function(opts)
  local d = { widgets = {}, data = {}, modifyCalls = 0, repaints = 0, bounds = Rectangle(0, 0, 300, 300), opts = opts }
  for _, kind in ipairs{ "combobox", "check", "button", "number", "canvas", "label" } do
    d[kind] = function(self, t)
      if t.id then
        self.widgets[t.id] = t
        if kind == "combobox" then self.data[t.id] = t.option
        elseif kind == "check" then self.data[t.id] = t.selected
        elseif kind == "number" then self.data[t.id] = tonumber(t.text) end
      end
      return self
    end
  end
  function d:newrow() return self end
  function d:show() self.shown = true end
  function d:repaint() self.repaints = self.repaints + 1 end
  function d:modify() self.modifyCalls = self.modifyCalls + 1 end
  function d:close() if not self.closed then self.closed = true; if opts.onclose then opts.onclose() end end end
  dialogs[#dialogs + 1] = d
  return d
end
Timer = function(t) t.start = function() end; t.stop = function() end; return t end

local texts, rects, placed = {}, {}, {}
local function fakeContext(w, h)
  return {
    width = w, height = h, color = nil,
    fillRect = function(_, r) rects[#rects + 1] = r end, strokeRect = function() end,
    fillText = function(_, text, x, y) texts[#texts + 1] = text; placed[#placed + 1] = { text = text, x = x, y = y } end,
    measureText = function(_, text) return { width = #text * 6, height = 10 } end,
  }
end

local M = dofile("color-usage.lua")
local command
init({ preferences = {}, newCommand = function(_, t) command = t end })

local spr = Sprite(10, 10, ColorMode.RGB)
local img = spr.cels[1].image
for y = 0, 9 do
  for x = 0, 9 do
    img:drawPixel(x, y, (y < 5) and Color{ r = 200, g = 30, b = 30 } or (x < 9 and Color{ r = 30, g = 30, b = 200 } or Color{ r = 31, g = 31, b = 199 }))
  end
end

local ok, err = pcall(command.onclick)
check("panel opens", ok, err)
local main = dialogs[1]
check("dialog shown", main and main.shown)
check("canvas widget present", main.widgets.list ~= nil)
check("compact layout: no label widgets", main.widgets.info == nil and main.widgets.detail == nil)

local cv = main.widgets.list
texts = {}
ok, err = pcall(cv.onpaint, { context = fakeContext(230, 230) })
check("paint runs", ok, err)
local joined = table.concat(texts, "|")
check("list shows colors", joined:find("#C81E1E", 1, true) ~= nil, joined)
check("status line shows summary", joined:find("colors", 1, true) ~= nil, joined)

ok, err = pcall(cv.onmousemove, { x = 20, y = 10 })
check("hover runs", ok, err)
texts = {}
pcall(cv.onpaint, { context = fakeContext(230, 230) })
check("hover detail in status", table.concat(texts, "|"):find("px", 1, true) ~= nil, table.concat(texts, "|"))

ok, err = pcall(cv.onmousedown, { x = 20, y = 10, button = MouseButton.LEFT })
check("left click sets FG", ok and app.fgColor.red == 200, err)
ok, err = pcall(cv.onmousedown, { x = 20, y = 32, button = MouseButton.RIGHT })
check("right click sets BG", ok and app.bgColor.blue == 200, err)
ok, err = pcall(cv.onwheel, { deltaY = 1 })
check("wheel runs", ok, err)

-- Replace FG (red) by BG (blue) through the button
ok, err = pcall(main.widgets.replace.onclick)
check("replace button runs", ok, err)
check("red replaced by blue", spr.cels[1].image:getPixel(0, 0) == app.pixelColor.rgba(30, 30, 200, 255),
      spr.cels[1].image:getPixel(0, 0))

-- Sort / filter widgets
main.data.sort = "Hue"; main.data.onlysimilar = true; main.data.group = true
ok, err = pcall(main.widgets.sort.onchange)
check("sort change runs", ok, err)
ok, err = pcall(main.widgets.onlysimilar.onclick)
check("filter runs", ok, err)
pcall(cv.onpaint, { context = fakeContext(230, 230) })

-- Options dialog
ok, err = pcall(main.widgets.options.onclick)
check("options dialog opens", ok and dialogs[2] ~= nil, err)
local opt = dialogs[2]
opt.data.scope = "All frames"; opt.data.threshold = 5; opt.data.tolerance = 8
check("scope change runs", pcall(opt.widgets.scope.onchange))
check("threshold change runs", pcall(opt.widgets.threshold.onchange))
check("tolerance change runs", pcall(opt.widgets.tolerance.onchange))
pcall(cv.onpaint, { context = fakeContext(230, 230) })

-- Responsive columns: whatever the width, the hex code never gets close to the bar
-- or to the percentage, and the bar never starts before the hex code ends.
local function checkLayout(width)
  rects, placed = {}, {}
  pcall(cv.onpaint, { context = fakeContext(width, 230) })
  local hexes, pcts, bars = {}, {}, {}
  for _, p in ipairs(placed) do
    if p.text:match("^#%x+$") then hexes[#hexes + 1] = p
    elseif p.text:match("%%$") and not p.text:match("colors") then pcts[#pcts + 1] = p end
  end
  for _, r in ipairs(rects) do
    if r.height == 10 and r.width > 10 then bars[#bars + 1] = r end
  end
  local minHexRight, minBarX, minPctX = math.huge, math.huge, math.huge
  local hexRight = 0
  for _, h in ipairs(hexes) do hexRight = math.max(hexRight, h.x + #h.text * 6) end
  for _, b in ipairs(bars) do minBarX = math.min(minBarX, b.x) end
  for _, p in ipairs(pcts) do
    if p.y < 230 - 30 then minPctX = math.min(minPctX, p.x) end -- skip status lines
  end
  return hexRight, minBarX, minPctX, #bars
end
for _, width in ipairs{ 60, 90, 120, 150, 180, 230, 400 } do
  local hexRight, barX, pctX, nbars = checkLayout(width)
  check("width " .. width .. ": bar keeps its distance from the hex code", nbars == 0 or barX >= hexRight + 8,
        string.format("hexRight=%s barX=%s", hexRight, barX))
  check("width " .. width .. ": percentage does not touch the hex code", pctX == math.huge or pctX >= hexRight + 6,
        string.format("hexRight=%s pctX=%s", hexRight, pctX))
end
local _, _, _, wideBars = checkLayout(400)
local _, _, _, narrowBars = checkLayout(60)
check("bar shown when wide, hidden when narrow", wideBars > 0 and narrowBars == 0, wideBars .. "/" .. narrowBars)

-- The bar length must mean something: with the absolute scale, a color using X% of
-- the pixels fills X% of the bar; with the relative scale the top color fills it all.
local function barRatios(width)
  rects = {}
  pcall(cv.onpaint, { context = fakeContext(width, 230) })
  local ratios = {}
  for i, r in ipairs(rects) do
    if r.height == 10 and r.width > 10 and rects[i + 1] and rects[i + 1].height == 10 and rects[i + 1].x == r.x then
      ratios[#ratios + 1] = rects[i + 1].width / r.width
      if #ratios > 0 and ratios[#ratios] > 1.01 then break end
    end
  end
  return ratios
end
main.data.group = false; main.data.onlysimilar = false; main.data.sort = "Usage"; main.data.order = "Descending"
pcall(main.widgets.sort.onchange)
local ratios = barRatios(400)
-- After the Replace step the sprite is 95% blue and 5% near-blue.
check("absolute bars: 95% / 5%", #ratios == 2 and math.abs(ratios[1] - 0.95) < 0.03
      and math.abs(ratios[2] - 0.05) < 0.03, table.concat(ratios, ","))
opt.data.barScale = "Relative (most used)"
pcall(opt.widgets.barScale.onchange)
ratios = barRatios(400)
check("relative bars: top color fills the bar", #ratios == 2 and ratios[1] > 0.97 and math.abs(ratios[2] - 0.053) < 0.03,
      table.concat(ratios, ","))
opt.data.barScale = "Absolute (100%)"
pcall(opt.widgets.barScale.onchange)

-- Ctrl+click selects the pixels of a color; Shift adds, Alt subtracts.
-- Rows are sorted by usage: row 1 = blue (95 px), row 2 = near-blue (5 px at x = 9, y >= 5).
spr.selection:deselect()
ok, err = pcall(cv.onmousedown, { x = 20, y = 10, button = MouseButton.LEFT, ctrlKey = true })
check("ctrl+click selects the color's pixels", ok and spr.selection:contains(Point(0, 0))
      and not spr.selection:contains(Point(9, 9)), err)
check("ctrl+click also sets FG", app.fgColor.blue == 200 and app.fgColor.red == 30)
ok, err = pcall(cv.onmousedown, { x = 20, y = 32, button = MouseButton.LEFT, ctrlKey = true, shiftKey = true })
check("ctrl+shift+click adds", ok and spr.selection:contains(Point(0, 0)) and spr.selection:contains(Point(9, 9)), err)
ok, err = pcall(cv.onmousedown, { x = 20, y = 32, button = MouseButton.LEFT, ctrlKey = true, altKey = true })
check("ctrl+alt+click subtracts", ok and spr.selection:contains(Point(0, 0)) and not spr.selection:contains(Point(9, 9)), err)
spr.selection:deselect()
ok, err = pcall(cv.onmousedown, { x = 20, y = 10, button = MouseButton.LEFT })
check("plain click leaves the selection alone", ok and spr.selection.isEmpty, err)
-- Group header: Ctrl+click selects every color of the group
main.data.group = true
pcall(main.widgets.group.onclick)
ok, err = pcall(cv.onmousedown, { x = 20, y = 5, button = MouseButton.LEFT, ctrlKey = true })
check("ctrl+click on a group selects all its colors", ok and spr.selection:contains(Point(0, 0))
      and spr.selection:contains(Point(9, 9)), err)
main.data.group = false
pcall(main.widgets.group.onclick)

-- Timer-driven refresh after the sprite changes
spr.cels[1].image:drawPixel(0, 0, Color{ r = 1, g = 2, b = 3 })
pcall(function() app.fgColor = Color{ r = 1, g = 2, b = 3 } end)

check("widgets never modified while in use", main.modifyCalls == 0 and opt.modifyCalls == 0,
      main.modifyCalls .. "/" .. opt.modifyCalls)
check("canvas repainted", main.repaints > 0)

-- Closing the panel also closes the options dialog, and reopening works
main:close()
check("options closed with panel", opt.closed == true)
ok, err = pcall(command.onclick)
check("panel reopens", ok and #dialogs == 3, err)
dialogs[#dialogs]:close()
exit({})
print(failures == 0 and "ALL PASSED" or (failures .. " FAILED"))
