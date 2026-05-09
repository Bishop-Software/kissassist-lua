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

-- ─── CastAA ───────────────────────────────────────────────────────────────────

-- Mirrors CastAA (kissassist.mac:2639-2705).
-- Banestrike race/distance/combat guard; /alt act ID; poll until AA consumed or
-- cast window clears. Bard twist-pause stubbed → M8 (bard.lua).
local function castAA(whatAA, sentFrom)
    -- Banestrike: skip if target race not valid, too far, and in combat
    if whatAA == 'Banestrike' or whatAA == '15073' then
        local baneStr    = state.misc.baneStrikeRaces or ''
        local targetRace = mq.TLO.Target.Race() or ''
        local dist       = mq.TLO.Spawn(state.combat.myTargetID or 0).Distance3D() or 999
        if baneStr ~= '' and not baneStr:find('|' .. targetRace .. '|', 1, true)
                and dist > 70 and state.combat.combatStart then
            return 'CAST_NO_RESULT'
        end
    end

    if mq.TLO.Me.Invis() and sentFrom ~= 'SingleHeal' and sentFrom ~= 'GroupHeal' then
        return 'CAST_CANCELLED'
    end

    -- Bard twist-pause stub → M8

    local aaID    = mq.TLO.Me.AltAbility(whatAA).ID() or 0
    local castTime = mq.TLO.Me.AltAbility(whatAA).Spell.CastTime() or 0

    if not mq.TLO.Me.Mount.ID() and mq.TLO.Me.Sitting() then
        mq.cmd('/stand')
        local t = os.clock() + 0.5
        while os.clock() < t and mq.TLO.Me.Sitting() do mq.delay(50) end
    end

    state.cast.castReturn = 'CAST_SUCCESS'
    mq.cmdf('/alt act %d', aaID)
    utils.debug('cast', 'CastAA: /alt act %d (%s)', aaID, whatAA)

    -- Wait for casting window to open when the AA has a cast time
    if castTime > 0 then
        local tw = os.clock() + 0.5
        while os.clock() < tw and not mq.TLO.Window('CastingWindow').Open() do
            mq.delay(50)
        end
    end

    local castResult = 'CAST_SUCCESS'
    local timeout    = os.clock() + 30
    while os.clock() < timeout do
        mq.delay(100)
        if sentFrom == 'pull' and state.pull.aggroTargetID ~= '' then
            return 'CAST_SUCCESS'
        end
        local casting = (mq.TLO.Me.Casting.ID() or 0) ~= 0
        local aaReady = mq.TLO.Me.AltAbilityReady(whatAA)()
        -- AA consumed and cast window clear → success
        if not aaReady and not casting then
            castResult = 'CAST_SUCCESS'
            break
        end
        -- Cast window closed but AA still ready → something else ended it
        if not casting then
            castResult = state.cast.castReturn
            break
        end
    end

    -- Bard cleanup stub → M8
    utils.debug('cast', 'CastAA result: %s', castResult)
    return castResult
end

-- ─── CastDisc ─────────────────────────────────────────────────────────────────

