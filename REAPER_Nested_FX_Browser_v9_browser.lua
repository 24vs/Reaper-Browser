-- REAPER Nested FX Browser — fixed
-- Uses REAPER's existing FX inventory. No network, no rescan, no plugin loading until Add.
-- Folder assignments are stored in REAPER ExtState and do not modify project/plugin files.
-- Folder paths use "/" separators, e.g. Delay/Waves or Delay/Valhalla.
-- Requires a REAPER version exposing EnumInstalledFX and TrackFX_AddByName.

local SECTION = "VSoundNestedFXBrowser"
local KEY = "folder_map_v1"
local FOLDERS_KEY = "folders_v1"
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

local function saveFolders(set)
  local list = {}
  for folder in pairs(set) do list[#list + 1] = folder end
  table.sort(list, function(a,b) return a:lower() < b:lower() end)
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
local selectedFX, selectedFolder = 1, "All FX"
local selectedFXKeys = {} -- multi-selection by stable plugin identifier
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
local dragTarget = nil
local scroll, folderScroll = 0, 0
local draggingListScrollbar = false
local draggingFolderScrollbar = false
local status = "Loaded " .. #fxList .. " unique entries (deduplicated by identifier)."
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
  table.sort(out, function(a,b)
    if a == b then return false end
    if a == "All FX" then return true end
    if b == "All FX" then return false end
    if a == "Unsorted" then return true end
    if b == "Unsorted" then return false end
    return a:lower() < b:lower()
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


local function currentRows()
  local out = {}
  local q = search:lower()
  for _, fx in ipairs(fxList) do
    local path = folderMap[fx.key] or ""
    -- A custom folder/category shows only plugins assigned directly to it.
    -- Descendant folders are shown only when their own folder is selected.
    -- Typing a search term searches globally; otherwise show only direct folder contents.
    local folderOK = q ~= "" or selectedFolder == "All FX"
      or (selectedFolder == "Unsorted" and path == "")
      or (selectedFolder ~= "My Folders" and path == selectedFolder)
    local manufacturerOK = q ~= "" or not selectedManufacturer or fx.manufacturer == selectedManufacturer
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

local function color(r,g,b,a) gfx.set(r,g,b,a or 1) end
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
  if #targets == 0 and next(selectedFXKeys) == nil and visible[selectedFX] then targets[1] = visible[selectedFX] end
  if #targets == 0 then status = "Select a plugin first."; return end
  local added = 0
  for _, fx in ipairs(targets) do if addFX(fx) then added = added + 1 end end
  if #targets > 1 then status = ("Added %d of %d selected plugins."):format(added, #targets) end
end

local function clearSelectionExcept(key)
  selectedFXKeys = {}
  if key then selectedFXKeys[key] = true end
end

local function toggleSelection(key)
  if selectedFXKeys[key] then selectedFXKeys[key] = nil else selectedFXKeys[key] = true end
end

local function modifierHeld(cap)
  -- REAPER gfx: Ctrl=4; platform command/super modifier is commonly reported as 32.
  return (cap & 4) == 4 or (cap & 32) == 32
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
  if not folderMap[fx.key] or folderMap[fx.key] == "" then
    status = fx.name .. " is not assigned to a custom folder."
    return
  end
  local old = folderMap[fx.key]
  folderMap[fx.key] = nil
  saveMap(folderMap)
  status = "Removed from folder " .. old .. ": " .. fx.name
end

local function draw()
  winW, winH = gfx.w, gfx.h
  leftW = math.max(150, math.min(leftW, winW - 420))
  listW = math.max(300, winW - leftW - 38)
  listH = math.max(150, winH - 180)
  listX, listY = 14, 118
  local rightX = 24 + leftW
  local dividerX = 18 + leftW
  gfx.set(0.105,0.115,0.13,1); gfx.rect(0,0,winW,winH,1)
  text(14,10,"REAPER NESTED FX BROWSER",1,0.86,0.48)
  text(14,34,"Read-only inventory; folder assignments are saved separately. No network/rescan functions.",0.72,0.77,0.80)

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
  table.sort(customPaths, function(a,b) return a:lower() < b:lower() end)
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

  local displayRows = {}
  local folderSet = {}
  if selectedFolder == "My Folders" then
    for _, p in ipairs(allFolders()) do
      if p ~= "All FX" and p ~= "Unsorted" and not p:find("/", 1, true) then
        folderSet[p] = true
      end
    end
  elseif selectedFolder ~= "All FX" and selectedFolder ~= "Unsorted" and not selectedManufacturer then
    local prefix = selectedFolder .. "/"
    for _, p in ipairs(allFolders()) do
      if p:sub(1, #prefix) == prefix then
        local rest = p:sub(#prefix + 1)
        if rest ~= "" and not rest:find("/", 1, true) then folderSet[p] = true end
      end
    end
  end
  local childPaths = {}
  for p in pairs(folderSet) do childPaths[#childPaths+1] = p end
  table.sort(childPaths, function(a,b) return a:lower() < b:lower() end)
  for _, p in ipairs(childPaths) do
    displayRows[#displayRows+1] = {kind="folderEntry", path=p, name=p:match("([^/]+)$")}
  end
  for n, fx in ipairs(visible) do
    displayRows[#displayRows+1] = {kind="pluginEntry", fx=fx, pluginIndex=n}
  end

  text(rightX+7,94,(selectedManufacturer and (selectedManufacturer .. " — ") or "") .. ("Entries (%d; %d plugins)"):format(#displayRows,#visible),0.72,0.80,0.88)
  local start = math.max(1, scroll + 1)
  local maxRows = math.floor((listH - 12) / rowHeight)
  if start > math.max(1,#displayRows-maxRows+1) then start = math.max(1,#displayRows-maxRows+1) end
  for n = start, math.min(#displayRows, start + maxRows - 1) do
    local y = listY + 7 + (n-start)*rowHeight
    local entry = displayRows[n]
    if entry.kind == "folderEntry" then
      text(rightX+10,y,"▸  " .. entry.name,0.96,0.82,0.42)
      text(rightX + math.floor((winW-rightX)*0.57),y,"Folder",0.55,0.65,0.72)
      text(rightX + math.floor((winW-rightX)*0.74),y,entry.path,0.50,0.63,0.68)
      rows[#rows+1] = {kind="folderEntry", value=entry.path, x=rightX, y=y-2, w=winW-rightX-32, h=rowHeight}
    else
      local fx = entry.fx
      local pluginIndex = entry.pluginIndex
      local isSelected = selectedFXKeys[fx.key] or (next(selectedFXKeys) == nil and pluginIndex == selectedFX)
      if isSelected then color(0.22,0.31,0.38,1); gfx.rect(rightX+4,y-2,winW-rightX-22,rowHeight,1) end
      if gfx.setclip then gfx.setclip(rightX+8,y-2,math.max(40,winW-rightX-20),rowHeight) end
      fitText(rightX+10,y,fx.name,math.max(40, math.floor((winW-rightX)*0.55)-14), isSelected and 1 or 0.88, isSelected and 0.91 or 0.89, isSelected and 0.58 or 0.90)
      if gfx.setclip then gfx.setclip(0,0,winW,winH) end
      local fmtX = rightX + math.floor((winW-rightX)*0.57)
      text(fmtX,y,fx.format,0.55,0.65,0.72)
      local path = folderMap[fx.key] or ""
      text(rightX + math.floor((winW-rightX)*0.74),y,path ~= "" and path or "—",0.50,0.63,0.68)
      rows[#rows+1] = {kind="plugin", value=fx, index=pluginIndex, x=rightX, y=y-2, w=winW-rightX-32, h=rowHeight}
    end
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
  gfx.quit()
  reaper.SetExtState(SECTION, RUN_KEY, "", false)
  reaper.SetExtState(SECTION, CLOSE_KEY, "", false)
end

reaper.atexit(function()
  saveGeometry()
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
    if contextMenu then
      if mx >= contextMenu.x and mx <= contextMenu.x+190 and my >= contextMenu.y and my <= contextMenu.y+50 then
        local fx = contextMenu.fx
        if my < contextMenu.y+25 then
          removeFromFolder(fx)
        else
          local current = folderMap[fx.key] or ""
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
        local current = folderMap[fx.key] or ""
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
          for key, path in pairs(folderMap) do
            if path == selectedFolder or path:sub(1, #prefix) == prefix then folderMap[key] = nil end
          end
          for path in pairs(savedFolders) do
            if path == selectedFolder or path:sub(1, #prefix) == prefix then savedFolders[path] = nil end
          end
          saveMap(folderMap); saveFolders(savedFolders)
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
      for _, row in ipairs(rows) do
        if mx >= row.x and mx <= row.x+row.w and my >= row.y and my <= row.y+row.h then
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
            -- Preserve selected plugin keys and list position across tree navigation.
          elseif row.kind == "folderEntry" then
            selectedFolder = row.value
            selectedManufacturer = nil
            ensureAncestorsExpanded(selectedFolder)
            scroll = 0
            status = "Folder selected: " .. selectedFolder
          elseif row.kind == "plugin" then
            local multi = modifierHeld(cap)
            if multi then
              toggleSelection(row.value.key)
              clickTime = 0
            else
              if not selectedFXKeys[row.value.key] then clearSelectionExcept(row.value.key) end
            end
            selectedFX = row.index
            dragFX = row.value
            dragStartX, dragStartY = mx, my
            if not multi then
              local clickNow = reaper.time_precise()
              if math.abs(clickX - mx) < 8 and math.abs(clickY - my) < 8 and (clickNow - clickTime) < 0.45 then addSelected(); clickTime = 0
              else clickTime,clickX,clickY = clickNow,mx,my end
            end
          end
          break
        end
      end
    end
  end
  if down and dragFX and not dragging then
    if math.abs(gfx.mouse_x - dragStartX) >= 6 or math.abs(gfx.mouse_y - dragStartY) >= 6 then
      dragging = true
      searchFocused = false
    end
  end
  if not down and mouseWasDown then
    if dragging and dragFX then
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
        for _, fx in ipairs(targets) do assignToFolder(fx, target) end
        status = ("Moved %d plugin(s) to %s"):format(#targets, target)
      elseif target then
        status = "Drop onto a custom folder, not All FX/Unsorted."
      else
        status = "Drag cancelled — drop the plugin on a folder name."
      end
    end
    dragFX, dragging = nil, false
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
      local path = promptFolder(folderMap[fx.key] or "")
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
