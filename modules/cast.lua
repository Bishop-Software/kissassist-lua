-- Casting engine — CastTarget, CastCommand, CastSkill primitives (Step 3.1).
-- CastSpell/CastAA/CastDisc/CastItem added in Steps 3.2-3.3.
-- CastMem/CastReMem/CastMemSpell added in Step 3.4.
-- CastWhat dispatcher completed in Step 3.5.
local mq = require('mq')

local Cast = {}

local state, utils

function Cast.init(s, u)
    state = s
    utils = u
end

-- ─── Primitives ───────────────────────────────────────────────────────────────

-- Mirrors CastTarget (kissassist.mac:3069-3078).
-- Clear current target then acquire targetID. Polls up to 500ms each step.
local function castTarget(targetID)
    if not targetID or targetID == 0 then return end
    mq.cmd('/squelch /target clear')
    local t0 = os.clock() + 0.5
    while os.clock() < t0 do
        if not mq.TLO.Target.ID() or mq.TLO.Target.ID() == 0 then break end
        mq.delay(50)
    end
    mq.cmdf('/squelch /target id %d', targetID)
    local t1 = os.clock() + 0.5
    while os.clock() < t1 do
        if (mq.TLO.Target.ID() or 0) == targetID then break end
        mq.delay(50)
    end
    utils.debug('cast', 'CastTarget %d → got %d', targetID, mq.TLO.Target.ID() or 0)
end

-- Mirrors CastCommand (kissassist.mac:2807-2815).
-- Strips "command:" prefix (8 chars) and executes the remainder via /docommand.
local function castCommand(spellName)
    local cmd = spellName:sub(9)
    utils.debug('cast', 'CastCommand: %s', cmd)
    mq.cmdf('/docommand %s', cmd)
    mq.delay(250)
    return 'CAST_SUCCESS'
end

-- Mirrors CastSkill (kissassist.mac:2819-2829).
-- Invis guard (except SingleHeal); /doability; poll up to 1s for ability to go not-ready.
local function castSkill(spellName, sentFrom)
    if mq.TLO.Me.Invis() and sentFrom ~= 'SingleHeal' then
        utils.debug('cast', 'CastSkill cancelled — invisible')
        return 'CAST_CANCELLED'
    end
    utils.debug('cast', 'CastSkill: %s', spellName)
    mq.cmdf('/doability "%s"', spellName)
    local timeout = os.clock() + 1.0  -- 20 ticks × 50ms
    while os.clock() < timeout do
        if not mq.TLO.Me.AbilityReady(spellName)() then
            return 'CAST_SUCCESS'
        end
        mq.delay(50)
    end
    return 'CAST_SUCCESS'
end

-- ─── CastSpell ────────────────────────────────────────────────────────────────

