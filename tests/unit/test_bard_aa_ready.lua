-- tests/unit/test_bard_aa_ready.lua
-- A bard's castWhat sends an owned AA to castAA even while it's on cooldown.
-- castAA must check readiness before its direct path (Regenother, Buffs, ...)
-- too: it used to stop the medley, fire /alt act and report CAST_SUCCESS, so a
-- |Endgroup Rallying Call on cooldown printed "Casting Rallying Call on X for
-- Endurance." and stopped/restarted the medley on every buff pass.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_bard_aa_ready')

    package.loaded['modules.cast'] = nil
    local Cast = require('modules.cast')

    local aaReady = false
    local function seed()
        MockMQ.reset()
        local none = function() return function() return nil end end
        MockMQ.set('TLO.Spell', function()
            return {
                TargetType = function() return 'Self' end,
                CastTime   = function() return 0 end,
                SpellType  = function() return 'Beneficial' end,
            }
        end)
        MockMQ.set('TLO.Me.AltAbility', function()
            return { ID = function() return 101 end, Spell = { CastTime = function() return 0 end } }
        end)
        MockMQ.set('TLO.Me.AltAbilityReady', function() return function() return aaReady end end)
        MockMQ.set('TLO.Me.CombatAbility', none)
        MockMQ.set('TLO.Me.CombatAbilityReady', none)
        MockMQ.set('TLO.Me.AbilityReady', none)
        MockMQ.set('TLO.Me.ItemReady', none)
        MockMQ.set('TLO.Me.Skill', none)
        MockMQ.set('TLO.Me.Book', none)
        MockMQ.set('TLO.Me.Gem', none)
        MockMQ.set('TLO.FindItem', function() return { ID = function() return nil end } end)
        MockMQ.set('TLO.InvSlot', function() return { Item = { Name = function() return nil end } } end)
        local noBuff = function() return { ID = function() return nil end } end
        MockMQ.set('TLO.Me.Buff', noBuff)  -- Buffs sender: self-buff check
        MockMQ.set('TLO.Me.Song', noBuff)
        MockMQ.set('TLO.Me.Invis', false)
        MockMQ.set('TLO.Me.Moving', false)
    end

    local state = { session = { iAmABard = true }, cast = {}, buffs = {} }
    Cast.init(state, {
        debug           = function() end,
        resolveCastRank = function(n) return n end,
        pullAggroID     = function() return 0 end,
    })
    local calls = {}
    Cast.setBard({
        pauseMedley  = function() calls[#calls + 1] = 'pause' end,
        resumeMedley = function() calls[#calls + 1] = 'resume' end,
        queueCast    = function() calls[#calls + 1] = 'queue'; return 'CAST_SUCCESS' end,
    })
    local function has(name)
        for _, c in ipairs(calls) do if c == name then return true end end
        return false
    end

    -- Direct-cast sender (BARD_DIRECT_CAST) with the AA on cooldown.
    seed()
    calls = {}
    local r = Cast.castWhat('Rallying Call', 77, 'Regenother')
    TH.assert_eq(r, 'CAST_RECOVER', 'Regenother, AA on cooldown: CAST_RECOVER, not CAST_SUCCESS')
    TH.assert_false(has('pause'), 'Regenother, AA on cooldown: medley not stopped')
    TH.assert_false(MockMQ.cmdMatched('^/alt act'), 'Regenother, AA on cooldown: no /alt act')

    -- Another direct sender: a Buffs entry.
    seed()
    calls = {}
    r = Cast.castWhat('Rallying Call', 0, 'Buffs')
    TH.assert_eq(r, 'CAST_RECOVER', 'Buffs, AA on cooldown: CAST_RECOVER')
    TH.assert_false(has('pause'), 'Buffs, AA on cooldown: medley not stopped')

    -- Queued sender (combat): unchanged, not queued while on cooldown.
    seed()
    calls = {}
    r = Cast.castWhat('Rallying Call', 0, 'combat')
    TH.assert_eq(r, 'CAST_RECOVER', 'combat, AA on cooldown: CAST_RECOVER')
    TH.assert_false(has('queue'), 'combat, AA on cooldown: not queued')

    -- Ready AA on a queued sender still goes to the medley queue.
    seed()
    aaReady = true
    calls = {}
    r = Cast.castWhat('Rallying Call', 0, 'combat')
    TH.assert_true(has('queue'), 'combat, AA ready: queued through MQ2Medley')
    TH.assert_eq(r, 'CAST_SUCCESS', 'combat, AA ready: queue result returned')

    package.loaded['modules.cast'] = nil
end

return M
