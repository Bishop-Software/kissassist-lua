local mq      = require('mq')
local Settings  = require('modules.combat.settings')
local Util      = require('modules.combat.util')
local Abilities = require('modules.combat.abilities')
local Radar     = require('modules.combat.radar')
local Targeting = require('modules.combat.targeting')
local Fight     = require('modules.combat.fight')

local Combat = {}
local _state, _utils, _heal, _movement, _bard, _mez, _debuff, _comms, _charm

local isDeadOrGone  = Util.isDeadOrGone
local distFromCamp  = Util.distFromCamp
local getMASpawn    = Util.getMASpawn

-- Ability helpers (modules/combat/abilities.lua)
local namedWatch   = Abilities.namedWatch
local groupEscape  = Abilities.groupEscape
local rogueHide    = Abilities.rogueHide
Combat.feignAggroCheck = Abilities.feignAggroCheck
Combat.aggroCheck      = Abilities.aggroCheck

-- Mob counting/validation (modules/combat/radar.lua) and targeting (modules/combat/targeting.lua)
local validateTarget = Radar.validateTarget
local campNpcCount   = Radar.campNpcCount
Combat.mobRadar          = Radar.mobRadar
Combat.assist            = Targeting.assist
Combat.getCombatTarget   = Targeting.getCombatTarget
Combat.combatTargetCheck = Targeting.combatTargetCheck
Combat.fight             = Fight.fight

-- Expose validateTarget for pull.lua (Step 7.8).
Combat.validateTarget = validateTarget

-- Expose groupEscape for debuff.lua (mac:7858).
Combat.groupEscape = groupEscape

-- Mirrors Bind_Settings (DPS/Melee/Burn/General sections) from kissassist.mac.
-- Loads combat arrays and wires state.combat flags from INI.
function Combat.init(state, utils, cast, heal, movement, bard, cond, mez, debuff, buffs, comms, merc, charm)
    _state    = state
    _utils    = utils
    _heal     = heal
    _movement = movement
    _bard     = bard
    _mez      = mez
    _debuff   = debuff
    _comms    = comms
    _charm    = charm

    Util.init(state)
    Abilities.init(state, utils, cast, cond, mez, Combat)
    Radar.init(state, utils)
    Targeting.init(state, utils, Combat)
    Fight.init(state, utils, cast, heal, movement, bard, mez, debuff, buffs, comms, merc, Combat)
    Settings.load(state, utils)
end

