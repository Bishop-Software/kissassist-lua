-- pull/settings.lua — pull settings: the [Pull]/[PullAdvanced] INI load (body of
-- Pull.init), this zone's pull/ignore lists and no-pull areas (PullLocs),
-- Pull Ranking, PullLevel, the movement mode (pickMoveUse) and the pull range
-- (rangeSet). Step 2 of the pull module split (see the pull_module_split_plan).
--
-- Calls to other pull functions go through the facade table (Pull.*), looked
-- up at call time, so tests that stub Pull functions still see the stubs.

local mq     = require('mq')
local Config = require('modules.config')
local Util   = require('modules.pull.util')

local Settings = {}
local _state, _utils
local Pull  -- the facade (modules/pull.lua), set by Settings.init

local dist2D = Util.dist2D

local PULL_LOC_SLOTS = 5  -- PullLocs1-5 (mac:14976)

function Settings.init(state, utils, pull)
    _state = state
    _utils = utils
    Pull   = pull
end

-- Load the [Pull] and [PullAdvanced] INI settings into State. Called from
-- Pull.init after Settings.init.
function Settings.load()
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

-- Load this zone's pull/ignore lists from KissAssist_Info.ini (shared across
-- characters). Called at startup and again after zoning.
function Settings.loadZoneLists()
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
function Settings.parsePullLoc(raw)
    if not raw then return nil end
    local y, x, r = tostring(raw):match('^%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)%s*|%s*([%d%.]+)%s*$')
    y, x, r = tonumber(y), tonumber(x), tonumber(r)
    if not (y and x and r) or r <= 0 then return nil end
    return { y = y, x = x, range = r }
end

-- Rebuild the parsed no-pull areas from pull.pullLocsRaw.
function Settings.buildPullLocAreas()
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
function Settings.setPullLoc(i, raw)
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
function Settings.inPullLocArea(y, x)
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
function Settings.setRanking(on, quiet)
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
function Settings.setPullLevel(value)
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
function Settings.levelGained()
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
function Settings.pickMoveUse(onlyIfChanged)
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
function Settings.rangeSet()
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

return Settings
