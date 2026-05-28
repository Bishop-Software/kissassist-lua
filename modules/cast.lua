-- Casting engine — CastTarget, CastCommand, CastSkill primitives (Step 3.1).
-- CastSpell/CastAA/CastDisc/CastItem added in Steps 3.2-3.3.
-- CastMem/CastReMem/CastMemSpell added in Step 3.4.
-- CastWhat dispatcher completed in Step 3.5.
local mq      = require('mq')
local Helpers = require('modules.helpers')

local Cast = {}

local Config = require('modules.config')
local state, utils, _bard, _cond

function Cast.init(s, u)
    state = s
    utils = u
    state.cast.checkStuckGem = Config.get('Spells', 'CheckStuckGem', '1') == '1'
end

-- Wire Bard module after Bard.init; called from init.lua (Step 8.7).
function Cast.setBard(bard)
    _bard = bard
end

-- Wire Cond module after Cond.init; called from init.lua (Step 11.3).
function Cast.setCond(cond)
    _cond = cond
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

-- Forward declaration — castMemSpell is defined later in this file.
local castMemSpell

-- ─── CastSpell ────────────────────────────────────────────────────────────────

-- Mirrors CastSpell (kissassist.mac:2833-2915).
-- Polls State.cast.castReturn (set by events.lua) while Me.Casting.ID is live.
-- Retries up to 2× on FIZZLE/INTERRUPT/RESIST when recast time ≤ 2s.
-- Interrupt sub-calls stubbed → M4 (DPS/burn), M5 (Cure/Mez), M6 (Buffs).
local function castSpell(spellName, sentFrom)
    -- Invis guard
    if mq.TLO.Me.Invis() and sentFrom ~= 'SingleHeal' and sentFrom ~= 'GroupHeal'
            and sentFrom ~= 'Buffs' and sentFrom ~= 'buffs-nomem' then
        utils.debug('cast', 'CastSpell cancelled — invisible')
        return 'CAST_CANCELLED'
    end

    -- Splash (free-target) check
    if (mq.TLO.Spell(spellName).TargetType() or '') == 'Free Target'
            and not mq.TLO.Target.CanSplashLand() then
        printf('\aw Skip %s — splash will not land here.', spellName)
        return 'CAST_NO_RESULT'
    end

    if state.session.iAmABard and _bard then _bard.pauseMedley() end

    -- Gem guard
    if not mq.TLO.Me.Gem(spellName)() then
        printf('\aw Skip Casting %s. Spell Not Memed.', spellName)
        return 'CAST_NO_RESULT'
    end

    -- Stuck-gem check (mac:16013-16025 translated to re-mem approach)
    if state.cast.checkStuckGem and not (sentFrom == 'bard') then
        local gemNum = mq.TLO.Me.Gem(spellName)()
        ---@diagnostic disable-next-line: undefined-field
        if gemNum and (mq.TLO.Me.Gem(gemNum).Name() or '') ~= spellName then
            printf('\ayKissAssist: stuck gem — slot %d has wrong spell; re-memming %s', gemNum, spellName)
            castMemSpell(spellName, gemNum, 0)
            mq.delay(500)
            ---@diagnostic disable-next-line: undefined-field
            if (mq.TLO.Me.Gem(gemNum).Name() or '') ~= spellName then
                printf('\arKissAssist: stuck gem could not be fixed for %s', spellName)
                return 'CAST_STUCK_GEM'
            end
        end
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
        if (mq.TLO.Me.Casting.ID() or 0) ~= 0 then return 'CAST_NO_RESULT' end
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
            -- Abort DPS/burn cast if target is dead or MA needs a heal (mac:3255)
            if sentFrom == 'dps' or sentFrom == 'burn' then
                local tgt = mq.TLO.Target
                if (tgt.ID() or 0) == 0 or (tgt.PctHPs() or 100) < 1
                        or (tgt.Type() or '') == 'corpse' then
                    mq.cmd('/stopcast')
                    return 'CAST_CANCELLED'
                end
                local cls = (mq.TLO.Me.Class.ShortName() or ''):lower()
                if (state.heal.healsOn or 0) > 0 and cls ~= 'nec' and cls ~= 'mag' then
                    local maName = state.session.mainAssist or ''
                    local maHP   = (maName ~= '' and mq.TLO.Spawn(maName).PctHPs()) or 100
                    local intAt  = math.min(state.heal.singleHealPointMA or 70, 70)
                    if maHP < intAt then
                        mq.cmd('/stopcast')
                        return 'CAST_CANCELLED'
                    end
                end
            end
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
            ---@diagnostic disable-next-line: undefined-field
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

    if state.session.iAmABard and _bard then _bard.resumeMedley() end

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

    if mq.TLO.Me.Invis() and sentFrom ~= 'SingleHeal' and sentFrom ~= 'GroupHeal'
            and sentFrom ~= 'Buffs' and sentFrom ~= 'buffs-nomem' then
        return 'CAST_CANCELLED'
    end

    if state.session.iAmABard and _bard then _bard.pauseMedley() end

    local aaID    = mq.TLO.Me.AltAbility(whatAA).ID() or 0
    local castTime = mq.TLO.Me.AltAbility(whatAA).Spell.CastTime() or 0

    if not mq.TLO.Me.Mount.ID() and mq.TLO.Me.Sitting() then
        mq.cmd('/stand')
        local t = os.clock() + 0.5
        while os.clock() < t and mq.TLO.Me.Sitting() do mq.delay(50) end
    end

    if (mq.TLO.Me.Casting.ID() or 0) ~= 0 then return 'CAST_NO_RESULT' end
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

    if state.session.iAmABard and _bard then _bard.resumeMedley() end
    utils.debug('cast', 'CastAA result: %s', castResult)
    return castResult
end

-- ─── CastDisc ─────────────────────────────────────────────────────────────────

