local mq = require('mq')

local Events = {}

-- Unique names for all registered events, for cleanup
local REGISTERED = {}

local function register(name, pattern, fn)
    mq.event(name, pattern, fn)
    REGISTERED[name] = true
end

-- Cast event handlers set State.cast.castReturn so the cast engine (cast.lua, M3)
-- can react. Patterns mirror kissassist.mac lines 48-101.

local state, utils

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
    if state.pull.pulling then
        state.movement.cantHit = true
    end
end

local function onCantSee()
    utils.debug('move', 'CantSee')
    if state.pull.pulling then
        state.movement.cantSee = true
        return
    end
    -- Full LOS movement response in M7 (movement.lua)
end

local function onTooClose()
    utils.debug('move', 'TooClose')
    if state.pull.pulling and state.pull.withAlt == 'Melee' then
        state.movement.toClose = true
    end
    -- Autofire disable in M4 (combat.lua)
end

local function onTooFar()
    utils.debug('move', 'TooFar')
    if state.pull.pulling then
        state.pull.tooFar = true
    end
    -- Stick/moveto response in M7 (movement.lua)
end

local function onMezBroke(_, mob, breaker)
    utils.debug('mez', 'MezBroke: ' .. tostring(mob) .. ' by ' .. tostring(breaker))
    state.combat.eventFlag = true
    state.mez.broke        = true
    -- Mez timer reset and target reassign in M5 (healing.lua)
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
            state.movement.returnToCamp = false
            state.movement.rememberCamp = true
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
    -- CombatReset, WinTitle, LoadSpawnMaster in M4/M7
end

local function onJoined(_, joinee)
    utils.debug('buffs', 'Joined: ' .. tostring(joinee))
    state.combat.eventFlag   = true
    state.timers.joinedParty = os.clock() + 2  -- 200 ticks * 50ms ≈ 2s heal suppression window
    state.buffs.forceBuffs   = true
    -- Per-member buff state reset in M6 (buffs.lua)
end

local function onLeftGroup()
    utils.debug('buffs', 'LeftGroup')
    state.combat.eventFlag = true
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
    -- Full GoM cast loop in M8 (bard.lua)
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
    -- Per-member buff slot reset and ReadBuffsTimer clear in M6 (buffs.lua)
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
    local spawnID = mq.TLO.Spawn('PC ' .. who).ID()
    if not spawnID or spawnID == 0 or spawnID == mq.TLO.Me.ID() then return end
    if mq.TLO.Spawn('id ' .. spawnID).Type() ~= 'PC' then return end
    state.buffs.kaBegActive = true
    -- Buff list building + raid/fellowship/guild/friends check in M6 (buffs.lua)
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

