local mq = require('mq')

local Events = {}

-- Unique names for all registered events, for cleanup
local REGISTERED = {}
local _nameCount  = {}

-- MQ2Lua requires unique event names. For events with multiple patterns we
-- append _2, _3 … so each registration gets its own unique name.
local function register(name, pattern, fn)
    local count = (_nameCount[name] or 0) + 1
    _nameCount[name] = count
    local uniqueName = count == 1 and name or (name .. '_' .. count)
    mq.event(uniqueName, pattern, fn)
    REGISTERED[uniqueName] = true
end

-- Cast event handlers set State.cast.castReturn so the cast engine (cast.lua, M3)
-- can react. Patterns mirror kissassist.mac lines 48-101.

local state, utils, movement, charm, _comms

-- CAST_BEGIN: optimistic — assume success until a failure event fires
local function onCastBegin(_, _)
    utils.debug('cast', 'CAST_BEGIN')
    state.cast.castReturn = 'CAST_SUCCESS'
end

-- Most failure events: just stamp the return code
local function onFizzle()
    utils.debug('cast', 'CAST_FIZZLE')
    state.cast.castReturn = 'CAST_FIZZLE'
end

local function onInterrupted()
    utils.debug('cast', 'CAST_INTERRUPTED')
    state.cast.castReturn = 'CAST_INTERRUPTED'
end

-- CAST_RESISTED: only act when cast.lua has armed checkResisted;
-- CAST_IMMUNE takes priority (never downgrade from IMMUNE to RESISTED).
local function onResisted(_, name)
    utils.debug('cast', 'CAST_RESISTED: ' .. tostring(name))
    if not state.cast.checkResisted then return end
    printf('\aw%s was Resisted \ag', tostring(name))
    if state.cast.castReturn ~= 'CAST_IMMUNE' then
        state.cast.castReturn = 'CAST_RESISTED'
    end
    state.cast.lastResisted = tostring(name)
end

-- CAST_RESISTEDYOU: no action needed (player resisted something cast on them)
local function onResistedYou(_, _)
    utils.debug('cast', 'CAST_RESISTEDYOU')
end

local function onTakehold(_, line)
    utils.debug('cast', 'CAST_TAKEHOLD: ' .. tostring(line))
    local check = state.cast.castCheck
    if check and check ~= '' then
        if string.find(line, 'Blocked by', 1, true) then
            if string.find(line, check, 1, true) then
                state.cast.castReturn = 'CAST_TAKEHOLD'
            end
        else
            state.cast.castReturn = 'CAST_TAKEHOLD'
        end
    else
        state.cast.castReturn = 'CAST_TAKEHOLD'
    end
end

local function onImmune(_, _)
    utils.debug('cast', 'CAST_IMMUNE')
    state.cast.castReturn = 'CAST_IMMUNE'
end

local function onDistracted()
    utils.debug('cast', 'CAST_DISTRACTED')
    state.cast.castReturn = 'CAST_DISTRACTED'
end

local function onStunned()
    utils.debug('cast', 'CAST_STUNNED')
    -- Do not delay here; cast engine polls castReturn and handles stun wait
    state.cast.castReturn = 'CAST_STUNNED'
end

local function onNoTarget()
    utils.debug('cast', 'CAST_NOTARGET')
    state.cast.castReturn = 'CAST_NOTARGET'
end

local function onOutOfRange()
    utils.debug('cast', 'CAST_OUTOFRANGE')
    state.cast.castReturn = 'CAST_OUTOFRANGE'
end

local function onOutOfMana()
    utils.debug('cast', 'CAST_OUTOFMANA')
    state.cast.castReturn = 'CAST_OUTOFMANA'
end

local function onNotReady()
    utils.debug('cast', 'CAST_NOTREADY')
    state.cast.castReturn = 'CAST_NOTREADY'
end

local function onRecover()
    utils.debug('cast', 'CAST_RECOVER')
    state.cast.castReturn = 'CAST_RECOVER'
end

local function onNoMount()
    utils.debug('cast', 'CAST_NOMOUNT')
    state.cast.castReturn = 'CAST_NOMOUNT'
end

-- CAST_OUTDOORS maps to CAST_OUTOFMANA intentionally (matches .mac behavior)
local function onOutdoors()
    utils.debug('cast', 'CAST_OUTDOORS')
    state.cast.castReturn = 'CAST_OUTOFMANA'