-- Mirrors CastDisc (kissassist.mac:2761-2803).
-- Skips if a self-targeted duration disc is already active. Uses /disc ID on live
-- MQ (MacroQuest.Build != 4) or /disc name on emu.
local function castDisc(whatDisc, sentFrom)
    if mq.TLO.Me.Invis() and sentFrom ~= 'SingleHeal' and sentFrom ~= 'GroupHeal'
            and sentFrom ~= 'Buffs' and sentFrom ~= 'buffs-nomem' then
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
    ---@diagnostic disable-next-line: undefined-field
    local recast  = mq.TLO.Spell(whatDisc).RecastTime.TotalSeconds() or 0
    local waitSec = 1.0
    if recast > 0 then
        waitSec = recast < 3 and recast or 3.0
    end

    ---@diagnostic disable-next-line: undefined-field
    local isEmu   = (mq.TLO.MacroQuest.Build() or 0) == 4
    local timeout = os.clock() + waitSec

    while mq.TLO.Me.CombatAbilityReady(whatDisc)() and os.clock() < timeout do
        if (mq.TLO.Me.Casting.ID() or 0) ~= 0 then return 'CAST_NO_RESULT' end
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
            ---@diagnostic disable-next-line: undefined-field
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
    ---@diagnostic disable-next-line: undefined-field
    if sub ~= 'gold' and mq.TLO.FindItem('=' .. whatItem).Prestige() then
        return 'CAST_NO_RESULT'
    end

    if mq.TLO.Me.Invis() and sentFrom ~= 'SingleHeal' and sentFrom ~= 'GroupHeal'
            and sentFrom ~= 'Buffs' and sentFrom ~= 'buffs-nomem' then
        return 'CAST_CANCELLED'
    end

    if state.session.iAmABard and _bard then _bard.pauseMedley() end
    ---@diagnostic disable-next-line: undefined-field
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

    if state.session.iAmABard and _bard then _bard.resumeMedley() end
    utils.debug('cast', 'CastItem result: %s', castResult)
    return castResult
end

-- ─── CastMemSpell ─────────────────────────────────────────────────────────────

-- Mirrors CastMemSpell (kissassist.mac:3177-3227).
-- Low-level /memspell gemNum "spell" with cursor cleanup and already-memed guard.
-- forceIt > 0: unmem from that slot first (used by CastReMem for LW spell restore).
castMemSpell = function(spellToMem, gemNum, forceIt)
    if not spellToMem or spellToMem == '' or spellToMem == 'null' or gemNum == 0 then
        return
    end

    local currentGem = mq.TLO.Me.Gem(spellToMem)() or 0
    -- Already in target gem and no force requested → skip
    if currentGem == gemNum and (not forceIt or forceIt == 0) then return end

    -- No-rent item on cursor → autoinventory
    if (mq.TLO.Cursor.ID() or 0) ~= 0 and mq.TLO.Cursor.NoRent() then
        mq.cmd('/autoinventory')
        mq.delay(1000)
    end

    -- ForceIt: spell is in a different slot — unmem it from forceIt slot first
    if forceIt and forceIt > 0 then
        if currentGem > 0 and gemNum ~= forceIt then
            mq.cmdf('/notify CastSpellWnd CSPW_Spell%d rightmouseup', forceIt - 1)
            local t = os.clock() + 2.0
            while os.clock() < t and (mq.TLO.Me.Gem(gemNum).ID() or 0) ~= 0 do
                mq.delay(100)
            end
        end
    end

    if not mq.TLO.Me.Book(spellToMem)() then
        printf('\aw Could Not find the spell %s in your spell book.', spellToMem)
        return
    end

    if (mq.TLO.Cursor.ID() or 0) ~= 0 then
        printf('\aw Cannot Mem a spell with Items on Cursor. Please drop item to Inventory.')
        return
    end

    -- Clear target gem slot if occupied
    if (mq.TLO.Me.Gem(gemNum).ID() or 0) ~= 0 then
        mq.cmdf('/notify CastSpellWnd CSPW_Spell%d rightmouseup', gemNum - 1)
        local t = os.clock() + 2.0
        while os.clock() < t and (mq.TLO.Me.Gem(gemNum).ID() or 0) ~= 0 do
            mq.delay(100)
        end
    end

    -- Mem the spell if slot name doesn't already match
    if (mq.TLO.Me.Gem(gemNum).Name() or '') ~= spellToMem then
        if state.session.iAmABard and _bard then _bard.pauseMedley() end
        while mq.TLO.Me.Moving() do mq.delay(100) end

        printf('\aw Memming %s in slot %d', spellToMem, gemNum)
        local stickActive = mq.TLO.Stick.Active()
        if stickActive then mq.cmd('/stick pause') end
        mq.cmdf('/memspell %d "%s"', gemNum, spellToMem)
        local timeout = os.clock() + 15.0
        while os.clock() < timeout do
            mq.delay(100)
            if (mq.TLO.Me.Gem(gemNum).Name() or '') == spellToMem then break end
        end
        if stickActive then mq.cmd('/stick unpause') end
    end

    if mq.TLO.Window('SpellBookWnd').Open() then
        mq.cmd('/windowstate spellbookwnd close')
    end
    utils.debug('cast', 'CastMemSpell %s gem=%d', spellToMem, gemNum)
end

-- ─── CastMem ──────────────────────────────────────────────────────────────────

-- Mirrors CastMem (kissassist.mac:3082-3132).
-- Routes to MiscGem (short recast) or MiscGemLW (>30s recast) slot.
-- Polls up to 35s for the spell to become ready. Returns true on success.
local BUFF_SENTFROM = {
    buffs=true, ['buffs-nomem']=true, buffonce=true, checkaura=true,
    ['summonstuff-nomem']=true, dopetstuff=true, pet=true, ['pet-nomem']=true,
}

