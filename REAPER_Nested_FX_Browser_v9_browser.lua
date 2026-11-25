-- REAPER Nested FX Browser — fixed
-- Uses REAPER's existing FX inventory. No network, no rescan, no plugin loading until Add.
-- Browser data is stored in a private sidecar file beside this script; REAPER settings/projects are not used for persistence.
-- Folder paths use "/" separators, e.g. Delay/Waves or Delay/Valhalla.
-- Requires a REAPER version exposing EnumInstalledFX and TrackFX_AddByName.

local SECTION = "VSoundNestedFXBrowser"
local RUN_KEY = "running_v9"
local CLOSE_KEY = "close_request_v9"
-- Run this script directly from REAPER's Actions list. Running it again closes the open browser.
if reaper.GetExtState(SECTION, RUN_KEY) == "1" then
  reaper.SetExtState(SECTION, CLOSE_KEY, "1", false)
  return
end
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

-- All persistent browser data is stored in a private sidecar file, not in REAPER ExtState.
-- Keep REAPER_Nested_FX_Folder_Storage.lua beside this browser script.
local scriptSource = debug.getinfo(1, "S").source or ""
local scriptPath = scriptSource:sub(1, 1) == "@" and scriptSource:sub(2) or ""
local scriptDir = scriptPath:match("^(.*[\\/])")
if not scriptDir then
  reaper.ShowMessageBox("Could not determine the browser script folder. Save the browser as a Lua file before running it.", "Nested FX Browser", 0)
  return
end
local storagePath = scriptDir .. "REAPER_Nested_FX_Folder_Storage.lua"
local storageOK, FolderStorage = pcall(dofile, storagePath)
if not storageOK or type(FolderStorage) ~= "table"
  or type(FolderStorage.loadMap) ~= "function"
  or type(FolderStorage.loadFolders) ~= "function"
  or type(FolderStorage.loadFolderOrder) ~= "function"
  or type(FolderStorage.getSetting) ~= "function"
  or type(FolderStorage.setSetting) ~= "function" then
  reaper.ShowMessageBox(
    "The browser's private storage module could not be loaded:\n\n" .. storagePath ..
    "\n\nKeep both Lua files in the same folder. REAPER settings have not been changed.",
    "Nested FX Browser", 0)
  return
end

-- One-time, read-only import of the old browser data from REAPER ExtState.
-- It preserves existing folders/assignments but never writes anything back to REAPER.
if FolderStorage.needsLegacyImport and FolderStorage.needsLegacyImport() then
  FolderStorage.importLegacy({
    map = reaper.GetExtState(SECTION, "folder_map_v1"),
    folders = reaper.GetExtState(SECTION, "folders_v1"),
    order = reaper.GetExtState(SECTION, "folder_order_v1"),
    settings = {
      formats_v1 = reaper.GetExtState(SECTION, "formats_v1"),
      ui_state_v1 = reaper.GetExtState(SECTION, "ui_state_v1"),
      color_theme_v1 = reaper.GetExtState(SECTION, "color_theme_v1"),
      window_geometry_v1 = reaper.GetExtState(SECTION, "window_geometry_v1")
    }
  })
end

local function loadMap() return FolderStorage.loadMap() end
local function loadFolders() return FolderStorage.loadFolders() end
local function loadFolderOrder() return FolderStorage.loadFolderOrder() end
local folderOrder = loadFolderOrder()
-- Revisions invalidate derived browser data only when folder assignments or
-- folder definitions actually change, not on every gfx/defer pass.
local folderDataRevision = 0
local function saveFolderOrder() FolderStorage.saveFolderOrder(folderOrder); folderDataRevision = folderDataRevision + 1 end

