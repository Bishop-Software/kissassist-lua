-- tests/unit/test_pull_level.lua
-- #61: Pull.setPullLevel / Pull.levelGained (the .mac's PullLevel, mac:16255
-- and mac:11400) and Pull.chainPullBusy (ChainPullHP, mac:8959).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_pull_level')
    MockMQ.reset()
    local Pull = require('modules.pull')

    local state = {
        session = { role = 'puller', infoFileName = '', zoneName = '' },
        pull    = {},
        timers  = {},
        heal    = { medOn = false },
        combat  = { aggroTargetID = '', myTargetID = 0, xTSlot = 1 },
        pet     = { attackRange = 100 },
    }
    Pull.init(state, { debug = function() end, zoneIniGet = function() return nil end })
    local p = state.pull

    -- Defaults: no PullLevel in config -> off; ChainPullHP 90 (mac default).
    TH.assert_eq(p.levelMode, 'off', 'default PullLevel: off')
    TH.assert_eq(p.min, 1,   'off: min 1')
    TH.assert_eq(p.max, 200, 'off: max 200')
    TH.assert_eq(p.chainPullHP, 90, 'default ChainPullHP 90')

    -- ---- PullLevel ----
    MockMQ.set('TLO.Me.Level', 60)
    TH.assert_eq(Pull.setPullLevel('40|55'), 'fixed', '40|55: fixed')
    TH.assert_eq(p.min, 40, 'fixed: min')
    TH.assert_eq(p.max, 55, 'fixed: max')
    TH.assert_eq(p.levelSetting, '40|55', 'setting kept as written')

    TH.assert_eq(Pull.setPullLevel('40|55|linked'), 'linked', '40|55|linked: linked')
    TH.assert_eq(p.min, 40, 'linked: min')
    TH.assert_eq(p.max, 55, 'linked: max')
    Pull.levelGained()
    TH.assert_eq(p.min, 41, 'linked level up: min +1')
    TH.assert_eq(p.max, 56, 'linked level up: max +1')

    TH.assert_eq(Pull.setPullLevel('auto'), 'auto', 'auto: auto')
    TH.assert_eq(p.min, 55, 'auto: my level -5')
    TH.assert_eq(p.max, 62, 'auto: my level +2')
    MockMQ.set('TLO.Me.Level', 61)
    Pull.levelGained()
    TH.assert_eq(p.min, 56, 'auto level up: recalculated min')
    TH.assert_eq(p.max, 63, 'auto level up: recalculated max')

    Pull.setPullLevel('40|55')
    Pull.levelGained()
    TH.assert_eq(p.min, 40, 'fixed: level up leaves the range alone')

    for _, v in ipairs({ '0|0', '0', 'null', '45' }) do
        TH.assert_eq(Pull.setPullLevel(v), 'off', 'off for ' .. v)
    end
    TH.assert_eq(Pull.setPullLevel('60|40'), 'off', 'min > max: reset to off')
    TH.assert_eq(p.min, 1, 'invalid: min 1')
    TH.assert_eq(Pull.setPullLevel('0|50'), 'off', 'min 0: reset to off')

    -- ---- ChainPullHP ----
    -- xt: XTarget slot 1 mob ID; tgtID/tgtHP: current target; myHP: MyTargetID's HP
    local function setChain(xt, tgtID, tgtHP, myTgt, myHP)
        MockMQ.reset()
        MockMQ.set('TLO.Me.XTarget', function() return { ID = function() return xt end } end)
        MockMQ.set('TLO.Target.ID', tgtID)
        MockMQ.set('TLO.Target.PctHPs', tgtHP)
        MockMQ.set('TLO.Spawn', function() return { PctHPs = function() return myHP end } end)
        state.combat.myTargetID = myTgt
    end
    p.chainPullHP = 80

    setChain(0, 0, nil, 0, nil)
    TH.assert_false(Pull.chainPullBusy(), 'nothing on XTarget: not busy')
    setChain(500, 0, nil, 0, nil)
    TH.assert_true(Pull.chainPullBusy(), 'XTarget mob but no target info: busy')
    setChain(500, 500, 95, 500, 95)
    TH.assert_true(Pull.chainPullBusy(), 'current mob at 95% >= 80: busy')
    setChain(500, 500, 80, 500, 80)
    TH.assert_true(Pull.chainPullBusy(), 'current mob at exactly 80%: busy')
    setChain(500, 500, 60, 500, 60)
    TH.assert_false(Pull.chainPullBusy(), 'current mob at 60% < 80: pull the next')
    setChain(500, 0, nil, 500, 90)
    TH.assert_true(Pull.chainPullBusy(), 'no target, MyTargetID at 90%: busy')
    setChain(500, 0, nil, 500, 50)
    TH.assert_false(Pull.chainPullBusy(), 'no target, MyTargetID at 50%: pull the next')

    package.loaded['modules.pull'] = nil
end

return M
