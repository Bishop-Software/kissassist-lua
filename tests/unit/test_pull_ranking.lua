-- tests/unit/test_pull_ranking.lua
-- Pull.setRanking / Pull.nameAllowed (#146): the .mac's UpdatePullRanking
-- (mac:15064) splits the zone's MobsToPull list into MobsToPullFirst (entries
-- marked with ':') and MobsToPull while pull ranking is on.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_ranking')
    MockMQ.reset()
    local Pull = require('modules.pull')

    local zoneList = 'a gnoll pup,:a gnoll shaman,*skeleton,:#Fippy Darkpaw'
    local state = {
        session = { role = 'pullertank', infoFileName = 'info.ini', zoneName = 'qeytoqrg' },
        pull    = {},
        timers  = {},
        heal    = { medOn = false },
        combat  = { aggroTargetID = '' },
        pet     = { attackRange = 100 },
    }
    local utils = {
        debug = function() end,
        zoneIniGet = function(_, _, key) if key == 'MobsToPull' then return zoneList end end,
    }
    Pull.init(state, utils)
    local p = state.pull

    -- Startup: ranking off, ':' marks stripped, everything in MobsToPull.
    TH.assert_false(p.ranking, 'ranking off at start')
    TH.assert_eq(p.mobsToPullRaw, zoneList, 'raw list kept as written')
    TH.assert_eq(p.mobsToPull, 'a gnoll pup,a gnoll shaman,*skeleton,#Fippy Darkpaw',
        'off: marks stripped, all entries in MobsToPull')
    TH.assert_eq(p.mobsToPullFirst, 'all', 'off: no priority list')
    TH.assert_true(Pull.nameAllowed('a gnoll shaman'), 'off: marked mob allowed')
    TH.assert_true(Pull.nameAllowed('a decaying skeleton'), 'off: * substring entry allowed')
    TH.assert_false(Pull.nameAllowed('a black bear'), 'off: unlisted mob rejected')

    -- On: marked entries move to MobsToPullFirst.
    TH.assert_true(Pull.setRanking(true, true), 'setRanking(true) returns on')
    TH.assert_true(p.ranking, 'ranking on')
    TH.assert_eq(p.mobsToPullFirst, 'a gnoll shaman,#Fippy Darkpaw', 'on: marked entries are first')
    TH.assert_eq(p.mobsToPull, 'a gnoll pup,*skeleton', 'on: unmarked entries stay in MobsToPull')
    TH.assert_true(Pull.nameAllowed('Fippy Darkpaw'), 'on: first-list mob allowed')
    TH.assert_true(Pull.nameAllowed('a gnoll pup'), 'on: MobsToPull mob allowed')
    TH.assert_false(Pull.nameAllowed('a black bear'), 'on: unlisted mob rejected')

    -- Off again: back to one merged list.
    TH.assert_false(Pull.setRanking(false, true), 'setRanking(false) returns off')
    TH.assert_eq(p.mobsToPullFirst, 'all', 'off again: no priority list')
    TH.assert_eq(p.mobsToPull, 'a gnoll pup,a gnoll shaman,*skeleton,#Fippy Darkpaw',
        'off again: merged list restored')

    -- Every entry marked: MobsToPull becomes 'all' (marked first, then anything).
    p.mobsToPullRaw = ':a gnoll shaman,:Fippy Darkpaw'
    Pull.setRanking(true, true)
    TH.assert_eq(p.mobsToPullFirst, 'a gnoll shaman,Fippy Darkpaw', 'all marked: first list')
    TH.assert_eq(p.mobsToPull, 'all', 'all marked: MobsToPull is all')
    TH.assert_true(Pull.nameAllowed('a black bear'), 'all marked: any mob allowed after the first list')

    -- No marks: ranking refuses to turn on.
    p.mobsToPullRaw = 'a gnoll pup,a gnoll shaman'
    TH.assert_false(Pull.setRanking(true, true), 'no marks: ranking stays off')
    TH.assert_eq(p.mobsToPullFirst, 'all', 'no marks: no priority list')
    TH.assert_eq(p.mobsToPull, 'a gnoll pup,a gnoll shaman', 'no marks: list unchanged')

    -- Zone list is 'all': ranking refuses to turn on, everything pullable.
    p.mobsToPullRaw = 'all'
    TH.assert_false(Pull.setRanking(true, true), 'list all: ranking stays off')
    TH.assert_eq(p.mobsToPull, 'all', 'list all: MobsToPull is all')
    TH.assert_true(Pull.nameAllowed('a black bear'), 'list all: any mob allowed')

    -- Zoning reloads the list and keeps the current ranking setting.
    zoneList = 'a fire beetle,:a giant wasp drone'
    p.ranking = true
    Pull.loadZoneLists()
    TH.assert_true(p.ranking, 'zoning keeps ranking on')
    TH.assert_eq(p.mobsToPullFirst, 'a giant wasp drone', 'zoning: new first list')
    TH.assert_eq(p.mobsToPull, 'a fire beetle', 'zoning: new MobsToPull')

    -- Empty or "all for all" zone entries mean all.
    zoneList = ''
    Pull.loadZoneLists()
    TH.assert_eq(p.mobsToPullRaw, 'all', 'empty zone entry is all')
    TH.assert_false(p.ranking, 'empty zone list turns ranking off')

    package.loaded['modules.pull'] = nil
end

return M
