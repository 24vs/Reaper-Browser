-- REAPER Nested FX Browser — fixed
-- Uses REAPER's existing FX inventory. No network, no rescan, no plugin loading until Add.
-- Folder assignments are stored in REAPER ExtState and do not modify project/plugin files.
-- Folder paths use "/" separators, e.g. Delay/Waves or Delay/Valhalla.
-- Requires a REAPER version exposing EnumInstalledFX and TrackFX_AddByName.

local SECTION = "VSoundNestedFXBrowser"
local KEY = "folder_map_v1"
local FOLDERS_KEY = "folders_v1"
local FOLDER_ORDER_KEY = "folder_order_v1"
local GEOMETRY_KEY = "window_geometry_v1"
local RUN_KEY = "running_v9"
local CLOSE_KEY = "close_request_v9"
-- This is the worker window. Use the companion *_launcher.lua for the toolbar button.
reaper.SetExtState(SECTION, RUN_KEY, "1", false)
reaper.SetExtState(SECTION, CLOSE_KEY, "", false)

if not reaper.EnumInstalledFX then
  reaper.ShowMessageBox("EnumInstalledFX is unavailable in this REAPER version.", "Nested FX Browser", 0)
  return
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split(s, sep)
  local out = {}
  for part in (s .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = part end
  return out
end

local function loadMap()
  local map = {}
  local raw = reaper.GetExtState(SECTION, KEY)
  for line in (raw .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then
      local tab = line:find("\t", 1, true)
      if tab then map[line:sub(1, tab - 1)] = line:sub(tab + 1) end
    end
  end
  return map
end

local function loadFolders()
  local set = {}
  local raw = reaper.GetExtState(SECTION, FOLDERS_KEY)
  for line in (raw .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then set[line] = true end
  end
  return set
end

local function loadFolderOrder()
  local order, raw = {}, reaper.GetExtState(SECTION, FOLDER_ORDER_KEY)
  for line in (raw .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then order[#order + 1] = line end
  end
  return order
end

local folderOrder = loadFolderOrder()
local function saveFolderOrder()
  reaper.SetExtState(SECTION, FOLDER_ORDER_KEY, table.concat(folderOrder, "\n"), true)
end

local function saveFolders(set)
  local list, known = {}, {}
  for folder in pairs(set) do list[#list + 1] = folder; known[folder] = true end
  table.sort(list, function(a,b) return a:lower() < b:lower() end)
  local ordered = {}
  for _, folder in ipairs(folderOrder) do
    if known[folder] then ordered[folder] = true end
  end
  local missing = {}
  for _, folder in ipairs(list) do if not ordered[folder] then missing[#missing+1] = folder end end
  for _, folder in ipairs(missing) do folderOrder[#folderOrder+1] = folder end
  saveFolderOrder()
  reaper.SetExtState(SECTION, FOLDERS_KEY, table.concat(list, "\n"), true)
end

local function saveMap(map)
  local keys = {}
  for k in pairs(map) do keys[#keys + 1] = k end
  table.sort(keys)
  local lines = {}
  for _, k in ipairs(keys) do
    lines[#lines + 1] = k .. "\t" .. map[k]
  end
  reaper.SetExtState(SECTION, KEY, table.concat(lines, "\n"), true)
end

local function getFormat(ident, name)
  -- REAPER identifiers may include instrument suffixes (VSTi/VST3i) or
  -- place the format prefix in either the identifier or display name.
  local candidates = {tostring(ident or ""), tostring(name or "")}
  for _, raw in ipairs(candidates) do
    local s = trim(raw):upper()
    local prefix = s:match("^([%w]+)%s*:") or s:match("^([%w]+)%s*%-") or s:match("^([%w]+)%s+") or s
    if prefix == "AU" or prefix == "AUDIOUNIT" then return "AU" end
    if prefix == "VST3" or prefix == "VST3I" or prefix == "VST3X64" then return "VST3" end
    if prefix == "VST" or prefix == "VSTI" or prefix == "VST2" or prefix == "VSTX64" then return "VST" end
    if prefix == "CLAP" then return "CLAP" end
    if prefix == "JS" or prefix == "JSFX" then return "JSFX" end
    if prefix == "LV2" then return "LV2" end
    if prefix == "DX" or prefix == "DXI" then return "DX" end
  end
  return "Other"
end

local function getManufacturer(name, ident)
  local function validVendor(v)
    if not v then return nil end
    v = trim(v):gsub("^%s+", ""):gsub("%s+$", "")
    if v == "" then return nil end
    local low = v:lower():gsub("[%s_]+", " ")
    -- Channel layouts and REAPER's routing/format descriptors are not vendors.
    if low == "other" or low == "unknown" or low == "other / unknown" or low == "crossover" then return nil end
    if low:match("^%d") or low:match("[%d]+%s*[%+%-→x/]+%s*[%d]*") then return nil end
    if low:find("range", 1, true) or low:find("channel", 1, true) or low:find("stereo", 1, true)
      or low:find("mono", 1, true) or low:find("crossover", 1, true)
      or low:find("in/out", 1, true) or low:find("input", 1, true) or low:find("output", 1, true)
      or low:match("%d+%s*ch") or low:match("%d+%s*in") or low:match("%d+%s*out")
      or low:match("%d+%s*inch") or low:match("%d+%s*fon") then return nil end
    if low:match("^%d+%s*[%a%s/+-]*$") then return nil end
    return v
  end
  local function trailingParen(s)
    -- Skip trailing parenthetical channel/layout labels and look at earlier
    -- parentheses, since REAPER may append more than one descriptor.
    local candidates = {}
    for v in tostring(s or ""):gmatch("%(([^%(%)]+)%)") do candidates[#candidates + 1] = v end
    for i = #candidates, 1, -1 do
      local vendor = validVendor(candidates[i])
      if vendor then return vendor end
    end
  end
  local vendor = trailingParen(name) or trailingParen(ident)
  if vendor then return vendor end
  -- Accept a non-format prefix only when it looks like a real vendor label.
  local prefix = tostring(ident or ""):match("^%s*([^:]+):")
  if prefix then
    local u = prefix:upper()
    if u ~= "AU" and u ~= "AUDIOUNIT" and u ~= "VST" and u ~= "VSTI" and u ~= "VST2" and u ~= "VST3" and u ~= "VST3I" and u ~= "CLAP" and u ~= "JS" and u ~= "JSFX" and u ~= "LV2" and u ~= "DX" and u ~= "DXI" then
      vendor = validVendor(prefix)
      if vendor then return vendor end
    end
  end
  return "Other / Unknown"
end

local function getFX()
  local fx, seen = {}, {}
  for i = 0, 100000 do
    local ok, name, ident = reaper.EnumInstalledFX(i)
    if not ok then break end
    name, ident = tostring(name or ""), tostring(ident or "")
    local key = ident ~= "" and ident or name
    if key ~= "" and not seen[key] then
      seen[key] = true
      fx[#fx + 1] = {name = name, ident = ident, key = key,
        format = getFormat(ident, name), manufacturer = getManufacturer(name, ident)}
    end
  end
  table.sort(fx, function(a,b) return a.name:lower() < b.name:lower() end)
  return fx
end

local fxList = getFX()
local folderMap = loadMap()
local savedFolders = loadFolders()
local status = "" -- declared before helpers that update the status line

-- A plugin can belong to more than one custom folder. Legacy single-path
-- assignments remain readable; multiple paths use an internal control separator.
local ASSIGN_SEP = string.char(31)
local function assignedPaths(key)
  local value = folderMap and folderMap[key] or nil
  local paths = {}
  if not value or value == "" then return paths end
  if value:find(ASSIGN_SEP, 1, true) then
    for path in value:gmatch("([^" .. ASSIGN_SEP .. "]+)") do paths[#paths+1] = path end
  else
    paths[1] = value
  end
  return paths
end

local function hasFolderAssignment(key, wanted)
  for _, path in ipairs(assignedPaths(key)) do if path == wanted then return true end end
  return false
end

local function storeAssignedPaths(key, paths)
  local unique, out = {}, {}
  for _, path in ipairs(paths) do
    if path and path ~= "" and not unique[path] then unique[path] = true; out[#out+1] = path end
  end
  if #out == 0 then folderMap[key] = nil else folderMap[key] = table.concat(out, ASSIGN_SEP) end
end

local function addFolderAssignment(fx, path)
  if not fx or not path or path == "" then return false end
  local paths = assignedPaths(fx.key)
  for _, existing in ipairs(paths) do
    if existing == path then status = fx.name .. " is already in " .. path; return true end
  end
  paths[#paths+1] = path
  storeAssignedPaths(fx.key, paths)
  local cur = ""
  for _, part in ipairs(split(path, "/")) do
    cur = cur == "" and part or (cur .. "/" .. part)
    savedFolders[cur] = true
  end
  saveFolders(savedFolders); saveMap(folderMap)
  status = "Added to folder " .. path .. ": " .. fx.name
  return true
end

local selectedFX, selectedFolder = 1, "All FX"
local selectedFXKeys = {} -- multi-selection by stable plugin identifier
local selectionAnchorKey = nil -- anchor plugin for Shift-range selection
local selectionCleared = false -- distinguishes an intentionally empty selection from the default row
local selectedManufacturer = nil
local search = ""
local searchFocused = false
local cursorVisible = true
local lastCursorBlink = 0
local contextMenu = nil
local formatMenuOpen = false
local formatEnabled = {AU=true, VST=true, VST3=true, CLAP=true, JSFX=true, LV2=true, DX=true}
local rawFormatState = reaper.GetExtState(SECTION, "formats_v1")
if rawFormatState ~= "" then
  for _, f in ipairs({"AU","VST","VST3","CLAP","JSFX","LV2","DX"}) do formatEnabled[f] = rawFormatState:find("|" .. f .. "|", 1, true) ~= nil end
end
local function saveFormatState()
  local parts = {"|"}
  for _, f in ipairs({"AU","VST","VST3","CLAP","JSFX","LV2","DX"}) do
    if formatEnabled[f] then parts[#parts+1] = f; parts[#parts+1] = "|" end
  end
  reaper.SetExtState(SECTION, "formats_v1", table.concat(parts), true)
end
local expandedFolders = {} -- a parent shows its children only after clicking +
local pendingFolderReveal = nil
local manufacturersExpanded = false
local expandedManufacturers = {}
local dragFX, dragStartX, dragStartY, dragging = nil, 0, 0, false
local dragFolder, draggingFolder = nil, false
local dragTarget = nil
local scroll, folderScroll = 0, 0
local draggingListScrollbar = false
local draggingFolderScrollbar = false

-- Restore the browser's working view across close/reopen.
local UI_STATE_KEY = "ui_state_v1"
local function restoreUIState()
  local raw = reaper.GetExtState(SECTION, UI_STATE_KEY)
  if raw == "" then return end
  local values = {}
  for line in (raw .. "\n"):gmatch("(.-)\n") do
    local tab = line:find("\t", 1, true)
    if tab then values[line:sub(1, tab-1)] = line:sub(tab+1) end
  end
  if values.folder and (values.folder == "All FX" or values.folder == "Unsorted" or values.folder == "My Folders" or savedFolders[values.folder]) then
    selectedFolder = values.folder
  end
  selectedManufacturer = values.manufacturer ~= "" and values.manufacturer or nil
  search = values.search or ""
  selectedFX = math.max(1, tonumber(values.selectedFX) or 1)
  scroll = math.max(0, tonumber(values.scroll) or 0)
  folderScroll = math.max(0, tonumber(values.folderScroll) or 0)
  selectionCleared = values.selectionCleared == "1"
  selectionAnchorKey = values.anchor ~= "" and values.anchor or nil
  for key in (values.selectedKeys or ""):gmatch("([^\30]+)") do selectedFXKeys[key] = true end
  for path in (values.expandedFolders or ""):gmatch("([^\30]+)") do
    if savedFolders[path] then expandedFolders[path] = true end
  end
  manufacturersExpanded = values.manufacturersExpanded == "1"
  for name in (values.expandedManufacturers or ""):gmatch("([^\30]+)") do expandedManufacturers[name] = true end
end

local function saveUIState()
  local parts = {}
  local function put(k, v) parts[#parts+1] = k .. "\t" .. (v or "") end
  local function joinedKeys(t)
    local out = {}
    for k, v in pairs(t) do if v then out[#out+1] = k end end
    table.sort(out)
    return table.concat(out, "\30")
  end
  put("folder", selectedFolder)
  put("manufacturer", selectedManufacturer or "")
  put("search", search)
  put("selectedFX", selectedFX)
  put("scroll", scroll)
  put("folderScroll", folderScroll)
  put("selectionCleared", selectionCleared and "1" or "0")
  put("anchor", selectionAnchorKey or "")
  put("selectedKeys", joinedKeys(selectedFXKeys))
  put("expandedFolders", joinedKeys(expandedFolders))
  put("manufacturersExpanded", manufacturersExpanded and "1" or "0")
  put("expandedManufacturers", joinedKeys(expandedManufacturers))
  reaper.SetExtState(SECTION, UI_STATE_KEY, table.concat(parts, "\n"), true)
end

restoreUIState()
status = "Loaded " .. #fxList .. " unique entries (deduplicated by identifier)."
local rows = {}
local rowHeight = 23
local listX, listY, listW, listH = 14, 118, 650, 390
local winW, winH = 900, 570
local leftW = 210
local resizingDivider = false

local function allFolders()
  local set = {["All FX"] = true, ["Unsorted"] = true}
  for path in pairs(savedFolders) do
    if path ~= "" then
      local cur = ""
      for _, part in ipairs(split(path, "/")) do
        cur = cur == "" and part or (cur .. "/" .. part)
        set[cur] = true
      end
    end
  end
  for _, path in pairs(folderMap) do
    if path ~= "" then
      local cur = ""
      for _, part in ipairs(split(path, "/")) do
        cur = cur == "" and part or (cur .. "/" .. part)
        set[cur] = true
      end
    end
  end
  local out = {}
  for f in pairs(set) do out[#out + 1] = f end
  local orderRank = {}
  for i, path in ipairs(folderOrder) do orderRank[path] = i end
  local function segments(path) return split(path, "/") end
  table.sort(out, function(a,b)
    if a == b then return false end
    if a == "All FX" then return true end
    if b == "All FX" then return false end
    if a == "Unsorted" then return true end
    if b == "Unsorted" then return false end
    local aa, bb = segments(a), segments(b)
    for i = 1, math.min(#aa, #bb) do
      if aa[i] ~= bb[i] then
        local ap = table.concat(aa, "/", 1, i)
        local bp = table.concat(bb, "/", 1, i)
        local ar, br = orderRank[ap], orderRank[bp]
        if ar and br and ar ~= br then return ar < br end
        if ar and not br then return true end
        if br and not ar then return false end
        return aa[i]:lower() < bb[i]:lower()
      end
    end
    return #aa < #bb
  end)
  return out
end

local function hasChildren(path, folders)
  local prefix = path .. "/"
  for _, f in ipairs(folders) do
    if f:sub(1, #prefix) == prefix then return true end
  end
  return false
end

local function visibleFolders(folders)
  local out = {"All FX", "Unsorted"}
  local paths = {}
  for _, f in ipairs(folders) do
    if f ~= "All FX" and f ~= "Unsorted" then paths[#paths + 1] = f end
  end
  -- Lexical path order keeps each parent immediately before its descendants.
  table.sort(paths, function(a,b) return a:lower() < b:lower() end)
  for _, path in ipairs(paths) do
    local show = true
    local parent = path:match("^(.*)/[^/]+$")
    while parent do
      if not expandedFolders[parent] then show = false; break end
      parent = parent:match("^(.*)/[^/]+$")
    end
    if show then out[#out + 1] = path end
  end
  return out
end

local function ensureAncestorsExpanded(path)
  local parent = path and path:match("^(.*)/[^/]+$")
  while parent do
    expandedFolders[parent] = true
    parent = parent:match("^(.*)/[^/]+$")
  end
end

local function pathParent(path)
  return path:match("^(.*)/[^/]+$") or ""
end

local function pathBase(path)
  return path:match("([^/]+)$") or path
end

local function moveFolderPath(source, target, mode)
  if not source or source == "" or source == "All FX" or source == "Unsorted" then return false end
  if target == source or (target and target:sub(1, #source + 1) == source .. "/") then
    status = "Cannot move a folder into itself or one of its descendants."
    return false
  end
  local newPath
  if mode == "inside" then
    if not target or target == "All FX" or target == "Unsorted" then return false end
    newPath = target .. "/" .. pathBase(source)
  elseif mode == "root" then
    -- Dropping onto the My Folders header pulls a nested folder back to the top level.
    newPath = pathBase(source)
  else
    local parent = target and pathParent(target) or pathParent(source)
    newPath = parent ~= "" and (parent .. "/" .. pathBase(source)) or pathBase(source)
  end
  if newPath == source then
    -- A same-level drop can still reorder the folder.
  elseif newPath == "" or newPath:sub(1, #source + 1) == source .. "/" then
    status = "Invalid folder destination."
    return false
  else
    for _, existing in ipairs(allFolders()) do
      if existing == newPath or existing:sub(1, #newPath + 1) == newPath .. "/" then
        status = "A folder with that name already exists at the destination."
        return false
      end
    end
  end
  local sourceParent = pathParent(source)
  local targetParent = mode == "inside" and target or (target and pathParent(target) or sourceParent)
  local moving = {}
  for path in pairs(savedFolders) do
    if path == source or path:sub(1, #source + 1) == source .. "/" then
      moving[path] = newPath .. path:sub(#source + 1)
    end
  end
  if next(moving) == nil then moving[source] = newPath end
  for old, dest in pairs(moving) do
    if savedFolders[old] then savedFolders[old] = nil end
    savedFolders[dest] = true
  end
  for key in pairs(folderMap) do
    local remapped = {}
    for _, path in ipairs(assignedPaths(key)) do
      if path == source or path:sub(1, #source + 1) == source .. "/" then
        remapped[#remapped+1] = newPath .. path:sub(#source + 1)
      else
        remapped[#remapped+1] = path
      end
    end
    storeAssignedPaths(key, remapped)
  end

  local rebuilt = {}
  for _, path in ipairs(folderOrder) do
    if path == source or path:sub(1, #source + 1) == source .. "/" then
      rebuilt[#rebuilt + 1] = newPath .. path:sub(#source + 1)
    elseif not (path == newPath or path:sub(1, #newPath + 1) == newPath .. "/") then
      rebuilt[#rebuilt + 1] = path
    end
  end
  local known = {}
  for _, path in ipairs(rebuilt) do known[path] = true end
  for path in pairs(savedFolders) do if not known[path] then rebuilt[#rebuilt + 1] = path; known[path] = true end end
  folderOrder = rebuilt

  -- Move among siblings: remove the moved root from its new sibling list and insert before/after target.
  if mode == "before" or mode == "after" then
    local siblings = {}
    for _, path in ipairs(folderOrder) do if pathParent(path) == pathParent(newPath) then siblings[#siblings + 1] = path end end
    local movingRoot = newPath
    local filtered = {}
    for _, path in ipairs(siblings) do if path ~= movingRoot then filtered[#filtered + 1] = path end end
    local insertAt = #filtered + 1
    local targetPath = target
    for i, path in ipairs(filtered) do
      if path == targetPath then insertAt = i + (mode == "after" and 1 or 0); break end
    end
    table.insert(filtered, insertAt, movingRoot)
    local all = {}
    local replaced = false
    for _, path in ipairs(folderOrder) do
      if pathParent(path) == pathParent(newPath) then
        if not replaced then for _, sibling in ipairs(filtered) do all[#all + 1] = sibling end; replaced = true end
      else all[#all + 1] = path end
    end
    folderOrder = all
  end
  saveFolders(savedFolders); saveMap(folderMap); saveFolderOrder()
  selectedFolder = newPath
  selectedManufacturer = nil
  ensureAncestorsExpanded(newPath)
  expandedFolders[newPath] = true
  pendingFolderReveal = newPath
  status = "Moved folder to " .. newPath
  return true
end



local function currentRows()
  local out = {}
  local q = search:lower()
  for _, fx in ipairs(fxList) do
    local paths = assignedPaths(fx.key)
    -- Search narrows the current view inside the selected folder.
    local folderOK = selectedFolder == "All FX"
      or (selectedFolder == "Unsorted" and #paths == 0)
      or (selectedFolder ~= "My Folders" and selectedFolder ~= "Unsorted" and selectedFolder ~= "All FX" and hasFolderAssignment(fx.key, selectedFolder))
    local manufacturerOK = not selectedManufacturer or fx.manufacturer == selectedManufacturer
    local formatOK = fx.format == "Other" or formatEnabled[fx.format] ~= false
    local searchOK = q == "" or fx.name:lower():find(q, 1, true) or fx.ident:lower():find(q, 1, true) or fx.manufacturer:lower():find(q, 1, true)
    if folderOK and manufacturerOK and formatOK and searchOK then out[#out + 1] = fx end
  end
  return out
end

local function getManufacturers()
  local set, out = {}, {}
  for _, fx in ipairs(fxList) do if fx.manufacturer ~= "Other / Unknown" then set[fx.manufacturer] = true end end
  for name in pairs(set) do out[#out+1] = name end
  table.sort(out, function(a,b) return a:lower() < b:lower() end)
  return out
end

local THEME_KEY = "color_theme_v1"
local themeNames = {"REAPER", "Dark", "Graphite", "Light", "Warm Light"}
local currentTheme = reaper.GetExtState(SECTION, THEME_KEY)
local validTheme = false
for _, name in ipairs(themeNames) do if currentTheme == name then validTheme = true; break end end
if not validTheme then currentTheme = "Dark" end
local themeMenuOpen = false
-- Read colors from the active REAPER theme. This keeps the browser aligned
-- with REAPER's own default/dark palette instead of hard-coding a lookalike.
local function reaperThemeRGB(key, fallbackR, fallbackG, fallbackB)
  local native = reaper.GetThemeColor(key, 0)
  if native == -1 then return fallbackR, fallbackG, fallbackB end
  local rr, gg, bb = reaper.ColorFromNative(native)
  return (rr or 0)/255, (gg or 0)/255, (bb or 0)/255
end
local reaperPalette = {
  bg = {reaperThemeRGB("col_main_bg", 0.105,0.115,0.13)},
  edit = {reaperThemeRGB("col_main_editbk", 0.07,0.08,0.09)},
  button = {reaperThemeRGB("col_buttonbg", 0.20,0.22,0.25)},
  text = {reaperThemeRGB("col_main_text", 0.88,0.89,0.90)},
  highlight = {reaperThemeRGB("col_main_3dhl", 0.42,0.45,0.48)},
  shadow = {reaperThemeRGB("col_main_3dsh", 0.27,0.30,0.32)}
}
local function mix(a,b,t) return a*(1-t)+b*t end
local function color(r,g,b,a)
  r, g, b = r or 0, g or 0, b or 0
  if currentTheme == "REAPER" then
    local lum = (r + g + b) / 3
    local spread = math.max(r,g,b) - math.min(r,g,b)
    local bgR,bgG,bgB = table.unpack(reaperPalette.bg)
    local editR,editG,editB = table.unpack(reaperPalette.edit)
    local buttonR,buttonG,buttonB = table.unpack(reaperPalette.button)
    local txtR,txtG,txtB = table.unpack(reaperPalette.text)
    local hiR,hiG,hiB = table.unpack(reaperPalette.highlight)
    local shR,shG,shB = table.unpack(reaperPalette.shadow)
    if spread < 0.12 then
      if lum < 0.095 then
        r,g,b = editR,editG,editB
      elseif lum < 0.15 then
        r,g,b = bgR,bgG,bgB
      elseif lum < 0.36 then
        r,g,b = buttonR,buttonG,buttonB
      elseif lum < 0.52 then
        r,g,b = shR,shG,shB
      elseif lum < 0.70 then
        r,g,b = hiR,hiG,hiB
      else
        local strength = math.max(0.45, math.min(1, lum))
        r,g,b = mix(bgR,txtR,strength),mix(bgG,txtG,strength),mix(bgB,txtB,strength)
      end
    end
  elseif currentTheme == "Light" then
    r, g, b = 1-r, 1-g, 1-b
  elseif currentTheme == "Warm Light" then
    r, g, b = 1-r, 1-g, 1-b
    r, g, b = math.min(1,r*0.96+0.04), math.min(1,g*0.95+0.035), math.min(1,b*0.88+0.03)
  elseif currentTheme == "Graphite" then
    r, g, b = r*0.88+0.035, g*0.90+0.035, b*0.94+0.035
  end
  gfx.set(math.max(0,math.min(1,r)), math.max(0,math.min(1,g)), math.max(0,math.min(1,b)), a or 1)
end
local function text(x,y,s, r,g,b)
  color(r or 0.92,g or 0.92,b or 0.92,1); gfx.x, gfx.y = x,y; gfx.drawstr(tostring(s))
end

-- Draw text that stays inside a column even on REAPER builds without gfx.setclip.
local function fitText(x, y, value, maxWidth, r, g, b)
  local s = tostring(value or "")
  maxWidth = math.max(8, maxWidth or 8)
  if gfx.measurestr(s) > maxWidth then
    local suffix = "..."
    local lo, hi, best = 0, #s, ""
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      local candidate = s:sub(1, mid) .. suffix
      if gfx.measurestr(candidate) <= maxWidth then best = candidate; lo = mid + 1 else hi = mid - 1 end
    end
    s = best ~= "" and best or "..."
  end
  text(x, y, s, r, g, b)
end
local function button(x,y,w,h,label)
  local mx,my = gfx.mouse_x,gfx.mouse_y
  local hover = mx >= x and mx <= x+w and my >= y and my <= y+h
  color(hover and 0.29 or 0.20, hover and 0.32 or 0.22, hover and 0.36 or 0.25, 1)
  gfx.rect(x,y,w,h,1)
  color(0.42,0.45,0.48,1); gfx.rect(x,y,w,h,0)
  local tw,th = gfx.measurestr(label)
  text(x+(w-tw)/2,y+(h-th)/2,label)
  return hover and gfx.mouse_cap == 1
end

local function promptFolder(default)
  local ok, value = reaper.GetUserInputs("FX folder path", 1,
    "Folder path (use / for nesting):", default or "")
  if ok then
    value = trim(value):gsub("^/+", ""):gsub("/+$", "")
    if value:find("//", 1, true) or value == "" then
      reaper.ShowMessageBox("Enter a folder path such as Delay/Waves.", "Nested FX Browser", 0)
      return nil
    end
    return value
  end
  return nil
end

local function addFX(fx)
  if not fx then status = "Select a plugin first."; return false end
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    reaper.ShowMessageBox("Select a track in the REAPER arrange view first.", "Nested FX Browser", 0)
    return false
  end
  local candidates = {}
  if type(fx.ident) == "string" and fx.ident ~= "" then candidates[#candidates + 1] = fx.ident end
  if type(fx.name) == "string" and fx.name ~= "" then candidates[#candidates + 1] = fx.name end
  local idx = -1
  local errors = {}
  for _, token in ipairs(candidates) do
    local ok, result = pcall(reaper.TrackFX_AddByName, track, token, false, 1)
    if ok and type(result) == "number" and result >= 0 then idx = result; break
    elseif not ok then errors[#errors + 1] = tostring(result) end
  end
  if idx >= 0 then
    reaper.TrackFX_Show(track, idx, 3)
    status = "Added: " .. fx.name
    return true
  end
  status = "Could not add: " .. fx.name
  local detail = #errors > 0 and ("\n\nAPI details:\n" .. table.concat(errors, "\n")) or ""
  reaper.ShowMessageBox("REAPER could not add this entry:\n" .. fx.name .. "\n\nNo plugin was removed or changed." .. detail, "Nested FX Browser", 0)
  return false
end

local function addSelected()
  local visible = currentRows()
  local targets = {}
  for _, fx in ipairs(visible) do
    if selectedFXKeys[fx.key] then targets[#targets+1] = fx end
  end
  if #targets == 0 and not selectionCleared and next(selectedFXKeys) == nil and visible[selectedFX] then targets[1] = visible[selectedFX] end
  if #targets == 0 then status = "Select a plugin first."; return end
  local added = 0
  for _, fx in ipairs(targets) do if addFX(fx) then added = added + 1 end end
  if #targets > 1 then status = ("Added %d of %d selected plugins."):format(added, #targets) end
end

local function clearSelectionExcept(key)
  selectedFXKeys = {}
  if key then selectedFXKeys[key] = true end
  selectionCleared = key == nil
  selectionAnchorKey = key
end

local function toggleSelection(key)
  if selectedFXKeys[key] then selectedFXKeys[key] = nil else selectedFXKeys[key] = true end
  selectionCleared = next(selectedFXKeys) == nil
end

local function modifierHeld(cap)
  -- REAPER gfx: Ctrl=4; platform command/super modifier is commonly reported as 32.
  return (cap & 4) == 4 or (cap & 32) == 32
end

local function selectRange(visible, clickedIndex, additive)
  local anchorIndex = nil
  if selectionAnchorKey then
    for i, fx in ipairs(visible) do
      if fx.key == selectionAnchorKey then anchorIndex = i; break end
    end
  end
  if not anchorIndex then anchorIndex = selectedFX end
  if #visible == 0 then return end
  anchorIndex = math.max(1, math.min(anchorIndex, #visible))
  clickedIndex = math.max(1, math.min(clickedIndex, #visible))
  if not additive then selectedFXKeys = {} end
  local first, last = math.min(anchorIndex, clickedIndex), math.max(anchorIndex, clickedIndex)
  for i = first, last do selectedFXKeys[visible[i].key] = true end
  selectionCleared = next(selectedFXKeys) == nil
  if not selectionAnchorKey and visible[anchorIndex] then selectionAnchorKey = visible[anchorIndex].key end
end

local function normalizedPath(path)
  path = trim(path or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
  path = path:gsub("/", "/")
  if path == "" or path:find("//", 1, true) then return nil end
  for part in path:gmatch("[^/]+") do
    if part == "." or part == ".." or trim(part) == "" then return nil end
  end
  return path
end

local function assignToFolder(fx, path)
  path = normalizedPath(path)
  if not fx or not path then return false end
  local cur = ""
  for _, part in ipairs(split(path, "/")) do
    cur = cur == "" and part or (cur .. "/" .. part)
    savedFolders[cur] = true
  end
  saveFolders(savedFolders)
  folderMap[fx.key] = path
  saveMap(folderMap)
  ensureAncestorsExpanded(path)
  status = "Moved to folder " .. path .. ": " .. fx.name
  return true
end


local function createFolderFromInput(value)
  local path = normalizedPath(value)
  if not path then
    reaper.ShowMessageBox("Enter a folder name, or a path such as VSFX/Dynamic.", "Nested FX Browser", 0)
    return nil
  end
  -- A simple name entered while a custom folder is selected creates a child.
  local parentSelection = nil
  if not value:find("/", 1, true) and selectedFolder ~= "All FX" and selectedFolder ~= "Unsorted" and selectedFolder ~= "My Folders" then
    parentSelection = selectedFolder
    path = selectedFolder .. "/" .. path
  end
  local cur = ""
  for _, part in ipairs(split(path, "/")) do
    cur = cur == "" and part or (cur .. "/" .. part)
    savedFolders[cur] = true
  end
  saveFolders(savedFolders)
  -- Select the new folder and reveal it in place; never reset the tree to row 1.
  selectedFolder = path
  selectedManufacturer = nil
  ensureAncestorsExpanded(path)
  expandedFolders[path] = true
  pendingFolderReveal = path
  selectedFX, scroll = 1, 0
  status = "Folder created: " .. path
  return path
end

local function removeFromFolder(fx)
  if not fx then status = "Select a plugin first."; return end
  local paths = assignedPaths(fx.key)
  if #paths == 0 then
    status = fx.name .. " is not assigned to a custom folder."
    return
  end
  local removePath = hasFolderAssignment(fx.key, selectedFolder) and selectedFolder or paths[1]
  local kept = {}
  for _, path in ipairs(paths) do if path ~= removePath then kept[#kept+1] = path end end
  storeAssignedPaths(fx.key, kept)
  saveMap(folderMap)
  status = "Removed from folder " .. removePath .. ": " .. fx.name
end

local function draw()
  winW, winH = gfx.w, gfx.h
  leftW = math.max(150, math.min(leftW, winW - 420))
  listW = math.max(300, winW - leftW - 38)
  listH = math.max(150, winH - 180)
  listX, listY = 14, 118
  local rightX = 24 + leftW
  local dividerX = 18 + leftW
  color(0.105,0.115,0.13,1); gfx.rect(0,0,winW,winH,1)
  text(14,10,"REAPER NESTED FX BROWSER",1,0.86,0.48)
  text(14,34,"Read-only inventory; folder assignments are saved separately. No network/rescan functions.",0.72,0.77,0.80)
  button(winW-124,8,110,24,"Color: " .. currentTheme)

  -- Search and compact format menu in the top bar.
  local searchW = math.max(150, winW - 700)
  color(0.07,0.08,0.09,1); gfx.rect(14,58,searchW,28,1)
  color(searchFocused and 0.70 or 0.35, searchFocused and 0.62 or 0.38, searchFocused and 0.30 or 0.40,1); gfx.rect(14,58,searchW,28,0)
  text(22,64,(search == "" and not searchFocused) and "Search..." or search, (search == "" and not searchFocused) and 0.55 or 0.96, (search == "" and not searchFocused) and 0.58 or 0.96, (search == "" and not searchFocused) and 0.60 or 0.96)
  if searchFocused and cursorVisible then
    local cx = 22 + gfx.measurestr(search)
    local fieldRight = 14 + searchW - 5
    if cx > fieldRight then cx = fieldRight end
    color(0.98,0.88,0.48,1); gfx.rect(cx,62,2,19,1)
  end
  button(winW-486,58,90,28,"FX On/Off")
  button(winW-390,58,70,28,"Clear")
  button(winW-314,58,96,28,"Assign")
  button(winW-212,58,96,28,"Delete Folder")
  button(winW-110,58,96,28,"Create")

  text(14,94,"Library",0.72,0.80,0.88)
  text(rightX+7,94,"Plugins",0.72,0.80,0.88)
  color(0.07,0.08,0.09,1); gfx.rect(14,114,leftW,listH+4,1); gfx.rect(rightX,114,winW-rightX-14,listH+4,1)
  color(0.27,0.30,0.32,1); gfx.rect(14,114,leftW,listH+4,0); gfx.rect(rightX,114,winW-rightX-14,listH+4,0)
  color(0.40,0.43,0.46,1); gfx.rect(dividerX,114,4,listH+4,1)

  local folders = allFolders()
  local customPaths = {}
  for _, f in ipairs(folders) do if f ~= "All FX" and f ~= "Unsorted" then customPaths[#customPaths+1] = f end end
  local manufacturers = getManufacturers()
  local treeRows = {}
  treeRows[#treeRows+1] = {kind="folder", value="All FX", label="All FX", depth=0}
  treeRows[#treeRows+1] = {kind="folder", value="Unsorted", label="Unsorted", depth=0}
  treeRows[#treeRows+1] = {kind="manufacturerHeader", value="Manufacturers", label="Manufacturers", depth=0, hasKids=#manufacturers>0}
  if manufacturersExpanded then
    -- Only manufacturer names live in the left tree. Their plugins appear on the right.
    for _, m in ipairs(manufacturers) do
      treeRows[#treeRows+1] = {kind="manufacturer", value=m, label=m, depth=1}
    end
  end
  treeRows[#treeRows+1] = {kind="customHeader", value="My Folders", label="My Folders", depth=0, hasKids=true}
  local customExpanded = true
  if customExpanded then
    for _, path in ipairs(customPaths) do
      local show = true
      local parent = path:match("^(.*)/[^/]+$")
      while parent do
        if not expandedFolders[parent] then show = false; break end
        parent = parent:match("^(.*)/[^/]+$")
      end
      if show then
        local depth = select(2, path:gsub("/", "")) + 1
        treeRows[#treeRows+1] = {kind="folder", value=path, label=path:match("([^/]+)$"), depth=depth, hasKids=hasChildren(path, folders)}
      end
    end
  end
  local folderRowH = 22
  local folderViewH = listH
  local maxFolderRows = math.max(1, math.floor((folderViewH - 12) / folderRowH))
  if pendingFolderReveal then
    for idx, treeItem in ipairs(treeRows) do
      if treeItem.kind == "folder" and treeItem.value == pendingFolderReveal then
        if idx <= folderScroll then
          folderScroll = idx - 1
        elseif idx > folderScroll + maxFolderRows then
          folderScroll = idx - maxFolderRows
        end
        break
      end
    end
    pendingFolderReveal = nil
  end
  local maxFolderScroll = math.max(0, #treeRows - maxFolderRows)
  folderScroll = math.max(0, math.min(folderScroll, maxFolderScroll))
  local fy = 122
  if gfx.setclip then gfx.setclip(14,114,leftW,listH+4) end
  for fi = folderScroll + 1, math.min(#treeRows, folderScroll + maxFolderRows) do
    local item = treeRows[fi]
    local depth = item.depth or 0
    local indent = depth * 13
    local isSelected = (item.kind == "folder" and item.value == selectedFolder and not selectedManufacturer)
      or (item.kind == "customHeader" and selectedFolder == "My Folders" and not selectedManufacturer)
      or (item.kind == "manufacturer" and item.value == selectedManufacturer)
     
    if isSelected then color(0.22,0.31,0.38,1); gfx.rect(18,fy-2,leftW-4,20,1) end
    if item.kind == "manufacturerHeader" then
      text(21,fy,manufacturersExpanded and "−" or "+",0.96,0.82,0.42)
      text(39,fy,item.label,0.96,0.88,0.68)
      rows[#rows+1] = {kind="manufacturerHeader", value=item.value, x=18, y=fy-2, w=leftW-34, h=20}
    elseif item.kind == "customHeader" then
      text(21,fy,"▾",0.96,0.82,0.42); text(39,fy,item.label,0.96,0.88,0.68)
      rows[#rows+1] = {kind="customHeader", value=item.value, x=18, y=fy-2, w=leftW-34, h=20}
    elseif item.kind == "manufacturer" then
      fitText(39+indent,fy,item.label,leftW-(39+indent)-12,selectedManufacturer == item.value and 1 or 0.82,0.86,0.90)
      rows[#rows+1] = {kind="manufacturer", value=item.value, x=18+indent, y=fy-2, w=leftW-35-indent, h=20}
    elseif item.kind == "folder" then
      if item.hasKids then
        text(21+indent,fy,expandedFolders[item.value] and "−" or "+",0.96,0.82,0.42)
        rows[#rows+1] = {kind="toggleFolder", value=item.value, x=18+indent, y=fy-2, w=16, h=20}
      end
      fitText(39+indent,fy,item.label,leftW-(39+indent)-12, item.value == selectedFolder and not selectedManufacturer and 1 or 0.82, item.value == selectedFolder and not selectedManufacturer and 0.91 or 0.85, item.value == selectedFolder and not selectedManufacturer and 0.55 or 0.88)
      rows[#rows+1] = {kind="folder", value=item.value, x=18+indent, y=fy-2, w=leftW-35-indent, h=20}
    end
    fy = fy + 22
  end
  if gfx.setclip then gfx.setclip(0,0,winW,winH) end

  -- Independent visible, draggable scrollbar for the left Manufacturers/My Folders tree.
  local treeSBX, treeSBY, treeSBW, treeSBH = 14 + leftW - 13, 122, 10, math.max(40, listH - 12)
  color(0.08,0.09,0.10,1); gfx.rect(treeSBX,treeSBY,treeSBW,treeSBH,1)
  color(0.32,0.35,0.38,1); gfx.rect(treeSBX,treeSBY,treeSBW,treeSBH,0)
  local treeMaxScroll = math.max(0, #treeRows - maxFolderRows)
  folderScroll = math.max(0, math.min(folderScroll, treeMaxScroll))
  local treeThumbH = math.max(28, math.floor(treeSBH * math.min(1, maxFolderRows / math.max(1,#treeRows))))
  local treeThumbY = treeSBY + (treeMaxScroll > 0 and math.floor((treeSBH-treeThumbH) * folderScroll / treeMaxScroll) or 0)
  color(draggingFolderScrollbar and 0.98 or 0.60, draggingFolderScrollbar and 0.78 or 0.64, draggingFolderScrollbar and 0.30 or 0.68,1)
  gfx.rect(treeSBX+1,treeThumbY,treeSBW-2,treeThumbH,1)
  rows[#rows+1] = {kind="folderScrollbar", value={x=treeSBX,y=treeSBY,w=treeSBW,h=treeSBH,thumbY=treeThumbY,thumbH=treeThumbH,maxScroll=treeMaxScroll}, x=treeSBX-2,y=treeSBY,w=treeSBW+4,h=treeSBH}

  if draggingFolder and dragFolder then
    for _, row in ipairs(rows) do
      if row.kind == "folder" and row.value ~= "All FX" and row.value ~= "Unsorted"
        and gfx.mouse_x >= row.x and gfx.mouse_x <= row.x+row.w and gfx.mouse_y >= row.y and gfx.mouse_y <= row.y+row.h then
        color(0.58,0.40,0.14,0.85); gfx.rect(row.x,row.y,row.w,row.h,1)
        color(1,0.88,0.56,1); gfx.rect(row.x,row.y,row.w,row.h,0)
      end
    end
    color(1,0.82,0.40,1)
    text(math.min(gfx.mouse_x+12,winW-240), math.max(96,math.min(gfx.mouse_y+10,winH-35)), "↳ Folder: " .. pathBase(dragFolder))
  end

  if dragging and dragFX then
    -- Highlight the exact custom folder under the pointer as visual drop feedback.
    for _, row in ipairs(rows) do
      if row.kind == "folder" and row.value ~= "All FX" and row.value ~= "Unsorted" and gfx.mouse_x >= row.x and gfx.mouse_x <= row.x+row.w and gfx.mouse_y >= row.y and gfx.mouse_y <= row.y+row.h then
        color(0.65,0.42,0.12,0.85); gfx.rect(row.x,row.y,row.w,row.h,1)
        color(1,0.9,0.62,1); gfx.rect(row.x,row.y,row.w,row.h,0)
        dragTarget = row.value
      end
    end
    color(1,0.78,0.28,0.95)
    text(math.min(gfx.mouse_x+14,winW-260),math.max(94,math.min(gfx.mouse_y+12,winH-72)),"↳ " .. dragFX.name,1,0.82,0.36)
  end

  local visible = currentRows()
  if selectedFX > #visible then selectedFX = math.max(1, #visible) end
  if selectedFX < 1 then selectedFX = 1 end

  -- The right pane is a plugin list only. Folder hierarchy belongs exclusively
  -- in the left tree, where each parent folder can be expanded/collapsed.
  local displayRows = {}
  for n, fx in ipairs(visible) do
    displayRows[#displayRows+1] = {kind="pluginEntry", fx=fx, pluginIndex=n}
  end

  text(rightX+7,94,(selectedManufacturer and (selectedManufacturer .. " — ") or "") .. ("Plugins (%d)"):format(#visible),0.72,0.80,0.88)
  local start = math.max(1, scroll + 1)
  local maxRows = math.floor((listH - 12) / rowHeight)
  if start > math.max(1,#displayRows-maxRows+1) then start = math.max(1,#displayRows-maxRows+1) end
  for n = start, math.min(#displayRows, start + maxRows - 1) do
    local y = listY + 7 + (n-start)*rowHeight
    local entry = displayRows[n]
    local fx = entry.fx
    local pluginIndex = entry.pluginIndex
    local isSelected = selectedFXKeys[fx.key] or (not selectionCleared and next(selectedFXKeys) == nil and pluginIndex == selectedFX)
    if isSelected then color(0.22,0.31,0.38,1); gfx.rect(rightX+4,y-2,winW-rightX-22,rowHeight,1) end
    if gfx.setclip then gfx.setclip(rightX+8,y-2,math.max(40,winW-rightX-20),rowHeight) end
    fitText(rightX+10,y,fx.name,math.max(40, math.floor((winW-rightX)*0.55)-14), isSelected and 1 or 0.88, isSelected and 0.91 or 0.89, isSelected and 0.58 or 0.90)
    if gfx.setclip then gfx.setclip(0,0,winW,winH) end
    local fmtX = rightX + math.floor((winW-rightX)*0.57)
    text(fmtX,y,fx.format,0.55,0.65,0.72)
    local paths = assignedPaths(fx.key)
    local pathLabel = #paths > 0 and table.concat(paths, ", ") or "—"
    text(rightX + math.floor((winW-rightX)*0.74),y,pathLabel,0.50,0.63,0.68)
    rows[#rows+1] = {kind="plugin", value=fx, index=pluginIndex, x=rightX, y=y-2, w=winW-rightX-32, h=rowHeight}
  end

  -- Visible draggable scrollbar for the right pane.
  local sbX, sbY, sbW, sbH = winW-29, listY+2, 15, listH-7
  color(0.08,0.09,0.10,1); gfx.rect(sbX,sbY,sbW,sbH,1)
  color(0.32,0.35,0.38,1); gfx.rect(sbX,sbY,sbW,sbH,0)
  local maxScroll = math.max(0, #displayRows - maxRows)
  scroll = math.max(0, math.min(scroll, maxScroll))
  local thumbH = math.max(28, math.floor(sbH * math.min(1, maxRows / math.max(1,#displayRows))))
  local thumbY = sbY + (maxScroll > 0 and math.floor((sbH-thumbH) * scroll / maxScroll) or 0)
  color(draggingListScrollbar and 0.98 or 0.60, draggingListScrollbar and 0.78 or 0.64, draggingListScrollbar and 0.30 or 0.68,1)
  gfx.rect(sbX+1,thumbY,sbW-2,thumbH,1)
  rows[#rows+1] = {kind="listScrollbar", value={x=sbX,y=sbY,w=sbW,h=sbH,thumbY=thumbY,thumbH=thumbH,maxScroll=maxScroll}, x=sbX-2,y=sbY,w=sbW+4,h=sbH}

  if contextMenu then
    color(0.12,0.13,0.15,1); gfx.rect(contextMenu.x,contextMenu.y,190,50,1)
    color(0.50,0.53,0.56,1); gfx.rect(contextMenu.x,contextMenu.y,190,50,0)
    text(contextMenu.x+8,contextMenu.y+7,"Remove from folder",0.95,0.95,0.95)
    text(contextMenu.x+8,contextMenu.y+29,"Move to folder...",0.95,0.95,0.95)
  end

  -- Draw the dropdown last so it is not covered by the library/list panels.
  if formatMenuOpen then
    local fmX, fmY, fmW, fmH = winW-486, 88, 156, 7*24+10
    color(0.09,0.10,0.12,1); gfx.rect(fmX,fmY,fmW,fmH,1)
    color(0.50,0.53,0.56,1); gfx.rect(fmX,fmY,fmW,fmH,0)
    local formats = {"AU","VST","VST3","CLAP","JSFX","LV2","DX"}
    for i, fmt in ipairs(formats) do
      local yy = fmY + 5 + (i-1)*24
      color(0.74,0.77,0.79,1); gfx.rect(fmX+10,yy+2,12,12,0)
      if formatEnabled[fmt] then color(0.98,0.79,0.30,1); gfx.rect(fmX+13,yy+5,6,6,1) end
      text(fmX+34,yy,fmt,0.92,0.93,0.95)
      rows[#rows+1] = {kind="formatToggle", value=fmt, x=fmX+2, y=yy-3, w=fmW-4, h=23}
    end
  end

  if themeMenuOpen then
    local tmX, tmY, tmW, tmH = winW-180, 35, 166, 135
    color(0.09,0.10,0.12,1); gfx.rect(tmX,tmY,tmW,tmH,1)
    color(0.50,0.53,0.56,1); gfx.rect(tmX,tmY,tmW,tmH,0)
    for i, name in ipairs(themeNames) do
      local yy = tmY + 5 + (i-1)*25
      if name == currentTheme then
        color(0.22,0.31,0.38,1); gfx.rect(tmX+3,yy-2,tmW-6,23,1)
      end
      text(tmX+12,yy,name,0.92,0.93,0.95)
      rows[#rows+1] = {kind="themeChoice", value=name, x=tmX+2, y=yy-3, w=tmW-4, h=24}
    end
  end

  -- Visible splitter handle: drag left/right to resize the manufacturer/folder column.
  color(0.48,0.52,0.55,1); gfx.rect(dividerX,114,4,listH+4,1)

  color(0.07,0.08,0.09,1); gfx.rect(14,winH-50,winW-28,28,1)
  text(20,winH-43,status,0.72,0.86,0.78)
  text(14,winH-22,"Double-click: add selected plugins. Ctrl/Command-click: multi-select. Drag selected plugins to a folder. Drag divider to resize left pane.",0.62,0.69,0.72)
end

local mouseWasDown = false
local rightMouseWasDown = false
local clickTime, clickX, clickY = 0, -100, -100
local function saveGeometry()
  local ok, dockState, x, y, w, h = pcall(gfx.dock, -1)
  if ok and type(w) == "number" and type(h) == "number" and w >= 300 and h >= 200 then
    reaper.SetExtState(SECTION, GEOMETRY_KEY, table.concat({math.floor(w), math.floor(h), math.floor(x or 0), math.floor(y or 0), math.floor(dockState or 0), math.floor(leftW or 210)}, "|"), true)
  else
    reaper.SetExtState(SECTION, GEOMETRY_KEY, table.concat({math.floor(gfx.w or winW), math.floor(gfx.h or winH), 0, 0, 0, math.floor(leftW or 210)}, "|"), true)
  end
end

local function cleanup()
  saveGeometry()
  saveUIState()
  gfx.quit()
  reaper.SetExtState(SECTION, RUN_KEY, "", false)
  reaper.SetExtState(SECTION, CLOSE_KEY, "", false)
end

reaper.atexit(function()
  saveGeometry()
  saveUIState()
  reaper.SetExtState(SECTION, RUN_KEY, "", false)
  reaper.SetExtState(SECTION, CLOSE_KEY, "", false)
end)

local function loop()
  if reaper.GetExtState(SECTION, CLOSE_KEY) == "1" then cleanup(); return end
  local char = gfx.getchar()
  if char < 0 or char == 27 then cleanup(); return end

  local now = reaper.time_precise()
  if now - lastCursorBlink >= 0.5 then cursorVisible = not cursorVisible; lastCursorBlink = now end
  rows = {}
  dragTarget = nil
  draw()

  local cap = gfx.mouse_cap
  local down = (cap & 1) == 1
  if down and not mouseWasDown then
    for _, row in ipairs(rows) do
      if (row.kind == "listScrollbar" or row.kind == "folderScrollbar") and gfx.mouse_x >= row.x and gfx.mouse_x <= row.x+row.w and gfx.mouse_y >= row.y and gfx.mouse_y <= row.y+row.h then
        local info = row.value
        local relative = gfx.mouse_y - info.y - info.thumbH/2
        local ratio = math.max(0, math.min(1, relative / math.max(1, info.h-info.thumbH)))
        if row.kind == "listScrollbar" then
          draggingListScrollbar = true
          scroll = math.floor(ratio * info.maxScroll + 0.5)
        else
          draggingFolderScrollbar = true
          folderScroll = math.floor(ratio * info.maxScroll + 0.5)
        end
        break
      end
    end
  end
  if down and (draggingListScrollbar or draggingFolderScrollbar) then
    local wanted = draggingListScrollbar and "listScrollbar" or "folderScrollbar"
    local info = nil
    for _, row in ipairs(rows) do if row.kind == wanted then info = row.value; break end end
    if info then
      local relative = gfx.mouse_y - info.y - info.thumbH/2
      local ratio = math.max(0, math.min(1, relative / math.max(1, info.h-info.thumbH)))
      local value = math.floor(ratio * info.maxScroll + 0.5)
      if draggingListScrollbar then scroll = value else folderScroll = value end
    end
  elseif not down and mouseWasDown then
    draggingListScrollbar = false
    draggingFolderScrollbar = false
  end
  if down and not mouseWasDown and math.abs(gfx.mouse_x - (18 + leftW)) <= 7 and gfx.mouse_y >= 114 and gfx.mouse_y <= 114 + listH + 4 then
    resizingDivider = true
  end
  if down and resizingDivider then
    leftW = math.max(150, math.min(winW - 420, gfx.mouse_x - 18))
  elseif not down and mouseWasDown and resizingDivider then
    resizingDivider = false
  end
  if down and not mouseWasDown and not resizingDivider and not draggingListScrollbar and not draggingFolderScrollbar then
    local mx,my = gfx.mouse_x,gfx.mouse_y
    dragFX, dragging, dragStartX, dragStartY = nil, false, mx, my
    dragFolder, draggingFolder = nil, false
    if themeMenuOpen then
      local themeHit = nil
      for _, row in ipairs(rows) do
        if row.kind == "themeChoice" and mx >= row.x and mx <= row.x+row.w and my >= row.y and my <= row.y+row.h then themeHit = row.value; break end
      end
      if themeHit then
        currentTheme = themeHit
        reaper.SetExtState(SECTION, THEME_KEY, currentTheme, true)
        status = "Color theme: " .. currentTheme
      end
      themeMenuOpen = false
    elseif contextMenu then
      if mx >= contextMenu.x and mx <= contextMenu.x+190 and my >= contextMenu.y and my <= contextMenu.y+50 then
        local fx = contextMenu.fx
        if my < contextMenu.y+25 then
          removeFromFolder(fx)
        else
          local paths = assignedPaths(fx.key)
          local current = hasFolderAssignment(fx.key, selectedFolder) and selectedFolder or (paths[1] or "")
          local path = promptFolder(current)
          if path then assignToFolder(fx, path) end
        end
      end
      contextMenu = nil
    elseif formatMenuOpen and my >= 88 and my <= 88+7*24+10 and mx >= winW-486 and mx <= winW-330 then
      local index = math.floor((my - 90) / 24) + 1
      local formats = {"AU","VST","VST3","CLAP","JSFX","LV2","DX"}
      local fmt = formats[index]
      if fmt then formatEnabled[fmt] = not formatEnabled[fmt]; saveFormatState(); status = fmt .. (formatEnabled[fmt] and " shown" or " hidden") end
    elseif my >= 8 and my <= 32 and mx >= winW-124 and mx <= winW-14 then
      themeMenuOpen = not themeMenuOpen
      formatMenuOpen = false
      searchFocused = false
    elseif my >= 58 and my <= 86 and mx >= winW-486 and mx <= winW-396 then
      formatMenuOpen = not formatMenuOpen; searchFocused = false
    elseif my >= 58 and my <= 86 and mx >= 14 and mx <= 14+math.max(150,winW-700) then
      searchFocused = true
      cursorVisible = true; lastCursorBlink = reaper.time_precise()
    elseif my >= 58 and my <= 86 and mx >= winW-390 and mx <= winW-320 then
      search = ""; searchFocused = true; status = "Search cleared."
    elseif my >= 58 and my <= 86 and mx >= winW-314 and mx <= winW-218 then
      local fx = currentRows()[selectedFX]
      if fx then
        local paths = assignedPaths(fx.key)
        local current = hasFolderAssignment(fx.key, selectedFolder) and selectedFolder or (paths[1] or "")
        local path = promptFolder(current ~= "" and current or selectedFolder ~= "All FX" and selectedFolder ~= "Unsorted" and selectedFolder or "")
        if path then assignToFolder(fx, path) end
      else status = "Select a plugin first." end
    elseif my >= 58 and my <= 86 and mx >= winW-212 and mx <= winW-116 then
      if selectedFolder == "All FX" or selectedFolder == "Unsorted" or selectedFolder == "My Folders" then
        status = "Select a custom folder in My Folders to delete it."
      else
        local answer = reaper.ShowMessageBox("Delete the custom folder '" .. selectedFolder .. "' and its subfolders?\n\nPlugin assignments in those folders will be cleared. Installed plugins will not be deleted.", "Delete custom folder", 4)
        if answer == 6 then
          local prefix = selectedFolder .. "/"
          for key in pairs(folderMap) do
            local kept = {}
            for _, path in ipairs(assignedPaths(key)) do
              if not (path == selectedFolder or path:sub(1, #prefix) == prefix) then kept[#kept+1] = path end
            end
            storeAssignedPaths(key, kept)
          end
          for path in pairs(savedFolders) do
            if path == selectedFolder or path:sub(1, #prefix) == prefix then savedFolders[path] = nil end
          end
          saveMap(folderMap); saveFolders(savedFolders)
          local newOrder = {}
          for _, path in ipairs(folderOrder) do
            if path ~= selectedFolder and path:sub(1, #prefix) ~= prefix then newOrder[#newOrder+1] = path end
          end
          folderOrder = newOrder; saveFolderOrder()
          status = "Deleted custom folder and its subfolders: " .. selectedFolder
          selectedFolder = "My Folders"; selectedManufacturer = nil
          expandedFolders[selectedFolder] = true
        end
      end
    elseif my >= 58 and my <= 86 and mx >= winW-110 and mx <= winW-14 then
      local path = promptFolder("")
      if path then createFolderFromInput(path) end
    else
      if formatMenuOpen and not (mx >= winW-486 and mx <= winW-330 and my >= 88 and my <= 88+7*24+10) then formatMenuOpen = false end
      local clickedRow = false
      for _, row in ipairs(rows) do
        if mx >= row.x and mx <= row.x+row.w and my >= row.y and my <= row.y+row.h then
          clickedRow = true
          if row.kind == "formatToggle" then
            formatEnabled[row.value] = not formatEnabled[row.value]; saveFormatState()
          elseif row.kind == "manufacturerHeader" then
            manufacturersExpanded = not manufacturersExpanded
          elseif row.kind == "customHeader" then
            selectedFolder = "My Folders"
            selectedManufacturer = nil
            clearSelectionExcept(nil)
            selectedFX = 1; scroll = 0
            status = "My Folders selected. Create Folder makes a top-level folder here."
          elseif row.kind == "manufacturer" then
            selectedManufacturer = row.value
            selectedFolder = "All FX"
            -- Selecting a vendor filters the right pane; it never expands plugin rows on the left.
            -- Preserve selected plugin keys and right-pane scroll while browsing the tree.
          elseif row.kind == "toggleFolder" then
            expandedFolders[row.value] = not expandedFolders[row.value]
            -- draw() clamps folderScroll against the newly visible tree on the next frame.
          elseif row.kind == "folder" then
            selectedFolder = row.value
            selectedManufacturer = nil
            if row.value ~= "All FX" and row.value ~= "Unsorted" then dragFolder = row.value end
            -- Preserve selected plugin keys and list position across tree navigation.
          elseif row.kind == "folderEntry" then
            selectedFolder = row.value
            selectedManufacturer = nil
            ensureAncestorsExpanded(selectedFolder)
            scroll = 0
            status = "Folder selected: " .. selectedFolder
          elseif row.kind == "plugin" then
            local multi = modifierHeld(cap)
            local shift = (cap & 8) == 8
            local visible = currentRows()
            if shift then
              -- Shift-range selection is additive when there is already a selection,
              -- so plugins previously added with Ctrl/Command are preserved.
              local additiveRange = multi or next(selectedFXKeys) ~= nil
              selectRange(visible, row.index, additiveRange)
              clickTime = 0
            elseif multi then
              toggleSelection(row.value.key)
              selectionAnchorKey = row.value.key
              clickTime = 0
            else
              if not selectedFXKeys[row.value.key] then clearSelectionExcept(row.value.key) end
              selectionAnchorKey = row.value.key
            end
            selectedFX = row.index
            dragFX = row.value
            dragStartX, dragStartY = mx, my
            if not multi and not shift then
              local clickNow = reaper.time_precise()
              if math.abs(clickX - mx) < 8 and math.abs(clickY - my) < 8 and (clickNow - clickTime) < 0.45 then addSelected(); clickTime = 0
              else clickTime,clickX,clickY = clickNow,mx,my end
            end
          end
          break
        end
      end
      if not clickedRow then
        -- Clicking empty space clears the plugin selection without interfering with drag start.
        clearSelectionExcept(nil)
      end
    end
  end
  if down and dragFolder and not draggingFolder then
    if math.abs(gfx.mouse_x - dragStartX) >= 6 or math.abs(gfx.mouse_y - dragStartY) >= 6 then
      draggingFolder = true
      searchFocused = false
    end
  end

  if down and dragFX and not dragging then
    if math.abs(gfx.mouse_x - dragStartX) >= 6 or math.abs(gfx.mouse_y - dragStartY) >= 6 then
      dragging = true
      searchFocused = false
    end
  end
  if not down and mouseWasDown then
    if draggingFolder and dragFolder then
      local mx,my = gfx.mouse_x,gfx.mouse_y
      local targetRow = nil
      for _, row in ipairs(rows) do
        if (row.kind == "folder" or row.kind == "customHeader") and mx >= row.x and mx <= row.x+row.w and my >= row.y and my <= row.y+row.h then
          targetRow = row; break
        end
      end
      if targetRow and targetRow.kind == "customHeader" then
        moveFolderPath(dragFolder, nil, "root")
      elseif targetRow and targetRow.value ~= "All FX" and targetRow.value ~= "Unsorted" and targetRow.value ~= dragFolder then
        local relative = (my - targetRow.y) / math.max(1, targetRow.h)
        local mode = relative < 0.28 and "before" or (relative > 0.72 and "after" or "inside")
        moveFolderPath(dragFolder, targetRow.value, mode)
      elseif not targetRow then
        status = "Drop on a folder to nest/reorder, or on My Folders to pull it to the top level."
      else
        status = "Choose a different folder as the destination."
      end
      dragFolder, draggingFolder = nil, false
    elseif dragging and dragFX then
      local mx,my = gfx.mouse_x,gfx.mouse_y
      local target = nil
      for _, row in ipairs(rows) do
        if row.kind == "folder" and mx >= row.x and mx <= row.x+row.w and my >= row.y and my <= row.y+row.h then
          target = row.value
          break
        end
      end
      if target and target ~= "All FX" and target ~= "Unsorted" then
        local targets = {}
        for _, fx in ipairs(fxList) do if selectedFXKeys[fx.key] then targets[#targets+1] = fx end end
        if #targets == 0 then targets[1] = dragFX end
        local added = 0
        for _, fx in ipairs(targets) do
          if addFolderAssignment(fx, target) then added = added + 1 end
        end
        status = ("Added %d plugin(s) to %s; existing folder assignments kept"):format(added, target)
      elseif target then
        status = "Drop onto a custom folder, not All FX/Unsorted."
      else
        status = "Drag cancelled — drop the plugin on a folder name."
      end
    end
    dragFX, dragging = nil, false
    if not draggingFolder then dragFolder = nil end
  end
  mouseWasDown = down
  local rightDown = (cap & 2) == 2
  if rightDown and not rightMouseWasDown then
    local mx,my = gfx.mouse_x,gfx.mouse_y
    local hit = nil
    for _, row in ipairs(rows) do
      if row.kind == "plugin" and mx >= row.x and mx <= row.x+row.w and my >= row.y and my <= row.y+row.h then
        hit = row.value
        selectedFX = row.index
        break
      end
    end
    if hit then
      contextMenu = {x=math.min(mx, winW-195), y=math.min(my, winH-56), fx=hit}
      status = "Plugin menu: " .. hit.name
    else
      contextMenu = nil
    end
  end
  rightMouseWasDown = rightDown

  -- Keyboard: type to search; Backspace removes; Enter adds selected; printable ASCII appends.
  local c = char
  if c == 27 then searchFocused = false; contextMenu = nil
  elseif (c == 8 or c == 127) and searchFocused then search = search:sub(1, math.max(0,#search-1)); cursorVisible = true; lastCursorBlink = reaper.time_precise()
  elseif c == 1 and searchFocused then search = ""; cursorVisible = true; lastCursorBlink = reaper.time_precise()
  elseif c == 13 then searchFocused = false; addSelected()
  elseif c == 30064 and searchFocused then search = ""
  elseif c == 1818584692 then -- F2: assign/move selected plugin
    local fx = currentRows()[selectedFX]
    if fx then
      local paths = assignedPaths(fx.key)
      local current = hasFolderAssignment(fx.key, selectedFolder) and selectedFolder or (paths[1] or "")
      local path = promptFolder(current)
      if path then assignToFolder(fx, path) end
    end
  elseif c >= 32 and c <= 126 and searchFocused then search = search .. string.char(c); cursorVisible = true; lastCursorBlink = reaper.time_precise()
  elseif c == 30065 then scroll = math.max(0,scroll-1)
  elseif c == 30066 then scroll = scroll+1
  end

  if gfx.mouse_wheel ~= 0 then
    if gfx.mouse_x < (14 + leftW) then
      folderScroll = math.max(0, folderScroll - (gfx.mouse_wheel > 0 and 3 or -3))
    else
      scroll = math.max(0, scroll - (gfx.mouse_wheel > 0 and 3 or -3))
    end
    gfx.mouse_wheel = 0
  end

  gfx.update()
  reaper.defer(loop)
end

local geometry = reaper.GetExtState(SECTION, GEOMETRY_KEY)
if geometry ~= "" then
  local parts = split(geometry, "|")
  local gw, gh, gx, gy, gd, gl = tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4]), tonumber(parts[5]), tonumber(parts[6])
  if gw and gh and gw >= 700 and gh >= 420 then winW, winH = gw, gh end
  if gl and gl >= 150 and gl <= 700 then leftW = gl end
  gfx.init("REAPER Nested FX Browser v9 — worker (use launcher)", winW, winH, gd or 0, gx or 0, gy or 0)
else
  gfx.init("REAPER Nested FX Browser v9 — worker (use launcher)", winW, winH, 0)
end
gfx.setfont(1, "Arial", 15)
loop()