-- Mirrors CastDisc (kissassist.mac:2761-2803).
-- Skips if a self-targeted duration disc is already active. Uses /disc ID on live
-- MQ (MacroQuest.Build != 4) or /disc name on emu.
local function castDisc(whatDisc, sentFrom)
    if mq.TLO.Me.Invis() and sentFrom ~= 'SingleHeal' and sentFrom ~= 'GroupHeal' then
        return 'CAST_CANCELLED'
    end

    -- Only cast if: no duration, OR (self-target + no active disc), OR non-self target, OR has DurationWindow
    local hasDuration = (mq.TLO.Spell(whatDisc).Duration() or 0) > 0
    local targetType  = mq.TLO.Spell(whatDisc).TargetType() or ''
    local isSelf      = targetType == 'Self'
    local activeDisc  = (mq.TLO.Me.ActiveDisc.ID() or 0) ~= 0
    local durWindow   = mq.TLO.Spell(whatDisc).DurationWindow() or false
    local shouldCast  = not hasDuration
                     or (hasDuration and isSelf and not activeDisc)
                     or not isSelf
                     or durWindow
    if not shouldCast then
        utils.debug('cast', 'CastDisc skip — active self-disc: %s', whatDisc)
        return 'CAST_SUCCESS'
    end

    -- Determine how long to retry (mirrors .mac's WaitTimerCD timer)
    local recast  = mq.TLO.Spell(whatDisc).RecastTime.TotalSeconds() or 0
    local waitSec = 1.0
    if recast > 0 then
        waitSec = recast < 3 and recast or 3.0
    end

    local isEmu   = (mq.TLO.MacroQuest.Build() or 0) == 4
    local timeout = os.clock() + waitSec

    while mq.TLO.Me.CombatAbilityReady(whatDisc)() and os.clock() < timeout do
        if not isEmu then
            local ranked = mq.TLO.Me.CombatAbility(whatDisc)() or whatDisc
            local discID = mq.TLO.Me.CombatAbility(ranked).ID() or 0
            mq.cmdf('/disc %d', discID)
        else
            mq.cmdf('/disc "%s"', whatDisc)
        end
        utils.debug('cast', 'CastDisc: /disc %s', whatDisc)
        mq.delay(100)

        -- Emu: CombatAbilityReady always true for timeless discs — break after one attempt
        if isEmu then
            local recastID = mq.TLO.Spell(whatDisc).RecastTimerID() or -1
            if recastID == -1 then break end
        end

        -- Wait for disc to fire (up to 1s)
        if not isEmu and (mq.TLO.Spell(whatDisc).MyCastTime() or 0) > 0 then
            local castTimeout = os.clock() + 2.0
            while os.clock() < castTimeout do
                mq.delay(100)
                if (mq.TLO.Me.Casting.ID() or 0) == 0 then break end
            end
        end

        local t = os.clock() + 1.0
        while os.clock() < t and mq.TLO.Me.CombatAbilityReady(whatDisc)() do
            mq.delay(50)
        end
    end

    utils.debug('cast', 'CastDisc result: CAST_SUCCESS (%s)', whatDisc)
    return 'CAST_SUCCESS'
end

-- ─── CastItem ─────────────────────────────────────────────────────────────────

-- Mirrors CastItem (kissassist.mac:2709-2757).
-- Prestige/subscription guard; /useitem; polls CastingWindow if item has cast time.
-- Returns SUCCESS when item goes on cooldown or summoned item is consumed.
local function castItem(whatItem, sentFrom)
    -- Block prestige items for non-gold accounts
    local sub = mq.TLO.Me.Subscription() or ''
    if sub ~= 'gold' and mq.TLO.FindItem('=' .. whatItem).Prestige() then
        return 'CAST_NO_RESULT'
    end

    if mq.TLO.Me.Invis() and sentFrom ~= 'SingleHeal' and sentFrom ~= 'GroupHeal' then
        return 'CAST_CANCELLED'
    end

    -- Bard twist-pause stub → M8
    local castTime = mq.TLO.FindItem('=' .. whatItem).Clicky.CastTime.TotalSeconds() or 0

    if not mq.TLO.Me.Mount.ID() and mq.TLO.Me.Sitting() then
        mq.cmd('/stand')
        local t = os.clock() + 0.5
        while os.clock() < t and mq.TLO.Me.Sitting() do mq.delay(50) end
    end

    state.cast.castReturn = 'CAST_SUCCESS'
    mq.cmdf('/useitem "%s"', whatItem)
    utils.debug('cast', 'CastItem: /useitem "%s" (castTime=%.2f)', whatItem, castTime)

    if castTime > 0 then
        -- Wait for casting window
        local tw = os.clock() + 0.5
        while os.clock() < tw and not mq.TLO.Window('CastingWindow').Open() do
            mq.delay(50)
        end
        -- Poll while casting
        local timeout = os.clock() + 30
        while os.clock() < timeout do
            mq.delay(100)
            if sentFrom == 'pull' and state.pull.aggroTargetID ~= '' then
                return 'CAST_SUCCESS'
            end
            if (mq.TLO.Me.Casting.ID() or 0) == 0
                    or not mq.TLO.Window('CastingWindow').Open() then
                break
            end
        end
    else
        mq.delay(100)   -- let cast-result event fire for instant-click items
    end

    local castResult = state.cast.castReturn

    -- SUCCESS if item went on cooldown OR summoned item was consumed (not IMMUNE/RESISTED)
    local itemReady  = mq.TLO.Me.ItemReady('=' .. whatItem)()
    local itemExists = (mq.TLO.FindItem('=' .. whatItem).ID() or 0) ~= 0
    if not itemReady
            or (not itemExists
                and castResult ~= 'CAST_IMMUNE'
                and castResult ~= 'CAST_RESISTED') then
        castResult = 'CAST_SUCCESS'
    end

    -- Bard cleanup stub → M8
    utils.debug('cast', 'CastItem result: %s', castResult)
    return castResult
end

-- ─── Public API ───────────────────────────────────────────────────────────────

Cast.castTarget  = castTarget
Cast.castCommand = castCommand
Cast.castSkill   = castSkill
Cast.castSpell   = castSpell
Cast.castAA      = castAA
Cast.castDisc    = castDisc
Cast.castItem    = castItem

-- CastWhat dispatcher — Step 3.5. Stub returns SUCCESS so callers can be wired now.
function Cast.castWhat(spellName, targetID, sentFrom) -- condNumber, castCount added in Step 3.5
    utils.debug('cast', 'CastWhat [stub]: %s target=%s from=%s',
        tostring(spellName), tostring(targetID), tostring(sentFrom))
    return 'CAST_SUCCESS'
end

return Cast