local function castMem(whatMemSpell, sentFrom)
    -- Bards use twist system instead; non-bards: bail if casting or moving
    if not state.session.iAmABard then
        if (mq.TLO.Me.Casting.ID() or 0) ~= 0 or mq.TLO.Me.Moving() then
            return false
        end
    end

    if mq.TLO.Me.Invis() and sentFrom ~= 'SingleHeal' and sentFrom ~= 'GroupHeal'
            and sentFrom ~= 'Buffs' and sentFrom ~= 'buffs-nomem' then
        state.cast.castResult = 'CAST_CANCELLED'
        return false
    end

    -- Block tanks and healers from memming mid-combat with aggro
    local hasCombatAggro = state.combat.aggroTargetID ~= ''
                        and state.session.heals
                        and sentFrom ~= 'Heal'
                        and not mq.TLO.Me.Mount.ID()
    if (state.combat.attacking and state.session.iAmMA) or hasCombatAggro then
        printf('\aw Cannot mem a spell during combat or while you have aggro. %s', whatMemSpell)
        return false
    end

    -- No-rent cursor cleanup
    if (mq.TLO.Cursor.ID() or 0) ~= 0 and mq.TLO.Cursor.NoRent() then
        mq.cmd('/autoinventory')
        mq.delay(1000)
    end

    local miscGemRemem = state.cast.miscGemRemem or 0
    local miscGemLW    = state.cast.miscGemLW or 0
    ---@diagnostic disable-next-line: undefined-field
    local recast       = mq.TLO.Spell(whatMemSpell).RecastTime.TotalSeconds() or 0

    -- Long-recast path (>30s): use dedicated LW slot
    if miscGemRemem ~= 0 and miscGemLW ~= 0 and recast > 30 then
        if state.cast.reMemWaitLong == 'null' then
            state.cast.reMemWaitLong = whatMemSpell
            state.movement.dontMoveMe = true
            castMemSpell(whatMemSpell, miscGemLW, 0)
            state.movement.dontMoveMe = false
        else
            printf('\aw Still Waiting on Long Wait Spell %s', state.cast.reMemWaitLong)
        end
        return false
    end

    -- Short path: mana check
    if (mq.TLO.Spell(whatMemSpell).Mana() or 0) > (mq.TLO.Me.CurrentMana() or 0) then
        return false
    end

    state.cast.reMemWaitShort = whatMemSpell
    state.movement.dontMoveMe = true
    castMemSpell(whatMemSpell, state.cast.miscGem or 0, 0)
    state.movement.dontMoveMe = false

    -- Poll up to 35s for spell to become ready in the gem
    if mq.TLO.Me.Gem(whatMemSpell)() then
        local timeout = os.clock() + 35.0
        while os.clock() < timeout and not mq.TLO.Me.SpellReady(whatMemSpell)() do
            mq.delay(500)
            -- Cancel if aggro closes in while memming during buff context
            if BUFF_SENTFROM[sentFrom] and state.combat.aggroTargetID ~= '' then
                local dist = mq.TLO.Spawn(tonumber(state.combat.aggroTargetID) or 0).Distance() or 999
                if dist < 200 then
                    state.cast.castResult = 'CAST_CANCELLED'
                    return false
                end
            end
        end
    end

    if not mq.TLO.Me.Gem(whatMemSpell)() then return false end

    utils.debug('cast', 'CastMem success: %s', whatMemSpell)
    return true
end

-- ─── CastReMem ────────────────────────────────────────────────────────────────

-- Mirrors CastReMem (kissassist.mac:3136-3173).
-- Sets the remem flag when a misc-gem spell is cast successfully. When
-- forceReMem is true and out of combat, restores the displaced spell.
local function castReMem(whatMemSpell, forceReMem, sentFrom)
    -- Flag which slot needs restoring
    if state.cast.castReturn == 'CAST_SUCCESS' then
        if whatMemSpell == state.cast.reMemWaitShort then
            state.cast.reMemCast   = true
        elseif whatMemSpell == state.cast.reMemWaitLong then
            state.cast.reMemCastLW = true
        end
    end

    if not forceReMem then return end

    if sentFrom == 'buffs' and state.combat.aggroTargetID ~= '' then
        local dist = mq.TLO.Spawn(tonumber(state.combat.aggroTargetID) or 0).Distance() or 999
        if dist < 200 then return end
    end

    local miscGemRemem = state.cast.miscGemRemem or 0
    local rezSick      = (mq.TLO.Me.Buff('Resurrection Sickness').ID() or 0) ~= 0

    -- Restore short-recast MiscGem slot
    if miscGemRemem == 1 or miscGemRemem == 2 then
        local spell = state.cast.reMemMiscSpell
        if not mq.TLO.Me.Gem(spell)()
                and state.cast.reMemCast
                and not state.combat.combatStart
                and not rezSick
                and not sentFrom:find('-nomem', 1, true) then
            if (mq.TLO.Cursor.ID() or 0) ~= 0 and mq.TLO.Cursor.NoRent() then
                mq.cmd('/autoinventory') ; mq.delay(1000)
            end
            state.movement.dontMoveMe = true
            castMemSpell(spell, state.cast.miscGem or 0, 0)
            state.movement.dontMoveMe = false
            state.cast.reMemCast      = false
            state.cast.reMemWaitShort = 'null'
        end
    end

    -- Restore long-wait MiscGemLW slot
    local miscGemLW = state.cast.miscGemLW or 0
    if (miscGemRemem == 1 or miscGemRemem == 3)
            and miscGemLW ~= 0
            and state.cast.reMemWaitLong ~= 'null' then
        if state.cast.reMemCastLW and not rezSick then
            local spell = state.cast.reMemMiscSpellLW
            if (mq.TLO.Cursor.ID() or 0) ~= 0 and mq.TLO.Cursor.NoRent() then
                mq.cmd('/autoinventory') ; mq.delay(1000)
            end
            local currentSlot      = mq.TLO.Me.Gem(spell)() or 0
            state.movement.dontMoveMe = true
            castMemSpell(spell, miscGemLW, currentSlot)
            state.movement.dontMoveMe = false
            state.cast.reMemCastLW   = false
            state.cast.reMemWaitLong = 'null'
        end
    end

    utils.debug('cast', 'CastReMem done: %s', whatMemSpell)
end

-- ─── Public API ───────────────────────────────────────────────────────────────

