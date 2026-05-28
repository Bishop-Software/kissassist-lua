-- tests/unit/test_charm.lua
-- Tests for the Charm module: Charm.init (iAmACharmClass flag, INI defaults),
-- Charm.resetFight (array/timer clear + petId preservation), and timer math thresholds.
-- Requires mock injection (useMock=true) because charm.lua calls mq.TLO.*.
local M = {}

-- Build a minimal state table that satisfies every field charm.lua touches.
local function makeState(overrides)
    local arr = {}
    for i = 1, 50 do arr[i] = {0, 0, 'NULL'} end
    local s = {
        session = {
            iAmACharmClass = false,
            iAmABard       = false,
            infoFileName   = 'KissAssist_Info.ini',
        },
        combat  = { xTSlot = 0 },
        misc    = { dmz = false },
        arrays  = { charmArray = arr },
        charm   = {
            on          = false,
            radius      = 50,
            minLevel    = 5,
            maxLevel    = 0,
            spell       = '',
            keep        = false,
            petId       = 0,
            petZone     = '',
            immuneList  = '',
            aaImmune    = false,
            immuneIds   = '',
            mobCount    = 0,
            mobAECount  = 0,
            aeClosest   = 0,
            mobDone     = false,
            slotTimers  = {},
            cmTimers    = {},
            count       = {},
        },
    }
    if overrides then
        for k, v in pairs(overrides) do s[k] = v end
    end
    return s
end

local function makeUtils()
    return { debug = function() end }
end

-- Minimal no-op stubs for cast/pet/bard/comms.
local function makeStubs()
    local noop = {}
    return noop, noop, noop, noop
end

-- Set standard TLO mocks needed by every Charm.init call.
-- mq.TLO.Ini(file, section, key, default)() must return a callable result.
local function setupInitMocks(MockMQ, class, zone)
    MockMQ.reset()
    MockMQ.set('TLO.Me.Class.ShortName', class or 'ENC')
    MockMQ.set('TLO.Zone.ShortName',     zone  or 'testzone')
    -- TLO.Ini is called as: mq.TLO.Ini(file, section, key, default)()
    -- The first () invokes the proxy with args → must return something callable.
    MockMQ.set('TLO.Ini', function() return function() return 'NULL' end end)
end

