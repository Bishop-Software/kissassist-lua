-- tests/unit/test_camp_toggle.lua
-- Movement modes (control API phase 2, #362): Control.setMode (manual / camp /
-- chase, group and others), the /kactl mode parser and command, the mac's camp
-- and chase commands over it, the group messages a box receives, the DanNet
-- relay to .mac boxes, and ${KissAssist.Mode}.
local M = {}

local function fakeConfig()
    return { get = function() end, set = function() end, save = function() end }
end

local function newState()
    return {
        session  = { chaseAssist = false, mainAssist = 'Tank', danNetOn = false },
        movement = { returnToCamp = false, campX = 0, campY = 0, campZ = 0, campZoneName = '', whoToChase = '' },
        pull     = { mapSet = true },
    }
end

function M.run(TH, MockMQ)
    TH.setSuite('test_camp_toggle')
    MockMQ.reset()
    MockMQ.set('TLO.Me.CleanName', 'Box')
    MockMQ.set('TLO.Me.X', 10)
    MockMQ.set('TLO.Me.Y', 20)
    MockMQ.set('TLO.Me.FloorZ', 5)
    MockMQ.set('TLO.Zone.ID', 7)
    MockMQ.set('TLO.Zone.ShortName', 'zone')

    package.loaded['modules.control'] = nil
    local Control = require('modules.control')
    local state = newState()
    local sent = {}
    local comms = { broadcast = function(t, d) sent[#sent + 1] = { t = t, d = d } end }
    Control.init(state, fakeConfig(), comms)
    local mv, ses = state.movement, state.session
    local function lastSent() return sent[#sent] and sent[#sent].t end

    -- ── setMode ─────────────────────────────────────────────────────────────
    TH.assert_eq(Control.mode(), 'manual', 'starts in manual')

    ses.chaseAssist = true
    local ok = Control.setMode('camp', { here = true, group = true })
    TH.assert_true(ok, 'camp here group: ok')
    TH.assert_true(mv.returnToCamp and not ses.chaseAssist, 'camp here: camp on, chase off')
    TH.assert_true(mv.campX == 10 and mv.campY == 20 and mv.campZone == 7, 'camp here: spot at this toon')
    TH.assert_false(state.pull.mapSet, 'camp here: map repainted')
    TH.assert_eq(lastSent(), 'CAMP', 'camp here group: CAMP broadcast')
    TH.assert_true(sent[#sent].d.x == 10 and sent[#sent].d.y == 20, 'CAMP carries the spot')
    TH.assert_eq(Control.mode(), 'camp', 'mode camp')

    local n = #sent
    Control.setMode('manual')
    TH.assert_false(mv.returnToCamp, 'manual: camp off')
    TH.assert_eq(mv.campX, 10, 'manual: camp spot kept')
    TH.assert_eq(#sent, n, 'manual alone: nothing broadcast')
    TH.assert_eq(Control.mode(), 'manual', 'mode manual')

    ses.chaseAssist = true
    Control.setMode('camp', { resume = true })
    TH.assert_true(mv.returnToCamp and not ses.chaseAssist, 'camp resume: camp on, chase off')
    TH.assert_eq(mv.campX, 10, 'camp resume: same spot')

    Control.setMode('camp', { resume = true, group = true })
    TH.assert_eq(lastSent(), 'CAMPON', 'camp resume group: CAMPON broadcast')

    Control.setMode('manual', { clear = true, group = true })
    TH.assert_true(not mv.returnToCamp and mv.campX == 0 and mv.campY == 0, 'manual clear: camp off, spot cleared')
    TH.assert_eq(lastSent(), 'CAMPOFF', 'manual clear group: CAMPOFF broadcast')

    local msg
    ok, msg = Control.setMode('camp', { resume = true })
    TH.assert_true(not ok and msg == 'nocamp', 'camp resume with no camp: nocamp')
    TH.assert_false(mv.returnToCamp, 'camp resume with no camp: stays off')

    mv.returnToCamp = true
    Control.setMode('chase', { who = 'Leader' })
    TH.assert_true(ses.chaseAssist and not mv.returnToCamp, 'chase: chase on, camp off')
    TH.assert_eq(mv.whoToChase, 'Leader', 'chase: target set')
    TH.assert_eq(Control.mode(), 'chase', 'mode chase')
    Control.setMode('chase')
    TH.assert_eq(mv.whoToChase, 'Leader', 'chase with no name: target kept')

    ok, msg = Control.setMode('chase', { others = true })
    TH.assert_true(not ok and msg == 'nowho', 'chase others with no name: nowho')
    ok, msg = Control.setMode('dance')
    TH.assert_true(not ok and msg == 'badmode', 'unknown mode: badmode')

    -- others: only the group changes, this toon is left as it is
    ses.chaseAssist, mv.returnToCamp = false, true
    Control.setMode('manual', { others = true })
    TH.assert_true(mv.returnToCamp, 'manual others: this toon unchanged')
    TH.assert_eq(lastSent(), 'STAY', 'manual others: STAY broadcast')
    Control.setMode('chase', { who = 'Box', others = true })
    TH.assert_true(mv.returnToCamp and not ses.chaseAssist, 'chase others: this toon unchanged')
    TH.assert_eq(lastSent(), 'CHASE', 'chase others: CHASE broadcast')
    TH.assert_eq(sent[#sent].d.who, 'Box', 'CHASE names who to chase')

    -- ── /kactl mode parser ──────────────────────────────────────────────────
    local mode, opts = Control.parseMode({ 'camp', 'here', 'group' })
    TH.assert_true(mode == 'camp' and opts.here and opts.group, 'parse: camp here group')
    mode, opts = Control.parseMode({ 'CAMP', 'Resume' })
    TH.assert_true(mode == 'camp' and opts.resume, 'parse: case-insensitive')
    mode, opts = Control.parseMode({ 'chase', 'me', 'others' })
    TH.assert_true(mode == 'chase' and opts.who == 'Box' and opts.others, 'parse: chase me others')
    mode, opts = Control.parseMode({ 'chase', 'Leader' })
    TH.assert_true(mode == 'chase' and opts.who == 'Leader', 'parse: chase <name>')
    mode, opts = Control.parseMode({ 'manual', 'clear', 'group' })
    TH.assert_true(mode == 'manual' and opts.clear and opts.group, 'parse: manual clear group')
    local _, _, verbose = Control.parseMode({ 'manual', 'verbose' })
    TH.assert_true(verbose, 'parse: verbose')
    TH.assert_nil(Control.parseMode({ 'dance' }), 'parse: unknown mode rejected')
    TH.assert_nil(Control.parseMode({}), 'parse: no mode rejected')
    TH.assert_nil(Control.parseMode({ 'manual', 'here' }), 'parse: here only with camp')
    TH.assert_nil(Control.parseMode({ 'camp', 'clear' }), 'parse: clear only with manual')
    TH.assert_nil(Control.parseMode({ 'camp', 'here', 'resume' }), 'parse: here and resume rejected')
    TH.assert_nil(Control.parseMode({ 'manual', 'group', 'others' }), 'parse: group and others rejected')
    TH.assert_nil(Control.parseMode({ 'camp', 'Leader' }), 'parse: a name only with chase')
    TH.assert_nil(Control.parseMode({ 'chase', 'Leader', 'Other' }), 'parse: one name only')

    ses.chaseAssist, mv.returnToCamp = false, false
    TH.assert_true(Control.command({ 'mode', 'camp', 'here' }), '/kactl mode camp here: ok')
    TH.assert_true(mv.returnToCamp, '/kactl mode camp here: camping')
    TH.assert_false(Control.command({ 'mode', 'camp', 'clear' }), '/kactl bad args: fails')
    TH.assert_true(mv.returnToCamp, '/kactl bad args: nothing changed')
    TH.assert_false(Control.command({ 'dance' }), '/kactl unknown verb: fails')

    -- ── the mac's camp/chase commands ───────────────────────────────────────
    local saved = { aliases = package.loaded['modules.aliases'], bind = MockMQ.bind }
    package.loaded['modules.aliases'] = { sync = function() return 0, 0 end }
    package.loaded['modules.binds'] = nil
    local bound = {}
    MockMQ.bind = function(cmd, fn) bound[cmd] = fn end
    local Binds = require('modules.binds')
    Binds.register(state, {}, {}, {}, fakeConfig(), comms)

    TH.assert_nil(bound['/campon'], '/campon is gone (now /kactl mode camp resume)')
    TH.assert_nil(bound['/campoff'], '/campoff is gone (now /kactl mode manual)')
    TH.assert_not_nil(bound['/kactl'], '/kactl is bound')

    mv.campX, mv.campY, mv.returnToCamp, ses.chaseAssist = 0, 0, false, true
    bound['/makecamphere']()
    TH.assert_true(mv.returnToCamp and not ses.chaseAssist and mv.campX == 10, '/makecamphere: camp here')
    TH.assert_eq(lastSent(), 'CAMP', '/makecamphere: CAMP broadcast')

    bound['/stayhere']()
    TH.assert_true(mv.returnToCamp, '/stayhere: this toon unchanged (mac:11361)')
    TH.assert_eq(lastSent(), 'STAY', '/stayhere: STAY broadcast')

    bound['/chaseme']()
    TH.assert_false(ses.chaseAssist, '/chaseme: this toon does not chase itself')
    TH.assert_true(lastSent() == 'CHASE' and sent[#sent].d.who == 'Box', '/chaseme: CHASE me broadcast')

    bound['/trackmedown']('Leader')
    TH.assert_true(ses.chaseAssist and mv.whoToChase == 'Leader' and not mv.returnToCamp, '/trackmedown <name>: chase')
    bound['/trackmedown']()
    TH.assert_true(not ses.chaseAssist and mv.whoToChase == '', '/trackmedown: chase off')

    bound['/kactl']('mode', 'chase', 'Leader')
    TH.assert_true(ses.chaseAssist and mv.whoToChase == 'Leader', '/kactl mode chase Leader (bound)')

    MockMQ.bind = saved.bind
    package.loaded['modules.aliases'] = saved.aliases
    package.loaded['modules.binds']   = nil

    -- ── group messages received ─────────────────────────────────────────────
    local onMessage, actorSent = nil, {}
    package.loaded['actors'] = {
        register = function(_, cb)
            onMessage = cb
            return { send = function(_, m) actorSent[#actorSent + 1] = m end }
        end,
    }
    package.loaded['modules.comms'] = nil
    local Comms = require('modules.comms')
    local rstate = newState()
    rstate.movement.campX, rstate.movement.campY = 1, 2
    Control.init(rstate, fakeConfig(), nil)
    local rmv, rses = rstate.movement, rstate.session
    local members = { Leader = 2 }
    MockMQ.set('TLO.Group.Member', function(nm) return { Index = function() return members[nm] end } end)
    Comms.init(rstate, { debug = function() end })
    TH.assert_true(onMessage ~= nil, 'comms mailbox registered')
    local function recv(t, d)
        d = d or {}
        d.msgType, d.from = t, d.from or 'Leader'
        if onMessage then onMessage({ content = d }) end
    end

    recv('CAMP', { x = 50, y = 60, z = 1, zone = 7, zoneName = 'zone' })
    TH.assert_true(rmv.returnToCamp and rmv.campX == 50 and rmv.campY == 60, 'CAMP: camp at the sender\'s spot')

    recv('STAY')
    TH.assert_true(not rmv.returnToCamp and not rses.chaseAssist, 'STAY: stop where we are (mac /waithere)')
    TH.assert_eq(rmv.campX, 50, 'STAY: camp spot kept')

    recv('CAMPON')
    TH.assert_true(rmv.returnToCamp, 'CAMPON: back to our own camp')

    recv('CHASE', { who = 'Leader' })
    TH.assert_true(rses.chaseAssist and rmv.whoToChase == 'Leader', 'CHASE: chase the named toon')
    TH.assert_false(rmv.returnToCamp, 'CHASE: camp return off')

    recv('CAMPOFF', { from = 'Stranger' })
    TH.assert_true(rmv.campX == 50, 'CAMPOFF from outside the group: ignored')
    recv('CAMPOFF')
    TH.assert_true(not rmv.returnToCamp and rmv.campX == 0 and rmv.campY == 0, 'CAMPOFF from the group: spot cleared')

    -- DanNet relay to .mac boxes: what the mac's own commands send
    rses.danNetOn = true
    MockMQ.reset()
    MockMQ.set('TLO.Me.CleanName', 'Box')
    Comms.broadcast('STAY', {})
    TH.assert_true(MockMQ.cmdCalled('/dgge /waithere'), 'STAY relayed to .mac boxes as /waithere')
    Comms.broadcast('CHASE', { who = 'Box' })
    TH.assert_true(MockMQ.cmdCalled('/dgge /chase on Box'), 'CHASE relayed as /chase on <who>')
    TH.assert_false(MockMQ.cmdCalled('/dgge /stayhere'), 'no /stayhere relay (it would be broadcast again)')

    package.loaded['actors'] = nil
    package.loaded['modules.comms'] = nil

    -- ── ${KissAssist.Mode} ──────────────────────────────────────────────────
    package.loaded['modules.tlo'] = nil
    local Tlo = require('modules.tlo')
    local tstate = newState()
    Tlo.init(tstate)
    TH.assert_eq(select(2, Tlo.members.Mode()), 'manual', 'TLO Mode manual')
    tstate.movement.returnToCamp = true
    TH.assert_eq(select(2, Tlo.members.Mode()), 'camp', 'TLO Mode camp')
    tstate.session.chaseAssist = true
    TH.assert_eq(select(2, Tlo.members.Mode()), 'chase', 'TLO Mode chase')
    package.loaded['modules.tlo'] = nil

    package.loaded['modules.control'] = nil
end

return M
