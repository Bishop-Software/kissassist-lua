-- pull.lua — Pull module: mob discovery, validation, and pull execution.
-- Ported from kissassist.mac FindMobToPull (8945), PullValidate (9443), PullCheck (9308).
-- Steps 7.5 (scaffold+INI), 7.6 (pullValidate), 7.7 (findMobToPull), 7.8 (pullCheck).

local mq     = require('mq')
local Config = require('modules.config')

local Pull = {}
local _state, _utils, _cast, _movement

-- ---------------------------------------------------------------------------
-- Local helpers
-- ---------------------------------------------------------------------------

-- 2D XY distance.
local function dist2D(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return math.sqrt(dx * dx + dy * dy)
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

-- Check whether mobID falls within the configured pull arc.
-- Mac: FigureMobAngle (mac:14511-14520)
local function figureMobAngle(mobID)
    local sp = mq.TLO.Spawn('id ' .. mobID)
    if not sp() then return false end
    local locStr = tostring(_state.movement.campY) .. ',' .. tostring(_state.movement.campX)
    local dir    = sp.HeadingTo(locStr).Degrees() or 0
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

function Pull.init(state, utils, cast, movement)
    _state    = state
    _utils    = utils
    _cast     = cast
    _movement = movement

    -- [Pull] section
    _state.pull.on           = Config.get('Pull', 'PullOn',        '0') == '1'
    _state.pull.withAlt      = Config.get('Pull', 'PullWith',      'Melee')
    _state.pull.range        = tonumber(Config.get('Pull', 'PullRange',    '0'))  or 0
    _state.pull.maxRadius    = tonumber(Config.get('Pull', 'MaxRadius',    '0'))  or 0
    _state.pull.maxZRange    = tonumber(Config.get('Pull', 'MaxZRange',    '0'))  or 0
    _state.pull.min          = tonumber(Config.get('Pull', 'PullMin',      '0'))  or 0
    _state.pull.max          = tonumber(Config.get('Pull', 'PullMax',      '0'))  or 0
    _state.pull.hold         = Config.get('Pull', 'PullHold',      '0') == '1'
    _state.pull.pullArcWidth = tonumber(Config.get('Pull', 'PullArcWidth', '0'))  or 0
    _state.pull.lSide        = tonumber(Config.get('Pull', 'PullLSide',    '0'))  or 0.0
    _state.pull.rSide        = tonumber(Config.get('Pull', 'PullRSide',    '0'))  or 0.0
    _state.pull.pullWait     = tonumber(Config.get('Pull', 'PullWait',     '0'))  or 0
    _state.pull.chainPull    = tonumber(Config.get('Pull', 'ChainPull',    '0'))  or 0
    _state.pull.pullOnReturn = Config.get('Pull', 'PullOnReturn',  '0') == '1'
    _state.pull.ranking      = tonumber(Config.get('Pull', 'PullRanking',  '0'))  or 0
    _state.pull.mobsToPullFirst = Config.get('Pull', 'MobsToPull',     'all')
    _state.pull.mobsToIgnore    = Config.get('Pull', 'MobsToIgnore',   'null')
    _state.pull.mobsNotAllowed  = Config.get('Pull', 'MobsNotAllowed', 'null')
    _state.pull.moveUse         = Config.get('Pull', 'PullMoveUse',    'los')
    _state.pull.searchType      = Config.get('Pull', 'SearchType',     '')
    -- waypointZRange mirrors MaxZRange (used by movement nav Z-range guard)
    _state.pull.waypointZRange  = _state.pull.maxZRange

    -- Derive arc half-widths from PullArcWidth when individual sides not set
    if _state.pull.pullArcWidth > 0 and _state.pull.lSide == 0 and _state.pull.rSide == 0 then
        local half = _state.pull.pullArcWidth / 2.0
        _state.pull.lSide = -half
        _state.pull.rSide =  half
    end

    -- [PullAdvanced] section
    _state.pull.pullLocsOn  = Config.get('PullAdvanced', 'PullLocsOn', '0') == '1'
    _state.pull.pathWpCount = tonumber(Config.get('PullAdvanced', 'PullWpCount', '0')) or 0
    _state.pull.maxWpRange  = tonumber(Config.get('PullAdvanced', 'MaxWpRange',  '0')) or 0

    for i = 1, _state.pull.pathWpCount do
        _state.pull.pullLocY[i] = tonumber(Config.get('PullAdvanced', 'PullLocY'..i, '0')) or 0.0
        _state.pull.pullLocX[i] = tonumber(Config.get('PullAdvanced', 'PullLocX'..i, '0')) or 0.0
        _state.pull.pullLocZ[i] = tonumber(Config.get('PullAdvanced', 'PullLocZ'..i, '0')) or 0.0
    end

    _utils.debug('pull', 'Pull.init complete — on=%s with=%s range=%d maxRadius=%d',
        tostring(_state.pull.on), _state.pull.withAlt,
        _state.pull.range, _state.pull.maxRadius)
end

-- ---------------------------------------------------------------------------
-- Step 7.6 — Pull.pullValidate
-- ---------------------------------------------------------------------------

-- Validate a single spawn as a pull candidate.
-- Mac: PullValidate (mac:9443-9567)
-- flag: spawn index from findMobToPull (>0 enables server-lag HP recheck).
-- Returns true (valid) or false (skip).
function Pull.pullValidate(mobID, flag)
    local sp = mq.TLO.Spawn('id ' .. mobID)
    if not sp() then return false end

    local name     = sp.CleanName() or ''
    local moveUse  = _state.pull.moveUse

    -- Mob-name allowed-list filter.
    -- Mac has a two-level MobsToPullFirst/MobsToPull split; Lua port uses one merged list.
    -- If mobsToPullFirst != 'all': mob name must appear in the list.
    if _state.pull.mobsToPullFirst ~= 'all' then
        if not inNameList(_state.pull.mobsToPullFirst, name) then
            _utils.debug('pull', 'pullValidate: %s not on MobsToPull list', name)
            return false
        end
    end

    -- Ignore by name.
    if inNameList(_state.pull.mobsToIgnore, name) then
        _utils.debug('pull', 'pullValidate: %s on MobsToIgnore list', name)
        return false
    end

    -- Ignore by spawn ID.
    if _state.pull.mobsToIgnoreByID ~= 'null' and
       _state.pull.mobsToIgnoreByID:find(tostring(mobID) .. '|', 1, true) then
        _utils.debug('pull', 'pullValidate: %d on MobsToIgnoreByID list', mobID)
        return false
    end

    -- PullLocs proximity: reject mobs too close to any advpath waypoint location.
    if _state.pull.pullLocsOn and _state.pull.maxWpRange > 0 then
        local mx, my = sp.X() or 0, sp.Y() or 0
        for i = 1, #_state.pull.pullLocX do
            if dist2D(mx, my, _state.pull.pullLocX[i], _state.pull.pullLocY[i])
               <= _state.pull.maxWpRange then
                _utils.debug('pull', 'pullValidate: %s near pull loc %d', name, i)
                return false
            end
        end
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
        if suffix ~= '' and (mq.TLO.SpawnCount('pc ' .. suffix)() or 0) > 0 then
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

-- Step 7.7: scan zone for best pull candidate; sets state.pull.mob on success.
-- Returns 1 (found) or 0 (none).
function Pull.findMobToPull(readyFlag, a, b) -- luacheck: ignore a b
    _utils.debug('pull', 'findMobToPull stub — Step 7.7')
    return 0
end

-- Step 7.8: execute the pull against state.pull.mob.
function Pull.pullCheck()
    _utils.debug('pull', 'pullCheck stub — Step 7.8')
end

return Pull
