-- tests/unit/test_pull_locs.lua
-- #69: PullLocs no-pull areas - per zone 'Y,X|Range' entries PullLocs1-5 in
-- KissAssist_Info.ini (mac:14979); mobs inside one are not pulled (mac:9494).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_locs')
    MockMQ.reset()
    local Pull = require('modules.pull')

    local zoneIni = {}
    local state = {
        session  = { role = 'puller', infoFileName = 'Info.ini', zoneName = 'zone1' },
        pull     = {},
        timers   = {},
        heal     = { medOn = false },
        combat   = { aggroTargetID = '' },
        pet      = { attackRange = 100 },
        movement = { campX = 0, campY = 0, campRadius = 30 },
    }
    local utils = {
        debug      = function() end,
        zoneIniGet = function(_, _, key) return zoneIni[key] end,
    }
    Pull.init(state, utils)
    local p = state.pull

    -- parsePullLoc
    local a = Pull.parsePullLoc('120,-450|60')
    TH.assert_true(a ~= nil and a.y == 120 and a.x == -450 and a.range == 60, 'parses Y,X|Range')
    a = Pull.parsePullLoc(' 1.5 , 2.5 | 10 ')
    TH.assert_true(a ~= nil and a.y == 1.5 and a.x == 2.5, 'allows spaces and decimals')
    TH.assert_nil(Pull.parsePullLoc('120,-450'), 'no range: rejected')
    TH.assert_nil(Pull.parsePullLoc('120,-450|0'), 'zero range: rejected')
    TH.assert_nil(Pull.parsePullLoc('0'), "'0' is empty")
    TH.assert_nil(Pull.parsePullLoc('null'), "'null' is empty")
    TH.assert_nil(Pull.parsePullLoc(nil), 'nil is empty')

    -- loadZoneLists reads PullLocs1-5, skipping empty and malformed slots
    zoneIni = { PullLocs1 = '100,100|50', PullLocs2 = 'null', PullLocs3 = 'junk', PullLocs4 = '-200,300|25' }
    Pull.loadZoneLists()
    TH.assert_eq(p.pullLocsRaw[1], '100,100|50', 'slot 1 loaded')
    TH.assert_eq(p.pullLocsRaw[2], '', "'null' slot is empty")
    TH.assert_eq(p.pullLocsRaw[3], '', 'malformed slot is empty')
    TH.assert_eq(p.pullLocsRaw[4], '-200,300|25', 'slot 4 loaded past a gap')
    TH.assert_eq(#p.pullLocAreas, 2, 'two areas in use')

    -- inPullLocArea uses each entry's own range (Y first, then X)
    TH.assert_true(Pull.inPullLocArea(130, 100), 'inside area 1 (30 away, range 50)')
    TH.assert_false(Pull.inPullLocArea(160, 100), 'outside area 1 (60 away)')
    TH.assert_true(Pull.inPullLocArea(-200, 320), 'inside area 4 (20 away, range 25)')
    TH.assert_false(Pull.inPullLocArea(-200, 330), 'outside area 4 (30 away)')
    TH.assert_false(Pull.inPullLocArea(300, -200), 'Y and X are not swapped')

    -- setPullLoc saves to the zone section and updates the areas
    MockMQ.reset()
    TH.assert_true(Pull.setPullLoc(2, ' 0,0|10 '), 'valid entry accepted')
    TH.assert_true(MockMQ.cmdCalled('/ini "Info.ini" "zone1" "PullLocs2" "0,0|10"'), 'saved to the zone section')
    TH.assert_true(Pull.inPullLocArea(5, 5), 'new area takes effect')
    TH.assert_false(Pull.setPullLoc(2, '1,2'), 'invalid entry rejected')
    TH.assert_eq(p.pullLocsRaw[2], '0,0|10', 'rejected entry leaves the slot alone')
    MockMQ.reset()
    TH.assert_true(Pull.setPullLoc(2, ''), 'clearing accepted')
    TH.assert_true(MockMQ.cmdCalled('/ini "Info.ini" "zone1" "PullLocs2" "null"'), "cleared slot saved as 'null'")
    TH.assert_false(Pull.inPullLocArea(5, 5), 'cleared area no longer used')

    package.loaded['modules.pull'] = nil
end

return M
