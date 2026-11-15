-- tests/unit/test_pull_move.lua
-- Pull.pickMoveUse (#264): choose nav when MQ2Nav has a mesh for the zone,
-- else los, as the .mac's startup block does (mac:16498). PullMoveUse is not
-- read from the config.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_move')
    MockMQ.reset()
    local Pull = require('modules.pull')

    local state = {
        session = { role = 'pullertank', infoFileName = '', zoneName = '', pullPath = 'null' },
        pull    = { moveUse = '' },
        timers  = {},
        heal    = { medOn = false },
        combat  = { aggroTargetID = '' },
        pet     = { attackRange = 100 },
    }

    -- navLoaded: MQ2Nav plugin loaded; mesh: Navigation.MeshLoaded
    local function setNav(navLoaded, mesh)
        MockMQ.reset()
        MockMQ.set('TLO.Plugin', function(name)
            return { IsLoaded = function() return name == 'MQ2Nav' and navLoaded end }
        end)
        MockMQ.set('TLO.Navigation.MeshLoaded', mesh)
    end

    -- Init with no MQ2Nav mocked: los.
    Pull.init(state, { debug = function() end, zoneIniGet = function() return nil end })
    local p = state.pull
    TH.assert_eq(p.moveUse, 'los', 'init without MQ2Nav: los')

    setNav(true, true)
    TH.assert_eq(Pull.pickMoveUse(), 'nav', 'MQ2Nav with a mesh: nav')
    TH.assert_eq(p.moveUse, 'nav', 'state.pull.moveUse set to nav')

    setNav(true, false)
    TH.assert_eq(Pull.pickMoveUse(), 'los', 'MQ2Nav without a mesh: los')

    setNav(false, true)
    TH.assert_eq(Pull.pickMoveUse(), 'los', 'MQ2Nav not loaded: los')

    -- Non-puller roles use the same choice for movement.
    state.session.role = 'assist'
    setNav(true, true)
    TH.assert_eq(Pull.pickMoveUse(), 'nav', 'assist role with a mesh: nav')
    state.session.role = 'pullertank'

    -- advpath only when a path is loaded (puller roles).
    p.pathWpCount, state.session.pullPath = 3, 'camp1'
    setNav(true, true)
    TH.assert_eq(Pull.pickMoveUse(), 'advpath', 'puller with a loaded path: advpath')
    state.session.role = 'assist'
    TH.assert_eq(Pull.pickMoveUse(), 'nav', 'non-puller ignores the path')
    state.session.role = 'pullertank'
    p.pathWpCount, state.session.pullPath = 0, 'null'

    -- Zoning (onlyIfChanged): re-picks, e.g. into a zone with no mesh.
    setNav(true, true)
    Pull.pickMoveUse()
    setNav(true, false)
    TH.assert_eq(Pull.pickMoveUse(true), 'los', 'zoned into a zone without a mesh: los')
    setNav(true, true)
    TH.assert_eq(Pull.pickMoveUse(true), 'nav', 'zoned back into a meshed zone: nav')

    package.loaded['modules.pull'] = nil
end

return M