Cast.castTarget   = castTarget
Cast.castCommand  = castCommand
Cast.castSkill    = castSkill
Cast.castSpell    = castSpell
Cast.castAA       = castAA
Cast.castDisc     = castDisc
Cast.castItem     = castItem
Cast.castMemSpell = castMemSpell
Cast.castMem      = castMem
Cast.castReMem    = castReMem

-- ─── Buff Stacking Check ──────────────────────────────────────────────────────

-- Mirrors CastBuffsSpellCheck (kissassist.mac:2946) — simplified.
-- Returns true if spellName is already active on self (Me.Buff or Me.Song).
-- Full WillStack / SPA-374/340 group-target check deferred to M10.
local function castBuffsSpellCheck(spellName)
    if (mq.TLO.Me.Buff(spellName).ID() or 0) ~= 0 then return true end
    if (mq.TLO.Me.Song(spellName).ID() or 0) ~= 0 then return true end
    return false
end

-- CastWhat dispatcher — mirrors CastWhat (kissassist.mac:2467-2614).
-- Determines what type of ability castWhat is, checks readiness, acquires target,
-- then routes to the appropriate cast sub. Stacking checks (DPS/Buffs), conditions,
-- StopMoving, and bard twist-restart are stubbed → M4/M5/M6/M7/M8.
function Cast.castWhat(castWhat, whatID, sentFrom, condNumber)
    -- Non-bard: bail immediately if already casting with the window open
    if not state.session.iAmABard then
        if (mq.TLO.Me.Casting.ID() or 0) ~= 0
                and mq.TLO.Window('CastingWindow').Open() then
            return 'CAST_CASTING'
        end
    end

    state.cast.castReturn = 'CAST_NO_RESULT'
    state.cast.castResult = 'CAST_NO_RESULT'
    local memReturn     = 'null'
    local strTargetType = mq.TLO.Spell(castWhat).TargetType() or 'null'

    -- Existence check — must be recognisable as one of: command, AA, disc, item, skill, spell
    local isCommand = castWhat:find('command:', 1, true)
    local hasAA     = (mq.TLO.Me.AltAbility(castWhat).ID() or 0) ~= 0
    local hasDisc   = mq.TLO.Me.CombatAbility(castWhat)() ~= nil
    local hasItem   = (mq.TLO.FindItem('=' .. castWhat).ID() or 0) ~= 0
    local hasSkill  = (mq.TLO.Me.Skill(castWhat)() or 0) > 0
    local inBook    = (mq.TLO.Me.Book(castWhat)() or 0) ~= 0

    if not (isCommand or hasAA or hasDisc or hasItem or hasSkill or inBook) then
        utils.debug('cast', 'CastWhat: %s not found', castWhat)
        return 'CAST_NOT_FOUND'
    end

    -- ReadyToCast: position of first ready check (mirrors .mac Select[TRUE,...])
    local isBard = state.session.iAmABard
    local rtc    = 0
    if mq.TLO.Me.ItemReady('=' .. castWhat)() then
        rtc = 1
    elseif mq.TLO.Me.AltAbilityReady(castWhat)() then
        rtc = 2
    elseif mq.TLO.Me.CombatAbilityReady(castWhat)() then
        rtc = 3
    elseif mq.TLO.Me.AbilityReady(castWhat)() and hasSkill then
        rtc = 4
    elseif isBard then
        if mq.TLO.Me.Gem(castWhat)() and (mq.TLO.Me.GemTimer(castWhat)() or 0) == 0 then
            rtc = 5
        end
    elseif mq.TLO.Me.SpellReady(castWhat)() then
        rtc = 5
    end
    if rtc == 0 and isCommand then rtc = 6 end

    -- Stuck-gem / not-memed override
    if (rtc == 0 or (mq.TLO.Me.Casting.ID() or 0) ~= 0) and inBook then
        if not isBard
                and (mq.TLO.Me.Casting.ID() or 0) ~= 0
                and not mq.TLO.Window('CastingWindow').Open() then
            -- Casting but window closed → gem may be stuck; re-mem handled in castSpell
            rtc = mq.TLO.Me.Gem(castWhat)() and 5 or 7
        elseif not hasItem and not mq.TLO.Me.Gem(castWhat)() and not hasAA then
            rtc = 7     -- in book but not memed → needs CastMem
        end
    end

    if rtc == 0 then
        utils.debug('cast', 'CastWhat: %s CAST_RECOVER', castWhat)
        return 'CAST_RECOVER'
    end

    -- Item spells use the clicky spell's TargetType
    if strTargetType == 'null' and rtc == 1 then
        strTargetType = mq.TLO.FindItem('=' .. castWhat).Spell.TargetType() or 'null'
    end

    if condNumber and condNumber > 0 and _cond then
        if not _cond.eval(condNumber) then return 'CAST_COND_FAILED' end
    end

    -- Target acquisition for non-self spells
    if strTargetType ~= 'Self' then
        local tID = mq.TLO.Target.ID() or 0
        if tID == 0 or (tID ~= whatID and (mq.TLO.Spawn(whatID).ID() or 0) ~= 0) then
            castTarget(whatID)
        end
    end

    -- DPS stacking check stub → M4

    -- Buff stacking check: skip if spell is already active on self
    if (sentFrom == 'Buffs' or sentFrom == 'buffs-nomem') and castBuffsSpellCheck(castWhat) then
        utils.debug('cast', 'CastWhat: %s CAST_HASBUFF (already active on self)', castWhat)
        return 'CAST_HASBUFF'
    end

    -- Pull short-circuit pre-cast
    if sentFrom:find('pull', 1, true) and state.pull.aggroTargetID ~= '' then
        return 'CAST_SUCCESS'
    end

    -- Stop moving before spells with cast time (non-bard) — full impl stub → M7
    if (mq.TLO.Spell(castWhat).CastTime() or 0) > 0
            and mq.TLO.Me.Moving()
            and not isBard then
        mq.cmd('/squelch /stand')
        mq.delay(250)
    end

    utils.debug('cast', 'CastWhat: %s rtc=%d from=%s', castWhat, rtc, sentFrom)

    local castResult = 'CAST_NO_RESULT'

    if rtc == 1 and mq.TLO.Me.ItemReady('=' .. castWhat)() and hasItem then
        castResult = castItem(castWhat, sentFrom)

    elseif rtc == 2 and mq.TLO.Me.AltAbilityReady(castWhat)() and not hasItem then
        castResult = castAA(castWhat, sentFrom)

    elseif rtc == 3 and mq.TLO.Me.CombatAbilityReady(castWhat)() then
        local endCost = mq.TLO.Spell(castWhat).EnduranceCost() or 0
        if endCost < (mq.TLO.Me.CurrentEndurance() or 0) then
            castResult = castDisc(castWhat, sentFrom)
        end

    elseif rtc == 4 and mq.TLO.Me.AbilityReady(castWhat)() then
        castResult = castSkill(castWhat, sentFrom)

    elseif rtc == 5 then
        local spellMana = mq.TLO.Spell(castWhat).Mana() or 0
        if spellMana < (mq.TLO.Me.CurrentMana() or 0) then
            local canCast = isBard
                and (mq.TLO.Me.Gem(castWhat)() and (mq.TLO.Me.GemTimer(castWhat)() or 0) == 0)
                or  (mq.TLO.Me.SpellReady(castWhat)() and inBook)
            if canCast then
                castResult = castSpell(castWhat, sentFrom)
            end
            memReturn = castResult
        else
            castResult = 'CAST_NEEDMANA'
            memReturn  = 'CAST_NO_RESULT'
        end

    elseif rtc == 6 and isCommand then
        castResult = castCommand(castWhat)

    elseif rtc == 7 then
        if not sentFrom:find('combat', 1, true) then
            local spellMana = mq.TLO.Spell(castWhat).Mana() or 0
            if spellMana < (mq.TLO.Me.CurrentMana() or 0) then
                local memOk = castMem(castWhat, sentFrom)
                memReturn = memOk and '1' or 'notready'
                if memOk and (mq.TLO.Me.Gem(castWhat)() or 0) ~= 0 then
                    castResult = castSpell(castWhat, sentFrom)
                end
            else
                castResult = 'CAST_NEEDMANA'
                memReturn  = 'notready'
            end
        else
            castResult = 'CAST_NO_RESULT'
            memReturn  = 'notready'
        end
    end

    state.cast.castResult = castResult

    -- Pull short-circuit post-cast
    if sentFrom:find('pull', 1, true) and state.pull.aggroTargetID ~= '' then
        return 'CAST_SUCCESS'
    end

    -- CastReMem: restore displaced spell out of combat after misc-gem cast
    if (state.cast.miscGemRemem or 0) ~= 0 then
        if rtc == 7 and memReturn ~= 'notready' then
            castReMem(castWhat, false, sentFrom)
        elseif rtc == 5 and memReturn ~= 'CAST_NO_RESULT' then
            if castWhat == state.cast.reMemWaitLong
                    or castWhat == state.cast.reMemWaitShort then
                castReMem(castWhat, false, sentFrom)
            end
        end
    end

    if state.session.iAmABard and _bard then _bard.resumeMedley() end

    utils.debug('cast', 'CastWhat leave: %s → %s', castWhat, castResult)
    return castResult
