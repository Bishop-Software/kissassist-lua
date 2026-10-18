local mq      = require('mq')
local Settings  = require('modules.combat.settings')
local Util      = require('modules.combat.util')
local Abilities = require('modules.combat.abilities')
local Radar     = require('modules.combat.radar')
local Targeting = require('modules.combat.targeting')

local Combat = {}
local _state, _utils, _cast, _heal, _movement, _bard, _mez, _debuff, _buffs, _comms, _merc, _charm

local dist2D        = Util.dist2D
local isDeadOrGone  = Util.isDeadOrGone
local targetAndWait = Util.targetAndWait
local distFromCamp  = Util.distFromCamp
local getMASpawn    = Util.getMASpawn

-- Ability helpers (modules/combat/abilities.lua)
local beforeAttack = Abilities.beforeAttack
local combatPet    = Abilities.combatPet
local namedWatch   = Abilities.namedWatch
local groupEscape  = Abilities.groupEscape
local aeCheck      = Abilities.aeCheck
local checkGoM     = Abilities.checkGoM
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

-- Expose validateTarget for pull.lua (Step 7.8).
Combat.validateTarget = validateTarget

-- Expose groupEscape for debuff.lua (mac:7858).
Combat.groupEscape = groupEscape

-- Mirrors Bind_Settings (DPS/Melee/Burn/General sections) from kissassist.mac.
-- Loads combat arrays and wires state.combat flags from INI.
function Combat.init(state, utils, cast, heal, movement, bard, cond, mez, debuff, buffs, comms, merc, charm)
    _state    = state
    _utils    = utils
    _cast     = cast
    _heal     = heal
    _movement = movement
    _bard     = bard
    _mez      = mez
    _debuff   = debuff
    _buffs    = buffs
    _comms    = comms
    _merc     = merc
    _charm    = charm

    Util.init(state)
    Abilities.init(state, utils, cast, cond, mez, Combat)
    Radar.init(state, utils)
    Targeting.init(state, utils, Combat)
    Settings.load(state, utils)
end

