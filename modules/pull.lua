-- pull.lua — Pull module: mob discovery, validation, and pull execution.
-- Ported from kissassist.mac FindMobToPull (8945), PullValidate (9443), PullCheck (9308).
-- Steps 7.5 (scaffold+INI), 7.6 (pullValidate), 7.7 (findMobToPull), 7.8 (pullCheck).

local mq       = require('mq')
local Util     = require('modules.pull.util')
local Settings = require('modules.pull.settings')
local Arc      = require('modules.pull.arc')
local Roles    = require('modules.pull.roles')
local Holds    = require('modules.pull.holds')
local Validate = require('modules.pull.validate')
local Search   = require('modules.pull.search')

local Pull = {}

-- Submodule functions are re-exported so callers keep using Pull.*.

-- Settings (modules/pull/settings.lua)
Pull.loadZoneLists     = Settings.loadZoneLists
Pull.parsePullLoc      = Settings.parsePullLoc
Pull.buildPullLocAreas = Settings.buildPullLocAreas
Pull.setPullLoc        = Settings.setPullLoc
Pull.inPullLocArea     = Settings.inPullLocArea
Pull.setRanking        = Settings.setRanking
Pull.setPullLevel      = Settings.setPullLevel
Pull.levelGained       = Settings.levelGained
Pull.pickMoveUse       = Settings.pickMoveUse
Pull.rangeSet          = Settings.rangeSet

-- Pull arc and map drawing (modules/pull/arc.lua)
Pull.headingTo         = Arc.headingTo
Pull.pullAngles        = Arc.pullAngles
Pull.clearArc          = Arc.clearArc
Pull.arcPoint          = Arc.arcPoint
Pull.drawArc           = Arc.drawArc
Pull.setPullAngles     = Arc.setPullAngles
Pull.paintMap          = Arc.paintMap

-- Role setup and the group Puller role toggle (modules/pull/roles.lua)
Pull.setupHunterRole   = Roles.setupHunterRole
Pull.setupPullerRole   = Roles.setupPullerRole
Pull.roleToggle        = Roles.roleToggle

-- Ready check, PullWait, PullPause and hold reasons (modules/pull/holds.lua)
Pull.pullAbilityReady  = Holds.pullAbilityReady
Pull.startPullWait     = Holds.startPullWait
Pull.pullWaiting       = Holds.pullWaiting
Pull.setPullPause      = Holds.setPullPause
Pull.pullPauseCheck    = Holds.pullPauseCheck
Pull.pullPauseActive   = Holds.pullPauseActive
Pull.heldByCond        = Holds.heldByCond
Pull.holdReasons       = Holds.holdReasons

-- Pull candidate validation (modules/pull/validate.lua)
Pull.nameAllowed       = Validate.nameAllowed
Pull.pullValidate      = Validate.pullValidate

-- Mob search, chain pull, ignore list, pull on return (modules/pull/search.lua)
Pull.findMobToPull     = Search.findMobToPull
Pull.chainPullNextMob  = Search.chainPullNextMob
Pull.chainPullBusy     = Search.chainPullBusy
Pull.ignoreAdd         = Search.ignoreAdd
Pull.onPullIgnore      = Search.onPullIgnore
Pull.pullIgnoreTick    = Search.pullIgnoreTick
Pull.findMobOnReturn   = Search.findMobOnReturn
Pull.setGroupWatch     = Search.setGroupWatch  -- findMobToPull runs GroupWatch (mac:8986)

local _state, _utils, _cast, _movement, _combat, _pet, _bard, _comms

-- Classes whose rampage pets CheckRampPets waits on (mac:8965).
local RAMP_PET_CLASSES = {MAG = true, NEC = true, BST = true}

-- ---------------------------------------------------------------------------
-- Shared helpers (modules/pull/util.lua)
-- ---------------------------------------------------------------------------

local dist2D        = Util.dist2D
local distToCamp3D  = Util.distToCamp3D
local hasAggro      = Util.hasAggro
local stopMoving    = Util.stopMoving
local pullReset     = Util.pullReset
local xtSlotID      = Util.xtSlotID
local moveToMob     = Util.moveToMob
local grabOwnCorpse = Util.grabOwnCorpse

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------

function Pull.init(state, utils, cast, movement, combat, pet, bard, healing, comms)
    _state    = state
    _utils    = utils
    _cast     = cast
    _movement = movement
    _combat   = combat
    _pet      = pet
    _bard     = bard
    _comms    = comms
    Util.init(state, utils, healing)
    if movement and movement.setPull then movement.setPull(Pull) end
    Arc.init(state, Pull)     -- before Settings.load, which aims the arc
    Roles.init(state, utils)
    Holds.init(state, Pull)   -- before Settings.load, which sets PullPause
    Validate.init(state, utils, Pull)
    Search.init(state, utils, combat, movement, Pull)

    -- [Pull] / [PullAdvanced] INI settings (modules/pull/settings.lua).
    Settings.init(state, utils, Pull)
    Settings.load()
end

