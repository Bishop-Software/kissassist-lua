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
        local name = entry:sub(1, 1) == '#' and entry:sub(2) or entry
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
    if mq.TLO.Me.Invis() or s.pull.hold or s.dps.paused or
       (mq.TLO.Me.Buff('Resurrection Sickness').ID() or 0) > 0 or
       (mq.TLO.Me.Buff('Revival Sickness').ID()         or 0) > 0 then
        return 0
    end

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
            -- Simplified: if XTarget[slot] still occupied, previous chain mob live (mac:8958)
            if (mq.TLO.Me.XTarget(s.combat.xTSlot).ID() or 0) > 0 then return 0 end
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
        vstStr1    = useCampLoc and (base .. ' loc ' .. cx .. ' ' .. cy) or base
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

-- Step 7.8: execute the pull against state.pull.mob.
function Pull.pullCheck()
    _utils.debug('pull', 'pullCheck stub — Step 7.8')
end

return Pull