end

local function onComponents()
    utils.debug('cast', 'CAST_COMPONENTS')
    state.cast.castReturn = 'CAST_COMPONENTS'
end

local function onStanding()
    utils.debug('cast', 'CAST_STANDING')
    if not state.heal.medding then mq.cmd('/stand') end
    state.cast.castReturn = 'CAST_RESTART'
end

local function onCollapse()
    utils.debug('cast', 'CAST_COLLAPSE')
    state.cast.castReturn = 'CAST_COLLAPSE'
end

local function onCannotSee()
    utils.debug('cast', 'CAST_CANNOTSEE')
    state.cast.castReturn = 'CAST_CANNOTSEE'
end

local function onFailed(_, _)
    utils.debug('cast', 'CAST_FAILED')
    state.cast.castReturn = 'CAST_FAILED'
end

-- CAST_FDFAIL: only applies when this character FD'd mid-cast
local function onFdFail(_, name)
    utils.debug('cast', 'CAST_FDFAIL: ' .. tostring(name))
    if tostring(name) == mq.TLO.Me.Name() then
        if mq.TLO.Me.Sitting() then mq.cmd('/stand') end
        state.cast.castReturn = 'CAST_RESTART'
    end
end

-- ─── 2.2: Combat, movement, and session events ───────────────────────────────

local DMZ_ZONES = {[345]=true,[344]=true,[202]=true,[203]=true,[279]=true,[151]=true,[33506]=true}

local function onGotHit(_, mob)
    utils.debug('combat', 'GotHit: ' .. tostring(mob))
    state.combat.eventFlag    = true
    state.timers.sitToMed     = os.clock() + 6  -- delay sit-to-med on hit; M7 uses configured value
    state.combat.gotHitToggle = true
    -- Full pettank/pullertank movement response in M7 (movement.lua)
end

local function onAttackCalled(_, caller, mobID)
    utils.debug('combat', 'AttackCalled: ' .. tostring(caller) .. ' ID:' .. tostring(mobID))
    state.combat.eventFlag = true
    if not mobID or mobID == '' then
        state.combat.calledTargetID = 0
        return
    end
    if state.session.iAmMA then return end
    if caller == state.session.mainAssist then
        state.combat.calledTargetID = tonumber(mobID) or 0
    end
end

local function onCantHit()
    utils.debug('combat', 'CantHit')
    state.movement.cantHit = true
    mq.cmd('/squelch /attack off')
    if (mq.TLO.Target.ID() or 0) ~= 0 then
        mq.cmdf('/face fast id %d', mq.TLO.Target.ID())
    end
end

local function onCantSee()
    utils.debug('move', 'CantSee')
    state.movement.cantSee = true
end

local function onTooClose()
    utils.debug('move', 'TooClose')
    state.movement.toClose = true
    -- AutoFireOn: mob too close, pause ranged autofire (mac:11178-11180)
    if state.combat.autoFireOn == 1 and state.combat.combatStart
       and (state.combat.myTargetID or 0) ~= 0 then
        if mq.TLO.Me.AutoFire() then mq.cmd('/autofire') end
        state.combat.autoFireOn = 2
    end
    if state.pull.pulling and state.pull.withAlt == 'Melee' then
        -- pull module handles TooClose during pulls
        return
    end
    if (mq.TLO.Target.ID() or 0) ~= 0 then
        mq.cmdf('/face fast id %d', mq.TLO.Target.ID())
    end
    mq.cmd('/keypress back hold')
    mq.delay(100)
    mq.cmd('/keypress back')
end

local function onTooFar()
    utils.debug('move', 'TooFar')
    state.pull.tooFar         = true
    state.movement.dontMoveMe = false
    if movement and not state.combat.combatStart then
        movement.doWeMove(1, 'tooFar')
    end
end

local function onMezBroke(_, mob, _breaker)
    utils.debug('mez', 'MezBroke: %s by %s', tostring(mob), tostring(_breaker))
    state.combat.eventFlag = true
    state.mez.broke        = true
    if state.mez.on == 0 then return end
    -- Clear the per-slot timer so the awoken mob can be immediately re-mezzed (mac:8166,8180)
    local arr = state.arrays and state.arrays.mezArray
    if arr then
        local myID = tostring(state.combat.myTargetID or 0)
        for i = 1, 50 do
            local entry = arr[i]
            if entry and entry[3] ~= 'NULL' and entry[3] == mob
               and entry[1] ~= 'NULL' and entry[1] ~= myID then
                state.timers['mezTimer' .. i] = 0
                utils.debug('mez', 'MezBroke: cleared slot %d timer for %s', i, mob)
            end
        end
    end