end

-- ─── DPS Stacking Check ───────────────────────────────────────────────────────

-- Mirrors CastDPSSpellCheck (kissassist.mac:2919).
-- Returns true if spellName (or its SPA-470 trigger) is already on the current
-- target and was cast by me — prevents re-casting active DoTs.
local function castDPSSpellCheck(spellName)
    local myName = mq.TLO.Me.CleanName() or ''
    local tgt    = mq.TLO.Target
    if (tgt.Buff(spellName).ID() or 0) ~= 0
            and (tgt.Buff(spellName).Caster() or '') == myName then
        return true
    end
    if mq.TLO.Spell(spellName).HasSPA(470)() then
        local numFX = mq.TLO.Spell(spellName).NumEffects() or 0
        for k = 1, numFX do
            if (mq.TLO.Spell(spellName).Attrib(k)() or 0) == 470 then
                local trigName = mq.TLO.Spell(spellName).Trigger(k).Name() or ''
                if trigName ~= ''
                        and (tgt.Buff(trigName).ID() or 0) ~= 0
                        and (tgt.Buff(trigName).Caster() or '') == myName then
                    return true
                end
            end
        end
    end
    return false
end

-- ─── Mash Buttons ─────────────────────────────────────────────────────────────

-- Mirrors MashButtons (kissassist.mac:1973).
-- Iterates MashArray and fires any ready instant-cast AA/disc/item/skill each tick.
-- Cond check deferred → M5. TargetSwitchingOn+IAmMA path simplified to plain retarget.
local function mashButtons()
    if not state.combat.dpsOn then return end
    if (mq.TLO.Me.Casting.ID() or 0) ~= 0 then return end
    local meState = mq.TLO.Me.State() or ''
    if meState ~= 'STAND' and meState ~= 'MOUNT' then return end

    if (mq.TLO.Target.ID() or 0) ~= state.combat.myTargetID then
        mq.cmdf('/squelch /target id %d', state.combat.myTargetID)
        local t = os.clock() + 0.5
        while os.clock() < t do
            if mq.TLO.Target.ID() == state.combat.myTargetID then break end
            mq.delay(50)
        end
    end

    local mashArr = state.arrays.mashArray
    for i = 1, #mashArr do
        if (mq.TLO.Me.Casting.ID() or 0) ~= 0 then return end
        local entry = mashArr[i]
        if not entry or entry == 'null' then return end
        local name = entry:match('^([^|]+)') or entry
        if name == '' or name == 'null' then return end
        if (mq.TLO.Target.ID() or 0) == 0 then return end
        if (mq.TLO.Target.Type() or ''):lower() == 'corpse' then return end
        -- Condition guard
        if _cond then
            local cp = entry:find('|cond', 1, true)
            if cp then
                local condNo = tonumber(entry:sub(cp + 5, cp + 7)) or 0
                if condNo > 0 and not _cond.eval(condNo) then goto next_mash end
            end
        end
        if (mq.TLO.FindItem('=' .. name).ID() or 0) ~= 0 and mq.TLO.Me.ItemReady(name)() then
            mq.cmd('/useitem "' .. name .. '"')
            mq.delay(100)
            mq.cmd('/echo ## Mashing >> ' .. name .. ' <<')
        elseif (mq.TLO.Me.AltAbility(name).ID() or 0) ~= 0
                and mq.TLO.Me.AltAbilityReady(name)()
                and (mq.TLO.Me.AltAbility(name).Type() or 0) ~= 5
                and name:lower() ~= 'twincast' then
            mq.cmdf('/squelch /alt act %d', mq.TLO.Me.AltAbility(name).ID() or 0)
            mq.delay(100)
            if not mq.TLO.Me.AltAbilityReady(name)() then
                mq.cmd('/echo ## Mashing >> ' .. name .. ' <<')
            end
        elseif mq.TLO.Me.CombatAbility(name)() ~= nil
                and not mq.TLO.Me.CombatAbilityTimer(name)()
                and mq.TLO.Me.CombatAbilityReady(name)()
                and (mq.TLO.Spell(name).EnduranceCost() or 0) < (mq.TLO.Me.CurrentEndurance() or 0) then
            ---@diagnostic disable-next-line: undefined-field
            local isEmu = (mq.TLO.MacroQuest.Build() or 0) == 4
            if not isEmu then
                local ranked = mq.TLO.Me.CombatAbility(name)() or name
                mq.cmdf('/squelch /disc %d', mq.TLO.Me.CombatAbility(ranked).ID() or 0)
            else
                mq.cmdf('/squelch /disc "%s"', name)
            end
            mq.delay(100)
            if not mq.TLO.Me.CombatAbilityReady(name)() then
                mq.cmd('/echo ## Mashing >> ' .. name .. ' <<')
            end
        elseif (mq.TLO.Me.Skill(name)() or 0) > 0 and mq.TLO.Me.AbilityReady(name)() then
            mq.cmdf('/squelch /doability "%s"', name)
            mq.delay(100)
            if not mq.TLO.Me.AbilityReady(name)() then
                mq.cmd('/echo ## Mashing >> ' .. name .. ' <<')
            end
        elseif name:find('command:', 1, true) then
            mq.cmdf('/docommand %s', name:sub(9))
            mq.cmd('/echo ## Mashing >> ' .. name .. ' <<')
        end
        ::next_mash::
    end
