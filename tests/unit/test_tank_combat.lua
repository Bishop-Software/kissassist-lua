-- tests/unit/test_tank_combat.lua
-- #333 items 1 and 2.
--   * Combat.tankBetweenFights (tank branch of CheckForCombat, mac:587-599):
--     chase the puller, back to camp (no mobs and >15, or one aggro mob and >75),
--     stop while a mob in camp has aggro, else |End endurance buffs.
--   * Buffs.checkEnduranceBuffs (mac:592-597): |End entries at or below their %,
--     disc or AA ready.
--   * Assist returns 'switch' for an offtank whose MA is more than 200 away
--     (mac:779-780), so CheckForCombat makes it the tank.
local M = {}

local SUBMODULES = {
    'modules.combat.settings', 'modules.combat.util', 'modules.combat.abilities',
    'modules.combat.radar', 'modules.combat.targeting', 'modules.combat.fight',
}

function M.run(TH, MockMQ)
    TH.setSuite('test_tank_combat')

    -- ── Buffs.checkEnduranceBuffs ───────────────────────────────────────────
    local RealConfig = require('modules.config')
    package.loaded['modules.config'] = {
        parseCondArray = RealConfig.parseCondArray,
        get = function(_, _, default) return default end,
    }
    package.loaded['modules.buffs'] = nil
    local Buffs = require('modules.buffs')
    MockMQ.set('TLO.Plugin', function() return { IsLoaded = function() return false end } end)
    local casts = {}
    local bstate = {
        session = {}, misc = {}, pet = { toysArray = {} },
        buffs = { buffsArray = {}, petBuffsArray = {} },
    }
    Buffs.init(bstate,
        { debug = function() end, resolveSpellRank = function(s) return s end },
        { castWhat = function(spell) casts[#casts + 1] = spell; return 'CAST_SUCCESS' end },
        {}, nil, {})
    bstate.buffs.buffsArray = {
        { name = 'Breather|End|30' },
        { name = 'Hold the Line|End|50' },
        { name = 'Plain Buff' },
        { name = 'Some Mana Item|Mana|50' },
    }
    local endPct = 25
    local caReady = { Breather = true }
    local aaReady = { ['Hold the Line'] = true }
    MockMQ.set('TLO.Me.PctEndurance', function() return endPct end)
    MockMQ.set('TLO.Me.CombatAbilityReady', function(s) return function() return caReady[s] == true end end)
    MockMQ.set('TLO.Me.AltAbilityReady', function(s) return function() return aaReady[s] == true end end)

    Buffs.checkEnduranceBuffs()
    TH.assert_eq(table.concat(casts, ','), 'Breather,Hold the Line',
        'below both thresholds: disc and AA |End entries cast')

    casts = {}
    endPct = 40
    Buffs.checkEnduranceBuffs()
    TH.assert_eq(table.concat(casts, ','), 'Hold the Line', 'at 40%: only the 50% entry')

    casts = {}
    endPct = 25
    caReady.Breather, aaReady['Hold the Line'] = false, false
    Buffs.checkEnduranceBuffs()
    TH.assert_eq(#casts, 0, 'nothing ready: nothing cast')

    package.loaded['modules.buffs']  = nil
    package.loaded['modules.config'] = nil

    -- ── Assist 'switch' for an offtank ──────────────────────────────────────
    for _, m in ipairs(SUBMODULES) do package.loaded[m] = nil end
    local Util      = require('modules.combat.util')
    local Targeting = require('modules.combat.targeting')
    local tstate = {
        misc    = { dmz = false },
        combat  = { meleeOn = true, dpsOn = true, myTargetID = 0, mobCount = 1, aggroTargetID = '' },
        mez     = { on = 0 },
        dps     = { paused = false },
        pull    = { pulled = false },
        session = { role = 'offtank', mainAssist = 'Tank', iAmMA = false },
        movement = { campX = 0, campY = 0 },
    }
    Util.init(tstate)
    Targeting.init(tstate, { debug = function() end }, { mobRadar = function() end })
    local maDist = 300
    MockMQ.set('TLO.Spawn', function()
        return { ID = function() return 5 end, Distance = function() return maDist end }
    end)

    TH.assert_eq(Targeting.assist('test'), 'switch', 'offtank, MA 300 away: assist returns switch')
    tstate.session.role = 'assist'
    TH.assert_true(Targeting.assist('test') ~= 'switch', 'assist role, MA 300 away: no switch')
    tstate.session.role = 'offtank'
    tstate.combat.mobCount = 0
    TH.assert_true(Targeting.assist('test') ~= 'switch', 'offtank, no mobs: no switch')

    -- ── Combat.tankBetweenFights ────────────────────────────────────────────
    -- Stub the combat submodules so combat.lua loads without the real ones.
    local noop = function() end
    local function stub(fields)
        return setmetatable(fields or {}, { __index = function() return noop end })
    end
    local dist = 0
    for _, m in ipairs(SUBMODULES) do package.loaded[m] = stub() end
    package.loaded['modules.combat.util'] = stub({ distFromCamp = function() return dist end })
    package.loaded['modules.combat'] = nil
    local Combat = require('modules.combat')

    local chases, moves, endChecks = 0, {}, 0
    local cstate = {
        session  = { chaseAssist = false, role = 'tank' },
        combat   = { mobCount = 0, aggroTargetID = '' },
        buffs    = { buffsOn = true },
        movement = { returnToCamp = true, campX = 100, campY = 100, whoToChase = '' },
    }
    local movement = {
        doWeChase = function() chases = chases + 1 end,
        doWeMove  = function(force) moves[#moves + 1] = force end,
    }
    local buffs = { checkEnduranceBuffs = function() endChecks = endChecks + 1 end }
    Combat.init(cstate, { debug = noop }, {}, {}, movement, {}, {}, {}, {}, buffs, {}, {}, {})
    MockMQ.set('TLO.Me.CleanName', 'Me')

    local function run(mobCount, aggro, d)
        moves, endChecks = {}, 0
        cstate.combat.mobCount, cstate.combat.aggroTargetID, dist = mobCount, aggro, d
        Combat.tankBetweenFights()
    end

    run(0, '', 20)
    TH.assert_eq(#moves, 1, 'no mobs, 20 from camp: back to camp')
    TH.assert_eq(moves[1], 1, 'back to camp forced (DoWeMove 1)')
    TH.assert_eq(endChecks, 1, 'no aggro: endurance buffs checked')
    run(0, '', 10)
    TH.assert_eq(#moves, 0, 'no mobs, 10 from camp: stays')
    run(1, '500', 80)
    TH.assert_eq(#moves, 1, 'one aggro mob, 80 from camp: back to camp')
    TH.assert_eq(endChecks, 0, 'mob with aggro: no endurance check (mac /continue)')
    run(1, '500', 50)
    TH.assert_eq(#moves, 0, 'one aggro mob, 50 from camp: stays')
    run(2, '500', 80)
    TH.assert_eq(#moves, 0, 'two aggro mobs: stays to tank them')

    cstate.movement.returnToCamp = false
    run(0, '', 200)
    TH.assert_eq(#moves, 0, 'ReturnToCamp off: never moves')
    cstate.buffs.buffsOn = false
    run(0, '', 0)
    TH.assert_eq(endChecks, 0, 'BuffsOn off: no endurance check')

    -- Chase: only when chasing someone else.
    cstate.session.chaseAssist = true
    cstate.movement.whoToChase = 'Puller'
    run(0, '', 0)
    TH.assert_eq(chases, 1, 'chasing the puller: DoWeChase')
    cstate.movement.whoToChase = 'Me'
    run(0, '', 0)
    TH.assert_eq(chases, 1, 'chasing myself: no DoWeChase')

    for _, m in ipairs(SUBMODULES) do package.loaded[m] = nil end
    package.loaded['modules.combat'] = nil
end

return M