-- ---------------------------------------------------------------------------
-- Step 7.8 — local helpers for pull execution
-- ---------------------------------------------------------------------------

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
                    local d = dist2D(mob.Y() or 0, mob.X() or 0, ma.Y() or 0, ma.X() or 0)
                    keepWaiting = d > 20 and (mq.TLO.Target.ID() or 0) == s.combat.myTargetID
                        and (me.TargetOfTarget.ID() or 0) == (me.ID() or -1)
                end
            end
        elseif role == 'pullerpettank' then
            local pet = me.Pet
            if (pet.ID() or 0) > 0 and
               dist2D(pet.Y() or 0, pet.X() or 0, campY, campX) > s.movement.campRadius and
               dist2D(pet.Y() or 0, pet.X() or 0, me.Y() or 0, me.X() or 0) > 20 then
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
    local returnStat
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
    local nextTick = os.clock() + 1  -- next once-a-second pull check

    ::outer::
    do
        local pullStatusFlag = 1  -- 1=moving 2=in-range 4=abort 5=oor-return
        returnStat = ''

        mq.doevents()

        -- GrabCorpse: own corpse within MaxRadius during pull (mac:9645)
        if grabOwnCorpse(s.pull.maxRadius, 1) then returnStat = 'btcr'; goto done end

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
            local mobCamp3D = distToCamp3D(sp.Y(), sp.X(), sp.Z())
            local meCamp3D  = distToCamp3D(mq.TLO.Me.Y(), mq.TLO.Me.X(), mq.TLO.Me.Z())
            if mobCamp3D > (s.pull.maxRadius + s.pull.range) then
                pullStatusFlag = 4
            elseif os.clock() > s.timers.pullTimer or
                   (pullAttempts >= 7 and not sp.LineOfSight()) then
                pullStatusFlag = 4
            elseif pullAttempts >= 7 then
                pullAttempts = 0  -- still in sight: the mac starts a new round of tries (mac:9690)
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
                    if grabOwnCorpse(89, 2) then returnStat = 'btcr'; goto done end
                elseif moveUse == 'los' then
                    if hasLOS then
                        moveToMob(mobID, pullDist)
                        x2 = math.floor(mq.TLO.Me.X())
                        y2 = math.floor(mq.TLO.Me.Y())
                    elseif x2 ~= 0 then
                        -- Lost LOS: abort if we drifted too far or timed out.
                        if dist2D(mq.TLO.Me.Y(), mq.TLO.Me.X(), y2, x2) > 200
                           or os.clock() > s.timers.pullTimer then
                            mq.cmd('/squelch /moveto off')
                            returnStat     = 'btcr'
                            pullStatusFlag = 4
                        elseif (not mq.TLO.Me.Moving() or not mq.TLO.MoveTo.Moving())
                               and pullDist < (sp.Distance() or 0) then
                            -- Keep closing in to find LOS again (mac:9743-9750).
                            moveToMob(mobID, pullDist)
                        end
                    end
                    if mq.TLO.Me.Moving() or mq.TLO.MoveTo.Moving() then
                        s.timers.pullTimer = s.timers.pullTimer + 0.5
                    end
                    mq.delay(100)
                end

                -- Once a second, as the mac's pull loop (its /delay 10, mac:9806):
                -- stuck check, attempt count and creeping closer.
                if os.clock() >= nextTick then
                    nextTick = os.clock() + 1

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

                    -- The mac's nav step doesn't return until the mob is in
                    -- range and in sight (PullUsingNav, mac:10420), so a try
                    -- only counts once nav has stopped moving us.
                    local navigating = moveUse == 'nav' and mq.TLO.Navigation.Active()
                    if not navigating then pullAttempts = pullAttempts + 1 end

                    myDist3D = sp.Distance3D() or 999
                    local los = sp.LineOfSight()
                    if myDist3D <= pullDist and (sp.FeetWet() == mq.TLO.Me.FeetWet() or withAlt == 'Pet') then
                        wasInRange = true  -- mac:9764
                    end
                    -- Creep pullDist smaller on repeated failures (mac:9791–9800).
                    -- Not while nav is still walking us in (the mac is still
                    -- inside PullUsingNav then).
                    if not navigating and pullAttempts >= 7 and myDist3D <= pullDist
                       and not los and withAlt ~= 'Pet' then
                        pullDist = pullDist * 0.6
                    elseif not navigating and pullAttempts >= 3 and (sp.Speed() or 0) > 25
                           and wasInRange and myDist3D > pullDist then
                        pullDist   = pullDist * 0.6
                        wasInRange = false
                    elseif not navigating and (myDist3D > s.pull.range or not los)
                           and (withAlt ~= 'Pet' or myDist3D > s.pull.range)
                           and (not mq.TLO.Me.Moving() or wasInRange) then
                        -- Out of range or sight and not closing in: move in
                        -- closer next time (mac:9832-9836).
                        pullDist = pullDist * 0.8
                    end
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
    if s.pull.hold or s.pull.watchHold then return end
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

return Pull
