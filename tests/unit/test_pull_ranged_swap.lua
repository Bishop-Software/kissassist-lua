-- tests/unit/test_pull_ranged_swap.lua
-- Bow|Arrow pulls swap the pull bow and ammo into the ranged/ammo slots and
-- put the startup items back afterwards (mac PullWithRanged RSwitch 0 / 2).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_ranged_swap')
    MockMQ.reset()
    local Execute = require('modules.pull.execute')

    local state = {
        pull = { item = 'NULL', ammo = 'NULL' },
        misc = { origRanged = '', tempAmmo = '' },
    }
    Execute.init(state, { debug = function() end }, nil, nil, nil, {})

    local slots = { ranged = 'Shiny Wand', ammo = 'Gnomish Bolts' }
    MockMQ.set('TLO.Me.Inventory', function(slot)
        return { Name = function() return slots[slot] end }
    end)
    MockMQ.set('TLO.Cursor.ID', 0)

    -- Not a Bow|Arrow pull (no item / ammo): nothing is swapped.
    Execute.swapRangedIn()
    TH.assert_false(MockMQ.cmdMatched('/exchange'), 'no pull item: no swap')

    -- Pull bow and arrows not equipped: both are swapped in.
    state.pull.item, state.pull.ammo = 'Hunter Bow', 'Field Arrows'
    Execute.swapRangedIn()
    TH.assert_true(MockMQ.cmdCalled('/exchange "Hunter Bow" ranged'), 'bow swapped into ranged')
    TH.assert_true(MockMQ.cmdCalled('/exchange "Field Arrows" ammo'), 'arrows swapped into ammo')

    -- Already equipped: no swap.
    MockMQ.reset()
    MockMQ.set('TLO.Me.Inventory', function(slot)
        return { Name = function() return slots[slot] end }
    end)
    MockMQ.set('TLO.Cursor.ID', 0)
    slots.ranged, slots.ammo = 'Hunter Bow', 'Field Arrows'
    Execute.swapRangedIn()
    TH.assert_false(MockMQ.cmdMatched('/exchange'), 'already equipped: no swap')

    -- After the pull: the startup items go back.
    state.misc.origRanged, state.misc.tempAmmo = 'Shiny Wand', 'Gnomish Bolts'
    Execute.swapRangedBack()
    TH.assert_true(MockMQ.cmdCalled('/exchange "Shiny Wand" ranged'), 'startup ranged item swapped back')
    TH.assert_true(MockMQ.cmdCalled('/exchange "Gnomish Bolts" ammo'), 'startup ammo swapped back')
    TH.assert_false(MockMQ.cmdCalled('/autoinventory'), 'empty cursor: no autoinventory')

    -- Something on the cursor goes to the inventory first.
    MockMQ.reset()
    MockMQ.set('TLO.Me.Inventory', function(slot)
        return { Name = function() return slots[slot] end }
    end)
    MockMQ.set('TLO.Cursor.ID', 1234)
    Execute.swapRangedBack()
    TH.assert_true(MockMQ.cmdCalled('/autoinventory'), 'item on cursor: autoinventory')

    -- Nothing recorded at startup (empty slots): nothing to put back.
    MockMQ.reset()
    MockMQ.set('TLO.Me.Inventory', function(slot)
        return { Name = function() return slots[slot] end }
    end)
    MockMQ.set('TLO.Cursor.ID', 0)
    state.misc.origRanged, state.misc.tempAmmo = '', ''
    Execute.swapRangedBack()
    TH.assert_false(MockMQ.cmdMatched('/exchange'), 'nothing recorded at startup: no swap back')
end

return M
