-- tests/unit/test_memmyspells_bard.lua
-- #333 item 5: /memmyspells stops a bard's songs before memming (mac:14182
-- CastBardCheck 0) and restarts the medley afterwards (mac:14221-14224). With
-- MQ2Medley: Bard.pauseMedley() / Bard.resumeMedley(). Non-bards are untouched.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_memmyspells_bard')

    local saved = {
        aliases = package.loaded['modules.aliases'],
        bard    = package.loaded['modules.bard'],
        bind    = MockMQ.bind,
    }
    local calls = {}
    package.loaded['modules.aliases'] = { sync = function() return 0, 0 end }
    package.loaded['modules.bard'] = {
        pauseMedley  = function() calls[#calls + 1] = 'pause' end,
        resumeMedley = function() calls[#calls + 1] = 'resume' end,
    }
    package.loaded['modules.binds'] = nil
    local bound = {}
    MockMQ.bind = function(cmd, fn) bound[cmd] = fn end
    local Binds = require('modules.binds')

    local state = {
        session  = { iAmABard = true },
        cast     = { gemSlots = 1, miscGem = 0, miscGemLW = 0 },
        movement = {},
    }
    local config = {
        get  = function(section, key) if section == 'Spells' and key == 'Gems' then return { 'Selo' } end end,
        set  = function() end,
        save = function() end,
    }
    Binds.register(state, {}, {}, {}, config, {})
    local mem = bound['/memmyspells']
    TH.assert_true(mem ~= nil, '/memmyspells is bound')

    MockMQ.set('TLO.Spell', function(n) return { RankName = function() return n end } end)
    MockMQ.set('TLO.Me.Book', function() return function() return nil end end)  -- not in the book: no memming

    mem()
    TH.assert_eq(table.concat(calls, ','), 'pause,resume', 'bard: medley stopped before memming, restarted after')

    calls = {}
    state.session.iAmABard = false
    mem()
    TH.assert_eq(#calls, 0, 'non-bard: medley untouched')

    MockMQ.bind = saved.bind
    package.loaded['modules.aliases'] = saved.aliases
    package.loaded['modules.bard']    = saved.bard
    package.loaded['modules.binds']   = nil
end

return M
