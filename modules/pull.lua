-- pull.lua — Pull module facade. Wires up the modules/pull/ submodules,
-- re-exports their functions as Pull.* (so callers and tests are unchanged),
-- and holds pullCheck, the outer pull coordinator (mac PullCheck, 9308).
--
--   pull/util.lua      shared helpers (distances, aggro, PullReset, ...)
--   pull/settings.lua  INI load, zone lists, PullLocs, PullLevel, ranking, range
--   pull/arc.lua       pull arc and MQ2Map drawing
--   pull/roles.lua     puller/hunter role setup, group Puller role toggle
--   pull/holds.lua     ready check, PullWait, PullPause, hold reasons
--   pull/validate.lua  PullValidate
--   pull/search.lua    FindMobToPull, chain pull, ignore list, pull on return
--   pull/execute.lua   executePull (approach loop), pull methods, WaitForMob

local mq       = require('mq')
local Util     = require('modules.pull.util')
local Settings = require('modules.pull.settings')
local Arc      = require('modules.pull.arc')
local Roles    = require('modules.pull.roles')
local Holds    = require('modules.pull.holds')
local Validate = require('modules.pull.validate')
local Search   = require('modules.pull.search')
local Execute  = require('modules.pull.execute')

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
Pull.mercPullerRole    = Roles.mercPullerRole

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

local _state, _utils, _movement, _combat, _pet, _bard, _comms

-- Classes whose rampage pets CheckRampPets waits on (mac:8965).
local RAMP_PET_CLASSES = {MAG = true, NEC = true, BST = true}

local dist2D      = Util.dist2D
local executePull = Execute.executePull  -- the approach loop (modules/pull/execute.lua)

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------

function Pull.init(state, utils, cast, movement, combat, pet, bard, healing, comms)
    _state    = state
    _utils    = utils
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
    Execute.init(state, utils, cast, combat, movement, Pull)

    -- [Pull] / [PullAdvanced] INI settings (modules/pull/settings.lua).
    Settings.init(state, utils, Pull)
    Settings.load()
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

    -- AdvPath pulling: not ported (parked) (mac:9321-9333).
    if moveUse == 'advpath' then
        _utils.debug('pull', 'pullCheck: advpath mode not supported')
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