function M.run(TH, MockMQ)
    local Charm = require('modules.charm')

    TH.setSuite('test_charm')

    -- -----------------------------------------------------------------------
    -- Suite 1: iAmACharmClass flag set by Charm.init
    -- -----------------------------------------------------------------------

    local charmClasses = {'ENC', 'DRU', 'NEC', 'BRD'}
    for _, cls in ipairs(charmClasses) do
        setupInitMocks(MockMQ, cls)
        local state = makeState()
        local utils = makeUtils()
        local cast, pet, bard, comms = makeStubs()
        Charm.init(state, utils, cast, pet, bard, comms)
        TH.assert_true(state.session.iAmACharmClass,
            'iAmACharmClass=true for class=' .. cls)
    end

    local nonCharmClasses = {'WAR', 'PAL', 'RNG', 'ROG', 'SHD', 'CLR', 'SHM', 'MNK', 'MAG', 'WIZ'}
    for _, cls in ipairs(nonCharmClasses) do
        setupInitMocks(MockMQ, cls)
        local state = makeState()
        local utils = makeUtils()
        local cast, pet, bard, comms = makeStubs()
        Charm.init(state, utils, cast, pet, bard, comms)
        TH.assert_false(state.session.iAmACharmClass,
            'iAmACharmClass=false for class=' .. cls)
    end

    -- -----------------------------------------------------------------------
    -- Suite 2: INI defaults applied by Charm.init (Config not loaded → all defaults)
    -- -----------------------------------------------------------------------

    setupInitMocks(MockMQ, 'ENC', 'myzone')
    local state2 = makeState()
    local cast2, pet2, bard2, comms2 = makeStubs()
    Charm.init(state2, makeUtils(), cast2, pet2, bard2, comms2)

    TH.assert_false(state2.charm.on,       'charm.on default = false')
    TH.assert_eq(state2.charm.spell,    '', 'charm.spell default = ""')
    TH.assert_eq(state2.charm.minLevel,  5, 'charm.minLevel default = 5')
    TH.assert_eq(state2.charm.maxLevel,  0, 'charm.maxLevel default = 0')
    TH.assert_eq(state2.charm.radius,   50, 'charm.radius default = 50')
    TH.assert_false(state2.charm.keep,     'charm.keep default = false')
    TH.assert_eq(state2.charm.immuneList,'','charm.immuneList default = ""')

    -- Slot timer tables initialised to 0 for all 30 slots
    for i = 1, 30 do
        TH.assert_eq(state2.charm.slotTimers[i], 0,
            'slotTimers[' .. i .. '] init = 0')
        TH.assert_eq(state2.charm.count[i], 0,
            'count[' .. i .. '] init = 0')
    end

    -- -----------------------------------------------------------------------
    -- Suite 3: Charm.resetFight — clears array and timers, preserves petId/petZone
    -- -----------------------------------------------------------------------

    setupInitMocks(MockMQ, 'ENC')
    local state3 = makeState()
    local cast3, pet3, bard3, comms3 = makeStubs()
    Charm.init(state3, makeUtils(), cast3, pet3, bard3, comms3)

    -- Dirty the state
    local arr3 = state3.arrays.charmArray
    arr3[1][1] = 9001; arr3[1][2] = 55; arr3[1][3] = 'Goblin'
    arr3[5][1] = 9002; arr3[5][2] = 40; arr3[5][3] = 'Orc'
    state3.charm.slotTimers[1] = 9999
    state3.charm.slotTimers[5] = 8888
    state3.charm.count[1]      = 3
    state3.charm.mobCount      = 7
    state3.charm.mobAECount    = 4
    state3.charm.aeClosest     = 9002
    state3.charm.mobDone       = true
    -- Set petId/petZone — should survive reset
    state3.charm.petId   = 12345
    state3.charm.petZone = 'crushbone'

    Charm.resetFight()

    -- Array entries cleared
    TH.assert_eq(arr3[1][1], 0,      'resetFight: arr[1].id cleared')
    TH.assert_eq(arr3[1][2], 0,      'resetFight: arr[1].level cleared')
    TH.assert_eq(arr3[1][3], 'NULL', 'resetFight: arr[1].name cleared')
    TH.assert_eq(arr3[5][1], 0,      'resetFight: arr[5].id cleared')
    TH.assert_eq(arr3[5][3], 'NULL', 'resetFight: arr[5].name cleared')

    -- Timers and counts reset
    TH.assert_eq(state3.charm.slotTimers[1], 0, 'resetFight: slotTimers[1] = 0')
    TH.assert_eq(state3.charm.slotTimers[5], 0, 'resetFight: slotTimers[5] = 0')
    TH.assert_eq(state3.charm.count[1],      0, 'resetFight: count[1] = 0')

    -- Mob counts reset
    TH.assert_eq(state3.charm.mobCount,   0,    'resetFight: mobCount = 0')
    TH.assert_eq(state3.charm.mobAECount, 0,    'resetFight: mobAECount = 0')
    TH.assert_eq(state3.charm.aeClosest,  0,    'resetFight: aeClosest = 0')
    TH.assert_false(state3.charm.mobDone,       'resetFight: mobDone = false')

    -- petId and petZone preserved for CharmKeep recharm
    TH.assert_eq(state3.charm.petId,   12345,        'resetFight: petId preserved')
    TH.assert_eq(state3.charm.petZone, 'crushbone',  'resetFight: petZone preserved')

    -- -----------------------------------------------------------------------
    -- Suite 4: resetFight no-op when _state not set (called before init)
    -- -----------------------------------------------------------------------

    -- Evict charm from cache so it has a fresh _state=nil
    package.loaded['modules.charm'] = nil
    local Charm2 = require('modules.charm')
    local ok = pcall(function() Charm2.resetFight() end)
    TH.assert_true(ok, 'resetFight before init: no error (early return)')
    package.loaded['modules.charm'] = nil  -- evict so caller re-requires Charm

    -- -----------------------------------------------------------------------
    -- Suite 5: Timer threshold math (documents the 90%/10% constants)
    -- -----------------------------------------------------------------------

    -- 90% timer: spell duration * 0.90 → recharm scheduled at 90% of full duration
    local dur60  = 60
    local dur120 = 120
    local dur30  = 30
    TH.assert_near(dur60  * 0.90, 54,   0.001, 'timer 90%: 60s spell → 54s')
    TH.assert_near(dur120 * 0.90, 108,  0.001, 'timer 90%: 120s spell → 108s')
    TH.assert_near(dur30  * 0.90, 27,   0.001, 'timer 90%: 30s spell → 27s')

    -- 10% early-return: if buff remaining > 10% of duration, skip recast
    TH.assert_near(dur60  * 0.10, 6,    0.001, 'early-return 10%: 60s spell → 6s threshold')
    TH.assert_near(dur120 * 0.10, 12,   0.001, 'early-return 10%: 120s spell → 12s threshold')
    TH.assert_near(dur30  * 0.10, 3,    0.001, 'early-return 10%: 30s spell → 3s threshold')

    -- Relationship: timer point < recharm threshold (10% < 90%)
    TH.assert_true(dur60 * 0.10 < dur60 * 0.90,
        'early-return threshold < recharm timer (10% < 90%)')
end

return M
