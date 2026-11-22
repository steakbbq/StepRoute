-- StepRoute tests. Fake RestedXP, fake MapzerothAPI, fake WoW API. Test fixture only.
-- Run: python -I tools\lua_runner.py run tests\test_steproute.lua   (HERE and SRC are set by the runner)

local realPrint = print
local PASS, FAIL = 0, 0
local function ok(cond, label)
    if cond then PASS = PASS + 1 else FAIL = FAIL + 1; realPrint("FAIL " .. tostring(label)) end
end

-------------------------------------------------------------------------------
-- fake WoW API

local ENV_KEYS            -- globals present before any test world
local NOW, TIMERS, FRAMES, CHAT, COMBAT, GHOST
local KNOWN = { PLAYER_LOGIN = 1, PLAYER_ENTERING_WORLD = 1, QUEST_ACCEPTED = 1, QUEST_TURNED_IN = 1,
    QUEST_LOG_UPDATE = 1, ZONE_CHANGED_NEW_AREA = 1, PLAYER_REGEN_ENABLED = 1 }

local function advance(dt)
    local target = NOW + dt
    while NOW < target - 1e-9 do
        NOW = math.min(target, NOW + 0.05)
        local due = {}
        for i = #TIMERS, 1, -1 do
            local t = TIMERS[i]
            if t.cancelled then
                table.remove(TIMERS, i)
            elseif t.at <= NOW + 1e-9 then
                if t.every then t.at = NOW + t.every else table.remove(TIMERS, i) end
                due[#due + 1] = t
            end
        end
        for i = #due, 1, -1 do        -- oldest first (the list is walked backwards)
            if not due[i].cancelled then due[i].fn() end
        end
    end
end

local function fire(event, ...)
    for _, f in ipairs(FRAMES) do
        if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
    end
end

local function slash(msg) SlashCmdList.STEPROUTE(msg) end

local function installFakeApi()
    NOW, TIMERS, FRAMES, CHAT, COMBAT, GHOST = 1000, {}, {}, {}, false, false
    date = os.date
    time = os.time
    function GetTime() return NOW end
    function InCombatLockdown() return COMBAT end
    function UnitIsGhost() return GHOST end
    function print(...)
        local t = {}
        for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
        CHAT[#CHAT + 1] = table.concat(t, " ")
    end
    SlashCmdList = {}
    C_Timer = {}
    function C_Timer.After(sec, fn) TIMERS[#TIMERS + 1] = { at = NOW + sec, fn = fn } end
    function C_Timer.NewTicker(sec, fn)
        local t = { at = NOW + sec, every = sec, fn = fn }
        function t:Cancel() self.cancelled = true end
        TIMERS[#TIMERS + 1] = t
        return t
    end
    function CreateFrame()
        local f = { events = {}, scripts = {} }
        function f:RegisterEvent(e)
            if not KNOWN[e] then error("unknown event " .. tostring(e)) end
            self.events[e] = true
        end
        function f:SetScript(n, fn) self.scripts[n] = fn end
        FRAMES[#FRAMES + 1] = f
        return f
    end
end

-------------------------------------------------------------------------------
-- fake RestedXP and Mapzeroth

local W   -- the world of one scenario

local function newStep(index)
    return { index = index, active = true, elements = {} }
end

local function addPoint(step, zone, x, y, extra)
    local e = { arrow = true, parent = true, textOnly = true, text = "Go", zone = zone, x = x, y = y,
        wx = 111, wy = 222, step = step }
    for k, v in pairs(extra or {}) do e[k] = v end
    step.elements[#step.elements + 1] = e
    return e
end

-- the active step moves: the old one goes inactive, the arrow follows (zone nil = a step without a point)
local function go(index, zone, x, y)
    for _, s in ipairs(RXPFrame.activeSteps) do s.active = nil end
    for i = #RXPFrame.activeSteps, 1, -1 do RXPFrame.activeSteps[i] = nil end
    local step = newStep(index)
    RXPFrame.activeSteps[1] = step
    RXPCData.currentStep = index
    if zone then
        RXPG_ARROW.element = addPoint(step, zone, x, y)
    else
        step.elements[1] = { text = "Kill 10 boars", step = step }
    end
    return step
end

local function installWorld(opts)
    opts = opts or {}
    RXP = nil
    RXPGuides = { RegisterGuide = function() end }
    RXPCData = { currentGuideName = "1-11 Durotar", currentStep = 4 }
    RXPFrame = { activeSteps = {} }
    RXPG_ARROW = {}
    W = { calls = {}, mode = "ok" }
    MapzerothAPI = { version = 1, MAX_POINTS = 50 }
    function MapzerothAPI.RouteTo(points, name, options)
        W.calls[#W.calls + 1] = { points = points, name = name, options = options }
        if W.mode == "false" then return false, "bad point 1" end
        if W.mode == "throw" then error("mapzeroth exploded") end
        return true
    end
    go(4, 1411, 45.2, 56.3)
end

local function snapshot()
    local out = {}
    local seenT = {}
    local function walk(v, path, depth)
        if type(v) == "function" then out[#out + 1] = path .. "=fn" return end
        if type(v) ~= "table" then out[#out + 1] = path .. "=" .. tostring(v) return end
        if seenT[v] or depth > 6 then out[#out + 1] = path .. "=<seen>" return end
        seenT[v] = true
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local val = v[k]
            if val == nil then val = v[tonumber(k)] end
            walk(val, path .. "." .. k, depth + 1)
        end
    end
    walk(RXPGuides, "RXPGuides", 0); walk(RXPFrame, "RXPFrame", 0); walk(RXPG_ARROW, "RXPG_ARROW", 0)
    walk(RXPCData, "RXPCData", 0); walk(MapzerothAPI, "MapzerothAPI", 0); walk(RXP, "RXP", 0)
    return table.concat(out, "\n")
end

local function globalKeys()
    local t = {}
    for k in pairs(_G) do t[k] = true end
    return t
end

-- a fresh world, the addon loaded, PLAYER_LOGIN fired
local function boot(opts)
    installFakeApi()
    installWorld(opts)
    StepRouteDB = nil
    local before = globalKeys()
    local chunk = assert(loadfile(SRC .. "/StepRoute.lua"))
    chunk("StepRoute")
    W.newGlobals = {}
    for k in pairs(_G) do if not before[k] then W.newGlobals[#W.newGlobals + 1] = k end end
    table.sort(W.newGlobals)
    fire("PLAYER_LOGIN")
end

local function logText()
    return table.concat(StepRouteDB.log, "\n")
end

local function count(text, pat)
    local n = 0
    for _ in text:gmatch(pat) do n = n + 1 end
    return n
end

-------------------------------------------------------------------------------
-- 1. boot, first send, point conversion, name, start

boot()
ok(table.concat(W.newGlobals, ",") == "SLASH_STEPROUTE1,SLASH_STEPROUTE2,StepRouteDB" or
   table.concat(W.newGlobals, ",") == "SLASH_STEPROUTE1,SLASH_STEPROUTE2",
   "only own globals added: " .. table.concat(W.newGlobals, ","))
ok(StepRouteDB.on == true and StepRouteDB.start == true, "defaults on + start")
ok(logText():find("BOOT v=0.1.2 on=1 start=1", 1, true), "boot line: " .. logText())
ok(logText():find("mz=1", 1, true), "boot line shows mapzeroth api version")
ok(#W.calls == 0, "no route before the first read")
advance(1.1)
ok(#W.calls == 1, "first read sends once, got " .. #W.calls)
local c = W.calls[1]
ok(c and c.points.mapID == 1411 and math.abs(c.points.x - 0.452) < 1e-9 and math.abs(c.points.y - 0.563) < 1e-9,
   "point 0-100 turned into 0-1")
ok(c and c.name == "Go #4", "route name: " .. tostring(c and c.name))
ok(c and c.options.start == true, "start = true by default")
ok(logText():find('STEP guide="1-11 Durotar" step=4 map=1411 x=0.452 y=0.563 sent=1 why=ok', 1, true), "STEP line sent=1")

-- same target: never sent again
advance(10)
ok(#W.calls == 1, "same target not sent again, got " .. #W.calls)
-- rounding: a tiny move inside 0.001 is the same target
RXPG_ARROW.element.x = 45.2004
advance(2)
ok(#W.calls == 1, "tiny move is same target")

-- step change: new target goes out
go(5, 1411, 50.0, 40.0)
advance(1.1)
ok(#W.calls == 2 and W.calls[2].name == "Go #5", "step change sends once")
advance(5)
ok(#W.calls == 2, "no repeat after change")
-- 0-1 coordinates are taken as they are
go(6, 1412, 0.25, 0.75)
advance(1.1)
ok(#W.calls == 3 and W.calls[3].points.x == 0.25 and W.calls[3].points.y == 0.75, "0-1 point kept")

-------------------------------------------------------------------------------
-- 2. events are quicker than the tick, and coalesce

boot()
advance(1.1)
local n0 = #W.calls
go(7, 1411, 10, 10)
fire("QUEST_TURNED_IN"); fire("QUEST_LOG_UPDATE"); fire("QUEST_ACCEPTED"); fire("ZONE_CHANGED_NEW_AREA")
ok(#W.calls == n0, "event does not send at once (RestedXP moves first)")
advance(0.6)
ok(#W.calls == n0 + 1, "event check sent once after 0.5 s, got " .. (#W.calls - n0))
advance(3)
ok(#W.calls == n0 + 1, "event spam made one send")

-------------------------------------------------------------------------------
-- 3. combat: queue, latest target goes out on PLAYER_REGEN_ENABLED

boot()
advance(1.1)
ok(#W.calls == 1, "combat test: first send")
COMBAT = true
go(5, 1411, 20, 20)
advance(3)
ok(#W.calls == 1, "no send in combat")
ok(logText():find("map=1411 x=0.200 y=0.200 sent=0 why=combat", 1, true), "combat line logged")
ok(count(logText(), "why=combat") == 1, "combat line once")
go(6, 1411, 30, 30)
advance(3)
ok(#W.calls == 1, "still no send in combat")
COMBAT = false
fire("PLAYER_REGEN_ENABLED")
ok(#W.calls == 2, "queued target sent at combat end, got " .. #W.calls)
ok(W.calls[2].points.x == 0.3 and W.calls[2].name == "Go #6", "the latest target, not the first")
advance(5)
ok(#W.calls == 2, "queued target sent once")

-- in combat, target returns to what was already sent: nothing goes out
COMBAT = true
go(7, 1411, 60, 60)
advance(2)
go(6, 1411, 30, 30)       -- back to the sent target
advance(2)
COMBAT = false
fire("PLAYER_REGEN_ENABLED")
advance(2)
ok(#W.calls == 2, "no resend when the target came back in combat, got " .. #W.calls)

-------------------------------------------------------------------------------
-- 4. a step without a point; ghost

boot()
advance(1.1)
go(8, nil)
advance(1.1)
local before = #W.calls
advance(8)
ok(#W.calls == before, "no point: no send")
ok(logText():find("map=- x=- y=- sent=0 why=no point", 1, true), "no point logged")
ok(count(logText(), "why=no point") == 1, "no point logged once")
go(9, 1411, 70, 70)
advance(1.1)
ok(#W.calls == before + 1, "point after a no-point step is sent")
GHOST = true
go(10, 1411, 80, 80)
advance(3)
ok(#W.calls == before + 1, "ghost: nothing sent")
ok(logText():find("why=ghost", 1, true), "ghost logged")
GHOST = false
advance(1.1)
ok(#W.calls == before + 2, "alive again: current target sent")

-------------------------------------------------------------------------------
-- 5. fallback: the arrow has nothing, the active steps do (normal point before low priority)

boot()
RXPG_ARROW.element = nil
local st = RXPFrame.activeSteps[1]
st.elements = {}
addPoint(st, 1411, 11, 11, { lowPrio = true })
addPoint(st, 1411, 22, 22)
advance(1.1)
ok(#W.calls == 1 and W.calls[1].points.x == 0.22, "fallback picks the normal point first")
-- a completed element is skipped
st.elements[2].completed = true
advance(1.1)
ok(#W.calls == 2 and W.calls[2].points.x == 0.11, "completed element skipped, low priority used")
-- a stale arrow element (its step is inactive) is not used
RXPG_ARROW.element = { arrow = true, zone = 1, x = 1, y = 1, step = { active = nil }, text = "old" }
st.elements[1].skip = true
st.elements[2].completed = false
advance(1.1)
ok(#W.calls == 3 and W.calls[3].points.x == 0.22, "stale arrow element ignored, steps used")

-------------------------------------------------------------------------------
-- 6. missing RestedXP

boot()
RXPGuides, RXPG_ARROW, RXPFrame = nil, nil, nil
advance(1.1)
advance(20)
ok(#W.calls == 0, "no RestedXP: no send")
ok(count(logText(), "RXP read fail") == 1, "no RestedXP: one fail line: " .. logText())
ok(logText():find("RXP read fail RXPGuides missing", 1, true), "fail names what")
ok(#CHAT == 1, "no RestedXP: one chat line, got " .. #CHAT)

-------------------------------------------------------------------------------
-- 7. renamed fields: one fail line, nothing else, no loop

boot()
advance(1.1)
ok(#W.calls == 1, "renamed: first send before the rename")
RXPFrame.steps, RXPFrame.activeSteps = RXPFrame.activeSteps, nil   -- activeSteps renamed
RXPG_ARROW.element = nil
advance(20)
ok(#W.calls == 1, "renamed activeSteps: no send")
ok(count(logText(), "RXP read fail") == 1, "renamed activeSteps: one fail line")
ok(logText():find("RXPFrame.activeSteps", 1, true), "fail names the field")

boot()
RXPG_ARROW.element = nil
RXPFrame.activeSteps[1].elements[1].zone = nil                      -- zone renamed
RXPFrame.activeSteps[1].elements[1].mapID = 1411
advance(20)
ok(#W.calls == 0, "renamed zone: no send")
ok(count(logText(), "RXP read fail") == 1 and logText():find("element zone/x/y", 1, true), "renamed zone: one fail line")

boot()
RXPG_ARROW.element = "oops"                                          -- element no longer a table
advance(20)
ok(#W.calls == 0 and count(logText(), "RXP read fail") == 1, "arrow element wrong type: one fail line")

-------------------------------------------------------------------------------
-- 8. Mapzeroth says false; Mapzeroth throws; Mapzeroth missing

boot()
W.mode = "false"
advance(1.1)
ok(#W.calls == 1, "mapzeroth false: tried once")
ok(logText():find("sent=0 why=bad point 1", 1, true), "mapzeroth why logged")
advance(10)
ok(#W.calls == 1, "mapzeroth false: not retried each tick")
ok(#CHAT == 1, "mapzeroth false: one chat line")
go(5, 1411, 12, 12)
W.mode = "ok"
advance(1.1)
ok(#W.calls == 2, "next target tried again")

boot()
W.mode = "throw"
advance(1.1)
advance(10)
ok(#W.calls == 1, "mapzeroth error: tried once")
ok(logText():find("sent=0 why=error", 1, true), "mapzeroth error logged")

boot()
MapzerothAPI = nil
advance(1.1)
ok(logText():find("sent=0 why=no mapzeroth", 1, true), "no mapzeroth logged")
advance(10)
ok(count(logText(), "why=no mapzeroth") == 1, "no mapzeroth logged once")
ok(#CHAT == 1, "no mapzeroth: one chat line")

-------------------------------------------------------------------------------
-- 9. slash commands

boot()
advance(1.1)
slash("start off")
go(5, 1411, 12, 12)
advance(1.1)
ok(#W.calls == 2 and W.calls[2].options.start == nil, "start off: route waits for Start")
slash("start on")
go(6, 1411, 13, 13)
advance(1.1)
ok(#W.calls == 3 and W.calls[3].options.start == true, "start on again")
slash("now")
ok(#W.calls == 4 and W.calls[4].points.x == 0.13, "now sends the same target again")
slash("off")
go(7, 1411, 14, 14)
advance(5)
ok(#W.calls == 4, "off: no send")
slash("on")
ok(#W.calls == 5 and W.calls[5].points.x == 0.14, "on: current target sent at once")
COMBAT = true
slash("now")
ok(#W.calls == 5, "now in combat is queued")
COMBAT = false
fire("PLAYER_REGEN_ENABLED")
ok(#W.calls == 6, "now queued goes out at combat end")
slash("")
slash("bogus")
ok(#CHAT >= 2, "help line printed")
ok(StepRouteDB.on == true and StepRouteDB.start == true, "db flags kept")

-------------------------------------------------------------------------------
-- 10. an error while reading is swallowed and logged, not looped

boot()
local bad = setmetatable({}, { __index = function() error("rxp internals changed") end })
RXPG_ARROW.element = nil
RXPFrame.activeSteps[1] = bad
advance(30)
ok(#W.calls == 0, "read error: no send")
ok(count(logText(), "ERR tick") >= 1 and count(logText(), "ERR tick") <= 20, "read error logged and capped")

-------------------------------------------------------------------------------
-- 11. read only: RestedXP and Mapzeroth tables unchanged; log is a ring

boot()
local snap1 = snapshot()
advance(1.1)
go(5, 1411, 12, 12)
local snap2 = snapshot()
advance(5)
fire("QUEST_ACCEPTED"); advance(1)
slash("now"); slash("off"); slash("on")
-- go() changed the fake itself; compare around a pure read period
local snapA = snapshot()
advance(30)
local snapB = snapshot()
ok(snapA == snapB, "no field written on RestedXP or Mapzeroth tables over 30 s")

boot()
advance(1.1)
for i = 1, 300 do
    go(i, 1411, (i % 90) + 1, 5)
    advance(1.1)
end
ok(#StepRouteDB.log <= 200, "log capped at 200, got " .. #StepRouteDB.log)
ok(StepRouteDB.log[#StepRouteDB.log]:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d STEP "), "every line has a time stamp")

-------------------------------------------------------------------------------
-- 13. the guide name the player sees (live 0.1.0 showed the internal key "27-29 ...", RestedXP shows "28-31 ...")

local KEY = "27-29 Wetlands/Excavation Site"
local function guideOf(fields, season)
    return { settings = { profile = { season = season } }, currentGuide = fields }
end

local function nameCase(label, rxp, meta, expectShown, expectSrc)
    boot()
    RXPCData.currentGuideName = KEY
    RXPCData.currentGuideGroup = "RestedXP Forever Dungeon Guide (A)"
    RXPCData.guideMetaData = meta
    RXP = rxp
    go(36, 1455, 69.5, 50.3)
    RXPG_ARROW.element.text = nil           -- no step text: the name falls back to the guide name
    advance(1.1)
    ok(W.calls[1] and W.calls[1].name == expectShown .. " #36", label .. " route name: " .. tostring(W.calls[1] and W.calls[1].name))
    ok(logText():find('GUIDE key="' .. KEY .. '" shown="' .. expectShown .. '" src=' .. expectSrc, 1, true), label .. " GUIDE line: " .. logText())
    ok(logText():find('STEP guide="' .. expectShown .. '" step=36 map=1455 x=0.695 y=0.503 sent=1 why=ok', 1, true), label .. " STEP line")
    ok(logText():find('text="' .. expectShown .. ' #36" src=guide', 1, true), label .. " STEP text + src=guide")
end

local ALL = { name = KEY, displayname = KEY, eraname = "28-31 Wetlands/Excavation Site", somname = "SoM Wetlands" }
nameCase("era", guideOf(ALL, 0), nil, "28-31 Wetlands/Excavation Site", "rxp")
nameCase("era, season nil", guideOf(ALL, nil), nil, "28-31 Wetlands/Excavation Site", "rxp")
nameCase("som", guideOf(ALL, 1), nil, "SoM Wetlands", "rxp")
nameCase("som without somname = displayname", guideOf({ name = KEY, displayname = "Shown D", eraname = "Era E" }, 1), nil, "Shown D", "rxp")
nameCase("era without eraname = displayname", guideOf({ name = KEY, displayname = "Shown D", somname = "Som S" }, 0), nil, "Shown D", "rxp")
nameCase("colour codes stripped", guideOf({ name = KEY, eraname = "|cff00ff00Green|r Wetlands" }, 0), nil, "Green Wetlands", "rxp")
nameCase("guide without names: key", guideOf({ name = KEY }, 0), nil, KEY, "key")
nameCase("no RXP, no meta: key", nil, nil, KEY, "key")
nameCase("no RXP, meta by key", nil,
    { ["RestedXP Forever Dungeon Guide (A)||" .. KEY] = { name = KEY, displayname = "Meta D", eraname = "Meta Era" } },
    "Meta Era", "meta")
nameCase("no RXP, meta found by name", nil,
    { ["some other key"] = { name = KEY, displayname = "Meta D" } }, "Meta D", "meta")
nameCase("RXP without currentGuide, meta", { settings = { profile = { season = 0 } } },
    { ["RestedXP Forever Dungeon Guide (A)||" .. KEY] = { name = KEY, eraname = "Meta Era" } }, "Meta Era", "meta")
nameCase("name fields not text: key", guideOf({ name = KEY, eraname = 42, displayname = {} }, 0), nil, KEY, "key")

-- one GUIDE line per guide change, not per send
boot()
RXPCData.currentGuideName = KEY
RXP = guideOf(ALL, 0)
advance(1.1)
go(37, 1455, 10, 10); advance(1.1)
go(38, 1455, 20, 20); advance(1.1)
ok(count(logText(), "GUIDE key") == 1, "GUIDE once for three sends, got " .. count(logText(), "GUIDE key"))
RXPCData.currentGuideName = "31-33 Arathi Highlands"
RXP = guideOf({ name = "31-33 Arathi Highlands", eraname = "33-36 Arathi Highlands" }, 0)
go(1, 1417, 30, 30); RXPG_ARROW.element.text = nil; advance(1.1)
ok(count(logText(), "GUIDE key") == 2, "second GUIDE line for the new guide")
ok(logText():find('GUIDE key="31-33 Arathi Highlands" shown="33-36 Arathi Highlands" src=rxp', 1, true), "new guide line")
ok(W.calls[#W.calls].name == "33-36 Arathi Highlands #1", "route name for the new guide: " .. tostring(W.calls[#W.calls].name))
-- a guide with no point still gets its GUIDE line (no send needed)
go(2, nil)
RXPCData.currentGuideName = "11-12 Elwynn"
RXP = guideOf({ name = "11-12 Elwynn", eraname = "11-12 Elwynn Forest" }, 0)
advance(1.1)
ok(logText():find('GUIDE key="11-12 Elwynn" shown="11-12 Elwynn Forest"', 1, true), "GUIDE line without a send")

-- reading the guide name fails: logged once, the route still goes out under the key
boot()
RXPCData.currentGuideName = KEY
RXP = { settings = { profile = { season = 0 } },
        currentGuide = setmetatable({}, { __index = function() error("guide internals changed") end }) }
go(36, 1455, 69.5, 50.3)
RXPG_ARROW.element.text = nil
advance(20)
ok(#W.calls == 1 and W.calls[1].name == KEY .. " #36", "guide name read error: route under the key")
ok(count(logText(), "RXP read fail guide name") == 1, "guide name read error: one fail line")
ok(logText():find('src=key', 1, true), "guide name read error: src=key")

-- read only: the live guide, RXP settings and saved data are not written
boot()
RXPCData.currentGuideName = KEY
RXPCData.guideMetaData = { a = { name = KEY, eraname = "E" } }
RXP = guideOf(ALL, 0)
advance(1.1)
local gA = snapshot()
advance(30)
slash("now")
ok(gA == snapshot(), "guide name read writes nothing on RXP, RXPCData or Mapzeroth tables")

-------------------------------------------------------------------------------
-- 14. route name = the last text line of the step, plus " #N"

local GOTO = {}      -- marks the element the arrow points at
local function stepCase(label, els, expectName, expectSrc, opts)
    opts = opts or {}
    boot()
    RXPCData.currentGuideName = KEY
    local step = newStep(37)
    local arrow
    for _, el in ipairs(els) do
        if el == GOTO then
            el = { arrow = true, zone = 1455, x = 69.5, y = 50.3, wx = 1, wy = 2 }
            arrow = el
        elseif type(el) == "string" then
            el = { text = el }
        end
        if not opts.noBackRef then el.step = step end
        step.elements[#step.elements + 1] = el
    end
    for _, old in ipairs(RXPFrame.activeSteps) do old.active = nil end
    RXPFrame.activeSteps[1] = step
    RXPG_ARROW.element = (not opts.scan) and arrow or nil
    advance(1.1)
    local call = W.calls[#W.calls]
    ok(call and call.name == expectName, label .. " name: " .. tostring(call and call.name))
    if not opts.noLog then
        ok(logText():find('text="' .. expectName .. '" src=' .. expectSrc, 1, true), label .. " log text + src: " .. logText())
    end
    return call
end

local function dashes(n) return ("abcd "):rep(n) end

-- Screenshot: step 37, "Talk to Gryth Thurden" then "Fly to Wetlands"
local c37 = stepCase("2 lines", { GOTO, "Talk to Gryth Thurden", "Fly to Wetlands" }, "Fly to Wetlands #37", "step")
ok(c37 and c37.points.mapID == 1455, "2 lines: the point is unchanged")
ok(logText():find('STEP guide="27-29 Wetlands/Excavation Site" step=37 map=1455 x=0.695 y=0.503 sent=1 why=ok start=1 text="Fly to Wetlands #37" src=step', 1, true), "2 lines: full STEP line")
stepCase("goto last in the list", { "Talk to Gryth Thurden", "Fly to Wetlands", GOTO }, "Fly to Wetlands #37", "step")
stepCase("1 line", { GOTO, "Talk to Gryth Thurden" }, "Talk to Gryth Thurden #37", "step")
stepCase("2 lines in one element", { GOTO, "Talk to Gryth Thurden\nFly to Wetlands" }, "Fly to Wetlands #37", "step")
stepCase("literal backslash n", { GOTO, "Talk to Gryth Thurden\\nFly to Wetlands" }, "Fly to Wetlands #37", "step")
stepCase("empty last lines skipped", { GOTO, "Fly to Wetlands\n   \n" }, "Fly to Wetlands #37", "step")
stepCase("one space text ignored", { GOTO, "Fly to Wetlands", " " }, "Fly to Wetlands #37", "step")
stepCase("hideTooltip element ignored", { GOTO, "Fly to Wetlands", { text = "Hidden line", hideTooltip = true } }, "Fly to Wetlands #37", "step")
stepCase("tooltipText when no text", { GOTO, { tooltipText = "Tip line" } }, "Tip line #37", "step")
stepCase("rawtext when no text", { GOTO, { rawtext = "Raw line" } }, "Raw line #37", "step")
stepCase("text beats tooltipText", { GOTO, { text = "Own text", tooltipText = "Tip line" } }, "Own text #37", "step")

-- codes stripped
stepCase("colour codes", { GOTO, "|cff00ff00Talk|r to |cffffd100Gryth Thurden|r" }, "Talk to Gryth Thurden #37", "step")
stepCase("texture + atlas tags", { GOTO, "|TInterface\\Icons\\Foo:0|t Fly |A:Taxi_Frame_Gray:12:12|a to   Wetlands" }, "Fly to Wetlands #37", "step")
stepCase("RXP colour tokens", { GOTO, "Talk to |cRXP_FRIENDLY_Gryth Thurden|r" }, "Talk to Gryth Thurden #37", "step")
stepCase("RXP bare token", { GOTO, "Kill RXP_ENEMY_Boars" }, "Kill Boars #37", "step")
stepCase("npc token", { GOTO, "Talk to npc:Gryth Thurden:2431" }, "Talk to Gryth Thurden #37", "step")
stepCase("name::id", { GOTO, "Talk to |cffffd100Gryth Thurden::2431|r" }, "Talk to Gryth Thurden #37", "step")
stepCase("link", { GOTO, "Get |Hitem:1234::::|h[Linen Cloth]|h" }, "Get [Linen Cloth] #37", "step")
stepCase("stray pipe", { GOTO, "Fly to |Wetlands" }, "Fly to Wetlands #37", "step")
stepCase("extra spaces", { GOTO, "  Fly    to \t Wetlands  " }, "Fly to Wetlands #37", "step")

-- long text: cut on a word, "..." added
stepCase("long text", { GOTO, "Kill 12 Dragonmaw Warriors and bring back their heads to the quest giver" },
    "Kill 12 Dragonmaw Warriors and bring... #37", "step")
stepCase("cut exactly at a word end", { GOTO, dashes(7) .. "abcde more words here" }, dashes(7) .. "abcde... #37", "step")
stepCase("exactly 40 chars is not cut", { GOTO, dashes(7) .. "abcde" }, dashes(7) .. "abcde #37", "step")
stepCase("one long word: hard cut", { GOTO, ("w"):rep(60) }, ("w"):rep(40) .. "... #37", "step")
stepCase("UTF-8 not cut inside a character", { GOTO, ("\226\130\172"):rep(20) }, ("\226\130\172"):rep(13) .. "... #37", "step")
ok(#W.calls[#W.calls].name <= 40 + 3 + 4, "long text: name length kept short")
stepCase("a quote in the text", { GOTO, 'Talk to "Gryth"' }, 'Talk to "Gryth" #37', "step", { noLog = true })
ok(logText():find("text=\"Talk to 'Gryth' #37\"", 1, true), "a quote in the text is written as ' in the log")

-- no text: the 0.1.1 name
stepCase("no text", { GOTO }, KEY .. " #37", "guide")
stepCase("only a one-space text", { GOTO, " " }, KEY .. " #37", "guide")
stepCase("only codes", { GOTO, "|cff00ff00|r |TFoo|t" }, KEY .. " #37", "guide")
stepCase("text not a string", { GOTO, { text = 42, tooltipText = {}, rawtext = true } }, KEY .. " #37", "guide")

-- scan path: the element has no step field, the step comes from the active steps
stepCase("scan path without element.step", { GOTO, "Fly to Wetlands" }, "Fly to Wetlands #37", "step", { scan = true, noBackRef = true })
-- the step number is the step's index also then
ok(logText():find("step=37 map=1455", 1, true), "scan path: step number from the step")

-- reading the step text fails: logged once, the route goes out under the guide name
local bad = setmetatable({}, { __index = function() error("step internals changed") end })
local cb = stepCase("step text read error", { GOTO, bad }, KEY .. " #37", "guide")
ok(count(logText(), "RXP read fail step text") == 1, "step text read error: one fail line")
advance(20)
ok(#W.calls == 1 and count(logText(), "RXP read fail step text") == 1, "step text read error: no loop")

-- combat line carries the text too; same position with new text is not sent again
boot()
advance(1.1)
COMBAT = true
go(37, 1455, 40, 40)
RXPG_ARROW.element.step.elements[#RXPG_ARROW.element.step.elements + 1] = { text = "Fly to Wetlands", step = RXPG_ARROW.element.step }
advance(2)
ok(logText():find('sent=0 why=combat start=1 text="Fly to Wetlands #37" src=step', 1, true), "combat line has the text")
COMBAT = false
fire("PLAYER_REGEN_ENABLED")
ok(W.calls[#W.calls].name == "Fly to Wetlands #37", "queued send has the text")
local n1 = #W.calls
go(38, 1455, 40, 40)
RXPG_ARROW.element.step.elements[#RXPG_ARROW.element.step.elements + 1] = { text = "Another text", step = RXPG_ARROW.element.step }
advance(5)
ok(#W.calls == n1, "same position, new step text: not sent again")
slash("now")
ok(#W.calls == n1 + 1 and W.calls[#W.calls].name == "Another text #38", "now sends the new text")

-- read only: step text reading writes nothing
boot()
RXPCData.currentGuideName = KEY
do
    local step = newStep(37)
    local el = { arrow = true, zone = 1455, x = 69.5, y = 50.3, wx = 1, wy = 2, step = step }
    step.elements = { el, { text = "|cff00ff00Fly|r to Wetlands", step = step } }
    RXPFrame.activeSteps[1].active = nil
    RXPFrame.activeSteps[1] = step
    RXPG_ARROW.element = el
end
advance(1.1)
local sA = snapshot()
advance(30)
slash("now")
ok(sA == snapshot(), "step text reading writes nothing on RestedXP, RXPCData or Mapzeroth tables")

-------------------------------------------------------------------------------
-- 12. toc

local f = assert(io.open(SRC .. "/StepRoute.toc", "rb"))
local toc = f:read("*a"); f:close()
ok(toc:find("## Interface: 16001", 1, true), "toc interface 16001")
ok(toc:find("## OptionalDeps: RXPGuides, Mapzeroth", 1, true), "toc optional deps")
ok(toc:find("## SavedVariables: StepRouteDB", 1, true), "toc saved variable")
ok(toc:find("## Version: 0.1.2", 1, true), "toc version matches")
ok(toc:find("StepRoute.lua", 1, true), "toc lists the file")

realPrint(string.format("RESULT steproute pass=%d fail=%d", PASS, FAIL))
if FAIL > 0 then error("tests failed") end