end

local function onMissing()
    utils.debug('combat', 'Missing component')
    state.combat.eventFlag        = true
    state.combat.missingComponent = true
end

local function onImDead()
    utils.debug('combat', 'ImDead')
    if state.session.iAmDead then return end
    printf('\awI have died and the Angels wept.')
    state.combat.eventFlag = true
    state.session.iAmDead  = true
    -- Bard twist stop in M8 (bard.lua); CombatReset in M4 (combat.lua)
end

local function onZoned(_, message)
    utils.debug('combat', 'Zoned: ' .. tostring(message))
    if message and (message:find('Drunken Monkey', 1, true) or message:find('effects', 1, true)) then
        return
    end
    state.combat.eventFlag  = true
    state.timers.justZoned  = os.clock() + 10  -- 200 ticks * 50ms
    local zoneID            = mq.TLO.Zone.ID()
    state.misc.dmz          = DMZ_ZONES[zoneID] == true
    local short             = mq.TLO.Zone.ShortName() or ''
    local suffix            = mq.TLO.Me.InInstance() and '_I' or ''
    local name              = mq.TLO.Zone.Name() or short
    if name:find(',', 1, true) or name:find("'", 1, true) then
        state.session.zoneName = short .. suffix
    else
        state.session.zoneName = short .. suffix
    end
    if state.movement.campZone ~= zoneID then
        if state.movement.returnToCamp then
            -- Active camp in another zone — pause RTC and remember to restore
            state.movement.returnToCamp = false
            state.movement.rememberCamp = true
        else
            -- No active camp — track the character to the new zone
            state.movement.campZone     = zoneID
            state.movement.campZoneName = mq.TLO.Zone.ShortName() or ''
        end
    else
        if state.movement.rememberCamp then
            local dx   = mq.TLO.Me.X() - state.movement.campX
            local dy   = mq.TLO.Me.Y() - state.movement.campY
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist <= 150 then
                state.movement.returnToCamp = true
                state.movement.rememberCamp = false
            end
        end
        if state.session.iAmDead then state.session.iAmDead = false end
    end
    state.misc.lastZone = zoneID
    if charm then charm.resetFight() end
    -- #133: stale buff state from the previous zone is irrelevant after a zone change
    state.buffs.memberBuffs       = {}
    state.buffs.memberBuffsExpiry = {}
    -- #132: broadcast our own buff state once buffs repopulate after zone-in
    state.buffs.pendingZoneBroadcast = true
    -- CombatReset, WinTitle, LoadSpawnMaster in M4/M7
end

local function onJoined(_, joinee)
    utils.debug('buffs', 'Joined: ' .. tostring(joinee))
    state.combat.eventFlag   = true
    state.timers.joinedParty = os.clock() + 2  -- 200 ticks * 50ms ≈ 2s heal suppression window
    state.buffs.forceBuffs   = true
    -- #138: announce our buff state to new group so they don't wait for the 30s heartbeat
    state.buffs.pendingZoneBroadcast = true
    -- Per-member buff state reset in M6 (buffs.lua)
end

local function onLeftGroup(_, leaver)
    utils.debug('buffs', 'LeftGroup: ' .. tostring(leaver))
    state.combat.eventFlag = true
    -- #133: remove departed member's buff state so orphaned entries don't linger
    if leaver and leaver ~= '' then
        local sid = mq.TLO.Spawn('PC ' .. leaver).ID()
        if sid and sid ~= 0 then
            state.buffs.memberBuffs[sid]       = nil
            state.buffs.memberBuffsExpiry[sid] = nil
        end
    end
end

local function onInvised()
    utils.debug('combat', 'Invised')
    state.combat.eventFlag = true
    -- Bard twist stop in M8 (bard.lua)
end

local function onCamping()
    utils.debug('combat', 'Camping — shutting down')
    state.combat.eventFlag = true
    -- Bard twist stop in M8 (bard.lua)
    state.terminate = true
end

local function onTooSteep()
    utils.debug('move', 'TooSteep')
    state.combat.eventFlag = true
    state.misc.campfireOn  = false
    printf('\ayTooSteep: CampfireOn disabled.')
