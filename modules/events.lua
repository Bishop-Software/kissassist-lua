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
    if not state.movement.medding then mq.cmd('/stand') end
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
end

function Events.unregister()
    for name in pairs(REGISTERED) do
        mq.unevent(name)
    end
    REGISTERED = {}
end

return Events
