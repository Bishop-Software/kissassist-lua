-- pull.lua — Pull module: mob discovery, validation, and pull execution.
-- Ported from kissassist.mac FindMobToPull (8945), PullValidate (9443), PullCheck (9308).
-- Steps 7.5 (scaffold+INI), 7.6 (pullValidate), 7.7 (findMobToPull), 7.8 (pullCheck).

local mq     = require('mq')
local Config = require('modules.config')

local Pull = {}
local _state, _utils, _cast, _movement, _combat, _pet, _bard, _healing, _comms

local PULL_LOC_SLOTS = 5  -- PullLocs1-5 (mac:14976)

-- Classes whose rampage pets CheckRampPets waits on (mac:8965).
local RAMP_PET_CLASSES = {MAG = true, NEC = true, BST = true}

-- ---------------------------------------------------------------------------
-- Local helpers
-- ---------------------------------------------------------------------------

-- 2D XY distance.
local function dist2D(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return math.sqrt(dx * dx + dy * dy)
end

-- True once the pull has drawn aggro (live XTarget check; see Utils.pullAggroID).
local function hasAggro()
    return _utils.pullAggroID() > 0
end

-- Case-insensitive name search in a comma/pipe-separated list.
-- '*' prefix = substring match; '#' prefix = strip then exact; plain = exact.
local function inNameList(list, name)
    if not list or list == 'null' or list == 'all' or list == '' then return false end
    local lname = name:lower()
    for entry in (list..'|'):gmatch('([^,|]+)[,|]') do
        entry = entry:match('^%s*(.-)%s*$')
        local ch = entry:sub(1, 1)
        if ch == '*' then
            if lname:find(entry:sub(2):lower(), 1, true) then return true end
        elseif ch == '#' then
            if lname == entry:sub(2):lower() then return true end
        else
            if lname == entry:lower() then return true end
        end
    end
    return false
end

-- Compass heading in degrees from (fromY, fromX) to (toY, toX): 0 = north,
-- clockwise (90 = east), the same as Me.Heading.Degrees and the arc facing.
-- MQ's raw HeadingTo value (MQ2SpawnType.cpp) runs counter-clockwise; its
-- .Degrees member, which the mac reads (mac:14515), is 360 minus that. EQ's +X
-- is west, so the raw value alone mirrors east and west.
function Pull.headingTo(fromY, fromX, toY, toX)
    -- Computed directly (east = fromX - toX, north = toY - fromY) rather than as
    -- 360 - raw, which leaves 360 instead of 0 due north from rounding.
    ---@diagnostic disable-next-line: deprecated
    local deg = math.deg(math.atan2(fromX - toX, toY - fromY))
    if deg < 0 then deg = deg + 360 end
    return deg
end

-- Left/right edges of a pull arc of `width` degrees centred on `facing`, wrapped
-- into 0-360. Mirrors Sub SetPullAngles (mac:14490).
function Pull.pullAngles(facing, width)
    local half  = width * 0.5
    local lSide = facing - half
    if lSide < 0 then lSide = 360 + lSide end
    local rSide = facing + half
    if rSide > 360 then rSide = rSide - 360 end
    return lSide, rSide
end

-- ---------------------------------------------------------------------------
-- Pull arc on the MQ2Map map (Lua port addition). MQ2Map can't draw lines, so
-- each edge of the arc is a dotted line of /maploc markers from the camp out to
-- MaxRadius; with the PullRadius circle (paintMap) that outlines the wedge.
-- ---------------------------------------------------------------------------
local ARC_DOTS = 4   -- markers per edge, evenly spaced out to MaxRadius

local function mapLoaded()
    local plugin = mq.TLO.Plugin('MQ2Map')
    return plugin ~= nil and plugin.IsLoaded() == true
end

local function isArcRole()
    local role = _state.session.role or ''
    return role:find('puller', 1, true) ~= nil or role:find('hunter', 1, true) ~= nil
end

-- Remove the arc markers this session placed (never a bare "/maploc remove",
-- which deletes every map loc).
function Pull.clearArc()
    local marks = _state.pull.arcMarks or {}
    if #marks > 0 and mapLoaded() then
        for _, loc in ipairs(marks) do mq.cmdf('/squelch /maploc remove %s', loc) end
    end
    _state.pull.arcMarks = {}
end

-- Point `dist` from camp on compass heading `deg` (0 north = +Y, 90 east = -X).
function Pull.arcPoint(campY, campX, deg, dist)
    local r = math.rad(deg)
    return campY + dist * math.cos(r), campX - dist * math.sin(r)
end

-- Redraw the arc's edges around the camp. Clears them when the arc is off,
-- there's no camp, or this isn't a puller/hunter role.
function Pull.drawArc()
    Pull.clearArc()
    local p, mv = _state.pull, _state.movement
    if (p.pullArcWidth or 0) <= 0 or not isArcRole() then return end
    if (mv.campX or 0) == 0 and (mv.campY or 0) == 0 then return end
    if not mapLoaded() then return end
    local radius = p.maxRadius or 0
    if radius <= 0 then return end
    local marks = {}
    for _, side in ipairs({ { p.lSide, 'Pull arc L' }, { p.rSide, 'Pull arc R' } }) do
        for i = 1, ARC_DOTS do
            local y, x = Pull.arcPoint(mv.campY, mv.campX, side[1], radius * i / ARC_DOTS)
            -- MQ2Map tags map locs by whole-number loc, so place and remove by that.
            local loc = string.format('%d %d', math.floor(y + 0.5), math.floor(x + 0.5))
            local label = (i == ARC_DOTS) and (' label ' .. side[2]) or ''
            mq.cmdf('/squelch /maploc size 10 color 255 200 0 %s%s', loc, label)
            marks[#marks + 1] = loc
        end
    end
    p.arcMarks = marks
end

-- Aim the pull arc: store its edges and facing in State.pull (mac:14490).
-- A width of 0 turns it off and clears the map markers.
function Pull.setPullAngles(facing, width, quiet)
    if not width or width <= 0 then Pull.clearArc() return end
    facing = facing or 0
    local p = _state.pull
    p.lSide, p.rSide = Pull.pullAngles(facing, width)
    p.heading = facing
    if not quiet then
        printf('\aySetting Pull Angles. Facing: \at%.2f\ay Left Side: \at%.2f\ay Right Side: \at%.2f\ay Width: \at%d',
            facing, p.lSide, p.rSide, width)
    end
    Pull.drawArc()
end

-- Check whether mobID falls within the configured pull arc.
-- Mac: FigureMobAngle (mac:14511-14520)
-- The .mac reads Spawn[mob].HeadingTo[CampY,CampX], but MQ's HeadingTo ignores its
-- argument and measures from the player, so it only matches the camp while the
-- puller stands there. Measure from the camp itself.
local function figureMobAngle(mobID)
    local sp = mq.TLO.Spawn('id ' .. mobID)
    if not sp() then return false end
    local dir = Pull.headingTo(_state.movement.campY, _state.movement.campX, sp.Y() or 0, sp.X() or 0)
    local lSide, rSide = _state.pull.lSide, _state.pull.rSide
    -- lSide >= rSide means the arc wraps through 0/360.
    if lSide >= rSide then
        if dir < lSide and dir > rSide then return false end
    else
        if dir < lSide or dir > rSide then return false end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------

-- Hunter role setup from CheckRoles (mac:8735-8798). Runs at startup after the
-- INI is loaded. A hunter engages at 100%. With ReturnToCamp on, it is turned
-- off: the hunter fights where it pulls and walks back only when it runs out of
-- mobs. With it off, the hunter stays put and pulls on its way back (StayPut +
-- PullOnReturn). Main assist identity is set in init.lua (TANK_ROLES).
function Pull.setupHunterRole()
    local s    = _state
    local role = s.session.role
    if role ~= 'hunter' and role ~= 'hunterpettank' then return end
    s.combat.assistAt = 100
    if s.combat.useMQ2Melee then
        mq.cmdf('/squelch /melee aggro=%d', role == 'hunter' and 1 or 0)
    end
    if s.movement.returnToCamp then
        s.movement.returnToCamp = false
        s.movement.stayPut      = false
    else
        s.movement.stayPut  = true
        s.pull.pullOnReturn = true
    end
    if role == 'hunterpettank' then
        s.session.chaseAssist = false
        s.misc.mountOn        = false
        s.pet.assistAt        = 100
    end
    if (mq.TLO.Me.Pet.ID() or 0) > 0 then mq.cmd('/pet follow') end
    _utils.debug('pull', 'setupHunterRole: role=%s stayPut=%s pullOnReturn=%s',
        role, tostring(s.movement.stayPut), tostring(s.pull.pullOnReturn))
end

-- Puller role setup from CheckRoles (mac:8688-8734, 8803-8826). Runs at startup
-- after the INI is loaded. Pullers always return to camp: executePull only walks
-- back and waits for the mob when ReturnToCamp is on, and the INI default is 0.
-- Main assist identity is set in init.lua (TANK_ROLES); pet taunt is handled by
-- the pet module; the PullRoleToggle group-leader check is in Pull.init.
function Pull.setupPullerRole()
    local s    = _state
    local role = s.session.role
    if role ~= 'puller' and role ~= 'pullertank' and role ~= 'pullerpettank' then return end
    s.movement.returnToCamp     = true
    s.session.chaseAssist       = false
    -- Leash: past this, ReturnToCamp turns off (mac CampRadiusExceed)
    s.movement.campRadiusExceed = (s.pull.maxRadius or 0) + 200
    if s.combat.useMQ2Melee then
        mq.cmdf('/squelch /melee aggro=%d', role == 'pullertank' and 1 or 0)
    end
    if role ~= 'puller' then s.combat.assistAt = 100 end
    if role == 'pullerpettank' then
        s.combat.meleeOn = false  -- the pet does the fighting
        s.misc.mountOn   = false
        s.pet.assistAt   = 100
    end
    -- Pet: guard if it's close by, else follow (mac:8705, 8728, 8818)
    if (mq.TLO.Me.Pet.ID() or 0) > 0 then
        mq.cmd((mq.TLO.Me.Pet.Distance() or 999) <= (s.movement.campRadius or 30)
            and '/pet guard' or '/pet follow')
    end
    _utils.debug('pull', 'setupPullerRole: role=%s campRadiusExceed=%d',
        role, s.movement.campRadiusExceed)
end

-- Load this zone's pull/ignore lists from KissAssist_Info.ini (shared across
-- characters). Called at startup and again after zoning.
function Pull.loadZoneLists()
    local infoFile = _state.session.infoFileName or ''
    local zone     = _state.session.zoneName     or ''
    local raw = _utils.zoneIniGet(infoFile, zone, 'MobsToPull') or 'all'
    if raw == '' or raw == 'null' or raw:lower():find('all for all', 1, true) then raw = 'all' end
    _state.pull.mobsToPullRaw = raw
    _state.pull.mobsToIgnore  = _utils.zoneIniGet(infoFile, zone, 'MobsToIgnore') or 'null'
    Pull.setRanking(_state.pull.ranking, true)
    -- No-pull areas, PullLocs1-5 in the zone section (mac:14979).
    local raws = {}
    for i = 1, PULL_LOC_SLOTS do
        local v = _utils.zoneIniGet(infoFile, zone, 'PullLocs' .. i)
        if Pull.parsePullLoc(v) then
            raws[i] = v
        else
            raws[i] = ''
            local lv = v and v:lower() or ''
            if lv ~= '' and lv ~= '0' and lv ~= 'null' then
                printf('\ayPullLocs%d "%s" is not Y,X|Range, ignoring it.', i, v)
            end
        end
    end
    _state.pull.pullLocsRaw = raws
    Pull.buildPullLocAreas()
end

-- Parse a PullLocs entry 'Y,X|Range' (mac:14978). Returns {y, x, range} or nil
-- for an empty or malformed entry ('0' and 'null' are empty).
function Pull.parsePullLoc(raw)
    if not raw then return nil end
    local y, x, r = tostring(raw):match('^%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)%s*|%s*([%d%.]+)%s*$')
    y, x, r = tonumber(y), tonumber(x), tonumber(r)
    if not (y and x and r) or r <= 0 then return nil end
    return { y = y, x = x, range = r }
end

-- Rebuild the parsed no-pull areas from pull.pullLocsRaw.
function Pull.buildPullLocAreas()
    local areas = {}
    for _, raw in ipairs(_state.pull.pullLocsRaw or {}) do
        local a = Pull.parsePullLoc(raw)
        if a then areas[#areas + 1] = a end
    end
    _state.pull.pullLocAreas = areas
end

-- Set no-pull area slot i (1-5) to 'Y,X|Range', or clear it with '' / nil, and
-- save it to the zone section of KissAssist_Info.ini. Returns false if the
-- text is not a valid entry.
function Pull.setPullLoc(i, raw)
    raw = raw and raw:match('^%s*(.-)%s*$') or ''
    if raw ~= '' and not Pull.parsePullLoc(raw) then return false end
    local p = _state.pull
    p.pullLocsRaw = p.pullLocsRaw or {}
    p.pullLocsRaw[i] = raw
    Pull.buildPullLocAreas()
    local infoFile = _state.session.infoFileName or ''
    local zone     = _state.session.zoneName     or ''
    if infoFile ~= '' and zone ~= '' then
        mq.cmdf('/ini "%s" "%s" "PullLocs%d" "%s"', infoFile, zone, i, raw ~= '' and raw or 'null')
    end
    return true
end

-- True if (y, x) is inside one of the no-pull areas.
function Pull.inPullLocArea(y, x)
    for _, a in ipairs(_state.pull.pullLocAreas or {}) do
        if dist2D(x, y, a.x, a.y) <= a.range then return true end
    end
    return false
end

-- Build MobsToPull / MobsToPullFirst from the raw zone list.
-- Mac: UpdatePullRanking (mac:15064). With ranking on, entries marked with ':'
-- go to MobsToPullFirst (pulled before anything else) and the rest stay in
-- MobsToPull ('all' if none are left). With ranking off, the ':' marks are
-- stripped and everything is in MobsToPull. quiet suppresses the messages.
function Pull.setRanking(on, quiet)
    local p   = _state.pull
    local raw = p.mobsToPullRaw or 'all'
    local function say(fmt, ...) if not quiet then printf(fmt, ...) end end

    local entries = {}
    if raw ~= 'all' and raw ~= 'null' and raw ~= '' then
        for entry in (raw .. ','):gmatch('([^,]*),') do
            entry = entry:match('^%s*(.-)%s*$')
            if entry ~= '' then entries[#entries + 1] = entry end
        end
    end

    local first, rest = {}, {}
    if on and #entries == 0 then
        on = false
        say('\ayPull Ranking is off. You need to update MobsToPull. Normal Pulling is Enabled.')
    elseif on then
        for _, e in ipairs(entries) do
            if e:find(':', 1, true) then
                first[#first + 1] = (e:gsub(':', ''))
            else
                rest[#rest + 1] = e
            end
        end
        if #first == 0 then
            on = false
            say('\ayNo mobs in MobsToPull list to Rank.')
        end
    end
    if not on then
        first, rest = {}, {}
        for _, e in ipairs(entries) do rest[#rest + 1] = (e:gsub(':', '')) end
    end

    p.ranking         = on and true or false
    p.mobsToPullFirst = #first > 0 and table.concat(first, ',') or 'all'
    p.mobsToPull      = #rest  > 0 and table.concat(rest,  ',') or 'all'
    if on then
        say('\ayPull Ranking is Now on.')
    elseif #entries > 0 then
        say('\ayPull Ranking is off. Normal Pulling is Enabled.')
    end
    return p.ranking
end

-- Pull level range from [Pull] PullLevel (mac:16255):
--   'min|max'        fixed range
--   'min|max|linked' range moves up one level each time you level
--   'auto'           your level -5 to +2, recalculated on level up
--   '0|0' / '0'      off (levels 1-200)
-- Sets pull.min, pull.max and pull.levelMode ('off'/'fixed'/'linked'/'auto').
function Pull.setPullLevel(value)
    local p     = _state.pull
    local v     = tostring(value or '0')
    local lower = v:lower()
    local lvl   = mq.TLO.Me.Level() or 0
    local mode, mn, mx
    if lower:find('auto', 1, true) then
        mode, mn, mx = 'auto', lvl - 5, lvl + 2
    elseif v == '0|0' or v == '0' or lower == 'null' or not v:find('|', 1, true) then
        mode, mn, mx = 'off', 1, 200
    else
        local a, b = v:match('^%s*([^|]*)|([^|]*)')
        mn = math.floor(tonumber(a) or 0)
        mx = math.floor(tonumber(b) or 0)
        mode = lower:find('linked', 1, true) and 'linked' or 'fixed'
    end
    if mn > mx or mn == 0 or mx == 0 then
        printf('\ayInvalid Pull Level Settings resetting to default.')
        mode, mn, mx = 'off', 1, 200
    end
    p.levelSetting = v
    p.levelMode, p.min, p.max = mode, mn, mx
    return mode
end

-- Level up: move the auto/linked pull level range (mac:11400 Event_GainSomething).
function Pull.levelGained()
    local p = _state.pull
    if p.levelMode == 'auto' then
        local lvl = mq.TLO.Me.Level() or 0
        p.min, p.max = lvl - 5, lvl + 2
    elseif p.levelMode == 'linked' then
        p.min, p.max = p.min + 1, p.max + 1
    end
end

-- True when MQ2Nav is loaded with a mesh for this zone.
local function navMeshLoaded()
    local plugin = mq.TLO.Plugin('MQ2Nav')
    if not plugin or not plugin.IsLoaded() then return false end
    return mq.TLO.Navigation.MeshLoaded() == true
end

-- Choose how to move for pulls and camp/chase movement (state.pull.moveUse).
-- Mac: startup block (mac:16498). PullMoveUse is not an INI setting there:
-- advpath when a path was loaded, else nav when MQ2Nav has a mesh for the
-- zone, else los. The mac only picks at startup; the port also re-picks after
-- zoning (onlyIfChanged = true) since the mesh differs per zone.
function Pull.pickMoveUse(onlyIfChanged)
    local s        = _state
    local role     = s.session.role or ''
    local isPuller = role:find('pull', 1, true) or role:find('hunt', 1, true)
    local mode
    if isPuller and (s.pull.pathWpCount or 0) > 0 and (s.session.pullPath or 'null') ~= 'null' then
        mode = 'advpath'
    elseif navMeshLoaded() then
        mode = 'nav'
    else
        mode = 'los'
    end
    local changed = mode ~= s.pull.moveUse
    s.pull.moveUse = mode
    if onlyIfChanged and not changed then return mode end

    if isPuller then
        if mode == 'advpath' then
            printf('\atPULL: Using MQ2AdvPath to Pull with.')
        elseif mode == 'nav' then
            printf('\atPULL: The MQ2Nav mesh for %s is loaded', mq.TLO.Zone.Name() or 'this zone')
            printf('\atPULL: Using MQ2Nav to Pull with %s', s.pull.withAlt or 'Melee')
        else
            printf('\atPULL: Using Line of Sight to Pull with %s', s.pull.withAlt or 'Melee')
        end
    elseif mode == 'nav' then
        printf('\atThe MQ2Nav mesh for %s is loaded', mq.TLO.Zone.Name() or 'this zone')
        printf('\atUsing MQ2Nav to Move.')
    else
        printf('\atUsing MoveUtil to move with.')
    end
    return mode
end

function Pull.init(state, utils, cast, movement, combat, pet, bard, healing, comms)
    _state    = state
    _utils    = utils
    _cast     = cast
    _movement = movement
    _combat   = combat
    _pet      = pet
    _bard     = bard
    _healing  = healing
    _comms    = comms
    if movement and movement.setPull then movement.setPull(Pull) end

    -- [Pull] section
    _state.pull.withAlt      = Config.get('Pull', 'PullWith',      'Melee')
    _state.pull.meleeStick   = Config.get('Pull', 'PullMeleeStick', '0') == '1'
    -- PullRange is a fallback only: Pull.rangeSet derives it from PullWith, as the
    -- .mac does (it never reads PullRange from the INI).
    _state.pull.range        = tonumber(Config.get('Pull', 'PullRange',    '15')) or 15
    -- PullRadiusToUse: % of the pull method's range to use (mac:14927, default 90,
    -- 0 or > 100 -> 100). Early Lua configs defaulted it to '1', which would mean
    -- 1%, so treat 1 as unset.
    local rtu = tonumber(Config.get('Pull', 'PullRadiusToUse', '90')) or 90
    if rtu == 1 then rtu = 90 elseif rtu <= 0 or rtu > 100 then rtu = 100 end
    _state.pull.radiusToUse  = rtu
    _state.pull.maxRadius    = tonumber(Config.get('Pull', 'MaxRadius',    '350')) or 350
    _state.pull.maxZRange    = tonumber(Config.get('Pull', 'MaxZRange',    '50'))  or 50
    Pull.setPullLevel(Config.get('Pull', 'PullLevel', '0|0'))
    _state.pull.chainPullHP  = tonumber(Config.get('Pull', 'ChainPullHP',  '90')) or 90
    -- PullRoleToggle needs the pullerpettank to lead the group (mac:8820; the
    -- mac ends the macro here, the port turns the option off instead).
    _state.pull.roleToggle   = Config.get('Pull', 'PullRoleToggle', '0') == '1'
    if _state.pull.roleToggle and _state.session.role == 'pullerpettank'
       and (mq.TLO.Group.Leader.ID() or 0) ~= (mq.TLO.Me.ID() or 0) then
        printf('\arYou are set to toggle puller mode but are NOT the group leader.')
        printf('\arPull role toggle is off until you lead the group and restart KissAssist.')
        _state.pull.roleToggle = false
    end
    Pull.setPullPause(Config.get('Pull', 'PullPause', '30|2'))
    _state.pull.hold         = Config.get('Pull', 'PullHold',      '0') == '1'
    _state.pull.pullArcWidth = tonumber(Config.get('Pull', 'PullArcWidth', '0'))  or 0
    if _state.pull.pullArcWidth > 359 then _state.pull.pullArcWidth = 0 end  -- mac:16278
    _state.pull.pullWait     = tonumber(Config.get('Pull', 'PullWait',     '5'))   or 5
    _state.pull.chainPull    = tonumber(Config.get('Pull', 'ChainPull',    '0'))  or 0
    -- Only the puller role chain pulls (mac:8841).
    if _state.session.role ~= 'puller' then _state.pull.chainPull = 0 end
    _state.pull.pullOnReturn = Config.get('Pull', 'PullOnReturn',  '0') == '1'
    _state.pull.ranking      = false  -- per session, always off at start (mac:14950)
    Pull.loadZoneLists()
    _state.pull.searchType      = Config.get('Pull', 'SearchType',     '')
    -- waypointZRange mirrors MaxZRange (used by movement nav Z-range guard)
    _state.pull.waypointZRange  = _state.pull.maxZRange

    -- Puller roles aim the arc the way the character faces at startup (mac:16492).
    if _state.pull.pullArcWidth > 0 and (_state.session.role or ''):find('puller', 1, true) then
        Pull.setPullAngles(mq.TLO.Me.Heading.Degrees() or 0, _state.pull.pullArcWidth, true)
        printf('\awPulling an Area starting from the Left at \at%.2f\aw degrees ending at \at%.2f\aw degrees.',
            _state.pull.lSide, _state.pull.rSide)
    end

    -- [PullAdvanced] section
    _state.pull.pullLocsOn  = Config.get('PullAdvanced', 'PullLocsOn', '0') == '1'
    _state.pull.pathWpCount = tonumber(Config.get('PullAdvanced', 'PullWpCount', '0')) or 0
    -- The no-pull areas themselves are per zone; Pull.loadZoneLists loads them.

    Pull.rangeSet()
    Pull.pickMoveUse()

    _utils.debug('pull', 'Pull.init complete — with=%s range=%d maxRadius=%d levels=%d-%d',
        _state.pull.withAlt,
        _state.pull.range, _state.pull.maxRadius, _state.pull.min, _state.pull.max)
end

-- ---------------------------------------------------------------------------
-- Step 7.6 — Pull.pullValidate
-- ---------------------------------------------------------------------------

-- Mob-name allowed-list filter (mac:9451). A mob on MobsToPullFirst (pull
-- ranking) is allowed; otherwise it must be on MobsToPull unless that is 'all'.
function Pull.nameAllowed(name)
    local p = _state.pull
    if inNameList(p.mobsToPullFirst, name) then return true end
    local list = p.mobsToPull or 'all'
    return list == 'all' or inNameList(list, name)
end

-- Validate a single spawn as a pull candidate.
-- Mac: PullValidate (mac:9443-9567)
-- flag: spawn index from findMobToPull (>0 enables server-lag HP recheck).
-- Returns true (valid) or false (skip).
function Pull.pullValidate(mobID, flag)
    local sp = mq.TLO.Spawn('id ' .. mobID)
    if not sp() then return false end

    local name     = sp.CleanName() or ''
    local moveUse  = _state.pull.moveUse

    if not Pull.nameAllowed(name) then
        _utils.debug('pull', 'pullValidate: %s not on MobsToPull list', name)
        return false
    end

    -- Ignore by name.
    if inNameList(_state.pull.mobsToIgnore, name) then
        _utils.debug('pull', 'pullValidate: %s on MobsToIgnore list', name)
        return false
    end

    -- Ignore by spawn ID.
    if _state.pull.mobsToIgnoreByID ~= 'null' and
       _state.pull.mobsToIgnoreByID:find('|' .. tostring(mobID) .. '|', 1, true) then
        _utils.debug('pull', 'pullValidate: %d on MobsToIgnoreByID list', mobID)
        return false
    end
    -- Mobs the puller gave up on (mac:9493 PullIgnore1).
    if Pull.onPullIgnore(mobID) then
        _utils.debug('pull', 'pullValidate: %d on the pull ignore list', mobID)
        return false
    end

    -- PullLocs: skip mobs inside a no-pull area (mac:9494-9502).
    if _state.pull.pullLocsOn and Pull.inPullLocArea(sp.Y() or 0, sp.X() or 0) then
        _utils.debug('pull', 'pullValidate: %s is in a no-pull area', name)
        return false
    end

    -- Range from camp + nav-path existence (los and nav modes only).
    if moveUse == 'los' or moveUse == 'nav' then
        local d = dist2D(sp.X() or 0, sp.Y() or 0,
                         _state.movement.campX, _state.movement.campY)
        if d > _state.pull.maxRadius then
            _utils.debug('pull', 'pullValidate: %s out of range (%.0f > %d)',
                name, d, _state.pull.maxRadius)
            return false
        end
        if moveUse == 'nav' then
            local pathLen = mq.TLO.Navigation.PathLength('id ' .. mobID)() or 0
            if pathLen <= 0 then
                _utils.debug('pull', 'pullValidate: %s no nav path', name)
                return false
            end
        end
    end

    -- Eye of Zomm / Tallon: reject if a matching PC name exists in zone.
    if name:find('Eye of', 1, true) then
        local suffix = name:sub(8)  -- everything after "Eye of "
        if suffix ~= '' and (mq.TLO.SpawnCount('pc name ' .. suffix)() or 0) > 0 then
            _utils.debug('pull', 'pullValidate: %s is Eye of Zomm/Tallon', name)
            return false
        end
    end

    -- Line-of-sight check (puller roles, los mode only).
    local role     = _state.session.role
    local isPuller = role == 'puller' or role == 'pullertank' or role == 'pullerpettank'
    if isPuller and moveUse == 'los' and not sp.LineOfSight() then
        _utils.debug('pull', 'pullValidate: %s no LOS', name)
        return false
    end

    -- Level range.
    local lvl = sp.Level() or 0
    if _state.pull.min > 0 and lvl < _state.pull.min then
        _utils.debug('pull', 'pullValidate: %s lvl %d below min %d', name, lvl, _state.pull.min)
        return false
    end
    if _state.pull.max > 0 and lvl > _state.pull.max then
        _utils.debug('pull', 'pullValidate: %s lvl %d above max %d', name, lvl, _state.pull.max)
        return false
    end

    -- PCs near the mob (only checked while actively pulling).
    if _state.pull.pulling then
        local meID   = mq.TLO.Me.ID() or 0
        local pcNear = mq.TLO.SpawnCount(
            ('notid %d loc %s %s radius 30 pc nogroup'):format(
                meID, tostring(sp.X() or 0), tostring(sp.Y() or 0)))() or 0
        if pcNear > 0 then
            _utils.debug('pull', 'pullValidate: %s has PCs nearby', name)
            return false
        end
    end

    -- Pull arc check.
    if _state.pull.pullArcWidth > 0 and not figureMobAngle(mobID) then
        _utils.debug('pull', 'pullValidate: %s outside pull arc', name)
        return false
    end

    -- HP% check: skip mobs already in combat (≤99% HP and outside melee range).
    local pctHp    = sp.PctHPs() or 100
    local mobDist  = sp.Distance() or 0
    local meleeDst = _state.combat.meleeDistance or 30
    if pctHp <= 99 and mobDist >= meleeDst then
        -- Server-lag double-check: target the mob and re-read HP.
        if flag > 0 and mobDist <= 360 and (mq.TLO.Target.ID() or 0) ~= mobID then
            printf('\awMob not at 100%%%% HP — checking server lag: %s (%d%%)', name, pctHp)
            mq.cmd('/target id ' .. mobID)
            mq.delay(1000, function()
                return (mq.TLO.Target.ID() or 0) == mobID
                    and mq.TLO.Target.BuffsPopulated() == true
            end)
            if (mq.TLO.Target.PctHPs() or 0) > 99 then return true end
        end
        _utils.debug('pull', 'pullValidate: %s not at 100%% HP (%d%%)', name, pctHp)
        return false
    end

    -- Named mob: skip when group is already occupied or pull not ready.
    -- Named allowed only when flag>0 (valid index) AND no mobs currently in camp.
    local isNamed = sp.Named() or false
    if isNamed then
        local xSlot    = _state.combat.xTSlot
        local xBusy    = xSlot > 0 and (mq.TLO.Me.XTarget(xSlot).ID() or 0) > 0
        local campBusy = _state.combat.mobCount > 0 and xBusy
        if flag == 0 or campBusy then
            _utils.debug('pull', 'pullValidate: %s is Named — mobs in camp or not ready', name)
            return false
        end
    end

    _utils.debug('pull', 'pullValidate: %s VALID', name)
    return true
end

-- ---------------------------------------------------------------------------
-- Step 7.7 helpers (local — not part of public API)
-- ---------------------------------------------------------------------------

-- Build shared NearestSpawn/SpawnCount query suffix.
local function pullQuery(filter, radius, zRadius, searchType)
    return filter .. ' radius ' .. radius ..
           ' zradius '          .. zRadius ..
           ' targetable '       .. (searchType or '')
end

-- Sequential LOS scan: return first spawn ID that passes pullValidate.
-- Mac: FindMobLOS (mac:9280-9304)
local function findMobLOS(pflag, bCount, eCount, filter)
    local s = _state
    local q = pullQuery(filter, s.pull.maxRadius, s.pull.maxZRange, s.pull.searchType)
    if bCount < 1 then bCount = 1 end
    for i = bCount, eCount do
        local mobID = mq.TLO.NearestSpawn(i .. ', ' .. q).ID() or 0
        if mobID == 0 then break end
        if Pull.pullValidate(mobID, pflag) then
            s.pull.chainPullTemp = mobID
            return mobID
        end
    end
    return 0
end

-- Nav scan: return spawn ID with shortest nav path length.
-- Mac: FindMobNAV (mac:9187-9235)
local function findMobNAV(pflag, bCount, mobCount, filter)
    local s         = _state
    local q         = pullQuery(filter, s.pull.maxRadius, s.pull.maxZRange, s.pull.searchType)
    local bestMob   = 0
    local shortest  = 0
    local pathCount = 1
    if bCount < 1 then bCount = 1 end
    for p = bCount, mobCount do
        local mobID = mq.TLO.NearestSpawn(p .. ', ' .. q).ID() or 0
        if mobID == 0 then break end
        -- Heuristic early-out: farther mob unlikely to have shorter path (mac:9201-9203)
        local mobDist = mq.TLO.Spawn('id ' .. mobID).Distance() or 0
        if mobDist > shortest and pathCount > 1 then goto continue end
        if not Pull.pullValidate(mobID, pflag) then goto continue end
        local pathLen = mq.TLO.Navigation.PathLength('id ' .. mobID)() or 0
        if pathLen > 0 then
            s.pull.chainPullTemp = mobID
            if pathCount == 1 or pathLen < shortest then
                bestMob  = mobID
                shortest = pathLen
            end
            pathCount = pathCount + 1
        end
        ::continue::
    end
    return bestMob
end

-- Priority-mob scan over MobsToPullFirst list.
-- Mac: FindMobsFirst (mac:9239-9276)
-- returnWhat=false → total count; returnWhat=true → first valid mob ID.
local function findMobsFirst(filter, returnWhat, pflag)
    local s = _state
    local list = s.pull.mobsToPullFirst
    if not list or list == 'all' or list == 'null' or list == '' then return 0 end
    local radius  = tostring(s.pull.maxRadius)
    local zRadius = tostring(s.pull.maxZRange)
    local sType   = s.pull.searchType or ''
    local total   = 0
    for entry in (list .. '|'):gmatch('([^,|]+)[,|]') do
        entry = entry:match('^%s*(.-)%s*$')
        local name = entry:gsub('^[#*]', '')
        local q    = name .. ' ' .. filter ..
                     ' radius '  .. radius  ..
                     ' zradius ' .. zRadius ..
                     ' targetable ' .. sType
        local cnt = mq.TLO.SpawnCount(q)() or 0
        if cnt > 0 then
            if not returnWhat then
                total = total + cnt
            else
                local mobID = mq.TLO.NearestSpawn('1, ' .. q).ID() or 0
                if mobID > 0 and Pull.pullValidate(mobID, pflag) then return mobID end
            end
        end
    end
    return total  -- 0 when returnWhat=true and none found
end

-- ---------------------------------------------------------------------------
-- Step 7.7 — Pull.findMobToPull
-- ---------------------------------------------------------------------------

-- Scan the zone for the best pull candidate; sets state.pull.mob on success.
-- Mac: FindMobToPull (mac:8945-9116)
-- readyFlag: 1=ready to pull, 0=chain-pull availability check.
-- a: initial Piterations (pass 1); b: UseCampLoc for hunter (pass 0).
-- Returns 1 (found, state.pull.mob set) or 0 (none).
local RANGED_TYPES = { archery = true, throwing = true, throwingv1 = true, throwingv2 = true, ammo = true }
local _lastRange   -- last "method|range" reported, so changes are announced once

-- Set PullRange from the PullWith method. Mirrors Sub PullRangeSet (mac:8857)
-- and Sub PullVars (mac:8935); called at init and before each mob search.
--   Bow|Arrow (ranged item + ammo): item range (50 if none) + arrow range for
--     bows, x PullRadiusToUse%; PullWith becomes 'Ranged'. No ammo -> Melee.
--   clicky item: its spell's range x PullRadiusToUse%.
--   spell / disc / AA: MyRange (AA: its spell's range) x PullRadiusToUse%.
--   Pet: 185 (hunterpettank: 80% of PetAttackRange).  Melee: 15.
-- Anything else keeps the current range.
function Pull.rangeSet()
    local p    = _state.pull
    local with = p.withAlt or 'Melee'
    local lw   = with:lower()
    local pct  = (p.radiusToUse or 90) / 100
    local me   = mq.TLO.Me
    local first, second = with:match('^([^|]*)|?(.*)$')

    local function set(range, method)
        -- Round, don't floor: 200 * 0.9 can come out as 179.999... in floating point.
        p.range   = math.floor((range or 0) + 0.5)
        p.withAlt = method
        local key = method .. '|' .. p.range
        if key ~= _lastRange then
            _lastRange = key
            printf('\awPull range set to \at%d\aw for \at%s', p.range, method)
            -- CastRadius follows the player, so it can be updated from anywhere.
            if p.mapSet then mq.cmdf('/squelch /mapfilter CastRadius %d', p.range) end
        end
    end

    -- Keywords first (the .mac checks items first, but no item is named Melee/Pet).
    if lw == 'pet' then
        if _state.session.role == 'hunterpettank' then
            set((_state.pet.attackRange or 0) * 0.80, 'Pet')
        else
            set(185, 'Pet')
        end
    elseif lw == 'melee' then
        set(15, 'Melee')
    elseif lw == 'ranged' then
        p.withAlt = 'Ranged'
    elseif (mq.TLO.FindItemCount('=' .. first)() or 0) > 0 then
        local item  = mq.TLO.FindItem('=' .. first)
        local itype = (item.Type() or ''):lower()
        if RANGED_TYPES[itype] then
            p.item = first
            local r = item.Range() or 0
            if r == 0 then r = 50 end
            local ammo = mq.TLO.FindItem('=' .. second)
            if second ~= '' and ammo.WornSlot('ammo')() and (mq.TLO.FindItemCount('=' .. second)() or 0) > 0 then
                p.ammo = second
                if itype == 'archery' then r = r + (ammo.Range() or 0) end
                set(r * pct, 'Ranged')
            else
                printf("\arI can't find any ammo, defaulting to Melee for PullWith")
                set(15, 'Melee')
            end
        elseif second == '' then
            set((item.Spell.Range() or 0) * pct, with)
        end
    elseif me.AltAbility(with)() then
        set((me.AltAbility(with).Spell.Range() or 0) * pct, with)
    else
        -- A base name like 'Terror of Ander' may only be in the book as Rk. II/III.
        -- Resolve to the owned rank and keep that as PullWith, so the ready check
        -- and the cast use the exact name too.
        local ranked = _utils.resolveSpellRank(with)
        if ranked == with then ranked = mq.TLO.Spell(with).RankName() or with end
        if me.CombatAbility(ranked)() or me.Book(ranked)() then
            set((mq.TLO.Spell(ranked).MyRange() or 0) * pct, ranked)
        elseif _lastRange ~= 'unknown|' .. with then
            _lastRange = 'unknown|' .. with
            printf('\arUnknown PullWith setting: %s', with)
        end
    end
end

-- Draw the pull and camp radii on the MQ2Map map. Mirrors Sub PaintMap
-- (mac:8917), run once while the puller stands in camp (mac:8494, MapSet).
-- MQ2Map anchors CampRadius/PullRadius at the player's position when they are
-- set, so this only paints from inside the camp radius. CastRadius follows the
-- player and shows the pull range. /makecamphere clears mapSet to repaint.
function Pull.paintMap()
    local s = _state
    if s.pull.mapSet then return end
    if s.movement.campX == 0 and s.movement.campY == 0 then return end
    if not mq.TLO.Plugin('MQ2Map').IsLoaded() then return end
    local d = dist2D(mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0, s.movement.campY, s.movement.campX)
    if d > (s.movement.campRadius or 0) then return end
    mq.cmdf('/squelch /mapfilter CastRadius %d', s.pull.range or 0)
    mq.cmdf('/squelch /mapfilter SpellRadius %d', s.pull.maxRadius or 0)
    mq.cmdf('/squelch /mapfilter PullRadius %d', s.pull.maxRadius or 0)
    mq.cmdf('/squelch /mapfilter CampRadius %d', s.movement.campRadius or 0)
    Pull.drawArc()  -- the arc's edges, around the (new) camp
    s.pull.mapSet = true
end

-- True when the PullWith method can be used right now (mac:418): Melee and Pet
-- always; Ranged when the ranged attack is ready; otherwise the named spell, AA,
-- combat ability or item must be ready. Checked before searching so the puller
-- doesn't run to a mob with the pull on cooldown.
function Pull.pullAbilityReady(withAlt)
    withAlt = withAlt or (_state and _state.pull.withAlt) or 'Melee'
    local lw = withAlt:lower()
    if lw == 'melee' or lw == 'pet' then return true end
    local me = mq.TLO.Me
    if lw == 'ranged' then return me.RangedReady() == true end
    return me.SpellReady(withAlt)() == true
        or me.AltAbilityReady(withAlt)() == true
        or me.CombatAbilityReady(withAlt)() == true
        or me.ItemReady(withAlt)() == true
end

-- Start the PullWait respawn wait (mac:9421-9439 Sub PullDelay). The .mac blocks
-- in a /doevents loop; here the main loop keeps running (heals, buffs, combat)
-- and Phase 9 skips pulling until Pull.pullWaiting() turns false.
function Pull.startPullWait(seconds)
    local s = _state
    s.timers.pullDelay = os.clock() + seconds
    s.pull.pulling = false
    s.pull.pulled  = false
    local me = mq.TLO.Me
    if s.heal.medOn and not me.Mount.ID() and me.Standing() and not me.Moving() then
        mq.cmd('/sit')
    end
end

-- True while the PullWait respawn wait is running. Aggro ends it early, as in
-- the .mac (the fight itself runs through the normal combat phases).
function Pull.pullWaiting()
    local s = _state
    if (s.timers.pullDelay or 0) == 0 then return false end
    if os.clock() >= s.timers.pullDelay or (s.combat.aggroTargetID or '') ~= '' then
        s.timers.pullDelay = 0
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- PullPause (mac:8502 DoMiscStuff): pull for X minutes, then hold pulls and
-- med for Y minutes. [Pull] PullPause = 'X|Y' or 'X|Y|condN'; X = 0 turns the
-- cycle off. The X-minute window restarts if no pull happens for Y minutes.
-- '|condN' holds pulls while condition N is true (mac PullHoldCond).
-- ---------------------------------------------------------------------------

function Pull.setPullPause(value)
    local p    = _state.pull
    local v    = tostring(value or '0')
    local role = _state.session.role or ''
    local a, b = v:match('^%s*([^|]*)|?([^|]*)')
    p.pauseSetting = v
    p.pauseRun  = math.floor(tonumber(a) or 0)
    p.pauseRest = math.floor(tonumber(b) or 0)
    p.pauseCond = tonumber(v:lower():match('|cond(%d+)')) or 0
    -- Only pullers and hunters pause (mac:8842).
    if not role:find('puller', 1, true) and not role:find('hunter', 1, true) then
        p.pauseRun, p.pauseCond = 0, 0
    end
    if p.pauseRest <= 0 then p.pauseRun = 0 end
    p.pauseHold = false
    _state.timers.pullPause1, _state.timers.pullPause2 = 0, 0
end

-- Run each main-loop pass. Starts and ends the pause.
function Pull.pullPauseCheck()
    local p, t = _state.pull, _state.timers
    if (p.pauseRun or 0) == 0 then return end
    local now = os.clock()
    if not p.hold and not p.pauseHold and (t.pullPause2 or 0) <= now then
        t.pullPause1 = now + p.pauseRun  * 60
        t.pullPause2 = now + p.pauseRest * 60
    end
    if (t.pullPause1 or 0) > now then
        -- Med through the pause, as the .mac's DoWeMed 1 does.
        local me = mq.TLO.Me
        if p.pauseHold and _state.heal.medOn and (_state.combat.aggroTargetID or '') == ''
           and not me.Mount.ID() and me.Standing() and not me.Moving() then
            mq.cmd('/sit')
        end
        return
    end
    if not p.hold and not p.pauseHold then
        printf('\ayPausing Pulls for %d Minutes.', p.pauseRest)
        p.pauseHold  = true
        t.pullPause1 = now + p.pauseRest * 60
    elseif p.pauseHold then
        printf('\ayResetting Pull Timer for %d Minutes.', p.pauseRun)
        p.pauseHold  = false
        t.pullPause1 = now + p.pauseRun  * 60
        t.pullPause2 = now + p.pauseRest * 60
        if mq.TLO.Me.Sitting() and not _state.heal.medding then mq.cmd('/stand') end
    end
end

-- A pull happened: keep the X-minute window running (mac:9368).
function Pull.pullPauseActive()
    local p = _state.pull
    if (p.pauseRun or 0) > 0 then
        _state.timers.pullPause2 = os.clock() + (p.pauseRest + 1) * 60
    end
end

-- True while the PullPause '|condN' hold condition is true (mac:9595).
local holdSpam = 0
function Pull.heldByCond()
    local n = _state.pull.pauseCond or 0
    if n == 0 then return false end
    -- Cond.eval treats "conditions off" and missing entries as true; a hold
    -- condition only applies when it exists.
    local c = _state.cond
    if not c or not c.on or not c.expressions or (c.expressions[n] or '') == '' then return false end
    if not require('modules.cond').eval(n) then return false end
    if os.clock() >= holdSpam then
        printf('\ayHolding Pulls Due to Pull Hold Condition.')
        holdSpam = os.clock() + 5
    end
    return true
end

-- PullRoleToggle (mac:10586 PullModeToggle): a pullerpettank who leads the
-- group with a merc in it takes the EQ group Puller role (3) for a pull of a
-- mob outside camp, and drops it again back in camp after a successful pull.
local function isGroupPuller()
    local myID = mq.TLO.Me.ID() or 0
    return myID > 0 and (mq.TLO.Group.Puller.ID() or 0) == myID
end

function Pull.roleToggle(on, mobID)
    local s = _state
    if not s.pull.roleToggle or s.session.role ~= 'pullerpettank' then return end
    if (mq.TLO.Group.Leader.ID() or 0) ~= (mq.TLO.Me.ID() or -1) then return end
    if (mq.TLO.SpawnCount('group mercenary')() or 0) == 0 then return end
    local name = mq.TLO.Me.CleanName() or ''
    if on then
        if isGroupPuller() then return end
        local sp = mq.TLO.Spawn('id ' .. (mobID or 0))
        if not sp() or dist2D(sp.X() or 0, sp.Y() or 0, s.movement.campX, s.movement.campY)
                       <= s.movement.campRadius then
            return
        end
        mq.cmdf('/grouproles set %s 3', name)
        mq.delay(1000, isGroupPuller)
        if isGroupPuller() then printf('\ag+ You have been set to be group puller.') end
    else
        if not isGroupPuller() then return end
        mq.cmdf('/grouproles unset %s 3', name)
        mq.delay(1000, function() return not isGroupPuller() end)
        if not isGroupPuller() then printf('\ag+ You are no longer group puller.') end
    end
end

-- Mid-fight chain pull hand-off. Mirrors Sub ChainPullNextMob (mac:15751),
-- called from the fight loop for a chain-pulling puller. When the current mob
-- is below ChainPullHP, the MA is in camp and nothing else is incoming, look
-- for the next mob (findMobToPull with readyFlag 0); if one is found, stop
-- fighting and leave it in state.pull.mob for Phase 9 to pull.
-- Returns 1 (go pull), 'W' (MA too far from camp, message shown) or 0.
function Pull.chainPullNextMob(echoWait)
    local s  = _state
    local ma = mq.TLO.Spawn('=' .. (s.session.mainAssist or ''))
    local maDist = ma() and dist2D(s.movement.campX, s.movement.campY, ma.X() or 0, ma.Y() or 0) or 0
    if maDist > 75 then
        if echoWait then
            printf('\ayHolding Pulls. Tank to far from camp.')
            return 'W'
        end
        return 0
    end
    local tgtID = mq.TLO.Target.ID() or 0
    local named = tgtID > 0 and _combat and _combat.isSpawnNamed and _combat.isSpawnNamed(tgtID)
    if s.pull.hold or s.pull.pauseHold or (s.combat.mobCount or 0) >= 2
       or (mq.TLO.Me.XTarget(s.combat.xTSlot2).ID() or 0) > 0 or named then
        _utils.debug('pull', 'chainPullNextMob: fail 1 hold=%s mobCount=%d named=%s',
            tostring(s.pull.hold), s.combat.mobCount or 0, tostring(named))
        return 0
    end
    if tgtID == 0 or (mq.TLO.Target.PctHPs() or 100) >= (s.pull.chainPullHP or 90) then
        _utils.debug('pull', 'chainPullNextMob: fail 2 target above ChainPullHP')
        return 0
    end
    Pull.findMobToPull(0, 1, 0)
    local mob = s.pull.mob or 0
    local nextDist = mq.TLO.Spawn('id ' .. (tonumber(s.pull.chainPullTemp) or 0)).Distance() or 9999
    if mob == 0 or nextDist >= (s.pull.range or 0) + 400
       or (mq.TLO.Me.TargetOfTarget.Name() or '') == (mq.TLO.Me.CleanName() or '')
       or (mq.TLO.Me.PctAggro() or 0) >= 50 then
        _utils.debug('pull', 'chainPullNextMob: fail 3 mob=%d dist=%d', mob, math.floor(nextDist))
        s.pull.mob = 0
        return 0
    end
    if s.combat.useMQ2Melee then mq.cmd('/squelch /melee melee=0') end
    if mq.TLO.Stick.Active() then mq.cmd('/squelch /stick off') end
    mq.cmd('/squelch /attack off')
    mq.delay(1000)
    if s.combat.useMQ2Melee then mq.cmd('/squelch /melee melee=1') end
    s.pull.chainPull       = 2
    s.combat.myTargetID    = 0
    s.combat.attacking     = false
    s.combat.combatStart   = false
    _utils.debug('pull', 'chainPullNextMob: next mob %d', mob)
    return 1
end

-- Chain pulling: don't pull the next mob while the current one is still
-- above ChainPullHP (mac:8959). True = wait.
function Pull.chainPullBusy()
    local s = _state
    if (mq.TLO.Me.XTarget(s.combat.xTSlot).ID() or 0) == 0 then return false end
    local hp    = s.pull.chainPullHP or 90
    local myTgt = tonumber(s.combat.myTargetID) or 0
    local tgtID = mq.TLO.Target.ID() or 0
    if myTgt == 0 and tgtID == 0 then return true end
    local tgtHP = tgtID > 0 and mq.TLO.Target.PctHPs() or nil
    if tgtHP and tgtHP >= hp then return true end
    if myTgt > 0 then
        local myHP = mq.TLO.Spawn(myTgt).PctHPs()
        if myHP and myHP >= hp then return true end
    end
    return false
end

function Pull.findMobToPull(readyFlag, a, b)
    local s    = _state
    local role = s.session.role

    local isPullerRole = role == 'puller'    or role == 'pullertank'    or
                         role == 'hunter'    or role == 'hunterpettank' or
                         role == 'pullerpettank'

    -- Entry guards (mac:8947-8948)
    if (s.misc.dmz and not mq.TLO.Me.InInstance()) or
       not isPullerRole or s.pull.pulled or
       (s.combat.aggroTargetID ~= '' and s.pull.chainPull == 0) then
        return 0
    end
    if mq.TLO.Me.Invis() or s.pull.hold or s.pull.pauseHold or s.dps.paused or
       (mq.TLO.Me.Buff('Resurrection Sickness').ID() or 0) > 0 or
       (mq.TLO.Me.Buff('Revival Sickness').ID()         or 0) > 0 then
        return 0
    end

    -- Re-derive the pull range each search (mac:8968): spell/AA ranges change
    -- with level and AAs.
    Pull.rangeSet()

    -- Clear CheckOnReturn once ready (mac:8949)
    if s.movement.checkOnReturn and readyFlag == 1 then
        s.movement.checkOnReturn = false
    end

    -- mobCount maintained by combat.checkForCombat — no MobRadar call needed here.

    -- Chain-pull guard (mac:8951)
    if s.pull.chainPull > 0 and
       (s.combat.mobCount > 1 or
        (mq.TLO.Me.XTarget(s.combat.xTSlot2).ID() or 0) > 0) then
        return 0
    end

    -- ReadyToPullFlag-specific guards (mac:8952-8964)
    if readyFlag == 1 then
        if s.pull.chainPull > 0 then
            if (mq.TLO.Target.ID() or 0) == (mq.TLO.Me.ID() or 0) then
                mq.cmd('/squelch /target clear')
                mq.delay(500)
            end
            if Pull.chainPullBusy() then return 0 end
            -- MA too far from camp (mac:8959)
            if s.session.mainAssist ~= '' then
                local ma = mq.TLO.Spawn('=' .. s.session.mainAssist)
                if ma() then
                    local maDist = dist2D(ma.X() or 0, ma.Y() or 0,
                                          s.movement.campX, s.movement.campY)
                    if maDist > 75 then return 0 end
                end
            end
        end
        if not isPullerRole or
           (mq.TLO.Me.Buff('Resurrection Sickness').ID() or 0) > 0 or
           (mq.TLO.Me.Buff('Revival Sickness').ID()         or 0) > 0 or
           mq.TLO.Me.Hovering() then
            return 0
        end
    end

    mq.doevents()  -- drain pending events (mac:8968-8972)

    s.pull.pulling = false
    if s.pull.hold then return 0 end  -- GroupWatch may have set hold (mac:8985-8986)
    Pull.pullIgnoreTick()

    -- Status echo (mac:8988-8994; throttled)
    if readyFlag == 1 then
        if s.cast.failCounter == 0 then printf('\awLooking for Close Range Mobs') end
    else
        if os.clock() > s.timers.spam then
            printf('\awChecking for Close Range Mobs')
            s.timers.spam = os.clock() + 2.5
        end
    end

    -- Alert/ignore list management deferred (mac:8997-9004)

    -- AdvPath dispatch — deferred (mac:9008-9010)
    if s.pull.moveUse == 'advpath' then
        _utils.debug('pull', 'findMobToPull: advpath mode not yet implemented')
        return 0
    end

    -- Build spawn filter string (mac:9012-9024)
    local cx, cy     = s.movement.campX, s.movement.campY
    local moveUse    = s.pull.moveUse
    local isHunter   = role == 'hunter' or role == 'hunterpettank'
    local useCampLoc = b and b ~= 0
    local vstStr1

    if isHunter then
        local base = moveUse == 'nav' and 'npc' or 'npc los'
        vstStr1    = useCampLoc and string.format('%s loc %s %s', base, cx, cy) or base
    elseif moveUse == 'nav' then
        vstStr1 = 'npc loc ' .. cx .. ' ' .. cy
    else
        vstStr1 = 'npc los loc ' .. cx .. ' ' .. cy
    end

    local maxRadius  = s.pull.maxRadius
    local maxZRange  = s.pull.maxZRange
    local searchType = s.pull.searchType or ''
    local meleeDist  = s.combat.meleeDistance or 30

    -- Decide attempt mode: 3=full radius, 1=progressive (mac:9029)
    local pullAttempts = 3
    local fullCount = mq.TLO.SpawnCount(vstStr1 .. ' radius ' .. maxRadius ..
                                        ' zradius ' .. maxZRange ..
                                        ' targetable ' .. searchType)() or 0
    if fullCount > (s.pull.maxCount or 500) then pullAttempts = 1 end

    -- Priority mob pre-count (mac:9030-9038)
    local pullFirstCount = 0
    if s.pull.mobsToPullFirst ~= 'all' then
        pullFirstCount = findMobsFirst(vstStr1, false, readyFlag)
    end

    -- Main progressive-radius search loop (mac:9040-9113)
    local pullMob   = 0
    local lastCount = 1

    while true do
        local modCheck  = pullAttempts < 3 and (pullAttempts * 25) or 10000
        local pIter     = 1
        local pullCount = 0
        local idx       = 1

        -- Find smallest sub-radius with ≤ modCheck mobs (mac:9049-9066)
        while pullCount == 0 and idx <= pIter do
            if idx == pIter then
                idx = pIter + 1      -- exits inner loop on next check
            else
                idx = idx + 1
            end
            local subRad = idx > pIter and maxRadius or
                           math.floor((maxRadius / pIter) * (idx - 1))
            pullCount = mq.TLO.SpawnCount(vstStr1 .. ' radius ' .. subRad ..
                                          ' zradius ' .. maxZRange ..
                                          ' targetable ' .. searchType)() or 0
            if pullCount > modCheck then
                pIter     = pIter + 1
                idx       = idx - 1
                pullCount = 0
            end
        end

        local mobsNearCamp = mq.TLO.SpawnCount(vstStr1 .. ' radius ' .. meleeDist ..
                                               ' zradius ' .. maxZRange ..
                                               ' targetable ' .. searchType)() or 0

        -- Chain pull adjustment: last mob still incoming (mac:9071-9076)
        if readyFlag == 0 then
            local lastDist = s.pull.lastMobPullID > 0 and
                             (mq.TLO.Spawn('id ' .. s.pull.lastMobPullID).Distance() or 0) or 0
            if pullCount > 0 and lastDist >= meleeDist then return 0 end
            pullCount = pullCount - mobsNearCamp
        end

        if pullCount == 0 and pullFirstCount > 0 then pullCount = 1 end

        if pullCount > 0 then
            local beginSearch
            if readyFlag == 0 and mobsNearCamp > 0 then
                beginSearch = lastCount < 2 and 2 or lastCount
            else
                beginSearch = lastCount
            end

            -- Dispatch to finder (mac:9089-9102)
            if moveUse == 'nav' then
                if pullFirstCount > 0 then pullMob = findMobsFirst(vstStr1, true, readyFlag) end
                if pullMob == 0 then pullMob = findMobNAV(readyFlag, beginSearch, pullCount, vstStr1) end
            else
                if pullFirstCount > 0 then pullMob = findMobsFirst(vstStr1, true, readyFlag) end
                if pullMob == 0 then pullMob = findMobLOS(readyFlag, beginSearch, pullCount, vstStr1) end
            end

            lastCount = pullCount
            if pullMob == 0 then s.pull.chainPullTemp = 0 end
        else
            s.pull.chainPullTemp = 0
            pullMob = 0
            break
        end

        if pullAttempts == 3 or pullMob > 0 then break end
        pullAttempts = pullAttempts + 1
    end

    _utils.debug('pull', 'findMobToPull: mob=%d name=%s',
        pullMob,
        pullMob > 0 and (mq.TLO.Spawn('id ' .. pullMob).CleanName() or '?') or 'none')

    s.pull.mob = pullMob
    return pullMob > 0 and 1 or 0
end

-- ---------------------------------------------------------------------------
-- Step 7.8 — local helpers for pull execution
-- ---------------------------------------------------------------------------

local function stopMoving()
    mq.cmd('/squelch /moveto off')
    mq.cmd('/squelch /nav stop')
    mq.cmd('/squelch /stick off')
end

-- Mirrors Sub PullReset (mac:10565).
local function pullReset()
    local s = _state
    s.pull.pulling        = false
    s.pull.pulled         = false
    s.combat.myTargetID   = 0
    s.combat.myTargetName = '0'
    s.movement.toClose    = false
    mq.cmd('/attack off')
    stopMoving()
    mq.cmd('/squelch /target clear')
end

-- Pull ignore list ("|id|id|", mac PullIgnore1): mobs the puller gave up on.
-- Only pull searches skip them (and combat while a pull is under way,
-- mac:994); it is cleared every 5 minutes (Pull.pullIgnoreTick). Separate
-- from MobsToIgnoreByID, which combat always refuses.

-- Add a spawn ID. Mirrors the 'a' action of Sub PullIgnoreCheck (mac:9980).
function Pull.ignoreAdd(mobID, from)
    local id = tonumber(mobID) or 0
    if id < 1 then return end
    local p    = _state.pull
    local list = p.ignore1
    if not list or list == 'null' or list == '' then list = '|' end
    if list:find('|' .. id .. '|', 1, true) then return end
    p.ignore1 = list .. id .. '|'
    printf('\awAdded %d to ignore pull list. (%s)', id, from or '')
end

function Pull.onPullIgnore(mobID)
    local list = _state.pull.ignore1
    if not list or list == 'null' or list == '' then return false end
    return list:find('|' .. tostring(mobID) .. '|', 1, true) ~= nil
end

-- Each mob search (mac:8998): clear the list every 5 minutes, otherwise drop
-- dead or despawned entries (PullIgnoreCheck 'c').
function Pull.pullIgnoreTick()
    local p, t = _state.pull, _state.timers
    local now = os.clock()
    if (t.pullAlert or 0) <= now then
        p.ignore1   = 'null'
        t.pullAlert = now + 300
        return
    end
    if not p.ignore1 or p.ignore1 == 'null' then return end
    local kept = {}
    for id in p.ignore1:gmatch('|(%d+)') do
        local sp = mq.TLO.Spawn('id ' .. id)
        if (sp.ID() or 0) > 0 and sp.Type() ~= 'Corpse' then kept[#kept + 1] = id end
    end
    p.ignore1 = #kept > 0 and ('|' .. table.concat(kept, '|') .. '|') or 'null'
end

local function xtSlotID(slot)
    if (slot or 0) == 0 then return 0 end
    return mq.TLO.Me.XTarget(slot).ID() or 0
end

-- After a successful pull, wait in camp for the mob to arrive. Mirrors
-- Sub WaitForMob (mac:10469). Up to 45 s; gives up (and ignores the target)
-- if aggro is lost. Per role:
--   pullertank:     wait until a hater is within MeleeDistance of camp.
--   puller:         wait until a hater is in camp or within 20 of the MA;
--                   chain pulling: leave if several mobs come, else wait while
--                   the pulled mob is still heading for us and > 20 from the MA.
--   pullerpettank:  bring the pet back, then send it at the first hater
--                   within PetAttackRange of camp.
-- Merc assignment and the ranged-weapon swap back are not ported.
local function waitForMob()
    local s    = _state
    local role = s.session.role
    if role == 'hunter' or role == 'hunterpettank' or s.dps.paused then return end
    if not s.pull.pulled then return end

    local me       = mq.TLO.Me
    local deadline = os.clock() + 45
    local campX, campY = s.movement.campX, s.movement.campY
    local zr       = s.pull.maxZRange
    local meleeDist = s.combat.meleeDistance or 75

    if s.pull.chainPull ~= 0 then s.pull.lastMobPullID = mq.TLO.Target.ID() or 0 end
    -- Target the mob that actually aggroed if it isn't the one we pulled.
    local pag = _utils.pullAggroID()
    if pag > 0 and (mq.TLO.Target.ID() or 0) ~= pag and (mq.TLO.Target.AggroHolder.ID() or 0) == 0 then
        local aggroID = xtSlotID(s.combat.xTSlot)
        if aggroID > 0 then mq.cmdf('/squelch /target id %d', aggroID) end
    end

    while true do
        local fm = s.movement.faceMobOn or 0
        if (fm == 1 or fm == 2) and mq.TLO.Target.ID() and (me.Standing() or me.Mount.ID()) then
            mq.cmd(fm == 1 and '/face fast nolook' or '/face nolook')
        end
        mq.doevents()
        if s.combat.myTargetID == 0 then
            _combat.combatTargetCheck(0)
            if s.combat.myTargetID == 0 then
                s.combat.myTargetID = tonumber(s.combat.aggroTargetID) or 0
            end
        end
        _combat.mobRadar('los', s.movement.campRadius)
        if s.combat.mobCount >= 2 and s.pull.chainPull == 0 then
            pullReset()
            return
        end
        -- The mac's AggroTargetID is live: the XTarget slot, else the radar's pick.
        local aggro = xtSlotID(s.combat.xTSlot) > 0 or (s.combat.aggroTargetID or '') ~= ''
        if not aggro or os.clock() > deadline then
            _utils.debug('pull', 'waitForMob: no aggro or timed out')
            local tid = mq.TLO.Target.ID() or 0
            if tid > 0 then Pull.ignoreAdd(tid, 'waitformob') end
            pullReset()
            return
        end
        mq.delay(500)

        local mobsInCamp = mq.TLO.SpawnCount(string.format('xtarhater loc %s %s radius %d zradius %d',
            campX, campY, meleeDist, zr))() or 0
        local keepWaiting = false
        if role == 'pullertank' then
            keepWaiting = mobsInCamp == 0
        elseif role == 'puller' then
            local ma = mq.TLO.Spawn('=' .. (s.session.mainAssist or ''))
            if s.pull.chainPull == 0 then
                local nearMA = ma() and (mq.TLO.SpawnCount(string.format('xtarhater loc %s %s radius 20 zradius %d',
                    ma.X() or 0, ma.Y() or 0, zr))() or 0) or 0
                keepWaiting = mobsInCamp == 0 and nearMA == 0
                -- The mob's in camp: send the merc in (mac:10525)
                if not keepWaiting and (s.merc.on or 0) > 0 and s.merc.assisting ~= s.combat.myTargetID
                   and (mq.TLO.Mercenary.State() or '') == 'ACTIVE' then
                    require('modules.merc').check()
                end
            else
                if mobsInCamp > 1 or s.combat.myTargetID == 0 or
                   (xtSlotID(s.combat.xTSlot) > 0 and xtSlotID(s.combat.xTSlot2) > 0) then
                    pullReset()
                    return
                end
                local mob = mq.TLO.Spawn('id ' .. s.combat.myTargetID)
                if mob() and ma() then
                    local d = math.sqrt(((mob.Y() or 0) - (ma.Y() or 0))^2 + ((mob.X() or 0) - (ma.X() or 0))^2)
                    keepWaiting = d > 20 and (mq.TLO.Target.ID() or 0) == s.combat.myTargetID
                        and (me.TargetOfTarget.ID() or 0) == (me.ID() or -1)
                end
            end
        elseif role == 'pullerpettank' then
            local pet = me.Pet
            if (pet.ID() or 0) > 0 and
               math.sqrt(((pet.Y() or 0) - campY)^2 + ((pet.X() or 0) - campX)^2) > s.movement.campRadius and
               math.sqrt(((pet.Y() or 0) - (me.Y() or 0))^2 + ((pet.X() or 0) - (me.X() or 0))^2) > 20 then
                mq.cmd('/pet back off')
                mq.delay(500)
                mq.cmd('/pet follow')
            end
            local filter = string.format('xtarhater targetable loc %s %s radius %d zradius %d',
                campX, campY, s.pet.attackRange or 0, zr)
            if (mq.TLO.SpawnCount(filter)() or 0) == 0 then
                keepWaiting = true
            else
                s.combat.myTargetID = mq.TLO.NearestSpawn('1, ' .. filter).ID() or 0
                if not mq.TLO.Pet.Combat() then _combat.combatPet() end
            end
        end
        if not keepWaiting then break end
    end

    if s.combat.myTargetID ~= 0 and _utils.pullAggroID() == 0 then pullReset() end
end

-- Mirrors Sub PullWithMelee (kissassist.mac:10040). Closes in and swings until the
-- mob aggros or takes damage. The .mac loops forever; here the loop also ends when
-- the mob is gone or the pull deadline passes, and only a landed pull sets pulled.
local function pullWithMelee(mobID)
    local s    = _state
    local role = s.session.role
    local retreatRole = role == 'puller' or role == 'pullertank' or
                        role == 'pullerpettank' or role == 'hunterpettank'
    -- Keep MQ2Melee from fighting the mob while a puller tags it (mac:10043).
    local meleeOff = (role == 'puller' or role == 'pullertank') and s.combat.useMQ2Melee
    if meleeOff then mq.cmd('/squelch /melee melee=0') end

    local function landed()
        return hasAggro() or (mq.TLO.Target.PctHPs() or 100) < 100
    end
    -- MoveTo arrival distance shrinks by 5 each pass, down to 1 (mac:10051).
    local function arrival()
        local d = mq.TLO.MoveTo.ArrivalDist() or 0
        return d > 5 and math.floor(d - 5) or 1
    end
    local function stick(withID)
        if not s.pull.meleeStick or hasAggro() then return end
        local d = math.floor(mq.TLO.MoveTo.ArrivalDist() or 0)
        if withID then
            mq.cmdf('/squelch /stick %d id %d front', d, mobID)
        else
            mq.cmdf('/squelch /stick %d front', d)
        end
    end

    local deadline = math.max(s.timers.pullTimer or 0, os.clock() + 10)
    mq.cmd('/moveto id ' .. mobID .. ' mdist 15')
    mq.delay(1000)
    while true do
        mq.doevents()
        if landed() then break end
        local sp = mq.TLO.Spawn('id ' .. mobID)
        if not sp() or (sp.Type() or ''):lower() == 'corpse' then break end
        if os.clock() > deadline then
            printf('\awMelee pull timed out, mob never engaged.')
            break
        end
        if mq.TLO.Target.ID() then
            mq.cmd(s.movement.faceMobOn == 2 and '/face nolook' or '/face fast nolook')
        end
        mq.cmd('/look 0')
        if (mq.TLO.Target.MaxRangeTo() or 0) >= (mq.TLO.Target.Distance3D() or 999) then
            if not mq.TLO.Me.Moving() then
                mq.cmdf('/moveto id %d mdist %d', mobID, arrival())
            else
                mq.cmdf('/moveto mdist %d', arrival())
            end
            stick(false)
            if not mq.TLO.Stick.Active() then stick(true) end
        elseif not mq.TLO.Me.Moving() then
            mq.cmdf('/moveto id %d mdist %d', mobID, arrival())
            stick(false)
        end
        mq.cmd('/squelch /attack on')
        mq.delay(1000, landed)
        if landed() then break end
    end

    local pulled = landed()
    -- Pullers drop the mob and run back to camp; so does anyone whose pull failed.
    if retreatRole or not pulled then
        mq.cmd('/attack off')
        mq.cmd('/squelch /stick off')
        if retreatRole then mq.cmd('/squelch /target clear') end
    end
    if meleeOff then mq.cmd('/squelch /melee melee=1') end
    s.pull.pulled      = pulled
    s.movement.toClose = false
end

-- Mirrors Sub PullWithRanged RSwitch==1 path (kissassist.mac:10083).
local function pullWithRanged(mobID)
    local s = _state
    if mq.TLO.Me.Combat() then
        mq.cmd('/attack off')
        mq.delay(200, function() return not mq.TLO.Me.Combat() end)
    end
    mq.cmd('/squelch /stick off')
    if mq.TLO.Target.ID() then
        mq.cmd('/face fast nolook')
        mq.cmd('/look 0')
    end
    local tries = 0
    while tries < 3 do
        mq.doevents()
        if hasAggro() then s.pull.pulled = true; return end
        local tID   = mq.TLO.Target.ID()       or 0
        local tDist = mq.TLO.Target.Distance3D() or 0
        if tID == mobID and tDist >= 30 and mq.TLO.Target.LineOfSight() then
            mq.cmd('/range')
            local waitMs = math.max(100, math.floor(tDist / 50 + 1) * 1000)
            mq.delay(waitMs, function() return hasAggro() end)
        end
        if hasAggro() then s.pull.pulled = true; return end
        tries = tries + 1
    end
    if hasAggro() then s.pull.pulled = true end
end

-- Mirrors Sub PullWithPet (kissassist.mac:10313).
local function pullWithPet(mobID)
    local s = _state
    if mq.TLO.Target.ID() then mq.cmd('/face fast nolook') end
    if (mq.TLO.Me.Pet.Stance() or '') ~= 'FOLLOW' then mq.cmd('/pet follow') end
    printf('\awPulling with PET now!')
    -- Re-send the pet each 2s window it isn't moving; give up after 6 idle windows (mac:10323-10346)
    local petMoving    = false
    local triedSending = 0
    while not hasAggro() do
        if not petMoving then mq.cmd('/pet attack') end
        mq.delay(2000, function() mq.doevents(); return hasAggro() end)
        if hasAggro() then break end
        if mq.TLO.Me.Pet.Moving() then
            petMoving    = true
            triedSending = 0
        else
            petMoving    = false
            triedSending = triedSending + 1
        end
        local sp = mq.TLO.Spawn('id ' .. mobID)
        if not sp() or (sp.Type() or ''):lower() == 'corpse' then break end
        if triedSending > 5 then break end
    end
    if hasAggro() then s.pull.pulled = true end
    mq.cmd('/pet back off')
end

-- Mirrors Sub PullWithCast (kissassist.mac:10287). Used for nav/los spell/AA/item pulls.
local function pullWithCast(mobID)
    local s = _state
    stopMoving()
    if mq.TLO.Target.ID() then
        mq.cmd('/face fast nolook')
        mq.cmd('/look 0')
    end
    local tries = 0
    while tries < 5 do
        mq.doevents()
        if hasAggro() then s.pull.pulled = true; return end
        local sp = mq.TLO.Spawn('id ' .. mobID)
        if not (sp() and sp.LineOfSight()) then return end
        if not mq.TLO.Me.Moving() then
            local result = _cast.castWhat(s.pull.withAlt, mobID, 'Pull', 0, 0)
            if result == 'CAST_FIZZLE' then
                tries = tries + 1
            else
                if result == 'CAST_SUCCESS' or result == 'CAST_RESISTED'
                   or hasAggro() then
                    s.pull.pulled = true
                end
                mq.delay(100, function() return hasAggro() end)
                break
            end
        else
            mq.delay(100)
        end
    end
    if hasAggro() then s.pull.pulled = true end
end

-- Main pull movement + dispatch loop. Mirrors Sub Pull (kissassist.mac:9589–9969).
local function executePull(mobID)
    local s       = _state
    local moveUse = s.pull.moveUse
    local withAlt = s.pull.withAlt
    local pullDist = s.pull.range

    local pullAttempts = 0
    local stuckCount   = 0
    local wasInRange   = false
    local returnStat   = ''
    -- One pull attempt per call, so the mac's TryPetFirst reset never matters here.
    local tryPetFirst  = s.session.role == 'hunterpettank'  -- mac:9623

    s.pull.pulled  = false
    s.pull.tooFar  = false
    -- Pull attempt deadline (~25 s), extended while actively moving.
    s.timers.pullTimer = os.clock() + 25

    if not mq.TLO.Me.Mount.ID() and (mq.TLO.Me.Sitting() or mq.TLO.Me.Feigning()) then
        mq.cmd('/stand')
        mq.delay(200)
    end

    Pull.roleToggle(true, mobID)  -- mac:9634
    s.pull.beginMobID = tostring(mq.TLO.Me.XTarget(s.combat.xTSlot).ID() or 0)

    -- Stuck-detection baseline positions.
    local x1 = math.floor(mq.TLO.Me.X())
    local y1 = math.floor(mq.TLO.Me.Y())
    local x2, y2 = 0, 0

    ::outer::
    do
        local pullStatusFlag = 1  -- 1=moving 2=in-range 4=abort 5=oor-return
        returnStat = ''

        mq.doevents()

        -- GrabCorpse: own corpse within MaxRadius during pull (mac:9645)
        if (_state.heal.corpsRecoveryOn or 0) > 0 and _healing then
            local selfName = mq.TLO.Me.CleanName() or ''
            if not s.misc.dragCorpse and
               (mq.TLO.SpawnCount('pccorpse ' .. selfName .. ' radius ' .. s.pull.maxRadius)() or 0) > 0 then
                _healing.grabCorpse(1)
                if s.misc.dragCorpse then returnStat = 'btcr'; goto done end
            end
        end

        -- Something already has aggro on us (mac:9658). The .mac retargets
        -- AggroTargetID, i.e. the mob in the first Auto Hater XTarget slot.
        if hasAggro() then
            local aggroID = mq.TLO.Me.XTarget(s.combat.xTSlot).ID() or 0
            if aggroID == 0 then aggroID = s.combat.myTargetID end
            s.pull.pulled         = true
            s.combat.myTargetID   = aggroID
            s.combat.myTargetName = mq.TLO.Spawn('id ' .. aggroID).CleanName() or '?'
            stopMoving()
            _utils.debug('pull', 'executePull: early aggro detected')
            goto done
        end

        -- Mobs already in camp → abort pull.
        local meCampDist = dist2D(mq.TLO.Me.Y(), mq.TLO.Me.X(), s.movement.campY, s.movement.campX)
        local xSlot2ID   = mq.TLO.Me.XTarget(s.combat.xTSlot2).ID() or 0
        if ((s.combat.aggroTargetID ~= '' and s.pull.chainPull == 0) or
            (xSlot2ID > 0 and s.pull.chainPull > 0)) and
           meCampDist < s.movement.campRadius then
            printf('\awLooks like mobs in camp, aborting pull.')
            pullReset()
            goto done
        end

        local sp = mq.TLO.Spawn('id ' .. mobID)

        -- Evaluate pull status flag.
        if sp() then
            local mobCamp3D = math.sqrt(
                (sp.Y()-s.movement.campY)^2 + (sp.X()-s.movement.campX)^2 + (sp.Z()-s.movement.campZ)^2)
            local meCamp3D  = math.sqrt(
                (mq.TLO.Me.Y()-s.movement.campY)^2 +
                (mq.TLO.Me.X()-s.movement.campX)^2 +
                (mq.TLO.Me.Z()-s.movement.campZ)^2)
            if mobCamp3D > (s.pull.maxRadius + s.pull.range) then
                pullStatusFlag = 4
            elseif os.clock() > s.timers.pullTimer or
                   (pullAttempts >= 7 and not sp.LineOfSight()) then
                pullStatusFlag = 4
            elseif meCamp3D >= s.pull.maxRadius * 0.95 then
                pullStatusFlag = 5
            end
        else
            pullStatusFlag = 4
        end
        if pullStatusFlag ~= 1 then returnStat = 'btcr' end

        -- Move toward mob while status is normal and out of pull range.
        if pullStatusFlag == 1 and sp() then
            local myDist3D = sp.Distance3D() or 999
            local hasLOS   = sp.LineOfSight()

            if myDist3D > pullDist or not hasLOS then
                -- Extend timer while actively navigating.
                if moveUse == 'nav' then
                    if mq.TLO.Navigation.PathExists('id ' .. mobID)() then
                        mq.cmd('/squelch /nav id ' .. mobID)  -- re-issued every pass (mac:10434)
                    end
                    if mq.TLO.Navigation.Active() then
                        s.timers.pullTimer = s.timers.pullTimer + 0.5
                    end
                    mq.delay(100)
                    -- GrabCorpse: own corpse found on nav path (mac:10370)
                    if (_state.heal.corpsRecoveryOn or 0) > 0 and _healing then
                        local selfName = mq.TLO.Me.CleanName() or ''
                        if not s.misc.dragCorpse and
                           (mq.TLO.SpawnCount('pccorpse ' .. selfName .. ' radius 89')() or 0) > 0 then
                            _healing.grabCorpse(2)
                            if s.misc.dragCorpse then returnStat = 'btcr'; goto done end
                        end
                    end
                elseif moveUse == 'los' then
                    if hasLOS then
                        local uwSuffix = mq.TLO.Me.FeetWet() and ' uw' or ''
                        mq.cmdf('/moveto id %d mdist %d%s', mobID, math.floor(pullDist), uwSuffix)
                        x2 = math.floor(mq.TLO.Me.X())
                        y2 = math.floor(mq.TLO.Me.Y())
                    elseif x2 ~= 0 then
                        -- Lost LOS: abort if we drifted too far or timed out.
                        if dist2D(mq.TLO.Me.Y(), mq.TLO.Me.X(), y2, x2) > 200
                           or os.clock() > s.timers.pullTimer then
                            mq.cmd('/squelch /moveto off')
                            returnStat     = 'btcr'
                            pullStatusFlag = 4
                        end
                    end
                    if mq.TLO.Me.Moving() or mq.TLO.MoveTo.Moving() then
                        s.timers.pullTimer = s.timers.pullTimer + 0.5
                    end
                    mq.delay(100)
                end

                -- Stuck detection (mac:9807–9825).
                local cx = math.floor(mq.TLO.Me.X())
                local cy = math.floor(mq.TLO.Me.Y())
                if cx == x1 and cy == y1 then
                    stuckCount = stuckCount + 1
                    if stuckCount >= 2 and not mq.TLO.Me.Hovering() then
                        _movement.stuck('pull')
                    end
                    if stuckCount >= 7 and not hasAggro() then
                        printf('\awI am stuck, aborting pull.')
                        stopMoving()
                        returnStat     = 'btcr'
                        pullStatusFlag = 4
                    end
                else
                    stuckCount = 0
                end
                x1, y1 = cx, cy

                pullAttempts = pullAttempts + 1
                -- Creep pullDist smaller on repeated failures (mac:9791–9800).
                myDist3D = sp.Distance3D() or 999
                if myDist3D <= pullDist and not sp.LineOfSight() and withAlt ~= 'Pet' then
                    if pullAttempts >= 7 then pullDist = pullDist * 0.6 end
                end
                if pullAttempts >= 3 and (sp.Speed() or 0) > 25 and wasInRange and myDist3D > pullDist then
                    pullDist   = pullDist * 0.6
                    wasInRange = false
                end
            elseif myDist3D <= pullDist and hasLOS then
                pullStatusFlag = 2
            end
        end

        if s.pull.pulled or hasAggro() then goto done end

        -- BTC: if abort-level, stop; if no LOS, stop.
        if returnStat == 'btcr' then
            if pullStatusFlag == 4 then goto done end
            if withAlt ~= 'Pet' then
                if not (sp() and sp.LineOfSight()) then goto done end
            else
                if not sp() or (sp.Distance3D() or 999) > pullDist then goto done end
            end
            if pullStatusFlag ~= 5 then returnStat = '' end
        end

        -- Still moving toward mob → loop.
        if pullStatusFlag == 1 then goto outer end

        -- In pull range: stop, validate, dispatch.
        if sp() then
            local myDist3D = sp.Distance3D() or 999
            if myDist3D < s.pull.range or
               (withAlt == 'Melee' and myDist3D < s.pull.range * 2) then
                stopMoving()
                mq.cmd('/target id ' .. mobID)
                mq.delay(200, function() return (mq.TLO.Target.ID() or 0) == mobID end)

                if not _combat.validateTarget(mobID) then
                    printf('\awAborting pull! Target no longer valid.')
                    returnStat = 'btcr'
                    goto done
                end
                wasInRange = true
                x2 = math.floor(mq.TLO.Me.X())
                y2 = math.floor(mq.TLO.Me.Y())

                -- hunterpettank sends the pet in first when the mob is close,
                -- whatever PullWith says (mac:9623, 9878-9887). If the pet won't
                -- engage, fall back to the normal pull method.
                local petSent = false
                if tryPetFirst and (mq.TLO.Pet.ID() or 0) > 0 and myDist3D < s.combat.meleeDistance then
                    if withAlt ~= 'Pet' then printf('\aw====>> Sending in Pet. Ignoring PullWith.') end
                    _combat.combatPet()
                    mq.delay(500, function() return mq.TLO.Pet.Combat() end)
                    petSent = mq.TLO.Pet.Combat() and true or false
                    if not petSent and withAlt ~= 'Pet' then
                        printf('\aw====>> Sending in Pet Failed. Trying normal PullWith Option.')
                    end
                end

                if petSent then
                    s.pull.pulled = true
                elseif withAlt == 'Melee' then
                    pullWithMelee(mobID)
                elseif withAlt == 'Ranged' and not s.movement.toClose then
                    pullWithRanged(mobID)
                elseif withAlt == 'Pet' then
                    pullWithPet(mobID)
                else
                    -- nav/los/spell/AA/item cast pull.
                    pullWithCast(mobID)
                end
                goto done
            end
        end

        -- los/nav: loop if not yet pulled.
        if (moveUse == 'los' or moveUse == 'nav') and not s.pull.pulled then
            goto outer
        end
    end

    ::done::
    -- Post-pull cleanup (mac:9924–9969).
    mq.cmd('/moveto dist 10')
    if not s.pull.pulled and hasAggro() then
        s.pull.pulled = true
        returnStat    = ''
    end
    s.pull.pulling = false

    if returnStat == 'btcr' then
        -- Don't keep retrying a mob we couldn't pull (mac:9936-9942).
        if s.combat.myTargetID ~= 0 then
            Pull.ignoreAdd(s.combat.myTargetID, 'pull2')
            s.combat.myTargetID = 0
        elseif (mq.TLO.Target.ID() or 0) > 0 then
            Pull.ignoreAdd(mq.TLO.Target.ID(), 'pull3')
            mq.cmd('/squelch /target clear')
        end
        -- PullOnReturn: hand back 'oor' so the caller looks for another mob on
        -- the way back (mac:9944-9949). Otherwise go back to camp.
        if s.pull.pullOnReturn then return 'oor' end
        if s.movement.returnToCamp then
            _movement.doWeMove(1, 'pullcheck')
        end
        return
    end

    -- Back to camp, then wait for the mob to arrive (mac:9951-9966).
    if s.movement.returnToCamp then
        _movement.doWeMove(1, 'pull')
    end
    if s.pull.pulled then Pull.roleToggle(false) end  -- back in camp (mac:9913)
    if s.movement.returnToCamp then
        if s.pull.pulled then
            waitForMob()
            if mq.TLO.Target.ID() and (s.movement.faceMobOn or 0) == 3 then
                mq.cmd('/face fast nolook')
            end
            s.pull.pulled = false
        end
    end
end

-- ---------------------------------------------------------------------------
-- Step 7.8 — Pull.pullCheck
-- ---------------------------------------------------------------------------

-- Outer pull coordinator. Mirrors Sub PullCheck (kissassist.mac:9308–9416).
-- Guards, target acquisition, ValidateTarget, announce, then executePull.
function Pull.pullCheck()
    local s = _state

    -- ChainPull 2 = "just-finished"; reset to 1 = active for next mob.
    if s.pull.chainPull == 2 then s.pull.chainPull = 1 end
    if s.pull.pullOnReturn and s.movement.checkOnReturn then
        s.movement.checkOnReturn = false
    end

    -- Guards (mac:9313).
    if s.pull.hold   then return end
    if s.dps.paused  then return end
    if (mq.TLO.Me.Buff('Resurrection Sickness').ID() or 0) > 0 then return end
    if (mq.TLO.Me.Buff('Revival Sickness').ID()       or 0) > 0 then return end
    if (s.movement.campX == 0 and s.movement.campY == 0) then return end
    if s.movement.campZone ~= mq.TLO.Zone.ID() then return end
    if mq.TLO.Me.Invis() then return end

    local pullMob = s.pull.mob

    -- No mob: increment fail counter; hunter returns to camp when exhausted.
    if pullMob == 0 then
        s.cast.failCounter = s.cast.failCounter + 1
        _utils.debug('pull', 'pullCheck: no valid target (failCounter=%d)', s.cast.failCounter)
        if s.cast.failCounter >= s.cast.failMax then
            s.cast.failCounter = 0
            s.timers.pullAlert = 0  -- clear the pull ignore list next search (mac:9398)
            local role     = s.session.role
            local isHunter = (role == 'hunter' or role == 'hunterpettank')
            if isHunter then
                local dCamp = dist2D(mq.TLO.Me.Y(), mq.TLO.Me.X(), s.movement.campY, s.movement.campX)
                if dCamp > 15 then
                    printf('\awNo mobs within %d. %s', s.pull.maxRadius,
                        s.movement.stayPut and 'Waiting here for respawn.' or 'Returning to camp.')
                    if not s.movement.stayPut then
                        _movement.doWeMove(1, 'pullcheck')
                    end
                end
            end
            -- PullWait respawn wait (mac:9415-9418). Non-blocking; see Pull.pullWaiting.
            if s.pull.pullWait > 0 and (s.combat.aggroTargetID or '') == '' then
                printf('\awPULLING-> Waiting %d seconds for mobs to respawn.', s.pull.pullWait)
                Pull.startPullWait(s.pull.pullWait)
            end
        end
        return
    end

    local sp = mq.TLO.Spawn('id ' .. pullMob)
    if not sp() then return end

    -- Target mob for los/nav modes so buffs-populated check can run (mac:9314–9317).
    local moveUse = s.pull.moveUse
    if moveUse == 'los' or moveUse == 'nav' then
        if (sp.Distance3D() or 999) <= 360 or sp.LineOfSight() then
            mq.cmd('/target id ' .. pullMob)
            mq.delay(200, function() return (mq.TLO.Target.ID() or 0) == pullMob end)
        end
    end

    -- Advpath guard: deferred to M7 stretch (mac:9321–9333).
    if moveUse == 'advpath' then
        _utils.debug('pull', 'pullCheck: advpath mode deferred (M7 stretch)')
        return
    end

    s.pull.pulling = true

    -- ValidateTarget (mac:9335–9342).
    if not _combat.validateTarget(pullMob) then
        mq.cmd('/squelch /target clear')
        s.pull.pulling = false
        return
    end
    -- Reject mob too far from camp for los/nav modes.
    if (mq.TLO.Target.ID() or 0) == pullMob and (moveUse == 'los' or moveUse == 'nav') then
        local mobCampDist = dist2D(sp.Y(), sp.X(), s.movement.campY, s.movement.campX)
        if mobCampDist > s.pull.maxRadius then
            mq.cmd('/squelch /target clear')
            s.pull.pulling = false
            return
        end
    end

    -- Announce pull (mac:9343–9350)
    local mobName = sp.CleanName() or '?'
    local mobFeet = math.floor(dist2D(sp.Y(), sp.X(), s.movement.campY, s.movement.campX))
    printf('\awPULLING-> \at%s\aw <- ID:%d at %d feet.', mobName, pullMob, mobFeet)
    if _comms then _comms.broadcast('PULL', {mob = mobName, dist = mobFeet}) end

    s.combat.myTargetID   = pullMob
    s.combat.myTargetName = mobName

    -- Bard: stop medley before pull when pullTwistOn=0 (mac:9629-9631)
    if _bard and s.session.iAmABard and not s.bard.pullTwistOn then
        _bard.stopMedley()
    end

    -- Wait for rampage pets to poof before executing pull. Only pullerpettank
    -- MAG/NEC/BST, as in the mac (mac:8965).
    if _pet and s.pet.on and s.pet.petRampageOn and mq.TLO.Me.CombatState() ~= 'COMBAT'
       and s.session.role == 'pullerpettank' and RAMP_PET_CLASSES[mq.TLO.Me.Class.ShortName() or ''] then
        _pet.checkRampPets()
    end

    local ret = executePull(pullMob)
    Pull.pullPauseActive()

    _utils.debug('pull', 'pullCheck: leave mob=%d ret=%s', pullMob, tostring(ret))
    if ret == 'oor' then
        s.movement.checkOnReturn = true  -- mac:9369-9371
        return 'oor'
    end
end

-- After a failed pull with PullOnReturn on, look for another mob on the way
-- back to camp instead of walking all the way home first. Port of
-- FindMobOnReturn (mac:10609-10626). Movement.doWeMove does the searching
-- (mac:3448) and leaves any mob it finds in pull.mob.
function Pull.findMobOnReturn()
    local s        = _state
    local isHunter = s.session.role:find('hunter', 1, true) ~= nil
    _utils.debug('pull', 'findMobOnReturn: enter role=%s', s.session.role)
    while not s.terminate do
        s.pull.mob = 0
        if isHunter then
            s.movement.checkOnReturn = true
            _movement.doWeMove(1, 'findMobOnReturn')
        else
            _movement.doWeMove(0, 'findMobOnReturn')
        end
        if s.pull.mob == 0 then break end
        Pull.pullCheck()
        if isHunter then break end
        if dist2D(mq.TLO.Me.X(), mq.TLO.Me.Y(), s.movement.campX, s.movement.campY) < 16 then break end
    end
    s.pull.mob = 0
    _utils.debug('pull', 'findMobOnReturn: leave')
end

return Pull
