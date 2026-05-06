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
end

function Events.unregister()
    for name in pairs(REGISTERED) do
        mq.unevent(name)
    end
    REGISTERED = {}
end

return Events