end

-- ─── 2.3: Buff, pet, comms, and utility events ───────────────────────────────

local function onGoMOn()
    utils.debug('bard', 'GoMOn')
    state.combat.eventFlag = true
    local cls = mq.TLO.Me.Class.ShortName()
    if cls=='BRD' or cls=='BER' or cls=='MNK' or cls=='ROG' or cls=='WAR' or state.bard.gomByPass then
        state.bard.gomByPass = false
        return
    end
    if not state.combat.combatStart or state.timers.gomTimer > os.clock() then return end
    state.bard.gomActive = true
end

local function onGoMOff()
    utils.debug('bard', 'GoMOff')
    state.combat.eventFlag = true
    state.bard.gomActive   = false
end

local function onWornOff(_, spell, target)
    utils.debug('buffs', 'WornOff: ' .. tostring(spell) .. ' on ' .. tostring(target))
    state.combat.eventFlag = true
    if not spell or not target then return end
    if target == mq.TLO.Me.Name() then return end
    if state.combat.aggroTargetID ~= '' then return end
    if state.session.iAmABard then return end
    if spell:find('promised') then return end
    state.buffs.forceBuffs = true
    state.timers.readBuffs  = 0
    if _comms then _comms.broadcastBuffState() end
end

local function onGainSomething(_, text)
    utils.debug('general', 'GainSomething: ' .. tostring(text))
    state.combat.eventFlag = true
    -- Broadcast + pull range recalc for level-up in M6/M9
end

local function onAskForBuffs(_, caller)
    utils.debug('buffs', 'AskForBuffs: ' .. tostring(caller))
    state.combat.eventFlag = true
    if not caller or caller == '' then return end
    local spawnID = mq.TLO.Spawn(caller).ID()
    if not spawnID or spawnID == 0 or spawnID == mq.TLO.Me.ID() then return end
    if mq.TLO.Group.Member(caller).Index() then return end
    if mq.TLO.Spawn('id ' .. spawnID).Type() ~= 'PC' then return end
    state.buffs.kaBegActive = true
    -- Raid/fellowship/guild/friends validation + buff queuing in M6 (buffs.lua)
end

local function onKABegCheck(_, who, what, _)
    utils.debug('buffs', 'KABegCheck: ' .. tostring(who) .. ' ' .. tostring(what))
    state.combat.eventFlag = true
    if not who or who == mq.TLO.Me.CleanName() then return end
    if not what or (what ~= 'BEGFORITEMS' and what ~= 'BEGFORBUFFS') then return end
    if not state.buffs.buffsOn then return end
    if #state.buffs.kaBegForList > 2000 then return end  -- guard against unbounded list growth

    local spawnID = mq.TLO.Spawn('PC ' .. who).ID()
    if not spawnID or spawnID == 0 or spawnID == mq.TLO.Me.ID() then return end
    if mq.TLO.Spawn('id ' .. spawnID).Type() ~= 'PC' then return end

    -- Social check: must be in raid/fellowship/guild/friends (mac:11625-11632)
    local inRaid       = mq.TLO.Raid.Member(who)() ~= nil
    local inFellowship = (mq.TLO.Me.Fellowship.Member(who).Level() or 0) > 0
    local sameGuild    = mq.TLO.Me.Guild() ~= nil and mq.TLO.Me.Guild() == (mq.TLO.Spawn(who).Guild() or '')
    local isFriend     = false
    pcall(function() isFriend = (mq.TLO.Friends.Friend(who)() ~= nil) end) ---@diagnostic disable-line: undefined-field
    if not (inRaid or inFellowship or sameGuild or isFriend) then return end

    -- Find a buff slot matching |alias|BCWhat; build beg entry if we can cast it (mac:11633-11647)
    local buffsArray = state.buffs.buffsArray
    for bcx = 1, #buffsArray do
        local slot = buffsArray[bcx]
        if slot and slot.name then
            local entry = slot.name
            if entry:find('|alias|' .. what, 1, true) then
                local buffToCast = entry:match('^([^|]*)') or entry
                if buffToCast == '' then goto bcxcontinue end
                if not mq.TLO.Me.Book(buffToCast)() and (mq.TLO.Me.AltAbility(buffToCast).ID() or 0) == 0 then
                    goto bcxcontinue
                end

                -- memberBuffs check: skip adding if requester already has the buff (replaces INI read)
                local received = state.buffs.memberBuffs[spawnID]
                local bsExpiry = state.buffs.memberBuffsExpiry[spawnID] or 0
                if received and bsExpiry > os.clock() then
                    if (received[buffToCast] or 0) > os.clock() then
                        goto bcxcontinue
                    end
                end

                local listEntry = what .. ':' .. who .. ':' .. tostring(bcx)
                state.buffs.kaBegActive = true
                if state.buffs.kaBegForList == '' then
                    state.buffs.kaBegForList = listEntry
                else
                    state.buffs.kaBegForList = state.buffs.kaBegForList .. '|' .. listEntry
                end
                break
            end
        end
        ::bcxcontinue::
    end