-- Mirrors Sub CombatReset (kissassist.mac:2144).
-- sFlag: 0=full reset (DPS output + loot), 1=quick reset (skip DPS/loot).
-- Clears CombatStart, stops attack, resets all target tracking fields.
function Combat.combatReset(sFlag, calledFrom)
    _utils.debug('combat', 'combatReset: enter sFlag=%s from=%s', tostring(sFlag), tostring(calledFrom))

    if _state.session.role == 'manual' then return end

    -- DPS meter output (deferred — MQ2DPSAdv not yet wired, Step M9)

    Combat.mobRadar('los', _state.combat.meleeDistance)

    -- Mez array and immune-ID cleanup (mac:2196–2214)
    if _state.mez.on > 0 then
        local myTID  = _state.combat.myTargetID
        local xTotal = _state.combat.xSlotTotal
        for j = 1, xTotal do
            local entry = _state.arrays.mezArray[j]
            if entry and entry[1] ~= 'NULL' then
                if entry[1] == tostring(myTID) or isDeadOrGone(entry[1]) then
                    _state.arrays.mezArray[j] = {'NULL','NULL','NULL'}
                end
            end
        end
        local immuneIDs = _state.mez.immuneIDs or ''
        if immuneIDs ~= '' then
            local kept = {}
            for id in immuneIDs:gmatch('|([^|]+)') do
                if not isDeadOrGone(id) then
                    kept[#kept+1] = id
                end
            end
            _state.mez.immuneIDs = #kept > 0 and ('|' .. table.concat(kept, '|')) or ''
        end
        _state.mez.mobDone = false
    end

    -- MobsToIgnoreByID: remove dead/corpse entries (mac:2216–2224)
    local ignoreIDs = _state.pull.mobsToIgnoreByID or 'null'
    if ignoreIDs ~= 'null' and ignoreIDs ~= '' then
        local kept = {}
        for id in ignoreIDs:gmatch('|([^|]+)') do
            if not isDeadOrGone(id) then
                kept[#kept+1] = id
            end
        end
        _state.pull.mobsToIgnoreByID = #kept > 0 and ('|' .. table.concat(kept, '|')) or 'null'
    end

    -- Core state reset (mac:2226–2234)
    _state.combat.calledTargetID  = 0
    _state.combat.aggroTargetID2  = '0'
    _state.combat.myTargetID      = 0
    _state.combat.myTargetName    = ''
    _state.combat.lastTargetID    = 0
    _state.combat.validTarget     = false
    _state.combat.combatStart     = false
    _state.pull.pulled            = false
    -- Bard: reset dpsTwisting so next doBardStuff tick transitions back to OOC medley.
    if _bard and _state.session.iAmABard then _state.bard.dpsTwisting = false end

    -- Stop attacking and clear target; reset autofire (mac:2246-2250)
    if _state.combat.useMQ2Melee then mq.cmd('/squelch /melee melee=0') end
    mq.cmd('/squelch /attack off')
    if mq.TLO.Me.AutoFire() then mq.cmd('/autofire') end
    if _state.combat.autoFireOn == 2 then _state.combat.autoFireOn = 1 end
    mq.cmd('/squelch /target clear')

    -- Reset XTarget slot to auto-hater for non-MA (mac:2252–2254)
    if _state.combat.xTarAutoSet and not mq.TLO.Me.Hovering() then
        local ma = _state.session.mainAssist
        if (mq.TLO.Group.Member(ma).Index() or 0) == 0 and not _state.session.iAmMA then
            local xSlot = _state.combat.xTSlot
            if xSlot > 0 then
                mq.cmd('/xtarget set ' .. xSlot .. ' autohater')
            end
        end
    end

    -- Pet: send back to camp (mac:2263–2266)
    if (mq.TLO.Me.Pet.ID() or 0) ~= 0 then
        _state.timers.petAttack = 0
        mq.cmd('/pet back off')
        -- PetHold re-enable (deferred — pet module Step M6)
    end

    -- Clear per-slot DPS timers on fight end (mac CreateTimersDPS; Step 13.1)
    for k in pairs(_state.combat.slotTimers) do _state.combat.slotTimers[k] = 0 end

    -- Combat flags (mac:2280–2282)
    _state.combat.attacking  = false
    _state.combat.burnActive = false
    _state.dps.target        = 0

    -- Clear burn state if burn target died (mac:2283–2287)
    local burnID = _state.combat.burnID
    if burnID ~= 0 then
        if isDeadOrGone(burnID) then
            _state.combat.burnCalled = false
            _state.combat.burnID     = 0
            mq.cmd('/echo Burn Target is Dead. Pausing Burn.')
        end
    end

    -- Loot (deferred — loot module Step M8)
    -- Bard stuff (deferred — bard module)

    -- TargetSwitching reset for non-MA (mac:2311)
    if not _state.session.iAmMA then
        _state.combat.targetSwitchingOn = false
    end

    -- Reset tank and pet-follow timers (mac:2312,2314)
    _state.timers.tank      = os.clock() + 30
    _state.timers.petFollow = os.clock() + 60

    -- Wait up to 2s for aggroOff timer to clear (mac:2315 /delay 2s ${AggroOffTimer}==0)
    mq.delay(2000, function()
        local exp = _state.timers.aggroOff or 0
        return exp == 0 or os.clock() >= exp
    end)

    -- Drain pending events (mac:2321–2325)
    repeat
        _state.combat.eventFlag = false
        mq.doevents()
    until not _state.combat.eventFlag

    -- Release combat stick; if ChaseAssist is on, doWeChase manages stick itself (mac:2326)
    if mq.TLO.Stick.Active() and not _state.session.chaseAssist then
        mq.cmd('/squelch /stick off')
    end

    -- Re-enable MQ2Melee melee mode for next engagement (mac:2246 inverse)
    if _state.combat.useMQ2Melee then mq.cmd('/squelch /melee melee=1') end

    if _debuff then _debuff.resetFight() end
    if _charm  then _charm.resetFight()  end

    -- ROG auto-stealth after combat ends (mac:2328)
    rogueHide()

    _utils.debug('combat', 'combatReset: done from=%s', tostring(calledFrom))
end

-- Mirrors Sub CheckForAdds (kissassist.mac:2333).
-- Called after each combat pass to detect and announce new mobs in camp.
function Combat.checkForAdds(calledFrom)
    Combat.mobRadar('los', _state.combat.meleeDistance)

    local mobCount = _state.combat.mobCount
    local aggroID  = tonumber(_state.combat.aggroTargetID) or 0

    if mobCount <= 1 then return end
    if _state.misc.dmz and not mq.TLO.Me.InInstance() then return end
    if _state.pull.pulling then return end
    if not _state.combat.dpsOn and not _state.combat.meleeOn then return end

    local role     = _state.session.role
    local isPuller = role == 'puller' or role == 'pullertank' or role == 'pullerpettank'

    if isPuller then
        local campDist = distFromCamp(mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0)
        if campDist >= _state.movement.campRadius then return end
    end

    if _state.session.iAmDead then return end
    if _state.pull.chainPull == 2 or _state.dps.paused then return end

    -- Re-acquire a valid living target within camp radius before declaring adds (mac:2346).
    -- Manual target mode owns selection — don't force a re-lock onto the tracked mob.
    local myID = _state.combat.myTargetID
    if (mq.TLO.Target.ID() or 0) == 0 and myID ~= 0 and not _state.combat.manualTargetMode then
        local sp = mq.TLO.Spawn('id ' .. myID)
        if sp and (sp.ID() or 0) ~= 0 then
            local spDist = distFromCamp(sp.Y() or 0, sp.X() or 0)
            if spDist < _state.movement.campRadius then
                mq.cmd('/squelch /target id ' .. myID)
                return
            end
        end
    end

    -- Add spam popup + optional broadcast (mac:2351–2356)
    if aggroID ~= 0 and myID == 0 then
        local aggrSp   = mq.TLO.Spawn('id ' .. aggroID)
        local aggrY    = aggrSp and aggrSp.Y() or 0
        local aggrX    = aggrSp and aggrSp.X() or 0
        local aggrDist = distFromCamp(aggrY, aggrX)
        local addExpiry = _state.timers.addSpam or 0
        if aggrDist <= _state.movement.campRadius and os.clock() >= addExpiry then
            mq.cmd('/popup Add(s) in camp detected')
            local isTank = role == 'tank' or role == 'pullertank'
                        or role == 'pettank' or role == 'pullerpettank'
            if _state.session.iAmMA or isTank then
                if _comms then
                    _comms.announce('Add(s) in camp detected')
                else
                    mq.cmd('/echo Add(s) in camp detected')
                end
            end
            if role == 'pullertank' or role == 'pullerpettank' then
                _state.pull.pulled = false
            end
            _state.timers.addSpam = os.clock() + 5
        end
    end

    -- Puller still returning toward camp — don't stall (mac:2358)
    if isPuller and _state.pull.pulled then
        local campDist = distFromCamp(mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0)
        if campDist >= 15 then return end
    end

    -- Tank roles acquire aggroTargetID if no target (mac:2359)
    local isTankRole = role == 'tank'    or role == 'pullertank'
                    or role == 'pettank' or role == 'pullerpettank'
                    or role == 'hunter' or role == 'hunterpettank'
    if (mq.TLO.Target.ID() or 0) == 0 and isTankRole and aggroID ~= 0
       and not _state.combat.manualTargetMode then
        mq.cmd('/squelch /target id ' .. aggroID)
    end

    -- Stale myTargetID cleanup: if current target is not an NPC, clear it (mac:2360)
    local tgtType = (mq.TLO.Target.Type() or ''):lower()
    if tgtType ~= 'npc' and myID ~= 0 then
        if isDeadOrGone(myID) then
            _state.combat.lastTargetID = myID
            _state.combat.myTargetID   = 0
        end
        -- Manual target mode: keep the dead/gone cleanup above (so after-death
        -- auto-pick still fires) but don't clear a target the player is holding.
        if not _state.combat.manualTargetMode then
            mq.cmd('/squelch /target clear')
        end
        return
    end

    _utils.debug('combat', 'checkForAdds: mobCount=%d from=%s', mobCount, tostring(calledFrom))
end

-- Port of GetCombatPosition 0 (kissassist.mac:627-678). Called only when LOSBeforeCombat=1.
-- Only repositions for a mob that is already within MeleeDistance but out of line of sight.
-- A mob farther out (e.g. one still being pulled) gets up to 3s to arrive; if it doesn't,
-- we stay put rather than running out to it.
local _combatPosSpam = 0
local function getCombatPosition(mobID)
    if _state.dps.paused then return end
    local function mob() return mq.TLO.Spawn('id ' .. mobID) end
    local function dist() return math.floor(mob().Distance3D() or 999) end
    if (mob().ID() or 0) == 0 then return end
    local md = _state.combat.meleeDistance

    if dist() > md then
        mq.delay(3000, function() return dist() <= md end)
        if dist() > md then
            if os.clock() > _combatPosSpam then
                printf('\awGet Combat Position Failed. Target is too far away(%d).', dist())
                _combatPosSpam = os.clock() + 5
            end
            return
        end
    end

    if mq.TLO.Stick.Active() then mq.cmd('/squelch /stick off') end
    local distanceCheck = _state.combat.meleeOn and math.floor(mob().MaxRangeTo() or md) or md
    local distanceFrom  = distanceCheck - 2
    local function inPosition() return dist() <= distanceCheck and mob().LineOfSight() end
    local timeout = os.clock() + 5

    local meshLoaded = _state.pull.moveUse == 'nav' and (mq.TLO.Navigation.MeshLoaded() or false)
    if meshLoaded then
        while os.clock() < timeout do
            if not mq.TLO.Navigation.Active() then
                mq.cmdf('/squelch /nav id %d dist=%d los=on', mobID, distanceFrom)
            end
            if inPosition() then break end
            mq.delay(500)
        end
        if mq.TLO.Navigation.Active() then mq.cmd('/squelch /nav stop') end
        if dist() > distanceCheck and mob().LineOfSight() then
            mq.cmdf('/squelch /moveto id %d dist %d', mobID, distanceFrom)
        end
    else
        mq.cmdf('/squelch /moveto id %d dist %d', mobID, distanceFrom)
        mq.delay(5000, inPosition)
        if mq.TLO.MoveTo.Moving() then mq.cmd('/squelch /moveto off') end
    end
end

-- Mirrors Sub CheckForCombat (kissassist.mac:484).
-- Called from the main loop each tick when dpsOn or meleeOn.
-- skipCombat: 0=full combat path, 1=healer/no-DPS mode (cures/heals only, no melee)
-- waitTime: EngageWaitTimer initial countdown in 50ms ticks (0 = no wait)
function Combat.checkForCombat(skipCombat, fromWhere, waitTime)
    skipCombat = skipCombat or 0
    fromWhere  = fromWhere  or 'main'
    waitTime   = waitTime   or 0

    if _state.session.role == 'manual' then return end

    -- ChaseAssist + moving guard: don't interrupt a moving non-MA chaser (mac:485)
    if _state.session.chaseAssist and mq.TLO.Me.Moving() then
        local myName     = mq.TLO.Me.CleanName() or ''
        local whoToChase = _state.movement.whoToChase
        if not _state.session.iAmMA or whoToChase ~= myName then
            return
        end
    end

    if skipCombat == 0 then
        -- Clear iAmDead once resurrection sickness fades and corpse despawns (mac:489)
        if _state.session.iAmDead then
            local sickBuff  = mq.TLO.Me.Buff('Resurrection Sickness')
            local hasSick   = sickBuff and (sickBuff.ID() or 0) ~= 0
            local myName    = mq.TLO.Me.CleanName() or ''
            local corpseCount = mq.TLO.SpawnCount('pccorpse ' .. myName)() or 0
            if hasSick or corpseCount == 0 then
                _state.session.iAmDead = false
            end
        end

        Combat.mobRadar('los', _state.combat.meleeDistance)

        if _movement then _movement.doWeChase() end

        -- Hard guards: bail if combat is not appropriate now (mac:493)
        local aggroID  = tonumber(_state.combat.aggroTargetID) or 0
        local mobCount = _state.combat.mobCount
        if _state.misc.dmz and not mq.TLO.Me.InInstance() then return end
        if mq.TLO.Me.Hovering() then return end
        if _state.session.iAmDead and aggroID == 0 then return end
        if mobCount == 0 and aggroID == 0 then
            -- Tank: after a kill, mezzed adds that were mem-blurred off XTarget are still
            -- in camp. Let getCombatTarget's MezMobFlag scan find them (mac:493, mac:899).
            if not (_state.session.iAmMA and _state.mez.mobFlag
                    and campNpcCount(_state.combat.meleeDistance) > 0) then
                return
            end
        end
        if not _state.combat.dpsOn and not _state.combat.meleeOn then return end

        -- Bard DPS twist (deferred — bard module)

        -- EngageWaitTimer: deadline after which we stop waiting for a target (mac:496)
        local engageDeadline = os.clock() + (waitTime * 0.05)

        if not _state.session.iAmMA then
            -- Non-MA: assist loop with EngageWaitTimer (mac:499–515)
            while true do
                local maID   = getMASpawn().ID() or 0

                if _state.session.role ~= 'offtank' or maID ~= 0 then
                    Combat.assist(fromWhere)
                    -- SwitchMA return value (deferred — DanNet/EQBC Step M9)
                else
                    -- Offtank with dead MA: promote self to MA (mac:508-511)
                    mq.cmd('/switchma ' .. (mq.TLO.Me.CleanName() or '') .. ' tank')
                    break
                end

                if _heal then _heal.checkHealth('CheckForCombat') end

                local myTID = _state.combat.myTargetID
                local aID   = tonumber(_state.combat.aggroTargetID) or 0
                if myTID ~= 0 or _state.session.role ~= 'assist'
                   or os.clock() >= engageDeadline or aID == 0 then
                    break
                end
                mq.delay(50)
            end
            -- Reposition to LOS before engaging (mac:516)
            if _state.combat.losBeforeCombat then
                local tid = _state.combat.myTargetID
                if tid ~= 0 and aggroID ~= 0 then
                    local tgtSp = mq.TLO.Spawn('id ' .. tid)
                    if tgtSp and not tgtSp.LineOfSight() then
                        getCombatPosition(tid)
                    end
                end
            end

        else
            -- MA/Offtank path: wait for mob in melee radius then select target (mac:520–535)
            local role     = _state.session.role
            local isPuller = role == 'pullertank' or role == 'pullerpettank'
                          or role == 'hunter'     or role == 'hunterpettank'

            if not isPuller then
                local aID = tonumber(_state.combat.aggroTargetID) or 0
                if aID ~= 0 then
                    while true do
                        if isDeadOrGone(aID) then break end

                        local md       = _state.combat.meleeDistance
                        local meY      = mq.TLO.Me.Y() or 0
                        local meX      = mq.TLO.Me.X() or 0
                        local campDist = distFromCamp(meY, meX)
                        local cnt
                        if campDist > md then
                            cnt = mq.TLO.SpawnCount('xtarhater radius ' .. md .. ' zradius 50')() or 0
                        else
                            local cY = _state.movement.campY
                            local cX = _state.movement.campX
                            cnt = mq.TLO.SpawnCount('xtarhater loc ' .. cX .. ' ' .. cY
                                                   .. ' radius ' .. md .. ' zradius 50')() or 0
                        end
                        _state.combat.mobCount = cnt

                        if cnt > 0 or os.clock() >= engageDeadline then break end
                        mq.delay(50)
                    end
                end
            end

            Combat.getCombatTarget()
        end

        -- Engage combat for the acquired target (Step 4.5)
        if _state.combat.myTargetID ~= 0 then
            Combat.fight(fromWhere)
        end

        -- FeignAggroCheck: if we FD'd to drop aggro, wait before standing (mac:538)
        if mq.TLO.Me.Feigning() or mq.TLO.Me.Invis() then
            Combat.feignAggroCheck()
        end

        -- ChainPull==2: puller signaled all done, exit combat pass (mac:540)
        if _state.pull.chainPull == 2 then return end
    end

    if _mez then _mez.check('checkForCombat') end
    if _mez then _mez.aeCheck() end

    -- SkipCombat==1 healer loop (mac:563-580)
    if skipCombat == 1 and _heal then
        _heal.checkCures()
        _heal.checkHealth('SkipCombat')
        -- NamedWatch IgnoreTarget=true: scan xtarhater for nearby named (mac:576)
        if not _state.combat.namedCheck then namedWatch(true) end
    end

    -- CheckForAdds: scan for new mobs that entered camp during combat (mac:586)
    Combat.checkForAdds(fromWhere)

    -- Tank/pullertank: camp movement and mob-count gating (mac:587–599)
    local role = _state.session.role
    if role == 'tank' or role == 'pullertank' then
        -- DoWeChase, DoWeMove, EnduranceCheck (deferred — movement/buffs modules)
    elseif role ~= 'manual' then
        -- Non-manual non-tank: CombatReset if our target died (mac:601)
        local myID = _state.combat.myTargetID
        if myID ~= 0 then
            if isDeadOrGone(myID) then
                Combat.combatReset(0, fromWhere .. '_targetDead')
            end
        end
    end

    _utils.debug('combat', 'checkForCombat: done from=%s', fromWhere)
end

return Combat
