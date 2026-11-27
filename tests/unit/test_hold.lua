-- tests/unit/test_hold.lua
-- /kactl hold (phase 4, #364): stay put but keep fighting. Under hold:
-- doWeMove / doWeChase don't move; zAxisCheck doesn't press down; checkStick
-- still attacks but doesn't close the gap or stick (and with MQ2Melee uses
-- /attack on, not /killthis); castWhat doesn't stop a movement for a spell with
-- a cast time (it returns CAST_NO_RESULT and is tried again later).
-- (Pull.holdReasons is in test_pull_hold, CantSee.respond in test_cantsee.)
local M = {}

local function sentMatching(MockMQ, pat)
    for _, c in ipairs(MockMQ.calls()) do
        if c:find(pat) then return true end
    end
    return false
end

function M.run(TH, MockMQ)
    TH.setSuite('test_hold')
    MockMQ.reset()

    -- ── movement ────────────────────────────────────────────────────────────
    local savedCfg = package.loaded['modules.config']
    package.loaded['modules.config'] = { get = function(_, _, d) return d end }
    package.loaded['modules.movement'] = nil
    local Movement = require('modules.movement')
    local state = {
        session  = { role = 'tank', paused = false, hold = true, mainAssist = 'MA', chaseAssist = true },
        combat   = { forcedTargetID = 0, myTargetID = 42, meleeDistance = 20, useMQ2Melee = false },
        movement = { returnToCamp = true },
        pull     = { moveUse = 'nav' },
    }
    Movement.init(state)
    local mv = state.movement
    mv.campX, mv.campY, mv.campZ, mv.campZone = 100, 100, 0, 1
    mv.stickHow = 'snaproll'

    local savedEvents = MockMQ.doevents
    local events = 0
    MockMQ.doevents = function() events = events + 1 end
    MockMQ.reset()
    Movement.doWeMove(1, 'test')
    TH.assert_eq(events, 0, 'doWeMove: nothing while holding (even forced)')
    Movement.doWeChase()
    TH.assert_eq(#MockMQ.calls(), 0, 'doWeChase: nothing while holding')
    MockMQ.doevents = savedEvents

    MockMQ.set('TLO.Me.Z', function() return 50 end)
    MockMQ.set('TLO.Me.FeetWet', function() return false end)
    TH.assert_false(Movement.zAxisCheck(), 'zAxisCheck: false while holding')
    TH.assert_eq(#MockMQ.calls(), 0, 'zAxisCheck: no keypress while holding')

    -- checkStick on a mob 100 away (MaxRangeTo 14)
    MockMQ.set('TLO.Spawn', function()
        return {
            ID = function() return 42 end, Y = function() return 0 end, X = function() return 100 end,
            MaxRangeTo = function() return 14 end, Distance = function() return 100 end,
            LineOfSight = function() return true end,
        }
    end)
    MockMQ.set('TLO.Me.Combat', function() return false end)
    MockMQ.set('TLO.Target.ID', function() return 42 end)
    MockMQ.set('TLO.Me.State', function() return 'STAND' end)
    MockMQ.set('TLO.Navigation.Active', function() return false end)
    Movement.checkStick(0, 1)
    TH.assert_true(MockMQ.cmdCalled('/squelch /attack on'), 'checkStick: attacks while holding')
    TH.assert_false(sentMatching(MockMQ, '^/stick') or sentMatching(MockMQ, '/nav ')
        or sentMatching(MockMQ, '/moveto '), 'checkStick: no gap-close or stick while holding')

    MockMQ.reset()
    MockMQ.set('TLO.Spawn', function()
        return { ID = function() return 42 end, MaxRangeTo = function() return 14 end,
                 Distance = function() return 100 end, Y = function() return 0 end, X = function() return 0 end }
    end)
    MockMQ.set('TLO.Me.Combat', function() return false end)
    MockMQ.set('TLO.Target.ID', function() return 42 end)
    MockMQ.set('TLO.Me.State', function() return 'STAND' end)
    state.combat.useMQ2Melee = true
    Movement.checkStick(0, 1)
    TH.assert_false(MockMQ.cmdCalled('/squelch /killthis'), 'checkStick, MQ2Melee: no /killthis while holding')
    TH.assert_true(MockMQ.cmdCalled('/squelch /attack on'), 'checkStick, MQ2Melee: /attack on instead')
    state.combat.useMQ2Melee = false

    package.loaded['modules.config'] = savedCfg
    package.loaded['modules.movement'] = nil

    -- ── castWhat: a spell with a cast time while moving ─────────────────────
    MockMQ.reset()
    local none = function() return function() return nil end end
    MockMQ.set('TLO.Spell', function()
        return {
            TargetType = function() return 'Self' end,
            CastTime   = function() return 3000 end,
            SpellType  = function() return 'Detrimental' end,
        }
    end)
    MockMQ.set('TLO.Me.AltAbility', function() return { ID = function() return nil end } end)
    MockMQ.set('TLO.Me.AltAbilityReady', none)
    MockMQ.set('TLO.Me.CombatAbility', none)
    MockMQ.set('TLO.Me.CombatAbilityReady', none)
    MockMQ.set('TLO.Me.AbilityReady', none)
    MockMQ.set('TLO.Me.ItemReady', none)
    MockMQ.set('TLO.Me.Skill', none)
    MockMQ.set('TLO.Me.Book', function() return function() return 5 end end)
    MockMQ.set('TLO.Me.Gem', function() return function() return 3 end end)
    MockMQ.set('TLO.Me.SpellReady', function() return function() return true end end)
    MockMQ.set('TLO.FindItem', function() return { ID = function() return nil end } end)
    MockMQ.set('TLO.InvSlot', function() return { Item = { Name = function() return nil end } } end)
    MockMQ.set('TLO.Me.Moving', function() return true end)
    MockMQ.set('TLO.Navigation.Active', function() return true end)

    package.loaded['modules.cast'] = nil
    local Cast = require('modules.cast')
    local cstate = { session = { iAmABard = false, hold = true }, cast = {}, buffs = {} }
    Cast.init(cstate, {
        debug           = function() end,
        resolveCastRank = function(n) return n end,
        pullAggroID     = function() return 0 end,
    })
    local r = Cast.castWhat('Long Nuke', 0, 'DPS')
    TH.assert_eq(r, 'CAST_NO_RESULT', 'castWhat while holding and moving: not cast (CAST_NO_RESULT)')
    TH.assert_false(MockMQ.cmdCalled('/squelch /nav stop'), "castWhat while holding: the nav isn't stopped")
    TH.assert_false(sentMatching(MockMQ, '/cast'), 'castWhat while holding and moving: nothing cast')
    package.loaded['modules.cast'] = nil
end

return M
