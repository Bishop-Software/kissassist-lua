-- tests/unit/test_pull_ready.lua
-- Pull.pullAbilityReady (#227): the .mac only searches for a mob when the
-- PullWith method is ready (mac:418).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_ready')
    local Pull = require('modules.pull')

    -- ready = { spell=bool, aa=bool, disc=bool, item=bool, ranged=bool }
    local function setReady(ready)
        MockMQ.reset()
        local function member(flag)
            return function() return function() return flag or false end end
        end
        MockMQ.set('TLO.Me.SpellReady',         member(ready.spell))
        MockMQ.set('TLO.Me.AltAbilityReady',    member(ready.aa))
        MockMQ.set('TLO.Me.CombatAbilityReady', member(ready.disc))
        MockMQ.set('TLO.Me.ItemReady',          member(ready.item))
        MockMQ.set('TLO.Me.RangedReady',        ready.ranged or false)
    end

    -- Melee and Pet are always ready, any case.
    setReady({})
    TH.assert_true(Pull.pullAbilityReady('Melee'), 'Melee always ready')
    TH.assert_true(Pull.pullAbilityReady('melee'), 'melee (lowercase) always ready')
    TH.assert_true(Pull.pullAbilityReady('Pet'),   'Pet always ready')

    -- Ranged follows RangedReady.
    setReady({ ranged = false })
    TH.assert_false(Pull.pullAbilityReady('Ranged'), 'Ranged not ready')
    setReady({ ranged = true })
    TH.assert_true(Pull.pullAbilityReady('ranged'), 'Ranged ready')
    -- A ready spell does not make Ranged ready.
    setReady({ spell = true, ranged = false })
    TH.assert_false(Pull.pullAbilityReady('Ranged'), 'Ranged ignores spell readiness')

    -- Named methods: any of spell / AA / disc / item ready.
    setReady({})
    TH.assert_false(Pull.pullAbilityReady('Snare'), 'named: nothing ready')
    setReady({ spell = true })
    TH.assert_true(Pull.pullAbilityReady('Snare'), 'named: spell ready')
    setReady({ aa = true })
    TH.assert_true(Pull.pullAbilityReady('Snare'), 'named: AA ready')
    setReady({ disc = true })
    TH.assert_true(Pull.pullAbilityReady('Snare'), 'named: combat ability ready')
    setReady({ item = true })
    TH.assert_true(Pull.pullAbilityReady('Snare'), 'named: item ready')

    -- Unknown names: every member returns nil, treated as not ready.
    MockMQ.reset()
    local nilMember = function() return function() return nil end end
    for _, m in ipairs({ 'SpellReady', 'AltAbilityReady', 'CombatAbilityReady', 'ItemReady' }) do
        MockMQ.set('TLO.Me.' .. m, nilMember)
    end
    TH.assert_false(Pull.pullAbilityReady('Nonexistent'), 'named: nil results -> not ready')

    package.loaded['modules.pull'] = nil
end

return M