end

local function onPetSusStateAdd1()
    utils.debug('pet', 'PetSusStateAdd1')
    state.combat.eventFlag = true
    state.pet.activeState  = false
    state.pet.suspendState = true
    state.pet.totCount     = 1
end

local function onPetSusStateAdd2()
    utils.debug('pet', 'PetSusStateAdd2')
    state.combat.eventFlag = true
    state.pet.activeState  = true
    state.pet.suspendState = true
    state.pet.totCount     = 2
end

local function onPetSusStateSub()
    utils.debug('pet', 'PetSusStateSub')
    state.combat.eventFlag = true
    state.pet.activeState  = true
    state.pet.suspendState = false
    state.pet.totCount     = 1
end

local function onPetToysPlease(_, petName)
    utils.debug('pet', 'PetToysPlease: ' .. tostring(petName))
    state.combat.eventFlag = true
    if not petName or petName == '' or petName:find('null') then return end
    local isGroup = petName:upper() == 'GROUP'
    if not isGroup and (not mq.TLO.Spawn('pet ' .. petName).ID() or mq.TLO.Spawn('pet ' .. petName).ID() == 0) then return end
    state.buffs.kaPetBegActive = true
    if state.buffs.kaBegForPetList == '' then
        state.buffs.kaBegForPetList = petName
    else
        state.buffs.kaBegForPetList = state.buffs.kaBegForPetList .. '|' .. petName
    end
    -- Actual toy-giving loop in M6 (buffs.lua)
end

local function onYouGotTell(_, fwho, swhat)
    utils.debug('general', 'YouGotTell: ' .. tostring(fwho))
    state.combat.eventFlag = true
    if not fwho then return end
    local myName = mq.TLO.Me.CleanName()
    local petID  = mq.TLO.Me.Pet.ID()
    if petID and petID > 0 and mq.TLO.Spawn(fwho).ID() == petID then return end
    if fwho:find(myName, 1, true) and fwho:find('s pet', 1, true) then return end
    if (not petID or petID == 0) and swhat
            and swhat:find(', master.', 1, true)
            and swhat:find('I am unable to wake an', 1, true) then return end
    local stype = mq.TLO.Spawn(fwho).Type()
    if stype == 'NPC' or stype == 'PET' then return end
    printf('====> %s Sent you a Tell: %s <====', fwho, tostring(swhat))
end

-- EQBC cross-char relay stubs (EQBC deprecated in Lua port; DanNet handled in M9)
local function onEQBCIRC()
    utils.debug('comms', 'EQBCIRC (stub — EQBC deprecated)')
    state.combat.eventFlag = true
end

local function onGUEQBC()
    utils.debug('comms', 'GUEQBC (stub — EQBC deprecated)')
    state.combat.eventFlag = true
end

local function onFSEQBC()
    utils.debug('comms', 'FSEQBC (stub — EQBC deprecated)')
    state.combat.eventFlag = true
end

local function onKTDismount()
    utils.debug('general', 'KTDismount')
    state.combat.eventFlag = true
    state.misc.mountOn = false
    if mq.TLO.Me.Mount.ID() then mq.cmd('/dismount') end
end

-- KT task helpers — blocking multi-step interactions; full impl in M7 (movement.lua)
local function onKTTarget(_, npcName)
    utils.debug('general', 'KTTarget: ' .. tostring(npcName))
    state.combat.eventFlag = true
end

local function onKTHail(_, mobID)
    utils.debug('general', 'KTHail: ' .. tostring(mobID))
    state.combat.eventFlag = true
end

local function onKTSay(_, sayWhat, mobID)
    utils.debug('general', 'KTSay: ' .. tostring(sayWhat) .. ' -> ' .. tostring(mobID))
    state.combat.eventFlag = true