end

-- ─── Combat Cast (DPS Rotation) ───────────────────────────────────────────────

-- Mirrors CombatCast (kissassist.mac:1616).
-- Compute per-slot timer expiry after a successful cast (mac ABTimer/DPSTimer logic).
-- daMod: optional modifier string from INI entry (e.g. '+0', '-30', '300').
--   '+N'/'-N' → timer = baseDuration + N seconds
--   plain 'N'  → timer = N seconds (fixed; mac:1807-1810)
-- Returns an os.clock() timestamp; 0 means no timer applies.
local function setSlotTimer(spellName, tType, daMod)
    -- 'once' / 'maonce' target types: suppress for 5 minutes (mac:1778-1779)
    if tType == 'once' or tType == 'maonce' then
        return os.clock() + 300
    end

    local function applyMod(baseDur)
        return Helpers.applyDAMod(baseDur, daMod)
    end

    -- Item: use item spell duration (mac:1781-1782)
    local item = mq.TLO.FindItem('=' .. spellName)
    if item and (item.ID() or 0) ~= 0 then
        local dur = applyMod(item.Spell.Duration.TotalSeconds() or 0)
        return dur > 0 and os.clock() + dur or 0
    end
    -- AA: use AA spell duration, then trigger duration (mac:1817-1830)
    local aa = mq.TLO.Me.AltAbility(spellName)
    if aa and (aa.ID() or 0) ~= 0 then
        ---@diagnostic disable-next-line: undefined-field
        local dur = aa.Spell.MyDuration.TotalSeconds() or 0
        ---@diagnostic disable-next-line: undefined-field
        if dur == 0 then dur = aa.Spell.Trigger.MyDuration.TotalSeconds() or 0 end
        dur = applyMod(dur)
        return dur > 0 and os.clock() + dur or 0
    end
    -- Spell (book or disc): use MyDuration (mac:1790-1814)
    local dur = applyMod(mq.TLO.Spell(spellName).MyDuration.TotalSeconds() or 0)
    return dur > 0 and os.clock() + dur or 0
end

