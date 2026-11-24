-- tests/unit/test_campfire.lua
-- Gap 4: Campfire.decidePlace (Sub Campfire, mac:12855) and Campfire.decideBack
-- (Sub CampfireBack, mac:13392). The Fellowship-window and Insignia clicks are
-- checked in game.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_campfire')
    MockMQ.reset()
    local Campfire = require('modules.campfire')

    -- ── decidePlace ─────────────────────────────────────────────────────────
    local function place(over)
        local snap = {
            campfireOn = 1, now = 100, timer = 0, zoneID = 10,
            campfireZoneID = 0, campfireZoneName = '',
            distToCamp = 5, campRadius = 30, aggro = false, combatStart = false,
            fellowsNear = 3,
        }
        for k, v in pairs(over or {}) do snap[k] = v end
        return Campfire.decidePlace(snap)
    end
    TH.assert_eq(place(), 'place', 'place: in camp, 3 fellows, no campfire -> place')
    TH.assert_eq(place({ fellowsNear = 2 }), 'retry', 'place: 2 fellows -> retry in 5 min')
    TH.assert_nil(place({ campfireOn = 0 }), 'place: CampfireOn 0 -> nothing')
    TH.assert_nil(place({ timer = 200 }), 'place: retry timer running -> nothing')
    TH.assert_nil(place({ campfireZoneID = 10 }), 'place: campfire already in this zone -> nothing')
    TH.assert_nil(place({ campfireZoneID = 20, campfireZoneName = 'Palatial Guild Hall' }),
        'place: campfire in a guild hall -> keep it')
    TH.assert_eq(place({ campfireZoneID = 20, campfireZoneName = 'Somewhere Else' }), 'place',
        'place: campfire in another (non guild hall) zone -> replace')
    TH.assert_nil(place({ distToCamp = 40 }), 'place: outside CampRadius -> nothing')
    TH.assert_nil(place({ aggro = true }), 'place: aggro -> nothing')
    TH.assert_nil(place({ combatStart = true }), 'place: fighting -> nothing')

    -- ── decideBack ──────────────────────────────────────────────────────────
    local function back(over)
        local snap = {
            clickBack = 1, now = 100, timer = 0, campZone = 10, zoneID = 20,
            revivalSickness = true, hasCampfire = true, campfireZoneID = 10,
            hasInsignia = true, insigniaReady = true, rested = true,
        }
        for k, v in pairs(over or {}) do snap[k] = v end
        return Campfire.decideBack(snap)
    end
    TH.assert_eq(back(), 'click', 'back: dead elsewhere, campfire up, Insignia ready -> click')
    TH.assert_nil(back({ clickBack = 0 }), 'back: ClickBacktoCamp 0 -> nothing')
    TH.assert_nil(back({ timer = 150 }), 'back: 1-minute timer running -> nothing')
    TH.assert_nil(back({ zoneID = 10 }), 'back: already in the camp zone -> nothing')
    TH.assert_nil(back({ revivalSickness = false }), 'back: no Revival Sickness -> nothing')
    TH.assert_eq(back({ hasCampfire = false }), 'none', 'back: no campfire up -> say so')
    TH.assert_eq(back({ campfireZoneID = 20 }), 'samezone', 'back: in the campfire\'s zone -> no longer dead')
    TH.assert_eq(back({ hasInsignia = false }), 'noinsignia', 'back: no Insignia -> say so')
    TH.assert_eq(back({ insigniaReady = false }), 'wait', 'back: Insignia on cooldown -> wait')
    TH.assert_eq(back({ rested = false }), 'wait', 'back: still in combat state -> wait')

    MockMQ.reset()
end

return M