end

local function onKTDoorClick(_, doorID)
    utils.debug('general', 'KTDoorClick: ' .. tostring(doorID))
    state.combat.eventFlag = true
end

local function onKTInvite()
    utils.debug('general', 'KTInvite')
    state.combat.eventFlag = true
end

local function onTaskUpdate(_, name)
    utils.debug('general', 'TaskUpdate: ' .. tostring(name))
    state.combat.eventFlag = true
    -- Broadcast in M9 (comms.lua)
end

local function onMLogOff()
    utils.debug('general', 'MLogOff')
    state.combat.eventFlag = true
    if state.debug.logging then
        mq.cmd('/mlog off')
        state.debug.logging = false
    end
end

-- Event definition table — kept at module level so Events.register() stays under
-- Lua's 60-upvalue-per-function limit. Each entry: { name, pattern, handler }.
local EVENT_DEFS = {
    -- 2.1: Cast results
    { 'CAST_BEGIN',        'You begin casting #1#',                                                           onCastBegin   },
    { 'CAST_BEGIN',        'You begin singing #1#',                                                            onCastBegin   },
    { 'CAST_BEGIN',        'Your #1# begins to glow.',                                                        onCastBegin   },
    { 'CAST_FIZZLE',       'Your spell fizzles#*#',                                                           onFizzle      },
    { 'CAST_FIZZLE',       'Your #*#spell fizzles#*#',                                                        onFizzle      },
    { 'CAST_FIZZLE',       'You miss a note, bringing your song to a close#*#',                               onFizzle      },
    { 'CAST_INTERRUPTED',  'Your spell is interrupted#*#',                                                    onInterrupted },
    { 'CAST_INTERRUPTED',  'Your casting has been interrupted#*#',                                            onInterrupted },
    { 'CAST_INTERRUPTED',  'Your #*# spell is interrupted.',                                                  onInterrupted },
    { 'CAST_RESISTED',     'Your target resisted the #1# spell#*#',                                           onResisted    },
    { 'CAST_RESISTED',     '#*# resisted your #1#!',                                                          onResisted    },
    { 'CAST_RESISTEDYOU',  'You resist the #1# spell#*#',                                                     onResistedYou },
    { 'CAST_RESISTEDYOU',  'You resist #*#',                                                                  onResistedYou },
    { 'CAST_TAKEHOLD',     'Your spell did not take hold#*#',                                                 onTakehold    },
    { 'CAST_TAKEHOLD',     'Your #*# spell did not take hold. (Blocked by#*#',                                onTakehold    },
    { 'CAST_TAKEHOLD',     'Your spell would not have taken hold#*#',                                         onTakehold    },
    { 'CAST_TAKEHOLD',     'Your spell is too powerfull for your intended target#*#',                         onTakehold    },
    { 'CAST_TAKEHOLD',     'This pet may not be made invisible#*#',                                           onTakehold    },
    { 'CAST_IMMUNE',       'Your target has no mana to affect#*#',                                            onImmune      },
    { 'CAST_IMMUNE',       'Your target is immune to changes in its attack speed#*#',                         onImmune      },
    { 'CAST_IMMUNE',       'Your target is immune to changes in its run speed#*#',                            onImmune      },
    { 'CAST_IMMUNE',       'Your target is immune to snare spells#*#',                                        onImmune      },
    { 'CAST_IMMUNE',       'Your target is immune to the stun portion of this effect#*#',                     onImmune      },
    { 'CAST_IMMUNE',       'Your target cannot be mesmerized#*#',                                             onImmune      },
    { 'CAST_IMMUNE',       'Your target looks unaffected#*#',                                                 onImmune      },
    { 'CAST_DISTRACTED',   'You need to play a#*#instrument for this song#*#',                                onDistracted  },
    { 'CAST_DISTRACTED',   'You are too distracted to cast a spell now#*#',                                   onDistracted  },
    { 'CAST_DISTRACTED',   "You can't cast spells while invulnerable#*#",                                     onDistracted  },
    { 'CAST_DISTRACTED',   'You *CANNOT* cast spells, you have been silenced#*#',                             onDistracted  },
    { 'CAST_STUNNED',      "You can't cast spells while stunned#*#",                                          onStunned     },
    { 'CAST_STUNNED',      'You are stunned#*#',                                                              onStunned     },
    { 'CAST_NOTARGET',     'You must first select a target for this spell#*#',                                onNoTarget    },
    { 'CAST_NOTARGET',     'This spell only works on#*#',                                                     onNoTarget    },
    { 'CAST_NOTARGET',     'You must first target a group member#*#',                                         onNoTarget    },
    { 'CAST_OUTOFRANGE',   'Your target is out of range, get closer#*#',                                      onOutOfRange  },
    { 'CAST_OUTOFMANA',    'Insufficient Mana to cast this spell#*#',                                         onOutOfMana   },
    { 'CAST_NOTREADY',     'Spell recast time not yet met#*#',                                                onNotReady    },
    { 'CAST_RECOVER',      "You haven't recovered yet#*#",                                                    onRecover     },
    { 'CAST_RECOVER',      'Spell recovery time not yet met#*#',                                              onRecover     },
    { 'CAST_NOMOUNT',      'You can only summon a mount on dry land#*#',                                      onNoMount     },
    { 'CAST_NOMOUNT',      'You need to be in a more open area to summon a mount#*#',                         onNoMount     },
    { 'CAST_NOMOUNT',      'You can not summon a mount here#*#',                                              onNoMount     },
    { 'CAST_NOMOUNT',      'You must have both the Horse Models and your current Luclin Character Model enabled to summon a mount#*#', onNoMount },
    { 'CAST_NOMOUNT',      'You can not summon a mount in this form#*#',                                      onNoMount     },
    { 'CAST_OUTDOORS',     'This spell does not work here#*#',                                                onOutdoors    },
    { 'CAST_OUTDOORS',     'You can only cast this spell in the outdoors#*#',                                 onOutdoors    },
    { 'CAST_COMPONENTS',   'You are missing some required components#*#',                                     onComponents  },
    { 'CAST_COMPONENTS',   'Your ability to use this item has been disabled because you do not have at least a gold membership#*#', onComponents },
    { 'CAST_STANDING',     'You must be standing to cast a spell#*#',                                        onStanding    },
    { 'CAST_CANNOTSEE',    'You cannot see your target#*#',                                                   onCannotSee   },
    { 'CAST_COLLAPSE',     'Your gate is too unstable, and collapses#*#',                                     onCollapse    },
    { 'CAST_FAILED',       'Your ability failed.#*#',                                                         onFailed      },
    { 'CAST_FDFAIL',       '#1# has fallen to the ground.#*#',                                                onFdFail      },
    -- 2.2: Combat / movement / session
    { 'GotHit',        '#1# bashes YOU for #*# points of damage.#*#',   onGotHit      },
    { 'GotHit',        '#1# bites YOU for #*# points of damage.#*#',    onGotHit      },
    { 'GotHit',        '#1# crushes YOU for #*# points of damage.#*#',  onGotHit      },
    { 'GotHit',        '#1# gores YOU for #*# points of damage.#*#',    onGotHit      },
    { 'GotHit',        '#1# hits YOU for #*# points of damage.#*#',     onGotHit      },
    { 'GotHit',        '#1# kicks YOU for #*# points of damage.#*#',    onGotHit      },
    { 'GotHit',        '#1# mauls YOU for #*# points of damage.#*#',    onGotHit      },
    { 'GotHit',        '#1# pierces YOU for #*# points of damage.#*#',  onGotHit      },
    { 'GotHit',        '#1# punches YOU for #*# points of damage.#*#',  onGotHit      },
    { 'GotHit',        '#1# rampages YOU for #*# points of damage.#*#', onGotHit      },
    { 'GotHit',        '#1# smashes YOU for #*# points of damage.#*#',  onGotHit      },
    { 'GotHit',        '#1# slashes YOU for #*# points of damage.#*#',  onGotHit      },
    { 'GotHit',        '#1# tries to #*# YOU, but #*#',                 onGotHit      },
    { 'AttackCalled',  '<#1#>#*#TANKING-> #*# <- ID:#2#',               onAttackCalled },
    { 'AttackCalled',  '[ #1# (#*#) ]#*#TANKING-> #*# <- ID:#2#',      onAttackCalled },
    { 'CantHit',       "You can't hit them from here.",                  onCantHit     },
    { 'CantSee',       'You cannot see your target.',                    onCantSee     },
    { 'TooClose',      'Your target is too close to use a ranged weapon!', onTooClose  },
    { 'TooFar',        'Your target is #*#, get closer!',               onTooFar      },
    { 'MezBroke',      '#1# has been awakened by #2#.',                 onMezBroke    },
    { 'Missing',       '#*#You are missing some required components.#*#', onMissing   },
    { 'Missing',       '#*#You are missing#*#',                          onMissing    },
    { 'ImDead',        '#*#Returning to Bind Location#*#',               onImDead     },
    { 'ImDead',        'You died.',                                       onImDead     },
    { 'ImDead',        'You have been slain by#*#',                       onImDead     },
    { 'Zoned',         'LOADING, PLEASE WAIT#*#',                         onZoned      },
    { 'Zoned',         'You have entered#*#',                             onZoned      },
    { 'Joined',        '#1# has joined the group.',                       onJoined     },
    { 'LeftGroup',     '#1# has left the group.',                         onLeftGroup  },
    { 'Invised',       'You Vanish #*#',                                  onInvised    },
    { 'Camping',       '#*#seconds to prepare your camp.',                onCamping    },
    { 'TooSteep',      'The ground here is too steep to camp',            onTooSteep   },
    -- 2.3: Buffs / pet / comms / utility
    { 'GoMOn',           '#*#granted#*#gift of#*#mana#*#',                     onGoMOn          },
    { 'GoMOn',           'You feel strengthened by a gift of magic.',           onGoMOn          },
    { 'GoMOn',           'You feel strengthened by magic.',                     onGoMOn          },
    { 'GoMOff',          'The gift of magic fades.',                            onGoMOff         },
    { 'GoMOff',          'Your#*#gift of#*#mana fades.',                        onGoMOff         },
    { 'WornOff',         'Your #1# spell has worn off of #2#.',                 onWornOff        },
    { 'GainSomething',   '#*#You have gained|#1#|',                             onGainSomething  },
    { 'AskForBuffs',     '#1# tells you,#*#Buffs Please!#*#',                   onAskForBuffs    },
    { 'AskForBuffs',     '#1# says,#*#Buffs Please!#*#',                        onAskForBuffs    },
    { 'KABegCheck',      '#*#KABeg for #1# #2# #3#',                            onKABegCheck     },
    { 'PetSusStateAdd1', "#*# tells you, 'By your command, master.#*#",         onPetSusStateAdd1 },
    { 'PetSusStateAdd2', '#*#You cannot have more than one pet at a time.#*#',  onPetSusStateAdd2 },
    { 'PetSusStateSub',  "#*# tells you, 'I live again...'#*#",                 onPetSusStateSub },
    { 'PetToysPlease',   '#*#PetToysPlease #1#',                                onPetToysPlease  },
    { 'YouGotTell',      '#1# tells you, #2#',                                  onYouGotTell     },
    { 'EQBCIRC',         '<#1#> #2#',                                            onEQBCIRC        },
    { 'FSEQBC',          '#1# tells the fellowship, #2#',                        onFSEQBC         },
    { 'GUEQBC',          '#1# tells the guild, #2#',                             onGUEQBC         },
    { 'KTDismount',      '[MQ2] KTDismount#*#',                                  onKTDismount     },
    { 'KTTarget',        '[MQ2] KTTarget #1#',                                   onKTTarget       },
    { 'KTHail',          '[MQ2] KTHail #1#',                                     onKTHail         },
    { 'KTSay',           '[MQ2] KTSay #1# #2#',                                  onKTSay          },
    { 'KTDoorClick',     '[MQ2] KTDoorClick #1#',                                onKTDoorClick    },
    { 'KTDoorClick',     '[MQ2] KTDoorClick#*#',                                 onKTDoorClick    },
    { 'KTInvite',        '[MQ2] KTInvite #1#',                                   onKTInvite       },
    { 'TaskUpdate',      'Your task |#1#| has been updated#*#',                  onTaskUpdate     },
    { 'MLogOff',         '#*#KissAssist Debug Off Marker!',                      onMLogOff        },
}

function Events.register(s, u, m, c, co)
    state    = s
    utils    = u
    movement = m
    charm    = c
    _comms   = co
    _nameCount = {}
    for _, def in ipairs(EVENT_DEFS) do
        register(def[1], def[2], def[3])
    end
end

function Events.unregister()
    for name in pairs(REGISTERED) do
        mq.unevent(name)
    end
    REGISTERED = {}
end

return Events
