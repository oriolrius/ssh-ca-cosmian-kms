-- table-widths.lua
-- pandoc emits non-wrapping `l` columns for tables that carry no explicit
-- widths, so wide reference tables run off the page. Assign each column a
-- proportional width, floored at its longest unbreakable word (plus a small
-- safety margin) so long tokens like "map<string,string>" never overflow.
-- Targets the pandoc 2.9 (pre-2.10) Table AST.

local function longest_word(s)
  local m = 1
  for w in s:gmatch("%S+") do if #w > m then m = #w end end
  return m
end

function Table(el)
  local ncol = #el.widths
  if ncol == 0 then return nil end
  for _, w in ipairs(el.widths) do
    if w and w > 0 then return nil end  -- widths already set
  end

  local cellmax, wordmax = {}, {}
  for i = 1, ncol do cellmax[i] = 1; wordmax[i] = 1 end

  local function consider(i, s)
    if #s > cellmax[i] then cellmax[i] = #s end
    local wm = longest_word(s)
    if wm > wordmax[i] then wordmax[i] = wm end
  end

  for i, cell in ipairs(el.headers) do consider(i, pandoc.utils.stringify(cell)) end
  for _, row in ipairs(el.rows) do
    for i, cell in ipairs(row) do consider(i, pandoc.utils.stringify(cell)) end
  end

  -- Approx. characters per full-width line; floors guarantee the longest
  -- unbreakable token fits (1.2x safety for wide glyphs like < > =).
  local budget = 100
  local floor = {}
  local sumfloor = 0
  for i = 1, ncol do floor[i] = wordmax[i] * 1.2; sumfloor = sumfloor + floor[i] end

  local widthc = {}
  if sumfloor >= budget then
    for i = 1, ncol do widthc[i] = floor[i] end
  else
    local extra = budget - sumfloor
    local sumdes = 0
    for i = 1, ncol do sumdes = sumdes + math.max(cellmax[i] - floor[i], 0) end
    for i = 1, ncol do
      local add = (sumdes > 0) and extra * (math.max(cellmax[i] - floor[i], 0) / sumdes)
                                or extra / ncol
      widthc[i] = floor[i] + add
    end
  end

  local tot = 0
  for i = 1, ncol do tot = tot + widthc[i] end
  for i = 1, ncol do el.widths[i] = 0.97 * widthc[i] / tot end
  return el
end
