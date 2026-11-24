-- pull/search.lua — finding the next mob to pull: FindMobToPull and its
-- LOS / nav / pull-first scans, the chain-pull hand-off, the pull ignore list
-- (PullIgnore1), and looking for a mob on the way back to camp.
-- Step 5 of the pull module split (see the pull_module_split_plan).
--
-- Calls to other pull functions go through the facade table (Pull.*), looked
-- up at call time. Two tests rely on that: test_pull_chain stubs
-- Pull.findMobToPull for chainPullNextMob, and test_pull_on_return stubs
-- Pull.pullCheck for findMobOnReturn.

local mq   = require('mq')
local Util = require('modules.pull.util')

local Search = {}
local _state, _utils, _combat, _movement
local _groupWatch  -- modules/groupwatch.lua, set by Search.setGroupWatch
local Pull  -- the facade (modules/pull.lua), set by Search.init

local dist2D = Util.dist2D

function Search.init(state, utils, combat, movement, pull)
    _state    = state
    _utils    = utils
    _combat   = combat
    _movement = movement
    Pull      = pull
end

function Search.setGroupWatch(gw) _groupWatch = gw end

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

-- Mid-fight chain pull hand-off. Mirrors Sub ChainPullNextMob (mac:15751),
-- called from the fight loop for a chain-pulling puller. When the current mob
-- is below ChainPullHP, the MA is in camp and nothing else is incoming, look
-- for the next mob (findMobToPull with readyFlag 0); if one is found, stop
-- fighting and leave it in state.pull.mob for Phase 9 to pull.
-- Returns 1 (go pull), 'W' (MA too far from camp, message shown) or 0.
function Search.chainPullNextMob(echoWait)
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
    if s.pull.hold or s.pull.pauseHold or s.pull.watchHold or (s.combat.mobCount or 0) >= 2
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
function Search.chainPullBusy()
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

-- ---------------------------------------------------------------------------
-- Step 7.7 — Pull.findMobToPull
-- ---------------------------------------------------------------------------

-- Scan the zone for the best pull candidate; sets state.pull.mob on success.
-- Mac: FindMobToPull (mac:8945-9116)
-- readyFlag: 1=ready to pull, 0=chain-pull availability check.
-- a: initial Piterations (pass 1); b: UseCampLoc for hunter (pass 0).
-- Returns 1 (found, state.pull.mob set) or 0 (none).
function Search.findMobToPull(readyFlag, _a, b)
    local s    = _state
    local role = s.session.role

    local isPullerRole = Util.isPullerRole(role)

    -- Entry guards (mac:8947-8948)
    if (s.misc.dmz and not mq.TLO.Me.InInstance()) or
       not isPullerRole or s.pull.pulled or
       (s.combat.aggroTargetID ~= '' and s.pull.chainPull == 0) then
        return 0
    end
    -- heal.medding: the mac's DoWeMed loop keeps a medding puller from pulling (mac:3956);
    -- heal.petMedding: its DoPetMedStuff loop waits on the pet's health (mac:4141).
    if mq.TLO.Me.Invis() or s.pull.hold or s.pull.pauseHold or s.pull.watchHold or s.dps.paused or
       s.heal.medding or s.heal.petMedding or
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
    if _groupWatch then _groupWatch.check() end  -- mac:8986
    if s.pull.hold or s.pull.watchHold then return 0 end  -- mac:8987
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

    -- The mac's alert-list ignore handling (mac:8997-9004) is covered by the
    -- MobsToIgnore check in pullValidate and pullIgnoreTick.

    -- AdvPath pulling: not ported (parked) (mac:9008-9010)
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

-- Pull ignore list ("|id|id|", mac PullIgnore1): mobs the puller gave up on.
-- Only pull searches skip them (and combat while a pull is under way,
-- mac:994); it is cleared every 5 minutes (Pull.pullIgnoreTick). Separate
-- from MobsToIgnoreByID, which combat always refuses.

-- Add a spawn ID. Mirrors the 'a' action of Sub PullIgnoreCheck (mac:9980).
function Search.ignoreAdd(mobID, from)
    local id = tonumber(mobID) or 0
    if id < 1 then return end
    local p    = _state.pull
    local list = p.ignore1
    if not list or list == 'null' or list == '' then list = '|' end
    if list:find('|' .. id .. '|', 1, true) then return end
    p.ignore1 = list .. id .. '|'
    printf('\awAdded %d to ignore pull list. (%s)', id, from or '')
end

function Search.onPullIgnore(mobID)
    local list = _state.pull.ignore1
    if not list or list == 'null' or list == '' then return false end
    return list:find('|' .. tostring(mobID) .. '|', 1, true) ~= nil
end

-- Each mob search (mac:8998): clear the list every 5 minutes, otherwise drop
-- dead or despawned entries (PullIgnoreCheck 'c').
function Search.pullIgnoreTick()
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

-- After a failed pull with PullOnReturn on, look for another mob on the way
-- back to camp instead of walking all the way home first. Port of
-- FindMobOnReturn (mac:10609-10626). Movement.doWeMove does the searching
-- (mac:3448) and leaves any mob it finds in pull.mob.
function Search.findMobOnReturn()
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

return Search