-- Mirrors CastSpell (kissassist.mac:2833-2915).
-- Polls State.cast.castReturn (set by events.lua) while Me.Casting.ID is live.
-- Retries up to 2× on FIZZLE/INTERRUPT/RESIST when recast time ≤ 2s.
-- Interrupt sub-calls stubbed → M4 (DPS/burn), M5 (Cure/Mez), M6 (Buffs).
local function castSpell(spellName, sentFrom)
    -- Invis guard
    if mq.TLO.Me.Invis() and sentFrom ~= 'SingleHeal' and sentFrom ~= 'GroupHeal' then
        utils.debug('cast', 'CastSpell cancelled — invisible')
        return 'CAST_CANCELLED'
    end

    -- Splash (free-target) check
    if (mq.TLO.Spell(spellName).TargetType() or '') == 'Free Target'
            and not mq.TLO.Target.CanSplashLand() then
        printf('\aw Skip %s — splash will not land here.', spellName)
        return 'CAST_NO_RESULT'
    end

    -- Bard twist-pause stub → M8 (bard.lua)

    -- Gem guard
    if not mq.TLO.Me.Gem(spellName)() then
        printf('\aw Skip Casting %s. Spell Not Memed.', spellName)
        return 'CAST_NO_RESULT'
    end

    local wasSitting  = mq.TLO.Me.Sitting()
    local castResult  = 'CAST_SUCCESS'
    local maxTries    = 2
    local tryNum      = 0

    while true do
        -- Wait for gem recast timer to clear
        while (mq.TLO.Me.GemTimer(spellName)() or 0) > 0
                and not mq.TLO.Me.SpellReady(spellName)() do
            mq.delay(250)
        end

        -- Stand up before casting (skip if mounted — mount handles movement)
        if not mq.TLO.Me.Mount.ID() and mq.TLO.Me.Sitting() then
            mq.cmd('/stand')
            local t = os.clock() + 0.5
            while os.clock() < t and mq.TLO.Me.Sitting() do mq.delay(50) end
        end

        -- Arm cast state; onCastBegin event will also set SUCCESS optimistically
        state.cast.castReturn = 'CAST_SUCCESS'
        mq.cmdf('/cast "%s"', spellName)
        utils.debug('cast', 'CastSpell: /cast "%s"', spellName)
        mq.delay(100)   -- let CAST_BEGIN event fire
        tryNum = tryNum + 1

        -- Poll while the spell is actively casting
        local timeout = os.clock() + 30
        while os.clock() < timeout do
            mq.delay(100)
            if (mq.TLO.Me.Casting.ID() or 0) == 0 then break end
            if state.cast.castReturn == 'CAST_CANCELLED' then break end
            -- Pull short-circuit: aggro achieved, no need to finish cast
            if sentFrom == 'pull' and state.pull.aggroTargetID ~= '' then
                mq.cmd('/stopcast')
                return 'CAST_SUCCESS'
            end
            -- Interrupt checks stub → M4 (dps/burn), M5 (Cure/MezMobs), M6 (Buffs)
        end

        mq.delay(100)   -- let final cast-result event settle

        if state.cast.castReturn == 'CAST_CANCELLED' then break end
        castResult = state.cast.castReturn

        -- Pull short-circuit (post-cast, e.g. resisted but mob is running)
        if sentFrom == 'pull' and state.pull.aggroTargetID ~= '' then
            return 'CAST_SUCCESS'
        end

        -- Retry on FIZZLE / INTERRUPTED / RESISTED if recast is short
        local retryable = castResult == 'CAST_FIZZLE'
                       or castResult == 'CAST_INTERRUPTED'
                       or castResult == 'CAST_RESISTED'
        if tryNum < maxTries and retryable then
            local recast = mq.TLO.Spell(spellName).RecastTime.TotalSeconds() or 99
            if recast <= 2 then
                while (mq.TLO.Me.GemTimer(spellName)() or 0) > 0
                        and not mq.TLO.Me.SpellReady(spellName)() do
                    mq.delay(250)
                end
                -- continue outer loop → cast again
            else
                break
            end
        else
            break
        end
    end

    -- Bard cleanup stub → M8 (bard.lua)

    -- Restore sit state if we were sitting and combat hasn't started
    if wasSitting and not mq.TLO.Me.Sitting() and not state.combat.combatStart then
        mq.cmd('/sit')
    end

    utils.debug('cast', 'CastSpell result: %s', castResult)
    return castResult
end

-- ─── Public API ───────────────────────────────────────────────────────────────

Cast.castTarget  = castTarget
Cast.castCommand = castCommand
Cast.castSkill   = castSkill
Cast.castSpell   = castSpell

-- CastWhat dispatcher — Step 3.5. Stub returns SUCCESS so callers can be wired now.
function Cast.castWhat(spellName, targetID, sentFrom) -- condNumber, castCount added in Step 3.5
    utils.debug('cast', 'CastWhat [stub]: %s target=%s from=%s',
        tostring(spellName), tostring(targetID), tostring(sentFrom))
    return 'CAST_SUCCESS'
end

return Cast
