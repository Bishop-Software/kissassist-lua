-- tests/unit/test_camp_toggle.lua
-- Status row camp toggles: /campoff (this toon, keeps the camp spot), /campon
-- (back to that camp), /campoff group (break camp for the group: CAMPOFF over
-- comms clears the spot on every kissassist-lua box in the group/raid).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_camp_toggle')

    -- ---- binds ----
    local saved = { aliases = package.loaded['modules.aliases'], bind = MockMQ.bind }
    package.loaded['modules.aliases'] = { sync = function() return 0, 0 end }
    package.loaded['modules.binds'] = nil
    local bound = {}
    MockMQ.bind = function(cmd, fn) bound[cmd] = fn end
    local Binds = require('modules.binds')

    local state = {
        session  = { chaseAssist = true },
        movement = { returnToCamp = true, campX = 10, campY = 20, campZ = 5, campZoneName = 'zone' },
    }
    local sent = {}
    local comms = { broadcast = function(t, d) sent[#sent + 1] = { t = t, d = d } end }
    MockMQ.reset()
    Binds.register(state, {}, {}, {}, { get = function() end, set = function() end, save = function() end }, comms)
    local mv = state.movement
    TH.assert_true(bound['/campon'] ~= nil, '/campon is bound')

    bound['/campoff']()
    TH.assert_false(mv.returnToCamp, '/campoff: stops returning to camp')
    TH.assert_eq(mv.campX, 10, '/campoff: camp spot kept')
    TH.assert_eq(#sent, 0, '/campoff: this toon only, nothing broadcast')

    bound['/campon']()
    TH.assert_true(mv.returnToCamp, '/campon: back to camp')
    TH.assert_eq(mv.campX, 10, '/campon: same camp spot')
    TH.assert_false(state.session.chaseAssist, '/campon: chase off')

    bound['/campoff']('group')
    TH.assert_false(mv.returnToCamp, '/campoff group: camp off')
    TH.assert_true(mv.campX == 0 and mv.campY == 0, '/campoff group: camp spot cleared')
    TH.assert_eq(sent[1] and sent[1].t, 'CAMPOFF', '/campoff group: CAMPOFF broadcast')

    bound['/campon']()
    TH.assert_false(mv.returnToCamp, '/campon with no camp: stays off')

    MockMQ.bind = saved.bind
    package.loaded['modules.aliases'] = saved.aliases
    package.loaded['modules.binds']   = nil

    -- ---- CAMPOFF received ----
    local onMessage
    package.loaded['actors'] = {
        register = function(_, cb) onMessage = cb; return { send = function() end } end,
    }
    package.loaded['modules.comms'] = nil
    local Comms = require('modules.comms')
    local rstate = {
        session  = { danNetOn = false, chaseAssist = false },
        movement = { returnToCamp = true, campX = 1, campY = 2, campZ = 3, campZoneName = 'zone' },
    }
    MockMQ.reset()
    local members = { Leader = 2 }
    MockMQ.set('TLO.Me.CleanName', 'Box')
    MockMQ.set('TLO.Group.Member', function(n) return { Index = function() return members[n] end } end)
    Comms.init(rstate, { debug = function() end })
    TH.assert_true(onMessage ~= nil, 'comms mailbox registered')

    onMessage({ content = { msgType = 'CAMPOFF', from = 'Stranger' } })
    TH.assert_true(rstate.movement.returnToCamp, 'CAMPOFF from outside the group: ignored')

    onMessage({ content = { msgType = 'CAMPOFF', from = 'Leader' } })
    TH.assert_false(rstate.movement.returnToCamp, 'CAMPOFF from the group: camp off')
    TH.assert_true(rstate.movement.campX == 0 and rstate.movement.campY == 0, 'CAMPOFF from the group: spot cleared')

    package.loaded['actors'] = nil
    package.loaded['modules.comms'] = nil
end

return M