-- Mirrors Sub Combat (kissassist.mac:1036).
-- Executes the melee/spell combat loop for the current myTargetID until the mob dies.
-- Called from checkForCombat once a target has been acquired.
function Combat.fight(fromWhere)
    mq.doevents()

    local myID = _state.combat.myTargetID
    if myID == 0 or (mq.TLO.Target.ID() or 0) == 0 then return end
    if _state.misc.dmz and not mq.TLO.Me.InInstance() then return end

    -- LOS check; hunter roles bypass it (mac:1042-1043)
    local role     = _state.session.role
    local isHunter = role == 'hunter' or role == 'hunterpettank'
    if not mq.TLO.Target.LineOfSight() and not isHunter then return end

    if _state.dps.paused then return end

    -- Mezzed target: non-MA won't attack below assistAt% to avoid breaking mez (mac:1047-1053)
    if mq.TLO.Target.Mezzed.ID() then
        if (getMASpawn().ID() or 0) ~= 0
           and not _state.session.iAmMA then
            local pct = mq.TLO.Spawn('id ' .. myID).PctHPs() or 100
            if pct <= _state.combat.assistAt then
                mq.delay(500)
                return
            end
        end
    end

    -- Puller: don't engage while actively pulling and outside camp radius (mac:1039)
    local isPuller = role == 'puller' or role == 'pullertank' or role == 'pullerpettank'
    if isPuller and _state.pull.pulling then
        local campDist = distFromCamp(mq.TLO.Me.Y() or 0, mq.TLO.Me.X() or 0)
        if campDist >= _state.movement.campRadius then return end
    end

    -- CombatRadius: MaxRangeTo+5 if it exceeds MeleeDistance (mac:1056)
    local sp = mq.TLO.Spawn('id ' .. myID)
    local maxRange     = sp and sp.MaxRangeTo() or 0
    local combatRadius = _state.combat.meleeDistance
    if maxRange > combatRadius then combatRadius = maxRange + 5 end

    -- Deferred: CheckCures/CheckHealth (M5), DoWeChase (M7), DPS meter (M9)

    -- Mez runs before the engage block (BeforeAttack/melee/discs) so a fresh pull
    -- doesn't wake adds before they can be locked down (mac:1069-1071).
    if _mez and _state.mez.on ~= 0 then _mez.check(fromWhere) end
    if _mez then _mez.aeCheck() end

    -- Initial pet engagement check (mac:1078)
    sp = mq.TLO.Spawn('id ' .. myID)
    if (sp and sp.PctHPs() or 100) <= _state.pet.assistAt
       and (sp and sp.Distance3D() or 999) < _state.pet.attackRange then
        combatPet()
    end

    -- Determine range condition (mob in melee range or MA+target both in camp) (mac:1080)
    sp = mq.TLO.Spawn('id ' .. myID)
    local mobPct  = sp and sp.PctHPs() or 100
    local mobDist = sp and sp.Distance()  or 999
    local spType  = sp and sp.Type()      or ''

    local maSpawn  = getMASpawn()
    local maY, maX = (maSpawn and maSpawn.Y() or 0), (maSpawn and maSpawn.X() or 0)
    local tgtY = sp and sp.Y() or 0
    local tgtX = sp and sp.X() or 0
    local campToMA = distFromCamp(maY, maX)
    local maToTgt  = dist2D(maY, maX, tgtY, tgtX)
    local cr       = _state.movement.campRadius
    local inRange  = mobDist < combatRadius
                  or (campToMA <= cr and maToTgt <= cr)

    -- ─── Main engage block: not corpse, HP ≤ assistAt (MA always engages), in range ──
    if spType:lower() ~= 'corpse'
       and (_state.session.iAmMA or mobPct <= _state.combat.assistAt)
       and inRange then

        -- CombatStart: announce first attack (mac:1081-1093)
        if not _state.combat.combatStart then
            _utils.debug('combat', 'fight: CombatStart set, Attacking=%s', tostring(_state.combat.attacking))
            _state.merc.assisting        = 0  -- reset so merc re-assists this fight (mac:1084)
            _state.combat.combatStart    = true
            local tgtName = mq.TLO.Spawn('id ' .. myID).CleanName() or '?'
            mq.cmd('/echo  ATTACKING -> ' .. tgtName .. ' <-')
            if _bard then _bard.doBardStuff() end
            -- Tank-announce on first engage (mac:1088-1089)
            if role == 'tank' or role == 'pullertank' or role == 'hunter' then
                if _comms then
                    _comms.announce(string.format('TANKING-> %s <- ID:%d', tgtName, myID))
                end
            elseif role == 'pettank' or role == 'pullerpettank' or role == 'hunterpettank' then
                local petName = mq.TLO.Me.Pet.CleanName() or 'Pet'
                if _comms then
                    _comms.announce(string.format('%s is TANKING-> %s <- ID:%d', petName, tgtName, myID))
                end
            end
            -- Hunter: close gap before combat announce (mac:1112 context)
            if (role == 'hunter' or role == 'hunterpettank')
               and not _state.combat.useMQ2Melee and _movement then
                _movement.checkStick(0, 0)
            end
        end

        -- Look level when not underwater (mac:1095)
        if not mq.TLO.Me.FeetWet() then mq.cmd('/squelch /look 0') end

        -- Merc re-assist on target change (mac:1144)
        if _merc then _merc.check() end

        -- Initiate attack (mac:1097-1127)
        if not _state.combat.attacking then
            if _state.combat.meleeOn then
                -- Bards: Casting.ID stays non-zero while songs play (same gate as cast.lua:201).
                if not _state.session.iAmABard
                        and ((mq.TLO.Me.Casting.ID() or 0) ~= 0
                             or mq.TLO.Window('CastingWindow').Open()) then
                    goto skip_first_engage
                end
                _state.combat.attacking = true
                if mq.TLO.Me.Sitting() then mq.cmd('/stand') end
                if _state.combat.autoFireOn ~= 1 then
                    -- Normal melee first engage (mac:1101-1114)
                    local isTankLike = role == 'tank' or role == 'pullertank' or role == 'hunter'
                    if isTankLike and (mq.TLO.Me.Skill('Taunt')() or 0) > 0
                       and mq.TLO.Me.AbilityReady('Taunt')() then
                        mq.cmd('/doability Taunt')
                    end
                    if not mq.TLO.Me.Combat() and _state.arrays.beforeArray[1] ~= 'null' then
                        beforeAttack(myID, 1)
                    end
                    if _state.pet.combatOn and (mq.TLO.Me.Pet.ID() or 0) ~= 0 then
                        sp = mq.TLO.Spawn('id ' .. myID)
                        if (sp and sp.PctHPs() or 100) <= _state.pet.assistAt
                           and not mq.TLO.Pet.Combat() then
                            combatPet()
                        end
                    end
                    if _movement then _movement.checkStick(0, 1) end
                    if _movement then _movement.zAxisCheck() end
                else
                    -- AutoFireOn==1: ranged only — BeforeAttack, no melee stick (mac:1116)
                    if not mq.TLO.Me.Combat() and _state.arrays.beforeArray[1] ~= 'null' then
                        beforeAttack(myID, 1)
                    end
                end
            else
                -- MeleeOn off: pet-only combat (mac:1119-1127)
                if mq.TLO.Stick.Active() then mq.cmd('/squelch /stick off') end
                if _state.pet.combatOn and (mq.TLO.Me.Pet.ID() or 0) ~= 0 then
                    sp = mq.TLO.Spawn('id ' .. myID)
                    if (sp and sp.PctHPs() or 100) <= _state.pet.assistAt
                       and not mq.TLO.Pet.Combat() then
                        combatPet()
                        _state.combat.attacking = true
                    end
                end
            end
        end
        ::skip_first_engage::

        -- Enable mez-mob scan for tank roles (mac:1131)
        if role == 'tank' or role == 'pullertank'
           or role == 'pettank' or role == 'pullerpettank' then
            _state.mez.mobFlag = true
        end

        -- ─── Inner combat while loop (mac:1132-1315) ─────────────────────────
        while true do
            -- Drain all pending events before each iteration (mac:1135-1138)
            repeat
                _state.combat.eventFlag = false
                mq.doevents()
            until not _state.combat.eventFlag

            if _state.terminate then break end

            -- Died mid-fight (or now hovering as a corpse): stop the loop so we
            -- don't spam casts/attacks while dead ("too distracted to cast").
            if _state.session.iAmDead or mq.TLO.Me.Hovering() then
                Combat.combatReset(0, fromWhere .. '_died')
                break
            end

            -- Manual target mode: if player switches in-game target to a different
            -- NPC mid-fight, break out so checkForCombat picks up the new target.
            if _state.combat.manualTargetMode then
                local liveID   = mq.TLO.Target.ID() or 0
                local liveType = (mq.TLO.Target.Type() or ''):lower()
                if liveID ~= 0 and liveID ~= myID
                   and liveType ~= 'corpse' and liveType ~= 'pc' then
                    _state.combat.myTargetID = liveID
                    break
                end
            end

            -- Mez/AE-mez runs before the casting gate so bards (always "casting"
            -- via MQ2Medley) are not permanently blocked from mezzing.
            if _mez then _mez.check('Combat') end
            if _mez then _mez.aeCheck() end

            -- Pause all commands while player or script is casting.
            -- Bards: Casting.ID stays non-zero while songs play — skip gate for bards.
            if not _state.session.iAmABard
                    and ((mq.TLO.Me.Casting.ID() or 0) ~= 0
                         or mq.TLO.Window('CastingWindow').Open()) then
                mq.delay(50)
                goto continue_fight
            end

            -- Face mob every tick when enabled (mac:1094); skip when MQ2Melee handles facing
            do
                local faceMob = _state.movement.faceMobOn or 0
                if faceMob > 0 and myID ~= 0 and not _state.combat.useMQ2Melee then
                    local meState = mq.TLO.Me.State() or ''
                    if meState == 'STAND' or (mq.TLO.Me.Mount.ID() or 0) ~= 0 then
                        local faceMode = (faceMob == 2) and 'nolook' or 'fast nolook'
                        local fsp = mq.TLO.Spawn('id ' .. myID)
                        local mobY = fsp and fsp.Y() or 0
                        local mobX = fsp and fsp.X() or 0
                        mq.cmdf('/squelch /face %s loc %f,%f', faceMode, mobY, mobX)
                    end
                end
            end

            -- Burn if flagged (mac:1139-1141)
            if _state.combat.burnOn and _state.combat.burnID ~= 0 then
                if _cast.doBurn then _cast.doBurn() end
                _state.combat.burnID = 0
            end

            -- Merc re-assist during the fight, not just on engage (mac:1605). Ranged
            -- assists that skip the melee-engage merc call still get checked here.
            if _merc then _merc.check() end

            -- AE rotation: threshold-triggered AE/multi-target spells (mac:12473-12560)
            aeCheck()

            -- GoM: cast free spell on Gift of Mana proc (mac:11497-11580)
            checkGoM()

            -- Offtank auto-promote: MA is gone, assume MA role (mac:1143)
            if _state.session.role == 'offtank'
               and (getMASpawn().ID() or 0) == 0 then
                mq.cmd('/switchma ' .. (mq.TLO.Me.CleanName() or '') .. ' tank')
            end
            -- Re-stick if mob moved beyond MaxRangeTo and stick dropped (mac:1150); MQ2Melee repositions itself
            if not _state.combat.useMQ2Melee and _movement and _state.combat.meleeOn then
                local _mob = mq.TLO.Spawn('id ' .. myID)
                if _mob and (_mob.Distance() or 0) > (_mob.MaxRangeTo() or 999)
                   and not mq.TLO.Stick.Active() then
                    _movement.checkStick(0, 1)
                end
            end
            if _bard then _bard.doBardStuff() end
            -- AggroCheck (mac:1165)
            if _state.combat.aggroOn and _cast and _cast.castWhat then
                Combat.aggroCheck()
            end

            -- CheckCures / CheckHealth (mac:1166-1167)
            if _heal then
                _heal.checkCures()
                _heal.checkHealth('Combat')
            end

            -- NamedWatch: trigger burn on named mob in range (mac:1177, mac:12884)
            if not _state.combat.namedCheck then namedWatch(false) end

            -- GroupEscape: evac if MA dies mid-combat (mac:1589 CheckBeforeCast)
            groupEscape()

            -- Non-chainpull DPS path (mac:1178-1200): only a plain puller that is chain-pulling skips it
            if not (role == 'puller' and _state.pull.chainPull ~= 0) then
                -- Dead/paused: exit combat (mac:1185-1187)
                if isDeadOrGone(myID) or _state.dps.paused then
                    Combat.combatReset(0, fromWhere .. '_inner')
                    break
                end

                if _state.combat.dpsOn then
                    -- Make visible if pure caster with no aggro timer (mac:1190)
                    if not _state.combat.meleeOn
                       and (_state.timers.aggroOff or 0) == 0
                       and mq.TLO.Me.Invis() then
                        mq.cmd('/makemevisible')
                    end
                    -- DoDebuffStuff: apply debuff-all DPS slots to target + nearby haters (mac:1179)
                    if (_state.debuff.on or 0) > 0 and _debuff then
                        _debuff.check(_state.combat.myTargetID)
                        myID = _state.combat.myTargetID
                        if myID == 0 then
                            Combat.combatReset(0, fromWhere .. '_afterDebuff')
                            break
                        end
                    end
                    -- CombatCast (mac:1191) — cast module provides this in Step M4.6+
                    if _cast.combatCast then
                        local ccResult = _cast.combatCast()
                        myID = _state.combat.myTargetID
                        if myID == 0 then
                            Combat.combatReset(0, fromWhere .. '_afterCast')
                            break
                        end
                        -- tcnc = this cast no combat: restart loop iteration (mac:1196)
                        if ccResult == 'tcnc' then goto continue_fight end
                    end
                else
                    -- MashButtons (deferred)
                end
            end

            -- WriteDebuffs + second cure/heal check (mac:1200-1215)
            if _heal then
                _heal.writeDebuffs()
                _heal.checkCures()
                _heal.checkHealth('Combat2')
            end

            -- Sync target state (mac:1216)
            Combat.combatTargetCheck(1)
            myID = _state.combat.myTargetID

            -- Re-engage if target alive and in range (mac:1217-1253)
            sp = mq.TLO.Spawn('id ' .. (myID ~= 0 and myID or 0))
            if myID ~= 0 and (sp and sp.Type() or ''):lower() ~= 'corpse'
               and not _state.dps.paused then
                -- Melee re-attack or autofire re-engage (mac:1218-1248)
                if _state.combat.autoFireOn ~= 1 then
                    if _state.combat.attacking and _state.combat.meleeOn then
                        -- Uses the live Target like the mac: after mezzing an add (still at
                        -- 100%) this stays false, so we don't swing at the mob we just mezzed.
                        local tgtPct  = mq.TLO.Target.PctHPs() or 100
                        local tgtDist = mq.TLO.Target.Distance() or 999
                        if tgtPct <= _state.combat.assistAt and tgtDist < combatRadius then
                            -- Re-target if we drifted (mac:1222-1224)
                            if not _state.combat.targetSwitchingOn
                               and not _state.combat.manualTargetMode
                               and (mq.TLO.Target.ID() or 0) ~= myID then
                                targetAndWait(myID, 500)
                            end
                            -- Re-engage, or keep the stick (mac:1225-1230)
                            if _movement then
                                if not mq.TLO.Me.Combat() then
                                    if mq.TLO.Me.Sitting() then mq.cmd('/stand') end
                                    _movement.checkStick(0, 1)
                                elseif not _state.combat.useMQ2Melee and not mq.TLO.Stick.Active() then
                                    _movement.checkStick(1, 0)
                                end
                            end
                        elseif not mq.TLO.Me.Combat() and _state.session.iAmMA
                               and not _state.combat.useMQ2Melee
                               and (mq.TLO.Target.ID() or 0) ~= 0 then
                            -- MA only: keep attack on while standing (mac:1231-1237)
                            local meState = (mq.TLO.Me.State() or ''):upper()
                            if meState == 'STAND' or meState == 'MOUNT' then
                                mq.cmd('/squelch /attack on')
                            end
                        end
                    end
                elseif _state.combat.autoFireOn == 1 then
                    -- AutoFireOn==1: re-enable autofire if toggled off (mac:1241-1248)
                    if _state.combat.combatStart and not mq.TLO.Me.AutoFire() then
                        local tgtMezzed = (mq.TLO.Target.Mezzed.ID() or 0)
                        if (mq.TLO.Target.ID() or 0) == myID and tgtMezzed == 0 then
                            if mq.TLO.Me.Sitting() then mq.cmd('/stand') end
                            mq.cmd('/autofire')
                        end
                    end
                end
                -- Pet engagement each iteration (mac:1249-1253)
                if _state.pet.combatOn and (mq.TLO.Me.Pet.ID() or 0) ~= 0 then
                    sp = mq.TLO.Spawn('id ' .. myID)
                    if (sp and sp.PctHPs() or 100) <= _state.pet.assistAt
                       and not mq.TLO.Pet.Combat() then
                        combatPet()
                    end
                end
                -- ChainPull puller path (deferred M5)

            else
                -- Target dead or gone (mac:1278-1309)
                if _state.dps.paused or not _state.combat.targetSwitchingOn then
                    Combat.combatReset(0, fromWhere .. '_targetGone')
                    break
                end
                -- TargetSwitching: MA acquires next target (mac:1283-1308)
                if _state.session.iAmMA then
                    local curTgt = mq.TLO.Target.ID() or 0
                    if curTgt ~= 0 and curTgt ~= myID then
                        _state.combat.lastTargetID = myID
                        _state.combat.myTargetID   = 0
                        Combat.combatTargetCheck(1)
                        myID = _state.combat.myTargetID
                        if myID == 0 then
                            _state.combat.myTargetID = _state.combat.lastTargetID
                            Combat.combatReset(0, fromWhere .. '_noNextTarget')
                            break
                        end
                        goto continue_fight
                    else
                        Combat.combatReset(0, fromWhere .. '_maNoTarget')
                        break
                    end
                else
                    Combat.combatReset(0, fromWhere .. '_noTarget')
                    break
                end
            end

            -- FeignAggroCheck: exit loop if still feigning after this iteration (mac:1310-1314)
            if mq.TLO.Me.Feigning() or mq.TLO.Me.Invis() then
                Combat.feignAggroCheck()
                mq.delay(250)
                if mq.TLO.Me.Feigning() or mq.TLO.Me.Invis() then break end
            end

            ::continue_fight::
        end

    -- ─── Out-of-HP-range block: mob in camp but above assistAt% (mac:1316-1331) ──
    elseif inRange then
        -- Burn check
        if _state.combat.burnOn and _state.combat.burnID ~= 0 then
            if _cast.doBurn then _cast.doBurn(_state.combat.burnID) end
            _state.combat.burnID = 0
        end
        -- Sync target
        if _state.combat.dpsOn or _state.combat.meleeOn or _state.pet.activeState then
            Combat.combatTargetCheck(1)
            myID = _state.combat.myTargetID
        end
        -- Pet / mez (mac:1322-1329)
        if _state.pet.activeState ~= 0 and _state.pet.combatOn and myID ~= 0 then
            if _mez then _mez.check('Combat') end
            sp = mq.TLO.Spawn('id ' .. myID)
            if (sp and sp.PctHPs() or 100) <= _state.pet.assistAt
               and not mq.TLO.Pet.Combat() then
                combatPet()
            end
        end
        -- Deferred: Bard twist (mac:1327, M8)
        -- DebuffAllOn==2: debuff adds even when not at melee range (mac:1328)
        if (_state.debuff.on or 0) == 2 and _state.combat.myTargetID ~= 0
           and (_state.combat.aggroTargetID or '') ~= '' and _debuff then
            _debuff.check(_state.combat.myTargetID)
        end
        -- BeforeAttack condCheck=2: fire only |cond entries (mac:1330)
        if not mq.TLO.Me.Combat() and _state.arrays.beforeArray[1] ~= 'null' then
            beforeAttack(myID, 2)
        end
    end

    -- Mana item cast after rotation (mac:1213 CastMana combat)
    if _buffs and _state.buffs.buffsOn then _buffs.castMana() end

    _utils.debug('combat', 'fight: done from=%s', tostring(fromWhere))
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