-- Iterates the DPS array (starting after debuff slots), casts each ready spell/AA/disc,
-- then calls mashButtons. Returns 'tcnc' if a cast signals no-combat restart.
-- Deferred: WeaveArray.
function Cast.combatCast()
    utils.debug('cast', 'combatCast enter')
    if (mq.TLO.Me.Casting.ID() or 0) ~= 0 then return end

    local debuffCount = state.debuff.count or 0
    local dpsStart    = debuffCount + 1
    local dpsArr      = state.combat.dpsArray

    -- If nothing to cast in DPS slots, still run mash
    if dpsStart > #dpsArr then
        mashButtons()
        return
    end

    local myID = state.combat.myTargetID
    if (mq.TLO.Target.ID() or 0) ~= 0 and mq.TLO.Target.ID() ~= myID then
        if myID == 0 then return end
    end
    for i = dpsStart, #dpsArr do
        -- Drain all pending events before each entry (mirrors inner EventFlag while loop)
        repeat
            state.combat.eventFlag = false
            mq.doevents()
        until not state.combat.eventFlag

        myID = state.combat.myTargetID
        if (mq.TLO.Spawn('id ' .. myID).Type() or ''):lower() == 'corpse'
                or (mq.TLO.Spawn('id ' .. myID).ID() or 0) == 0
                or state.dps.paused then
            return
        end

        local slot = dpsArr[i]
        if not slot then break end
        local condNo = slot.condNo or 0
        if condNo > 0 and _cond and not _cond.eval(condNo) then goto next_dps end
        local entry = slot.name or ''
        if entry == 'null' or entry == '' then break end

        -- Skip slot if per-slot cooldown timer has not expired (mac ABTimer/DPSTimer; Step 13.1)
        if os.clock() < (state.combat.slotTimers[i] or 0) then goto next_dps end

        -- Skip weave/mash/ambush-tagged entries (handled by other subsystems)
        if entry:find('|weave', 1, true) or entry:find('|mash', 1, true)
                or entry:find('|ambush', 1, true) then
            goto next_dps
        end

        -- Parse |-delimited fields: spellName|hpThresh|targetType|opt4|opt5
        -- DAMod= can appear in part3 or part4 (mac:1674-1686).
        local parts = {}
        for part in (entry .. '|'):gmatch('([^|]*)|') do
            parts[#parts + 1] = part
        end
        local spellName   = parts[1] or ''
        local hpThreshStr = parts[2] or ''
        local targetType  = parts[3] or ''
        local part4       = parts[4] or ''
        local daMod       = '+0'
        if targetType:find('DAMod=', 1, true) then
            daMod      = targetType:match('DAMod=(.+)') or '+0'
            targetType = ''
        elseif part4:find('DAMod=', 1, true) then
            daMod = part4:match('DAMod=(.+)') or '+0'
        end

        if spellName == '' or spellName == 'null' then goto next_dps end

        local hpThresh = tonumber(hpThreshStr)
        if not hpThresh or hpThresh <= 0 then break end

        -- IAmMA or DPSOn off → use global AssistAt; otherwise use per-entry threshold
        local dpsAt = (state.combat.dpsOn and not state.session.iAmMA)
                      and hpThresh or state.combat.assistAt

        -- Skip entry if nothing is ready to fire
        local rankName = mq.TLO.Spell(spellName).RankName() or spellName
        local isCmd    = spellName:find('command:', 1, true) ~= nil
        if not isCmd
                and not state.session.iAmABard
                and not mq.TLO.Me.SpellReady(rankName)()
                and not mq.TLO.Me.AltAbilityReady(spellName)()
                and not mq.TLO.Me.CombatAbilityReady(rankName)()
                and not mq.TLO.Me.AbilityReady(spellName)()
                and not mq.TLO.Me.ItemReady(spellName)() then
            goto next_dps
        end

        -- Mezzed guard: non-MA only casts Utility Detrimental on mezzed targets
        if mq.TLO.Target.Mezzed.ID() and not state.session.iAmMA then
            if (mq.TLO.Spell(spellName).Category() or '') ~= 'Utility Detrimental' then
                goto next_dps
            end
        end

        -- HP% gate (mac:1727)
        local targetHP = mq.TLO.Spawn('id ' .. myID).PctHPs() or 0
        -- Lower bound: stop entire rotation when mob is near death (mac DPSSkip)
        local dpsSkip = state.combat.dpsSkip or 0
        if dpsSkip > 0 and targetHP <= dpsSkip then return end
        -- Upper bound: skip slot when mob HP above threshold; bypassed in OOC mode (DPSOn==2)
        if state.combat.dpsOn and not state.combat.dpsOnOoc and targetHP > dpsAt then goto next_dps end

        -- Resolve cast target
        local castTargetID = myID
        local tType = targetType:lower()
        if tType == 'me' or tType == 'feign' then
            castTargetID = mq.TLO.Me.ID() or 0
        elseif tType == 'ma' or tType == 'maonce' then
            if state.session.role:find('pettank') then
                castTargetID = mq.TLO.Me.Pet.ID() or 0
            else
                castTargetID = mq.TLO.Spawn('=' .. state.session.mainAssist).ID() or 0
            end
        else
            local gIdx = tType:match('^group(%d)$')
            if gIdx then
                local member = mq.TLO.Group.Member(tonumber(gIdx) or 0)
                castTargetID = member and (member.ID() or 0) or 0
            end
        end

        -- Self-buff skip: already active on me
        if tType == 'me' then
            if (mq.TLO.Me.Buff(spellName).ID() or 0) ~= 0
                    or (mq.TLO.Me.Song(spellName).ID() or 0) ~= 0 then
                goto next_dps
            end
        end

        -- Drop attack for self/MA targeted casts when not the MA
        if (tType == 'me' or tType == 'ma') and mq.TLO.Me.Combat() and not state.session.iAmMA then
            mq.cmd('/attack off')
            local t = os.clock() + 0.5
            while os.clock() < t and mq.TLO.Me.Combat() do mq.delay(50) end
        end

        -- Skip gem-spell if under global spell cooldown (DPSOn==2 wait mode deferred)
        if mq.TLO.Me.SpellInCooldown() and not state.session.iAmABard then
            if mq.TLO.Me.Gem(spellName)() and (mq.TLO.Spawn('id ' .. myID).ID() or 0) ~= 0 then
                goto next_dps
            end
        end

        -- DPS stacking check: don't re-cast DoT/spell already on target from me
        if not isCmd and (tType == '' or tType == 'mob' or tType == 'target') then
            if castDPSSpellCheck(spellName) then goto next_dps end
        end

        -- Cast and handle result
        local result = Cast.castWhat(spellName, castTargetID, 'dps')
        utils.debug('cast', 'combatCast [%d] %s → %s', i, spellName, result or 'nil')

        -- Restore melee if we dropped attack for a self/MA spell
        if state.combat.meleeOn and not mq.TLO.Me.Combat()
                and mq.TLO.Target.ID() == state.combat.myTargetID then
            mq.cmd('/squelch /attack on')
        end

        if result == 'CAST_COND_FAILED' then goto next_dps end
        if result == 'tcnc' then return 'tcnc' end

        state.dps.lastCast = spellName
        mq.doevents()

        if result == 'CAST_SUCCESS' then
            local castTType = mq.TLO.Spell(spellName).TargetType() or ''
            if castTType == 'Self' or castTType:find('Group') then
                printf('** %s on >> %s <<', spellName, mq.TLO.Me.CleanName() or '')
            elseif (mq.TLO.Spawn('id ' .. myID).ID() or 0) ~= 0 then
                printf('** %s on >> %s <<', spellName,
                    mq.TLO.Spawn('id ' .. castTargetID).CleanName() or '')
            end
            if not isCmd then
                local expiry = setSlotTimer(spellName, tType, daMod)
                -- Fallback: zero-duration spells use DPSInterval as their cooldown (mac:1813-1814)
                if expiry == 0 and (state.combat.dpsInterval or 0) > 0 then
                    expiry = os.clock() + state.combat.dpsInterval
                end
                state.combat.slotTimers[i] = expiry
            end
            -- Feign-death sequence (mac:1783-1788; Step 13.3)
            -- tType 'feign' casts an FD ability on self, waits for aggro to drop, then stands.
            if tType == 'feign' then
                local fdClasses = { BST=true, MNK=true, NEC=true, SHD=true }
                if fdClasses[mq.TLO.Me.Class.ShortName() or ''] then
                    -- Wait up to 3s for feign state (mac: /delay 30 Me.State==FEIGN)
                    mq.delay(3000, function()
                        return mq.TLO.Me.Feigning() or (mq.TLO.Me.Dead() or false)
                    end)
                    if not (mq.TLO.Me.Dead() or false) then
                        -- Override slot timer to 60s: mob needs time to re-path (mac: FDTimer${i} 60s)
                        state.combat.slotTimers[i] = os.clock() + 60
                        -- Wait up to 10s for feign to break naturally (mac: /delay 10s Me.State!=FEIGN)
                        mq.delay(10000, function()
                            return not mq.TLO.Me.Feigning() or (mq.TLO.Me.Dead() or false)
                        end)
                        -- Stand if still feigning and able (mac:1788)
                        if mq.TLO.Me.Feigning() and not mq.TLO.Me.Sitting() then
                            mq.cmd('/stand')
                        end
                    end
                end
            end
        elseif result == 'CAST_RESISTED' then
            printf('** %s - RESISTED', mq.TLO.Spawn('id ' .. castTargetID).CleanName() or '')
        end

        -- After-cast target-switch check (mac:1860-1867; Step 13.4)
        -- Re-query the group assist target; if MA switched mobs mid-rotation, update and restart.
        if state.combat.targetSwitchingOn then
            local newID = mq.TLO.Me.GroupAssistTarget.ID() or 0
            if (newID ~= 0 and newID ~= myID) or myID == 0 then
                if newID ~= 0 then
                    state.combat.myTargetID   = newID
                    state.combat.myTargetName = mq.TLO.Spawn('id ' .. newID).CleanName() or ''
                end
                if state.session.iAmMA then
                    return          -- MA: outer fight loop restarts combatCast from slot 1
                elseif state.combat.meleeOn and not mq.TLO.Me.Combat() then
                    return 'tcnc'   -- non-MA: out of combat, signal restart (mac:1865-1867)
                end
            end
        end

        ::next_dps::
    end

    mashButtons()
end

-- ─── Burn sequence (mac:11770) ────────────────────────────────────────────────
-- NOTE: debuffCast / Cast.doDebuffStuff moved to modules/debuff.lua (M14.3)

function Cast.doBurn()
    -- Guards (mac:11771-11773)
    if mq.TLO.Me.Hovering() then return end
    if (state.movement.campZone or 0) ~= 0
       and (mq.TLO.Zone.ID() or 0) ~= state.movement.campZone then return end
    if not state.combat.burnOn then
        printf('Leaving Burn. Burn is turned Off.')
        return
    end

    -- Announce on first activation; BroadCast deferred M9 (mac:11782)
    if not state.combat.burnActive then
        mq.cmd('/echo BURN ACTIVATED => Autobots Transform <=')
    end

    -- Tribute (mac:11783-11787)
    if state.combat.useTribute and not mq.TLO.Me.TributeActive() then
        mq.cmd('/squelch /tribute personal on')
        mq.cmd('/squelch /trophy personal on')
        state.timers.tribute = os.clock() + 570
    end

    -- Iterate burn array (mac:11788-11825)
    for i, entry in ipairs(state.combat.burnArray) do
        if mq.TLO.Me.Hovering() then break end

        local parts = {}
        for p in (entry .. '|'):gmatch('([^|]*)|') do parts[#parts + 1] = p end
        local spellName  = parts[1] or 'null'
        local targetType = parts[2] or 'Mob'
        local condNo3    = tonumber(parts[3]) or 0  -- >0: skip entry if false; <0: abort burn if false

        if spellName == 'null' or spellName == '' then goto next_burn end

        -- Resolve target ID (mac:11799-11812)
        local tType = targetType:lower()
        local burnTargetID
        if tType == 'me' then
            burnTargetID = mq.TLO.Me.ID() or 0
        elseif tType == 'ma' then
            burnTargetID = mq.TLO.Spawn('=' .. state.session.mainAssist).ID() or 0
        elseif tType == 'pet' then
            burnTargetID = mq.TLO.Me.Pet.ID() or 0
        else
            burnTargetID = state.combat.myTargetID
        end

        if condNo3 ~= 0 and _cond then
            if not _cond.eval(math.abs(condNo3)) then
                if condNo3 < 0 then return end  -- abortFlag: abort entire burn
                goto next_burn                  -- normal skip
            end
        end

        local result = Cast.castWhat(spellName, burnTargetID, 'burn')

        if result == 'CAST_SUCCESS' then
            printf('Casting >> BURN%d:%s', i, spellName)
            if not state.session.iAmABard then
                local deadline = os.clock() + 10
                while os.clock() < deadline
                      and (mq.TLO.Me.Casting.ID() or 0) ~= 0
                      and mq.TLO.Window('CastingWindow').Open() do
                    mq.delay(50)
                end
            end
        end

        ::next_burn::
    end

    state.combat.burnActive = true
end

return Cast
