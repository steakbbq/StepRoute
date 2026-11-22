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
    walk(RXPCData, "RXPCData", 0); walk(MapzerothAPI, "MapzerothAPI", 0)
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
ok(logText():find("BOOT v=0.1.0 on=1 start=1", 1, true), "boot line: " .. logText())
ok(logText():find("mz=1", 1, true), "boot line shows mapzeroth api version")
ok(#W.calls == 0, "no route before the first read")
advance(1.1)
ok(#W.calls == 1, "first read sends once, got " .. #W.calls)
local c = W.calls[1]
ok(c and c.points.mapID == 1411 and math.abs(c.points.x - 0.452) < 1e-9 and math.abs(c.points.y - 0.563) < 1e-9,
   "point 0-100 turned into 0-1")
ok(c and c.name == "1-11 Durotar step 4", "route name: " .. tostring(c and c.name))
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
ok(#W.calls == 2 and W.calls[2].name == "1-11 Durotar step 5", "step change sends once")
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
ok(W.calls[2].points.x == 0.3 and W.calls[2].name == "1-11 Durotar step 6", "the latest target, not the first")
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
-- 12. toc

local f = assert(io.open(SRC .. "/StepRoute.toc", "rb"))
local toc = f:read("*a"); f:close()
ok(toc:find("## Interface: 16001", 1, true), "toc interface 16001")
ok(toc:find("## OptionalDeps: RXPGuides, Mapzeroth", 1, true), "toc optional deps")
ok(toc:find("## SavedVariables: StepRouteDB", 1, true), "toc saved variable")
ok(toc:find("## Version: 0.1.0", 1, true), "toc version matches")
ok(toc:find("StepRoute.lua", 1, true), "toc lists the file")

realPrint(string.format("RESULT steproute pass=%d fail=%d", PASS, FAIL))
if FAIL > 0 then error("tests failed") end
