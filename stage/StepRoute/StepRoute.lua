-- StepRoute: when the active RestedXP step has a map point, ask Mapzeroth for a route to it.
-- Read only. No hooks. No field is written on a RestedXP, Mapzeroth or Blizzard table.
-- RestedXP state read, by named globals:
--   RXPG_ARROW.element   the point the RestedXP arrow shows (its step gives the step text for the route name)
--   RXPFrame.activeSteps the active steps, fallback when the arrow has no usable point
--   RXPCData             saved per-character data: currentGuideName, currentStep, guideMetaData
-- Only for the guide name the player sees: RXP.currentGuide and RXP.settings.profile.season
-- (RXP is RestedXP's debug global; if it is gone the name falls back, nothing else changes).
-- Mapzeroth: MapzerothAPI.RouteTo(points, name, options).

local VERSION = "0.1.2"
local LOG_MAX = 200
local TICK = 1        -- seconds between reads
local DEFER = 0.5     -- seconds an event waits, so RestedXP has moved first
local ERR_MAX = 20    -- error lines kept per session

local DB                -- StepRouteDB, set at PLAYER_LOGIN
local sentKey           -- last target given to Mapzeroth (or tried)
local combatKey         -- target already logged as waiting for combat end
local noneWhy           -- last "no point" reason already logged
local again = false     -- /stepr now came in combat: send the same target again at combat end
local queued = false    -- a deferred check is waiting
local errN = 0
local seen = {}         -- one-time lines and chat messages
local ticker

local function stamp()
    return date and date("%Y-%m-%d %H:%M:%S") or "?"
end

local function Log(fmt, ...)
    if not DB then return end
    local log = DB.log
    if type(log) ~= "table" then log = {}; DB.log = log end
    log[#log + 1] = stamp() .. " " .. (select("#", ...) > 0 and fmt:format(...) or fmt)
    while #log > LOG_MAX do table.remove(log, 1) end
end

-- one short chat line per kind per session, for errors only
local function Warn(kind, text)
    if seen[kind] then return end
    seen[kind] = true
    print("StepRoute: " .. text)
end

-- a failure inside our own code is logged and swallowed, never raised (no error loop)
local function Safe(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        errN = errN + 1
        if errN <= ERR_MAX then Log("ERR %s %s", where, tostring(err)) end
    end
    return ok
end

-------------------------------------------------------------------------------
-- read RestedXP

-- an element that is still a live arrow target
local function Live(e)
    if e.hidden or e.skip then return false end
    local p = e.parent
    if type(p) == "table" and (p.completed or p.skip) then return false end
    if e.text and e.completed then return false end
    return true
end

local function HasPoint(e)
    return tonumber(e.zone) and tonumber(e.x) and tonumber(e.y)
end

-- first live arrow element with a map point in the active steps, and its step; normal before low priority.
-- third result: an element had world coordinates but no map point (RestedXP field names changed)
local function Scan(steps)
    local low, lowStep, odd
    for _, step in ipairs(steps) do
        local els = type(step) == "table" and step.elements
        if type(els) == "table" then
            for _, e in ipairs(els) do
                if type(e) == "table" and e.arrow and Live(e) then
                    if HasPoint(e) then
                        if not e.lowPrio then return e, step end
                        if not low then low, lowStep = e, step end
                    elseif tonumber(e.wx) and tonumber(e.wy) then
                        odd = true
                    end
                end
            end
        end
    end
    return low, lowStep, odd
end

-- "ok", element, step | "none", why | "fail", what
local function Read()
    local af, rf = _G.RXPG_ARROW, _G.RXPFrame
    if not (_G.RXPGuides or af or rf) then return "fail", "RXPGuides missing" end
    if UnitIsGhost and UnitIsGhost("player") then return "none", "ghost" end

    if type(af) == "table" then
        local e = af.element
        if e ~= nil and type(e) ~= "table" then return "fail", "RXPG_ARROW.element" end
        if e and type(e.step) == "table" and e.step.active and HasPoint(e) and Live(e) then
            return "ok", e, e.step
        end
    end

    local steps = type(rf) == "table" and rf.activeSteps
    if type(steps) ~= "table" then return "fail", "RXPFrame.activeSteps" end
    local e, estep, odd = Scan(steps)
    if e then return "ok", e, estep end
    if odd then return "fail", "element zone/x/y" end
    return "none", "no point"
end

-- a name as text: no colour codes, no group path
local function Clean(s)
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return s:match("([^\\]+)$") or s
end

-- the name RestedXP shows for a guide table: somname in season 1, else eraname, else displayname
-- (the same rule as RestedXP's own title; a field that is not a text is no name)
local function PickName(t, season1)
    if type(t) ~= "table" then return nil end
    local n
    if season1 and t.somname then n = t.somname
    elseif not season1 and t.eraname then n = t.eraname
    else n = t.displayname end
    if type(n) == "string" and n ~= "" then return n end
end

-- the guide inputs, cheap: internal key, live guide table, season 1 or not
local function GuideInputs()
    local c = _G.RXPCData
    local key = type(c) == "table" and type(c.currentGuideName) == "string" and c.currentGuideName ~= ""
        and c.currentGuideName or nil
    local rxp = type(_G.RXP) == "table" and _G.RXP or nil
    local profile = rxp and type(rxp.settings) == "table" and rxp.settings.profile
    local guide = rxp and type(rxp.currentGuide) == "table" and rxp.currentGuide or nil
    if guide and not key and type(guide.name) == "string" then key = guide.name end
    return key, guide, type(profile) == "table" and profile.season == 1
end

-- the name the player sees, and where it came from:
--   rxp  the live guide table (RXP.currentGuide, season from RXP.settings.profile.season)
--   meta RXPCData.guideMetaData, when the live guide is not readable
--   key  RXPCData.currentGuideName, the internal key, last resort
local function ResolveGuide(key, guide, season1)
    local shown = PickName(guide, season1)
    if shown then return shown, "rxp" end
    local c = _G.RXPCData
    local meta = type(c) == "table" and type(c.guideMetaData) == "table" and c.guideMetaData
    if meta and key then
        local m = meta[tostring(c.currentGuideGroup) .. "||" .. key]
        if type(m) ~= "table" then
            m = nil
            for _, v in pairs(meta) do
                if type(v) == "table" and v.name == key then m = v; break end
            end
        end
        shown = PickName(m, season1)
        if shown then return shown, "meta" end
    end
    return key, "key"
end

local gKey, gGuide, gSeason, gShown, gSrc   -- the last resolution, kept until an input changes
local gLogged                               -- the GUIDE line already written

-- the name the player sees for the active guide; logs one GUIDE line per change. Never raises.
local function Guide()
    local ok, key, guide, season1 = pcall(GuideInputs)
    if not ok then key, guide, season1 = nil, nil, false end
    if not (gSrc and key == gKey and guide == gGuide and season1 == gSeason) then
        local ok2, shown, src = pcall(ResolveGuide, key, guide, season1)
        if not (ok and ok2) then
            if not seen["fail:guide name"] then
                seen["fail:guide name"] = true
                Log("RXP read fail guide name")
            end
            shown, src = key, "key"
        end
        gKey, gGuide, gSeason = key, guide, season1
        gShown, gSrc = shown and Clean(shown) or "?", src
        local line = ("%s|%s|%s"):format(tostring(key), gShown, gSrc)
        if line ~= gLogged then
            gLogged = line
            Log('GUIDE key="%s" shown="%s" src=%s', tostring(key), gShown, gSrc)
        end
    end
    return gShown
end

-- one line of step text as plain text: no colour codes, textures, atlas tags, links, npc tokens, stray pipes
local function CleanText(s)
    s = s:gsub("|T.-|t", ""):gsub("|A.-|a", "")
    s = s:gsub("|H.-|h(.-)|h", "%1")
    s = s:gsub("|cRXP_%u+_", ""):gsub("RXP_%u+_", "")
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    s = s:gsub("npc:(.-):%d+", "%1"):gsub("::%d+", "")
    s = s:gsub("|", ""):gsub("%s+", " ")
    return (s:gsub("^ ", ""):gsub(" $", ""))
end

local TEXT_MAX = 40

-- cut a long text on a word (never inside a UTF-8 character) and add "..."
local function Shorten(s)
    if #s <= TEXT_MAX then return s end
    local i = TEXT_MAX
    while i > 0 and (s:byte(i + 1) or 0) >= 128 and (s:byte(i + 1) or 0) < 192 do i = i - 1 end
    local cut = s:sub(1, i)
    if not s:sub(i + 1, i + 1):match("%s") then cut = cut:match("^(.*%S)%s+%S*$") or cut end
    return cut .. "..."
end

-- the last text line of a step as the guide window lists it: the elements in order, each with its text
-- (else tooltipText, else rawtext), a text of one space and hideTooltip elements left out
local function StepText(step)
    local els = type(step) == "table" and step.elements
    if type(els) ~= "table" then return nil end
    local last
    for _, el in ipairs(els) do
        if type(el) == "table" and not el.hideTooltip then
            local raw
            if type(el.text) == "string" and el.text ~= " " then raw = el.text
            elseif type(el.tooltipText) == "string" and el.tooltipText ~= "" then raw = el.tooltipText
            elseif type(el.rawtext) == "string" and el.rawtext ~= "" then raw = el.rawtext end
            if raw then
                for line in raw:gsub("\\n", "\n"):gmatch("[^\n]+") do
                    line = CleanText(line)
                    if line ~= "" then last = line end
                end
            end
        end
    end
    return last and Shorten(last)
end

-- the route name and where it came from: "<last step text> #N" (step), else "<guide name> #N" (guide)
local function RouteName(step, shown, n)
    local ok, text = pcall(StepText, step)
    if not ok then
        if not seen["fail:step text"] then
            seen["fail:step text"] = true
            Log("RXP read fail step text")
        end
        text = nil
    end
    -- short: Mapzeroth shows its own "Step 1 of 1" for route legs, so the step is only #N
    if text then return ("%s #%s"):format(text, tostring(n)), "step" end
    return ("%s #%s"):format(shown, tostring(n)), "guide"
end

local function StepNumber(e, estep)
    local s = type(e) == "table" and (type(e.step) == "table" and e.step or estep)
    local n = type(s) == "table" and tonumber(s.index)
    if n then return n end
    local c = _G.RXPCData
    return type(c) == "table" and tonumber(c.currentStep) or "?"
end

-- RestedXP map points are 0-100; 0-1 is taken as it is
local function Coords(e)
    local x, y = tonumber(e.x), tonumber(e.y)
    if x > 1 or y > 1 then x, y = x / 100, y / 100 end
    return tonumber(e.zone), x, y
end

local function KeyOf(map, x, y)
    return ("%d:%.3f:%.3f"):format(map, x, y)
end

-------------------------------------------------------------------------------
-- send to Mapzeroth

-- name: the route name used (text="..."), src: step | guide
local function LogStep(guide, step, map, x, y, sent, why, name, src)
    Log('STEP guide="%s" step=%s map=%s x=%s y=%s sent=%d why=%s start=%d text="%s" src=%s',
        guide, tostring(step), map and tostring(map) or "-",
        x and ("%.3f"):format(x) or "-", y and ("%.3f"):format(y) or "-",
        sent, why, DB.start and 1 or 0, name and (name:gsub('"', "'")) or "-", src or "-")
end

-- true when Mapzeroth took the route
local function Send(guide, step, map, x, y, name, src)
    local mz = _G.MapzerothAPI
    if type(mz) ~= "table" or type(mz.RouteTo) ~= "function" then
        LogStep(guide, step, map, x, y, 0, "no mapzeroth", name, src)
        Warn("nomz", "Mapzeroth missing")
        return false
    end
    local opts = DB.start and { start = true } or {}
    local ok, res, why = pcall(mz.RouteTo, { mapID = map, x = x, y = y }, name, opts)
    if not ok then
        LogStep(guide, step, map, x, y, 0, "error " .. tostring(res), name, src)
        Warn("mzerr", "Mapzeroth error")
        return false
    elseif not res then
        LogStep(guide, step, map, x, y, 0, tostring(why), name, src)
        Warn("mzfalse", "Mapzeroth said " .. tostring(why))
        return false
    end
    LogStep(guide, step, map, x, y, 1, "ok", name, src)
    return true
end

-------------------------------------------------------------------------------
-- decide

-- force: send the current target again. Returns a short word for /stepr now.
local function Check(force)
    if not DB or not DB.on then return "off" end
    force = force or again
    local shown = Guide()          -- also writes the GUIDE line when the guide changed
    local st, e, estep = Read()

    if st == "fail" then
        if not seen["fail:" .. e] then
            seen["fail:" .. e] = true
            Log("RXP read fail %s", e)
            Warn("fail", "RXP read fail")
        end
        return "fail " .. e
    end

    if st == "none" then
        if noneWhy ~= e then
            noneWhy = e
            local c = _G.RXPCData
            LogStep(shown, type(c) == "table" and tonumber(c.currentStep) or "?", nil, nil, nil, 0, e)
        end
        return e
    end
    noneWhy = nil

    local map, x, y = Coords(e)
    local key = KeyOf(map, x, y)
    if key == sentKey and not force then
        combatKey = nil
        return "same"
    end

    local step = StepNumber(e, estep)
    local name, src = RouteName(estep, shown, step)
    if InCombatLockdown and InCombatLockdown() then
        again = again or force
        if combatKey ~= key or force then
            combatKey = key
            LogStep(shown, step, map, x, y, 0, "combat", name, src)
        end
        return "queued"
    end

    combatKey = nil
    again = false
    sentKey = key
    return Send(shown, step, map, x, y, name, src) and "sent" or "refused"
end

-- an event: look again soon, once however many events came
local function Later()
    if queued then return end
    queued = true
    C_Timer.After(DEFER, function()
        queued = false
        Safe("check", Check)
    end)
end

-------------------------------------------------------------------------------
-- start

local function Version(name)
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    if not get then return "-" end
    local ok, v = pcall(get, name, "Version")
    return ok and v or "-"
end

local function Init()
    local db = _G.StepRouteDB
    if type(db) ~= "table" then db = {}; _G.StepRouteDB = db end
    DB = db
    if DB.on == nil then DB.on = true end
    if DB.start == nil then DB.start = true end
    if type(DB.log) ~= "table" then DB.log = {} end

    local mz = _G.MapzerothAPI
    Log("BOOT v=%s on=%d start=%d rxp=%s arrow=%d frame=%d mz=%s",
        VERSION, DB.on and 1 or 0, DB.start and 1 or 0,
        _G.RXPGuides and Version("RXPGuides") or "-",
        type(_G.RXPG_ARROW) == "table" and 1 or 0,
        type(_G.RXPFrame) == "table" and 1 or 0,
        type(mz) == "table" and tostring(mz.version or "?") or "-")

    if not ticker then
        ticker = C_Timer.NewTicker(TICK, function() Safe("tick", Check) end)
    end
    Later()
end

local frame = CreateFrame("Frame")
for _, ev in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "QUEST_ACCEPTED", "QUEST_TURNED_IN",
    "QUEST_LOG_UPDATE", "ZONE_CHANGED_NEW_AREA", "PLAYER_REGEN_ENABLED" }) do
    pcall(frame.RegisterEvent, frame, ev)
end
frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        Safe("init", Init)
    elseif event == "PLAYER_REGEN_ENABLED" then
        Safe("check", Check)       -- the queued target goes out as soon as combat ends
    else
        Later()
    end
end)

-------------------------------------------------------------------------------
-- /stepr

local function Say(text) print("StepRoute " .. text) end

SLASH_STEPROUTE1 = "/stepr"
SLASH_STEPROUTE2 = "/steproute"
SlashCmdList["STEPROUTE"] = function(msg)
    if not DB then return end
    local a, b = (msg or ""):lower():match("^%s*(%S*)%s*(%S*)")
    if a == "on" then
        DB.on = true
        sentKey, combatKey, noneWhy, again = nil, nil, nil, false
        Say("on")
        Safe("check", Check)
    elseif a == "off" then
        DB.on = false
        Say("off")
    elseif a == "start" and (b == "on" or b == "off") then
        DB.start = (b == "on")
        Say("start " .. b)
    elseif a == "now" then
        local ok, res = pcall(Check, true)
        Say(ok and tostring(res) or "error")
    else
        Say(("%s, start %s. on|off|start on|off|now"):format(DB.on and "on" or "off", DB.start and "on" or "off"))
    end
end