local function saveFolders(set)
  local known, seen, ordered = {}, {}, {}
  for path in pairs(set or {}) do if path ~= "" then known[path] = true end end
  for _, path in ipairs(folderOrder or {}) do
    if known[path] and not seen[path] then ordered[#ordered + 1] = path; seen[path] = true end
  end
  local missing = {}
  for path in pairs(known) do if not seen[path] then missing[#missing + 1] = path end end
  table.sort(missing, function(a, b)
    local da, db = select(2, a:gsub("/", "")), select(2, b:gsub("/", ""))
    if da ~= db then return da < db end
    return a:lower() < b:lower()
  end)
  for _, path in ipairs(missing) do ordered[#ordered + 1] = path end
  folderOrder = FolderStorage.saveFolders(set, ordered)
  folderDataRevision = folderDataRevision + 1
end

local function saveMap(map)
  FolderStorage.saveMap(map)
  folderDataRevision = folderDataRevision + 1
end

reaper.SetExtState(SECTION, RUN_KEY, "1", false)
reaper.SetExtState(SECTION, CLOSE_KEY, "", false)

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

local function getManufacturer(name, ident, format)
  -- JSFX names often contain author/effect annotations in parentheses. Those
  -- are not reliable vendor metadata, so JSFX are deliberately kept out of
  -- the automatically generated Manufacturers tree.
  if format == "JSFX" then return "Other / Unknown" end

  local function validVendor(v)
    if not v then return nil end
    v = trim(v):gsub("^%s+", ""):gsub("%s+$", "")
    if v == "" or #v < 2 then return nil end
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
      local format = getFormat(ident, name)
      fx[#fx + 1] = {name = name, ident = ident, key = key,
        format = format, manufacturer = getManufacturer(name, ident, format)}
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

-- Older installations may already have folders but no saved manual-order list.
-- Seed the order once from existing data so a newly created folder is appended
-- after the user's current folders instead of being placed first/alphabetically.
do
  local known = {}
  local function addPathAndParents(path)
    local cur = ""
    for _, part in ipairs(split(path, "/")) do
      cur = cur == "" and part or (cur .. "/" .. part)
      known[cur] = true
    end
  end
  for path in pairs(savedFolders) do addPathAndParents(path) end
  for key in pairs(folderMap) do
    for _, path in ipairs(assignedPaths(key)) do addPathAndParents(path) end
  end
  local seen = {}
  for _, path in ipairs(folderOrder) do seen[path] = true end
  local missing = {}
  for path in pairs(known) do if not seen[path] then missing[#missing + 1] = path end end
  table.sort(missing, function(a, b)
    local da = select(2, a:gsub("/", ""))
    local db = select(2, b:gsub("/", ""))
    if da ~= db then return da < db end
    return a:lower() < b:lower()
  end)
  for _, path in ipairs(missing) do folderOrder[#folderOrder + 1] = path end
  if #missing > 0 then saveFolderOrder() end
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
local searchCursor = 0
local searchSelStart, searchSelEnd = nil, nil
local searchMouseSelecting = false

local function searchPositionAtX(mouseX)
  local relX = math.max(0, mouseX - 22)
  local pos = #search
  for i = 1, #search do
    if gfx.measurestr(search:sub(1, i)) >= relX then
      pos = i - 1
      break
    end
  end
  return math.max(0, math.min(#search, pos))
end
local cursorVisible = true
local lastCursorBlink = 0
local contextMenu = nil
local FOLDER_COLORS_KEY = "folder_colors_v1"
-- Legacy named colors remain readable; new selections are stored as exact RGB hex.
local legacyFolderColors = {
  red={0.96,0.30,0.32}, orange={1.00,0.55,0.20}, yellow={0.98,0.80,0.25},
  green={0.34,0.78,0.48}, teal={0.25,0.78,0.76}, blue={0.35,0.62,1.00},
  purple={0.68,0.48,0.96}, pink={0.98,0.48,0.70}, gray={0.68,0.72,0.77}
}
local folderColors = {}
-- Length-prefixed paths keep arbitrary folder names safe in the sidecar setting.
do
  local raw = FolderStorage.getSetting(FOLDER_COLORS_KEY) or ""
  local pos = 1
  while pos <= #raw do
    local colon = raw:find(":", pos, true)
    if not colon then break end
    local length = tonumber(raw:sub(pos, colon - 1))
    if not length or length < 0 then break end
    local first = colon + 1
    local last = first + length - 1
    if last > #raw then break end
    local path = raw:sub(first, last)
    local nextSep = raw:find("\n", last + 1, true)
    local colorId = raw:sub(last + 1, nextSep and nextSep - 1 or #raw)
    if path ~= "" and colorId ~= "" then folderColors[path] = colorId end
    if not nextSep then break end
    pos = nextSep + 1
  end
end
local function saveFolderColors()
  local paths = {}
  for path in pairs(folderColors) do paths[#paths+1] = path end
  table.sort(paths)
  local parts = {}
  for _, path in ipairs(paths) do
    parts[#parts+1] = tostring(#path) .. ":" .. path .. folderColors[path]
  end
  FolderStorage.setSetting(FOLDER_COLORS_KEY, table.concat(parts, "\n"))
end
local function getFolderColor(path)
  local value = folderColors[path]
  if not value then return nil end
  local rr, gg, bb = tostring(value):match("^#?(%x%x)(%x%x)(%x%x)$")
  if rr then return tonumber(rr,16)/255, tonumber(gg,16)/255, tonumber(bb,16)/255 end
  local legacy = legacyFolderColors[value]
  if legacy then return legacy[1], legacy[2], legacy[3] end
  return nil
end

local function chooseFolderColor(path)
  if not reaper.GR_SelectColor then
    status = "This REAPER build does not expose its native color picker."
    return false
  end
  local r, g, b = getFolderColor(path)
  local initial = (r and reaper.ColorToNative(
    math.floor(r*255+0.5), math.floor(g*255+0.5), math.floor(b*255+0.5))) or 0
  local ok, nativeColor = reaper.GR_SelectColor(gfx.hwnd or reaper.GetMainHwnd(), initial)
  if ok then
    local cr, cg, cb = reaper.ColorFromNative(nativeColor)
    if cr and cg and cb then
      folderColors[path] = ("%02X%02X%02X"):format(cr, cg, cb)
      saveFolderColors()
      status = "Folder color updated: " .. path
      return true
    end
  end
  return false
end
local function remapFolderColorPaths(source, destination, includeChildren)
  local remapped = {}
  for path, id in pairs(folderColors) do
    if path == source or (includeChildren and path:sub(1, #source + 1) == source .. "/") then
      remapped[destination .. path:sub(#source + 1)] = id
    else
      remapped[path] = id
    end
  end
  folderColors = remapped
  saveFolderColors()
end
local formatMenuOpen = false
local formatEnabled = {AU=true, VST=true, VST3=true, CLAP=true, JSFX=true, LV2=true, DX=true}
local rawFormatState = FolderStorage.getSetting("formats_v1") or ""
if rawFormatState ~= "" then
  for _, f in ipairs({"AU","VST","VST3","CLAP","JSFX","LV2","DX"}) do formatEnabled[f] = rawFormatState:find("|" .. f .. "|", 1, true) ~= nil end
end
local function saveFormatState()
  local parts = {"|"}
  for _, f in ipairs({"AU","VST","VST3","CLAP","JSFX","LV2","DX"}) do
    if formatEnabled[f] then parts[#parts+1] = f; parts[#parts+1] = "|" end
  end
  FolderStorage.setSetting("formats_v1", table.concat(parts))
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
  local raw = FolderStorage.getSetting(UI_STATE_KEY) or ""
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
  FolderStorage.setSetting(UI_STATE_KEY, table.concat(parts, "\n"))
end

restoreUIState()

-- Lightweight in-memory navigation history for folder/manufacturer views.
-- It does not alter saved folders, assignments, or REAPER project state.
local viewHistory, viewHistoryIndex = {}, 0
local function pushViewHistory()
  local last = viewHistory[viewHistoryIndex]
  if last and last.folder == selectedFolder and last.manufacturer == selectedManufacturer then return end
  for i = #viewHistory, viewHistoryIndex + 1, -1 do viewHistory[i] = nil end
  viewHistory[#viewHistory + 1] = {
    folder = selectedFolder, manufacturer = selectedManufacturer,
    scroll = scroll, selectedFX = selectedFX
  }
  viewHistoryIndex = #viewHistory
  if #viewHistory > 60 then
    table.remove(viewHistory, 1)
    viewHistoryIndex = #viewHistory
  end
end
pushViewHistory()

local function setBrowserView(folder, manufacturer)
  if folder == selectedFolder and manufacturer == selectedManufacturer then return false end
  local current = viewHistory[viewHistoryIndex]
  if current then current.scroll, current.selectedFX = scroll, selectedFX end
  selectedFolder, selectedManufacturer = folder, manufacturer
  scroll = 0
  pushViewHistory()
  return true
end

local function navigateHistory(direction)
  local current = viewHistory[viewHistoryIndex]
  if current then current.scroll, current.selectedFX = scroll, selectedFX end
  local target = viewHistoryIndex + direction
  if target < 1 or target > #viewHistory then return false end
  viewHistoryIndex = target
  local entry = viewHistory[target]
  selectedFolder, selectedManufacturer = entry.folder, entry.manufacturer
  scroll = math.max(0, entry.scroll or 0)
  selectedFX = math.max(1, entry.selectedFX or 1)
  searchFocused = false
  contextMenu = nil
  status = direction < 0 and "Back: " .. (selectedManufacturer or selectedFolder)
    or "Forward: " .. (selectedManufacturer or selectedFolder)
  return true
end

status = "Loaded " .. #fxList .. " unique entries (deduplicated by identifier)."
local rows = {}
local rowHeight = 23
local listX, listY, listW, listH = 14, 118, 650, 390
local winW, winH = 900, 570
local leftW = 210
local resizingDivider = false
local aboutOpen = false

local allFoldersCache = nil
local allFoldersCacheRevision = -1
local folderChildrenCache = nil
local folderChildrenCacheRevision = -1

local function allFolders()
  if allFoldersCache and allFoldersCacheRevision == folderDataRevision then
    return allFoldersCache
  end
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
  -- folderMap values may contain several assignments separated by ASSIGN_SEP.
  -- Always expand them with assignedPaths(); otherwise the separator can become
  -- part of a folder name and leave phantom entries that cannot be deleted.
  for key in pairs(folderMap) do
    for _, path in ipairs(assignedPaths(key)) do
      if path ~= "" then
        local cur = ""
        for _, part in ipairs(split(path, "/")) do
          cur = cur == "" and part or (cur .. "/" .. part)
          set[cur] = true
        end
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
    -- Compare each pair of sibling folders by the saved manual order first.
    -- Alphabetical order is only a fallback for legacy folders absent from the order list.
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
  allFoldersCache = out
  allFoldersCacheRevision = folderDataRevision
  return allFoldersCache
end

local function hasChildren(path, folders)
  if not folderChildrenCache or folderChildrenCacheRevision ~= folderDataRevision then
    local parents = {}
    for _, folder in ipairs(folders) do
      local parent = folder:match("^(.*)/[^/]+$")
      while parent do
        parents[parent] = true
        parent = parent:match("^(.*)/[^/]+$")
      end
    end
    folderChildrenCache = parents
    folderChildrenCacheRevision = folderDataRevision
  end
  return folderChildrenCache[path] == true
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
  if newPath ~= source then remapFolderColorPaths(source, newPath, true) end
  setBrowserView(newPath, nil)
  ensureAncestorsExpanded(newPath)
  expandedFolders[newPath] = true
  pendingFolderReveal = newPath
  status = "Moved folder to " .. newPath
  return true
end



local function renameSelectedFolder()
  local source = selectedFolder
  if not source or source == "All FX" or source == "Unsorted" or source == "My Folders" then
    status = "Select a custom folder in My Folders to rename it."
    return false
  end
  local oldName = pathBase(source)
  local ok, value = reaper.GetUserInputs("Rename folder", 1, "New folder name:", oldName)
  if not ok then return false end
  local newName = trim(value or "")
  if newName == "" or newName:find("/", 1, true) or newName:find("\\", 1, true) then
    reaper.ShowMessageBox("Enter a folder name without slash characters.", "Nested FX Browser", 0)
    return false
  end
  if newName == oldName then return false end
  local parent = pathParent(source)
  local newPath = parent ~= "" and (parent .. "/" .. newName) or newName
  for _, existing in ipairs(allFolders()) do
    if existing == newPath or existing:sub(1, #newPath + 1) == newPath .. "/" then
      status = "A folder with that name already exists."
      return false
    end
  end

  -- Rename only the selected folder path. Do not rename or move child folders.
  -- Plugin assignments pointing to this exact folder are updated so its plugins stay inside.
  local remap = function(path)
    if path == source then return newPath end
    return path
  end
  local renamedFolders = {}
  for path in pairs(savedFolders) do renamedFolders[remap(path)] = true end
  savedFolders = renamedFolders
  for key in pairs(folderMap) do
    local paths, changed = assignedPaths(key), {}
    for _, path in ipairs(paths) do changed[#changed + 1] = remap(path) end
    storeAssignedPaths(key, changed)
  end
  local renamedOrder = {}
  for _, path in ipairs(folderOrder) do renamedOrder[#renamedOrder + 1] = remap(path) end
  folderOrder = renamedOrder
  if folderColors[source] then remapFolderColorPaths(source, newPath, false) end
  local renamedExpanded = {}
  for path, isExpanded in pairs(expandedFolders) do
    if isExpanded then renamedExpanded[remap(path)] = true end
  end
  expandedFolders = renamedExpanded

  saveFolders(savedFolders)
  saveMap(folderMap)
  saveFolderOrder()
  setBrowserView(newPath, nil)
  ensureAncestorsExpanded(newPath)
  expandedFolders[newPath] = true
  pendingFolderReveal = newPath
  status = "Renamed folder: " .. source .. " → " .. newPath
  return true
end

local function normalizeSearch(s)
  -- Remove all separators for compact matching: L-1 == L1, Pro - G == Pro-G.
  return tostring(s or ""):lower():gsub("[%s%p]", "")
end

local function searchFieldMatches(field, query, compactQuery)
  if query == "" then return true end
  local value = tostring(field or ""):lower()
  if value:find(query, 1, true) then return true end
  local compactValue = normalizeSearch(value)
  return compactQuery ~= "" and compactValue:find(compactQuery, 1, true) ~= nil
end

local function pluginStartsWithSearch(fx, query)
  local q = normalizeSearch(query)
  if q == "" then return false end
  return normalizeSearch(fx.name):sub(1, #q) == q
      or normalizeSearch(fx.manufacturer):sub(1, #q) == q
end

local function pluginMatchesSearch(fx, query)
  if query == "" then return true end
  -- The search is intentionally limited to plugin display name and manufacturer.
  -- Check both fields together so "Waves L1" works as well as "L1" or "Waves".
  local name = tostring(fx.name or ""):lower()
  local vendor = tostring(fx.manufacturer or ""):lower()
  local combined = name .. " " .. vendor
  local compactCombined = normalizeSearch(combined)
  local compactQuery = normalizeSearch(query)

  -- First try the complete query. This preserves punctuation-aware names such as Pro-G,
  -- while the compact form also matches when the user types Pro - G or L-1 / L1.
  if combined:find(query, 1, true) then return true end
  if compactQuery ~= "" and compactCombined:find(compactQuery, 1, true) then return true end

  -- For multi-word queries, every typed word must match either the name or vendor.
  -- This avoids returning every "Pro" plugin when the user continues typing "Pro-G".
  for token in query:lower():gmatch("[^%s]+") do
    local compactToken = normalizeSearch(token)
    if compactToken ~= "" then
      local nameHit = name:find(token, 1, true) ~= nil
        or normalizeSearch(name):find(compactToken, 1, true) ~= nil
      local vendorHit = vendor:find(token, 1, true) ~= nil
        or normalizeSearch(vendor):find(compactToken, 1, true) ~= nil
      if not nameHit and not vendorHit then return false end
    end
  end
  return true
end

local currentRowsCache = nil
local currentRowsCacheKey = nil
local function currentRows()
  local formatKey = table.concat({
    formatEnabled.AU and "1" or "0",
    formatEnabled.VST and "1" or "0",
    formatEnabled.VST3 and "1" or "0",
    formatEnabled.CLAP and "1" or "0",
    formatEnabled.JSFX and "1" or "0",
    formatEnabled.LV2 and "1" or "0",
    formatEnabled.DX and "1" or "0"
  })
  local cacheKey = table.concat({search, selectedFolder, selectedManufacturer or "", formatKey, tostring(folderDataRevision)}, string.char(31))
  if currentRowsCache and currentRowsCacheKey == cacheKey then
    return currentRowsCache
  end
  local out, candidates = {}, {}
  local q = search:lower()
  local selectedVendor = normalizeSearch(selectedManufacturer)
  for _, fx in ipairs(fxList) do
    local paths = assignedPaths(fx.key)
    local folderOK = selectedFolder == "All FX"
      or (selectedFolder == "Unsorted" and #paths == 0)
    if selectedFolder == "My Folders" then
      -- The My Folders root shows every assigned plugin, including those in subfolders.
      folderOK = #paths > 0
    elseif selectedFolder ~= "All FX" and selectedFolder ~= "Unsorted" then
      -- A folder displays only plugins assigned directly to that exact folder.
      -- Child-folder plugins appear only when the child folder is selected.
      for _, path in ipairs(paths) do
        if path == selectedFolder then
          folderOK = true
          break
        end
      end
    end
    local fxVendor = normalizeSearch(fx.manufacturer)
    -- Manufacturer views are exact groups. Substring matching made short
    -- names (for example "R") pull unrelated vendors into the same group.
    local manufacturerOK = not selectedManufacturer or fxVendor == selectedVendor
    local formatOK = fx.format == "Other" or formatEnabled[fx.format] ~= false
    if folderOK and manufacturerOK and formatOK then candidates[#candidates + 1] = fx end
  end

  -- While typing a single word, prefer names that START with it, so the list
  -- behaves like live suggestions. If no prefix exists, fall back to substring
  -- matching (needed for names such as "FabFilter Pro-G"). Multiword searches
  -- always use the normal name/manufacturer matcher (e.g. "Waves L1").
  local trimmed = q:match("^%s*(.-)%s*$") or q
  local usePrefix = trimmed ~= "" and not trimmed:find("%s")
  if usePrefix then
    local hasPrefix = false
    for _, fx in ipairs(candidates) do
      if pluginStartsWithSearch(fx, trimmed) then hasPrefix = true; break end
    end
    if hasPrefix then
      for _, fx in ipairs(candidates) do
        if pluginStartsWithSearch(fx, trimmed) then out[#out + 1] = fx end
      end
      currentRowsCache, currentRowsCacheKey = out, cacheKey
      return currentRowsCache
    end
  end
  for _, fx in ipairs(candidates) do
    if pluginMatchesSearch(fx, q) then out[#out + 1] = fx end
  end
  currentRowsCache, currentRowsCacheKey = out, cacheKey
  return currentRowsCache
end

local manufacturersCache = nil
local function getManufacturers()
  if manufacturersCache then return manufacturersCache end
  local set, out = {}, {}
  for _, fx in ipairs(fxList) do if fx.manufacturer ~= "Other / Unknown" then set[fx.manufacturer] = true end end
  for name in pairs(set) do out[#out+1] = name end
  table.sort(out, function(a,b) return a:lower() < b:lower() end)
  manufacturersCache = out
  return manufacturersCache
end

local THEME_KEY = "color_theme_v1"
local themeNames = {"REAPER", "Dark", "Graphite", "Light", "Warm Light", "Forest", "Burgundy", "Brown"}
local currentTheme = FolderStorage.getSetting(THEME_KEY) or ""
local FONT_SIZE_KEY = "font_size_v1"
local fontSize = math.max(11, math.min(22, tonumber(FolderStorage.getSetting(FONT_SIZE_KEY)) or 15))
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
  elseif currentTheme == "Forest" or currentTheme == "Burgundy" or currentTheme == "Brown" then
    -- Muted dark tints: darker UI elements receive more color; bright text
    -- receives only a trace, keeping labels readable.
    local tr, tg, tb
    if currentTheme == "Forest" then tr, tg, tb = 0.045, 0.145, 0.085
    elseif currentTheme == "Burgundy" then tr, tg, tb = 0.155, 0.045, 0.075
    else tr, tg, tb = 0.16, 0.105, 0.065 end
    local lum = (r + g + b) / 3
    local amount = lum > 0.78 and 0.025 or (lum > 0.48 and 0.10 or 0.24)
    r, g, b = mix(r, tr, amount), mix(g, tg, amount), mix(b, tb, amount)
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
local function fitFolderText(x, y, value, maxWidth, r, g, b)
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
  gfx.set(math.max(0,math.min(1,r or 0.88)), math.max(0,math.min(1,g or 0.90)), math.max(0,math.min(1,b or 0.92)), 1)
  gfx.x, gfx.y = x, y
  gfx.drawstr(s)
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
  -- GetSelectedTrack() ignores the master track. GetSelectedTrack2() with
  -- wantmaster=true includes it, while preserving the normal selected-track
  -- behavior for ordinary tracks.
  local track = reaper.GetSelectedTrack2 and reaper.GetSelectedTrack2(0, 0, true)
  if not track then track = reaper.GetSelectedTrack(0, 0) end
  if not track then
    reaper.ShowMessageBox("Select a track (including the Master Track) in REAPER first.", "Nested FX Browser", 0)
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

local closeAfterAdd = false

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
  -- Match REAPER's native FX browser: close only after at least one plugin
  -- was successfully inserted. Failed additions leave the browser available.
  if added > 0 then closeAfterAdd = true end
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
  -- Append newly created path components BEFORE saving. This prevents the
  -- storage helper from appending them in alphabetical order during the save.
  local ordered = {}
  for _, existing in ipairs(folderOrder) do ordered[existing] = true end
  cur = ""
  for _, part in ipairs(split(path, "/")) do
    cur = cur == "" and part or (cur .. "/" .. part)
    if not ordered[cur] then
      folderOrder[#folderOrder + 1] = cur
      ordered[cur] = true
    end
  end
  saveFolders(savedFolders)
  -- Select the new folder and reveal it in place; never reset the tree to row 1.
  setBrowserView(path, nil)
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

local function removeSelectedFromFolder(fallbackFX)
  local visible = currentRows()
  local targets = {}
  for _, fx in ipairs(visible) do
    if selectedFXKeys[fx.key] then targets[#targets + 1] = fx end
  end
  if #targets == 0 and fallbackFX then targets[1] = fallbackFX end
  if #targets == 0 then status = "Select one or more plugins first."; return end

  local removed, skipped = 0, 0
  local removedFolder = nil
  for _, fx in ipairs(targets) do
    local paths = assignedPaths(fx.key)
    if #paths == 0 then
      skipped = skipped + 1
    else
      local removePath = hasFolderAssignment(fx.key, selectedFolder) and selectedFolder or paths[1]
      local kept = {}
      for _, path in ipairs(paths) do
        if path ~= removePath then kept[#kept + 1] = path end
      end
      storeAssignedPaths(fx.key, kept)
      removed = removed + 1
      removedFolder = removedFolder or removePath
    end
  end
  if removed > 0 then saveMap(folderMap) end
  if #targets == 1 and removed == 1 then
    status = "Removed from folder " .. tostring(removedFolder) .. ": " .. targets[1].name
  else
    status = ("Removed %d selected plugin(s) from folders."):format(removed)
    if skipped > 0 then status = status .. (" %d had no folder assignment."):format(skipped) end
  end
  clearSelectionExcept(nil)
end

local function draw()
  -- Keep interface controls and labels at a fixed size; fontSize is only for
  -- the folder tree and plugin names.
  gfx.setfont(1, "Arial", 15)
  rowHeight = fontSize + 8
  winW, winH = gfx.w, gfx.h
  leftW = math.max(150, math.min(leftW, winW - 420))
  listW = math.max(300, winW - leftW - 38)
  listH = math.max(150, winH - 180)
  listX, listY = 14, 118
  local rightX = 24 + leftW
  local dividerX = 18 + leftW
  color(0.105,0.115,0.13,1); gfx.rect(0,0,winW,winH,1)
  button(14,8,30,24,"<")
  button(48,8,30,24,">")
  text(88,10,"VSOUND",1,0.66,0.30)
  text(160,10,"REAPER NESTED FX BROWSER",1,0.86,0.48)
  text(14,34,"Read-only inventory; folder assignments are saved separately. No network/rescan functions.",0.72,0.77,0.80)
  button(winW-210,8,36,24,"A−")
  button(winW-170,8,36,24,"A+")
  button(winW-124,8,110,24,"Color: " .. currentTheme)

  -- Search and compact format menu in the top bar.
  local searchW = math.max(150, winW - 700)
  color(0.07,0.08,0.09,1); gfx.rect(14,58,searchW,28,1)
  color(searchFocused and 0.70 or 0.35, searchFocused and 0.62 or 0.38, searchFocused and 0.30 or 0.40,1); gfx.rect(14,58,searchW,28,0)
  if search == "" and not searchFocused then
    text(22,64,"Search...",0.55,0.58,0.60)
  else
    local a, b = searchSelStart, searchSelEnd
    if a and b and a ~= b then
      if a > b then a,b = b,a end
      local leftText, selectedText = search:sub(1,a), search:sub(a+1,b)
      local sx = 22 + gfx.measurestr(leftText)
      local sw = gfx.measurestr(selectedText)
      color(0.22,0.36,0.55,1); gfx.rect(sx,61,sw,20,1)
    end
    text(22,64,search,0.96,0.96,0.96)
  end
  if searchFocused and cursorVisible then
    local cx = 22 + gfx.measurestr(search:sub(1,searchCursor))
    local fieldRight = 14 + searchW - 5
    if cx > fieldRight then cx = fieldRight end
    color(0.98,0.88,0.48,1); gfx.rect(cx,62,2,19,1)
  end
  button(winW-486,58,90,28,"FX On/Off")
  button(winW-390,58,70,28,"Clear")
  button(winW-314,58,96,28,"Assign")
  button(winW-212,58,96,28,"Delete Folder")
  button(winW-110,58,96,28,"Create")

  button(14,90,58,22,"Fold all")
  button(76,90,82,22,"Rename")
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
  local folderRowH = fontSize + 7
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
  gfx.setfont(1, "Arial", fontSize)
  for fi = folderScroll + 1, math.min(#treeRows, folderScroll + maxFolderRows) do
    local item = treeRows[fi]
    local depth = item.depth or 0
    local indent = depth * 13
    local isSelected = (item.kind == "folder" and item.value == selectedFolder and not selectedManufacturer)
      or (item.kind == "customHeader" and selectedFolder == "My Folders" and not selectedManufacturer)
      or (item.kind == "manufacturer" and item.value == selectedManufacturer)
     
    if isSelected then color(0.22,0.31,0.38,1); gfx.rect(18,fy-2,leftW-4,folderRowH-2,1) end
    if item.kind == "manufacturerHeader" then
      text(21,fy,manufacturersExpanded and "−" or "+",0.96,0.82,0.42)
      text(39,fy,item.label,0.96,0.88,0.68)
      rows[#rows+1] = {kind="manufacturerHeader", value=item.value, x=18, y=fy-2, w=leftW-34, h=folderRowH-2}
    elseif item.kind == "customHeader" then
      text(21,fy,"▾",0.96,0.82,0.42); text(39,fy,item.label,0.96,0.88,0.68)
      rows[#rows+1] = {kind="customHeader", value=item.value, x=18, y=fy-2, w=leftW-34, h=folderRowH-2}
    elseif item.kind == "manufacturer" then
      fitText(39+indent,fy,item.label,leftW-(39+indent)-12,selectedManufacturer == item.value and 1 or 0.82,0.86,0.90)
      rows[#rows+1] = {kind="manufacturer", value=item.value, x=18+indent, y=fy-2, w=leftW-35-indent, h=folderRowH-2}
    elseif item.kind == "folder" then
      if item.hasKids then
        text(21+indent,fy,expandedFolders[item.value] and "−" or "+",0.96,0.82,0.42)
        rows[#rows+1] = {kind="toggleFolder", value=item.value, x=18+indent, y=fy-2, w=16, h=folderRowH-2}
      end
      local folderR, folderG, folderB = getFolderColor(item.value)
      local colorCX, colorCY = 43+indent, fy+7
      -- A small circular swatch is always visible; click it to open REAPER's
      -- native full color chooser. The folder label itself keeps its own color.
      color(0.05,0.06,0.07,1); gfx.circle(colorCX,colorCY,6,true,true)
      if folderR then
        gfx.set(folderR,folderG,folderB,1); gfx.circle(colorCX,colorCY,4.5,true,true)
      else
        color(0.48,0.52,0.56,1); gfx.circle(colorCX,colorCY,4.5,false,true)
      end
      local labelX = 56+indent
      if folderR then
        fitFolderText(labelX,fy,item.label,leftW-labelX-12,folderR,folderG,folderB)
      else
        fitText(labelX,fy,item.label,leftW-labelX-12, item.value == selectedFolder and not selectedManufacturer and 1 or 0.82, item.value == selectedFolder and not selectedManufacturer and 0.91 or 0.85, item.value == selectedFolder and not selectedManufacturer and 0.55 or 0.88)
      end
      rows[#rows+1] = {kind="folder", value=item.value, colorX=colorCX, x=18+indent, y=fy-2, w=leftW-35-indent, h=20}
    end
    fy = fy + folderRowH
  end
  gfx.setfont(1, "Arial", 15)
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
    -- Show a real insertion marker while reordering folders. A drop in the
    -- centre/right of a folder nests; a drop above/below a row reorders siblings.
    local nearestFolder, nearestDistance = nil, math.huge
    for _, row in ipairs(rows) do
      if row.kind == "folder" and row.value ~= "All FX" and row.value ~= "Unsorted"
        and gfx.mouse_x >= 14 and gfx.mouse_x <= 14 + leftW - 14
        and gfx.mouse_y >= 120 and gfx.mouse_y <= 120 + listH then
        local centerY = row.y + row.h / 2
        local distance = math.abs(gfx.mouse_y - centerY)
        if distance < nearestDistance then nearestFolder, nearestDistance = row, distance end
        if gfx.mouse_y >= row.y and gfx.mouse_y <= row.y + row.h
          and gfx.mouse_y >= row.y + row.h * 0.30 and gfx.mouse_y <= row.y + row.h * 0.70 then
          color(0.58,0.40,0.14,0.85); gfx.rect(row.x,row.y,row.w,row.h,1)
          color(1,0.88,0.56,1); gfx.rect(row.x,row.y,row.w,row.h,0)
        end
      end
    end
    if nearestFolder and not (gfx.mouse_y >= nearestFolder.y + nearestFolder.h * 0.30
      and gfx.mouse_y <= nearestFolder.y + nearestFolder.h * 0.70
      and gfx.mouse_y >= nearestFolder.y and gfx.mouse_y <= nearestFolder.y + nearestFolder.h) then
      local insertY = gfx.mouse_y < nearestFolder.y + nearestFolder.h / 2 and nearestFolder.y or (nearestFolder.y + nearestFolder.h)
      color(1,0.78,0.20,1); gfx.rect(20, insertY - 2, leftW - 36, 4, 1)
      color(1,0.94,0.64,1); gfx.rect(20, insertY - 1, leftW - 36, 1, 1)
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
    gfx.setfont(1, "Arial", fontSize)
    fitText(rightX+10,y,fx.name,math.max(40, math.floor((winW-rightX)*0.55)-14), isSelected and 1 or 0.88, isSelected and 0.91 or 0.89, isSelected and 0.58 or 0.90)
    gfx.setfont(1, "Arial", 15)
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
    local removeLabel = (contextMenu.selectedCount or 1) > 1
      and ("Remove " .. contextMenu.selectedCount .. " selected plugins") or "Remove from folder"
    text(contextMenu.x+8,contextMenu.y+7,removeLabel,0.95,0.95,0.95)
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
    local tmX, tmY, tmW, tmH = winW-180, 35, 166, (#themeNames * 25 + 10)
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

  -- The divider is visual only. Resize exclusively with the three-dot grip at its bottom.
  color(0.40,0.43,0.46,1); gfx.rect(dividerX,114,4,listH+4,1)
  local gripX, gripY = dividerX + 2, winH - 94
  color(0.78,0.81,0.83,1)
  gfx.circle(gripX, gripY - 6, 1.7, true, true)
  gfx.circle(gripX, gripY,     1.7, true, true)
  gfx.circle(gripX, gripY + 6, 1.7, true, true)

  color(0.07,0.08,0.09,1); gfx.rect(14,winH-78,winW-28,28,1)
  text(20,winH-71,status,0.72,0.86,0.78)
  color(0.085,0.095,0.11,1); gfx.rect(0,winH-44,winW,44,1)
  button(winW-92,winH-36,78,25,"About")

  if aboutOpen then
    local ax, ay, aw, ah = winW-310, winH-166, 296, 112
    color(0.055,0.065,0.078,1); gfx.rect(ax,ay,aw,ah,1)
    color(0.58,0.63,0.67,1); gfx.rect(ax,ay,aw,ah,0)
    text(ax+14,ay+12,"ABOUT THIS BROWSER",0.98,0.82,0.43)
    text(ax+14,ay+39,"Developer: Vassiliy Solovar",0.94,0.95,0.96)
    text(ax+14,ay+67,"YouTube: @v-sound",0.56,0.78,1.00)
    color(0.56,0.78,1.00,1); gfx.line(ax+14,ay+84,ax+128,ay+84)
    text(ax+14,ay+91,"Click the link to open the channel",0.62,0.67,0.71)
  end
end

local mouseWasDown = false
local rightMouseWasDown = false
local clickTime, clickX, clickY = 0, -100, -100
-- Keep input polling responsive, but cap full redraws at 20 fps. This avoids
-- spending REAPER's main-thread time repainting an unchanged browser window.
local lastDrawTime = 0
local drawInterval = 1 / 20
local function saveGeometry()
  local ok, dockState, x, y, w, h = pcall(gfx.dock, -1)
  if ok and type(w) == "number" and type(h) == "number" and w >= 300 and h >= 200 then
    FolderStorage.setSetting("window_geometry_v1", table.concat({math.floor(w), math.floor(h), math.floor(x or 0), math.floor(y or 0), math.floor(dockState or 0), math.floor(leftW or 210)}, "|"))
  else
    FolderStorage.setSetting("window_geometry_v1", table.concat({math.floor(gfx.w or winW), math.floor(gfx.h or winH), 0, 0, 0, math.floor(leftW or 210)}, "|"))
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
  local redraw = (now - lastDrawTime) >= drawInterval
  if redraw then
    rows = {}
    dragTarget = nil
    draw()
    lastDrawTime = now
  end

  local cap = gfx.mouse_cap
  local down = (cap & 1) == 1
  if down and not mouseWasDown then
    local searchW = math.max(150, winW - 700)
    if gfx.mouse_y >= 58 and gfx.mouse_y <= 86 and gfx.mouse_x >= 14 and gfx.mouse_x <= 14 + searchW then
      searchFocused = true
      local pos = searchPositionAtX(gfx.mouse_x)
      searchCursor = pos
      searchSelStart, searchSelEnd = pos, pos
      searchMouseSelecting = true
      cursorVisible = true
      lastCursorBlink = reaper.time_precise()
    end
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
  local gripCenterX = 18 + leftW + 2
  if down and not mouseWasDown
    and math.abs(gfx.mouse_x - gripCenterX) <= 8
    and gfx.mouse_y >= winH - 106 and gfx.mouse_y <= winH - 80 then
    resizingDivider = true
    aboutOpen = false
  end
  if down and resizingDivider then
    leftW = math.max(150, math.min(winW - 420, gfx.mouse_x - 20))
  elseif not down and mouseWasDown and resizingDivider then
    resizingDivider = false
  end
  if down and not mouseWasDown and not resizingDivider and not draggingListScrollbar and not draggingFolderScrollbar then
    local mx,my = gfx.mouse_x,gfx.mouse_y
    dragFX, dragging, dragStartX, dragStartY = nil, false, mx, my
    dragFolder, draggingFolder = nil, false
    if my >= winH-38 and my <= winH-8 and mx >= winW-96 and mx <= winW-12 then
      aboutOpen = not aboutOpen
      searchFocused = false
      contextMenu = nil
      themeMenuOpen = false
      formatMenuOpen = false
    elseif aboutOpen then
      local ax, ay, aw, ah = winW-310, winH-166, 296, 112
      if mx >= ax+8 and mx <= ax+aw-8 and my >= ay+58 and my <= ay+88 then
        local url = "https://www.youtube.com/@v-sound"
        if reaper.CF_ShellExecute then
          reaper.CF_ShellExecute(url)
        else
          local osname = reaper.GetOS and reaper.GetOS() or ""
          if osname:find("Win", 1, true) then
            reaper.ExecProcess('cmd /c start "" "' .. url .. '"', 0)
          elseif osname:find("OSX", 1, true) or osname:find("macOS", 1, true) then
            reaper.ExecProcess('open "' .. url .. '"', 0)
          else
            reaper.ExecProcess('xdg-open "' .. url .. '"', 0)
          end
        end
      end
      aboutOpen = false
    elseif my >= 8 and my <= 32 and mx >= 14 and mx <= 44 then
      navigateHistory(-1)
    elseif my >= 8 and my <= 32 and mx >= 48 and mx <= 78 then
      navigateHistory(1)
    elseif my >= 8 and my <= 32 and mx >= winW-210 and mx <= winW-174 then
      fontSize = math.max(11, fontSize - 1)
      FolderStorage.setSetting(FONT_SIZE_KEY, tostring(fontSize))
      status = "Font size: " .. fontSize
    elseif my >= 8 and my <= 32 and mx >= winW-170 and mx <= winW-134 then
      fontSize = math.min(22, fontSize + 1)
      FolderStorage.setSetting(FONT_SIZE_KEY, tostring(fontSize))
      status = "Font size: " .. fontSize
    elseif themeMenuOpen then
      local themeHit = nil
      for _, row in ipairs(rows) do
        if row.kind == "themeChoice" and mx >= row.x and mx <= row.x+row.w and my >= row.y and my <= row.y+row.h then themeHit = row.value; break end
      end
      if themeHit then
        currentTheme = themeHit
        FolderStorage.setSetting(THEME_KEY, currentTheme)
        status = "Color theme: " .. currentTheme
      end
      themeMenuOpen = false
    elseif contextMenu then
      if mx >= contextMenu.x and mx <= contextMenu.x+190 and my >= contextMenu.y and my <= contextMenu.y+50 then
        local fx = contextMenu.fx
        if my < contextMenu.y+25 then
          removeSelectedFromFolder(fx)
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
    elseif my >= 90 and my <= 112 and mx >= 14 and mx <= 72 then
      searchFocused = false
      expandedFolders = {}
      folderScroll = 0
      pendingFolderReveal = nil
      status = "All subfolders collapsed."
    elseif my >= 90 and my <= 112 and mx >= 76 and mx <= 158 then
      searchFocused = false
      renameSelectedFolder()
    elseif my >= 8 and my <= 32 and mx >= winW-124 and mx <= winW-14 then
      themeMenuOpen = not themeMenuOpen
      formatMenuOpen = false
      searchFocused = false
    elseif my >= 58 and my <= 86 and mx >= winW-486 and mx <= winW-396 then
      formatMenuOpen = not formatMenuOpen; searchFocused = false
    elseif my >= 58 and my <= 86 and mx >= 14 and mx <= 14+math.max(150,winW-700) then
      -- Search focus and mouse selection are started in the initial mouse-down
      -- handler above; do not start a second selection on the same click.
      searchFocused = true
    elseif my >= 58 and my <= 86 and mx >= winW-390 and mx <= winW-320 then
      search = ""; searchCursor = 0; searchSelStart, searchSelEnd = nil, nil; searchFocused = true; status = "Search cleared."
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
          local deleting = selectedFolder
          local function isInside(path)
            return path == deleting or path:sub(1, #deleting + 1) == deleting .. "/"
          end

          -- Remove this folder and every descendant from every plugin assignment.
          for key in pairs(folderMap) do
            local kept = {}
            for _, path in ipairs(assignedPaths(key)) do
              if not isInside(path) then kept[#kept + 1] = path end
            end
            storeAssignedPaths(key, kept)
          end

          -- Remove the same paths from the saved folder set and ordering,
          -- including any visual labels saved for the deleted folders.
          for path in pairs(savedFolders) do
            if isInside(path) then savedFolders[path] = nil end
          end
          local hadFolderColors = false
          for path in pairs(folderColors) do
            if isInside(path) then folderColors[path] = nil; hadFolderColors = true end
          end
          if hadFolderColors then saveFolderColors() end
          local newOrder = {}
          for _, path in ipairs(folderOrder) do
            if not isInside(path) then newOrder[#newOrder + 1] = path end
          end
          folderOrder = newOrder

          saveMap(folderMap)
          saveFolders(savedFolders)
          saveFolderOrder()
          status = "Deleted custom folder and its subfolders: " .. deleting
          setBrowserView("My Folders", nil)
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
            setBrowserView("My Folders", nil)
            clearSelectionExcept(nil)
            selectedFX = 1; scroll = 0
            status = "My Folders selected. Create Folder makes a top-level folder here."
          elseif row.kind == "manufacturer" then
            setBrowserView("All FX", row.value)
            -- Selecting a vendor filters the right pane; it never expands plugin rows on the left.
            -- Preserve selected plugin keys and right-pane scroll while browsing the tree.
          elseif row.kind == "toggleFolder" then
            expandedFolders[row.value] = not expandedFolders[row.value]
            -- draw() clamps folderScroll against the newly visible tree on the next frame.
          elseif row.kind == "folder" then
            if row.colorX and math.abs(mx-row.colorX) <= 8
              and row.value ~= "All FX" and row.value ~= "Unsorted" then
              chooseFolderColor(row.value)
            else
              setBrowserView(row.value, nil)
              if row.value ~= "All FX" and row.value ~= "Unsorted" then dragFolder = row.value end
            end
            -- Preserve selected plugin keys and list position across tree navigation.
          elseif row.kind == "folderEntry" then
            setBrowserView(row.value, nil)
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
              -- A busy project can delay gfx/defer polling; allow a wider
              -- double-click interval so the second click is not discarded.
              if math.abs(clickX - mx) < 8 and math.abs(clickY - my) < 8 and (clickNow - clickTime) < 0.90 then addSelected(); clickTime = 0
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
      local targetRow, nearestDistance = nil, math.huge
      -- Header drops are reserved for pulling a nested folder to the root.
      for _, row in ipairs(rows) do
        if row.kind == "customHeader" and mx >= row.x and mx <= row.x+row.w and my >= row.y and my <= row.y+row.h then
          targetRow = row; break
        end
      end
      -- Otherwise accept a drop on a row OR in the narrow gap immediately
      -- above/below it. This is what makes the insertion-line gesture usable.
      if not targetRow and mx >= 14 and mx <= 14 + leftW - 14 and my >= 120 and my <= 120 + listH then
        for _, row in ipairs(rows) do
          if row.kind == "folder" and row.value ~= "All FX" and row.value ~= "Unsorted" then
            local centerY = row.y + row.h / 2
            local distance = math.abs(my - centerY)
            if distance < nearestDistance then targetRow, nearestDistance = row, distance end
          end
        end
      end
      if targetRow and targetRow.kind == "customHeader" then
        moveFolderPath(dragFolder, nil, "root")
      elseif targetRow and targetRow.value ~= "All FX" and targetRow.value ~= "Unsorted" and targetRow.value ~= dragFolder then
        local insideRow = my >= targetRow.y and my <= targetRow.y + targetRow.h
        local relative = (my - targetRow.y) / math.max(1, targetRow.h)
        local mode
        if insideRow and relative >= 0.30 and relative <= 0.70 then
          mode = "inside"
        elseif my < targetRow.y + targetRow.h / 2 then
          mode = "before"
        else
          mode = "after"
        end
        moveFolderPath(dragFolder, targetRow.value, mode)
      elseif not targetRow then
        status = "Drop the folder on a row or on the insertion line between folders."
      else
        status = "Choose a different folder as the destination."
      end
      dragFolder, draggingFolder = nil, false
    elseif dragging and dragFX then
      local mx,my = gfx.mouse_x,gfx.mouse_y
      local target = nil
      -- A plugin drop is accepted only on the visible row of an EXISTING
      -- custom folder. Use the full left-pane row width, not the indented
      -- text area: dropping near the left edge of a nested row must still
      -- select that row rather than miss it or hit an unintended path.
      if mx >= 14 and mx <= 14 + leftW - 4 then
        for _, row in ipairs(rows) do
          if row.kind == "folder" and row.value ~= "All FX" and row.value ~= "Unsorted"
            and my >= row.y and my <= row.y + row.h then
            -- Do not synthesize folders from a drag destination. The target
            -- must already exist in the saved folder tree.
            if savedFolders[row.value] then target = row.value end
            break
          end
        end
      end
      if target then
        local targets = {}
        for _, fx in ipairs(fxList) do
          if selectedFXKeys[fx.key] then targets[#targets+1] = fx end
        end
        if #targets == 0 then targets[1] = dragFX end
        local moved = 0
        for _, fx in ipairs(targets) do
          if assignToFolder(fx, target) then moved = moved + 1 end
        end
        status = ("Moved %d plugin(s) to %s"):format(moved, target)
      else
        status = "Drop cancelled — release on the row of an existing custom folder."
      end
    end
    dragFX, dragging = nil, false
    if not draggingFolder then dragFolder = nil end
  end
  if searchMouseSelecting then
    if down then
      local pos = searchPositionAtX(gfx.mouse_x)
      searchSelEnd = pos
      searchCursor = pos
    else
      searchMouseSelecting = false
      if searchSelStart == searchSelEnd then searchSelStart, searchSelEnd = nil, nil end
    end
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
      -- Right-clicking an already selected plugin keeps the multi-selection.
      -- Right-clicking an unselected plugin makes it the sole selection.
      if not selectedFXKeys[hit.key] then clearSelectionExcept(hit.key) end
      local selectedCount = 0
      local visible = currentRows()
      for _, fx in ipairs(visible) do
        if selectedFXKeys[fx.key] then selectedCount = selectedCount + 1 end
      end
      contextMenu = {x=math.min(mx, winW-195), y=math.min(my, winH-56), fx=hit, selectedCount=math.max(1, selectedCount)}
      status = selectedCount > 1 and ("Plugin menu: " .. selectedCount .. " selected") or ("Plugin menu: " .. hit.name)
    else
      local folderHit = nil
      for _, row in ipairs(rows) do
        if row.kind == "folder" and row.value ~= "All FX" and row.value ~= "Unsorted"
          and mx >= row.x and mx <= row.x+row.w and my >= row.y and my <= row.y+row.h then
          folderHit = row.value
          break
        end
      end
      contextMenu = nil
      if folderHit then
        chooseFolderColor(folderHit)
      end
    end
  end
  rightMouseWasDown = rightDown

  -- Keyboard editing for the search box: caret, selection, Ctrl+A, Delete/Backspace.
  local c = char
  local shiftHeld = (cap & 8) == 8
  local ctrlHeld = (cap & 4) == 4
  local function deleteSearchSelection()
    if searchSelStart and searchSelEnd and searchSelStart ~= searchSelEnd then
      local a,b = searchSelStart, searchSelEnd
      if a > b then a,b = b,a end
      search = search:sub(1,a) .. search:sub(b+1)
      searchCursor = a
      searchSelStart, searchSelEnd = nil, nil
      return true
    end
    return false
  end
  if c == 27 then searchFocused = false; searchMouseSelecting = false; contextMenu = nil
  elseif searchFocused and (c == 8 or c == 127) then
    if not deleteSearchSelection() and searchCursor > 0 then
      search = search:sub(1,searchCursor-1) .. search:sub(searchCursor+1)
      searchCursor = searchCursor - 1
    end
    cursorVisible = true; lastCursorBlink = reaper.time_precise()
  elseif searchFocused and c == 30064 then
    if not deleteSearchSelection() and searchCursor < #search then
      search = search:sub(1,searchCursor) .. search:sub(searchCursor+2)
    end
    cursorVisible = true; lastCursorBlink = reaper.time_precise()
  elseif searchFocused and (c == 1 or (ctrlHeld and (c == 97 or c == 65))) then
    searchSelStart, searchSelEnd = 0, #search; searchCursor = #search
  elseif searchFocused and c == 1818584692 then -- F2 remains available for assign/move
    local fx = currentRows()[selectedFX]
    if fx then
      local paths = assignedPaths(fx.key)
      local current = hasFolderAssignment(fx.key, selectedFolder) and selectedFolder or (paths[1] or "")
      local path = promptFolder(current)
      if path then assignToFolder(fx, path) end
    end
  elseif searchFocused and c == 30067 then
    searchCursor = math.max(0, searchCursor - 1)
    if shiftHeld then searchSelEnd = searchCursor else searchSelStart, searchSelEnd = nil, nil end
  elseif searchFocused and c == 30068 then
    searchCursor = math.min(#search, searchCursor + 1)
    if shiftHeld then searchSelEnd = searchCursor else searchSelStart, searchSelEnd = nil, nil end
  elseif searchFocused and c == 30069 then -- Home
    searchCursor = 0
    if shiftHeld then searchSelEnd = searchCursor else searchSelStart, searchSelEnd = nil, nil end
  elseif searchFocused and c == 30070 then -- End
    searchCursor = #search
    if shiftHeld then searchSelEnd = searchCursor else searchSelStart, searchSelEnd = nil, nil end
  elseif c == 30065 then scroll = math.max(0,scroll-1)
  elseif c == 30066 then scroll = scroll+1
  elseif c == 32 and not searchFocused then
    -- gfx.getchar captures Space while this window is focused, so forward
    -- the normal REAPER Play/stop command explicitly to the main application.
    reaper.Main_OnCommand(40044, 0) -- Transport: Play/stop
  elseif c == 13 then searchFocused = false; addSelected()
  elseif c >= 32 and c <= 126 and searchFocused then
    deleteSearchSelection()
    search = search:sub(1,searchCursor) .. string.char(c) .. search:sub(searchCursor+1)
    searchCursor = searchCursor + 1
    searchSelStart, searchSelEnd = nil, nil
    cursorVisible = true; lastCursorBlink = reaper.time_precise()
  end

  if gfx.mouse_wheel ~= 0 then
    if gfx.mouse_x < (14 + leftW) then
      folderScroll = math.max(0, folderScroll - (gfx.mouse_wheel > 0 and 3 or -3))
    else
      scroll = math.max(0, scroll - (gfx.mouse_wheel > 0 and 3 or -3))
    end
    gfx.mouse_wheel = 0
  end

  if closeAfterAdd then cleanup(); return end
  if redraw then gfx.update() end
  reaper.defer(loop)
end

local geometry = FolderStorage.getSetting("window_geometry_v1") or ""
if geometry ~= "" then
  local parts = split(geometry, "|")
  local gw, gh, gx, gy, gd, gl = tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4]), tonumber(parts[5]), tonumber(parts[6])
  if gw and gh and gw >= 700 and gh >= 420 then winW, winH = gw, gh end
  if gl and gl >= 150 and gl <= 700 then leftW = gl end
  gfx.init("REAPER Nested FX Browser v9.2", winW, winH, gd or 0, gx or 0, gy or 0)
else
  gfx.init("REAPER Nested FX Browser v9.2", winW, winH, 0)
end
gfx.setfont(1, "Arial", 15)
loop()