-- Register all cast result events
function Events.register(s, u)
    state = s
    utils = u

    -- CAST_BEGIN (3 patterns)
    register('CAST_BEGIN', 'You begin casting #1#', onCastBegin)
    register('CAST_BEGIN', 'You begin singing #1#', onCastBegin)
    register('CAST_BEGIN', 'Your #1# begins to glow.', onCastBegin)

    -- CAST_FIZZLE (3 patterns)
    register('CAST_FIZZLE', 'Your spell fizzles#*#', onFizzle)
    register('CAST_FIZZLE', 'Your #*#spell fizzles#*#', onFizzle)
    register('CAST_FIZZLE', 'You miss a note, bringing your song to a close#*#', onFizzle)

    -- CAST_INTERRUPTED (3 patterns)
    register('CAST_INTERRUPTED', 'Your spell is interrupted#*#', onInterrupted)
    register('CAST_INTERRUPTED', 'Your casting has been interrupted#*#', onInterrupted)
    register('CAST_INTERRUPTED', 'Your #*# spell is interrupted.', onInterrupted)

    -- CAST_RESISTED (2 patterns)
    register('CAST_RESISTED', 'Your target resisted the #1# spell#*#', onResisted)
    register('CAST_RESISTED', '#*# resisted your #1#!', onResisted)

    -- CAST_RESISTEDYOU (2 patterns)
    register('CAST_RESISTEDYOU', 'You resist the #1# spell#*#', onResistedYou)
    register('CAST_RESISTEDYOU', 'You resist #*#', onResistedYou)

    -- CAST_TAKEHOLD (4 patterns)
    register('CAST_TAKEHOLD', 'Your spell did not take hold#*#', onTakehold)
    register('CAST_TAKEHOLD', 'Your #*# spell did not take hold. (Blocked by#*#', onTakehold)
    register('CAST_TAKEHOLD', 'Your spell would not have taken hold#*#', onTakehold)
    register('CAST_TAKEHOLD', 'Your spell is too powerfull for your intended target#*#', onTakehold)
    register('CAST_TAKEHOLD', 'This pet may not be made invisible#*#', onTakehold)

    -- CAST_IMMUNE (7 patterns)
    register('CAST_IMMUNE', 'Your target has no mana to affect#*#', onImmune)
    register('CAST_IMMUNE', 'Your target is immune to changes in its attack speed#*#', onImmune)
    register('CAST_IMMUNE', 'Your target is immune to changes in its run speed#*#', onImmune)
    register('CAST_IMMUNE', 'Your target is immune to snare spells#*#', onImmune)
    register('CAST_IMMUNE', 'Your target is immune to the stun portion of this effect#*#', onImmune)
    register('CAST_IMMUNE', 'Your target cannot be mesmerized#*#', onImmune)
    register('CAST_IMMUNE', 'Your target looks unaffected#*#', onImmune)

    -- Single-pattern events
    register('CAST_DISTRACTED',  'You need to play a#*#instrument for this song#*#', onDistracted)
    register('CAST_DISTRACTED',  'You are too distracted to cast a spell now#*#', onDistracted)
    register('CAST_DISTRACTED',  "You can't cast spells while invulnerable#*#", onDistracted)
    register('CAST_DISTRACTED',  'You *CANNOT* cast spells, you have been silenced#*#', onDistracted)
    register('CAST_STUNNED',     "You can't cast spells while stunned#*#", onStunned)
    register('CAST_STUNNED',     'You are stunned#*#', onStunned)
    register('CAST_NOTARGET',    'You must first select a target for this spell#*#', onNoTarget)
    register('CAST_NOTARGET',    'This spell only works on#*#', onNoTarget)
    register('CAST_NOTARGET',    'You must first target a group member#*#', onNoTarget)
    register('CAST_OUTOFRANGE',  'Your target is out of range, get closer#*#', onOutOfRange)
    register('CAST_OUTOFMANA',   'Insufficient Mana to cast this spell#*#', onOutOfMana)
    register('CAST_NOTREADY',    'Spell recast time not yet met#*#', onNotReady)
    register('CAST_RECOVER',     "You haven't recovered yet#*#", onRecover)
    register('CAST_RECOVER',     'Spell recovery time not yet met#*#', onRecover)
    register('CAST_NOMOUNT',     'You can only summon a mount on dry land#*#', onNoMount)
    register('CAST_NOMOUNT',     'You need to be in a more open area to summon a mount#*#', onNoMount)
    register('CAST_NOMOUNT',     'You can not summon a mount here#*#', onNoMount)
    register('CAST_NOMOUNT',     'You must have both the Horse Models and your current Luclin Character Model enabled to summon a mount#*#', onNoMount)
    register('CAST_NOMOUNT',     'You can not summon a mount in this form#*#', onNoMount)
    register('CAST_OUTDOORS',    'This spell does not work here#*#', onOutdoors)
    register('CAST_OUTDOORS',    'You can only cast this spell in the outdoors#*#', onOutdoors)
    register('CAST_COMPONENTS',  'You are missing some required components#*#', onComponents)
    register('CAST_COMPONENTS',  'Your ability to use this item has been disabled because you do not have at least a gold membership#*#', onComponents)
    register('CAST_STANDING',    'You must be standing to cast a spell#*#', onStanding)
    register('CAST_CANNOTSEE',   'You cannot see your target#*#', onCannotSee)
    register('CAST_COLLAPSE',    'Your gate is too unstable, and collapses#*#', onCollapse)
    register('CAST_FAILED',      'Your ability failed.#*#', onFailed)
    register('CAST_FDFAIL',      '#1# has fallen to the ground.#*#', onFdFail)

    -- 2.2: GotHit (12 melee attack types + near-miss)
    register('GotHit', '#1# bashes YOU for #*# points of damage.#*#',  onGotHit)
    register('GotHit', '#1# bites YOU for #*# points of damage.#*#',   onGotHit)
    register('GotHit', '#1# crushes YOU for #*# points of damage.#*#', onGotHit)
    register('GotHit', '#1# gores YOU for #*# points of damage.#*#',   onGotHit)
    register('GotHit', '#1# hits YOU for #*# points of damage.#*#',    onGotHit)
    register('GotHit', '#1# kicks YOU for #*# points of damage.#*#',   onGotHit)
    register('GotHit', '#1# mauls YOU for #*# points of damage.#*#',   onGotHit)
    register('GotHit', '#1# pierces YOU for #*# points of damage.#*#', onGotHit)
    register('GotHit', '#1# punches YOU for #*# points of damage.#*#', onGotHit)
    register('GotHit', '#1# rampages YOU for #*# points of damage.#*#',onGotHit)
    register('GotHit', '#1# smashes YOU for #*# points of damage.#*#', onGotHit)
    register('GotHit', '#1# slashes YOU for #*# points of damage.#*#', onGotHit)
    register('GotHit', '#1# tries to #*# YOU, but #*#',                onGotHit)

    -- 2.2: AttackCalled (EQBC and DanNet broadcast formats)
    register('AttackCalled', '<#1#>#*#TANKING-> #*# <- ID:#2#',       onAttackCalled)
    register('AttackCalled', '[ #1# (#*#) ]#*#TANKING-> #*# <- ID:#2#', onAttackCalled)

    -- 2.2: Movement/targeting feedback
    register('CantHit',  "You can't hit them from here.",       onCantHit)
    register('CantSee',  'You cannot see your target.',         onCantSee)
    register('TooClose', 'Your target is too close to use a ranged weapon!', onTooClose)
    register('TooFar',   'Your target is #*#, get closer!',    onTooFar)

    -- 2.2: Mez
    register('MezBroke', '#1# has been awakened by #2#.', onMezBroke)

    -- 2.2: Missing component (combat context; distinct from CAST_COMPONENTS)
    register('Missing', '#*#You are missing some required components.#*#', onMissing)
    register('Missing', '#*#You are missing#*#',                           onMissing)

    -- 2.2: Session events
    register('ImDead',   '#*#Returning to Bind Location#*#',  onImDead)
    register('ImDead',   'You died.',                          onImDead)
    register('ImDead',   'You have been slain by#*#',          onImDead)
    register('Zoned',    'LOADING, PLEASE WAIT#*#',            onZoned)
    register('Zoned',    'You have entered#*#',                onZoned)
    register('Joined',   '#1# has joined the group.',          onJoined)
    register('LeftGroup','#1# has left the group.',            onLeftGroup)
    register('Invised',  'You Vanish #*#',                     onInvised)
    register('Camping',  '#*#seconds to prepare your camp.',   onCamping)
    register('TooSteep', 'The ground here is too steep to camp', onTooSteep)

    -- 2.3: GoM (Gift of Mana) — flags state.bard.gomActive; cast loop in M8
    register('GoMOn',  '#*#granted#*#gift of#*#mana#*#',            onGoMOn)
    register('GoMOn',  'You feel strengthened by a gift of magic.', onGoMOn)
    register('GoMOn',  'You feel strengthened by magic.',           onGoMOn)
    register('GoMOff', 'The gift of magic fades.',                  onGoMOff)
    register('GoMOff', 'Your#*#gift of#*#mana fades.',              onGoMOff)

    -- 2.3: Buff events
    register('WornOff',       'Your #1# spell has worn off of #2#.',  onWornOff)
    register('GainSomething', '#*#You have gained|#1#|',              onGainSomething)
    register('AskForBuffs',   '#1# tells you,#*#Buffs Please!#*#',   onAskForBuffs)
    register('AskForBuffs',   '#1# says,#*#Buffs Please!#*#',        onAskForBuffs)
    register('KABegCheck',    '#*#KABeg for #1# #2# #3#',            onKABegCheck)

    -- 2.3: Pet suspend/resume state tracking
    register('PetSusStateAdd1', "#*# tells you, 'By your command, master.#*#", onPetSusStateAdd1)
    register('PetSusStateAdd2', '#*#You cannot have more than one pet at a time.#*#', onPetSusStateAdd2)
    register('PetSusStateSub',  "#*# tells you, 'I live again...'#*#",          onPetSusStateSub)
    register('PetToysPlease',   '#*#PetToysPlease #1#',                          onPetToysPlease)

    -- 2.3: Tell capture
    register('YouGotTell', '#1# tells you, #2#', onYouGotTell)

    -- 2.3: EQBC cross-char relay stubs (EQBC deprecated; DanNet in M9)
    register('EQBCIRC', '<#1#> #2#',                     onEQBCIRC)
    register('FSEQBC',  '#1# tells the fellowship, #2#', onFSEQBC)
    register('GUEQBC',  '#1# tells the guild, #2#',      onGUEQBC)

    -- 2.3: KT task helpers
    register('KTDismount',  '[MQ2] KTDismount#*#',   onKTDismount)
    register('KTTarget',    '[MQ2] KTTarget #1#',    onKTTarget)
    register('KTHail',      '[MQ2] KTHail #1#',      onKTHail)
    register('KTSay',       '[MQ2] KTSay #1# #2#',   onKTSay)
    register('KTDoorClick', '[MQ2] KTDoorClick #1#', onKTDoorClick)
    register('KTDoorClick', '[MQ2] KTDoorClick#*#',  onKTDoorClick)
    register('KTInvite',    '[MQ2] KTInvite #1#',    onKTInvite)

    -- 2.3: Timers / debug
    -- Note: #Event Timer Timer1 has no Lua equivalent — timer expiry uses os.clock() polling
    register('TaskUpdate', 'Your task |#1#| has been updated#*#', onTaskUpdate)
    register('MLogOff',    '#*#KissAssist Debug Off Marker!',     onMLogOff)
end

function Events.unregister()
    for name in pairs(REGISTERED) do
        mq.unevent(name)
    end
    REGISTERED = {}
end

return Events
