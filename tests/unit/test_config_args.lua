-- tests/unit/test_config_args.lua
-- Tests Config.parseArgs — role, MA name, assistAt, debug flags, and keyword args.
-- useMock=true because config.lua does require('mq') at the top; parseArgs itself
-- makes no mq calls, so MockMQ never needs any return values set.
local M = {}

-- Fresh minimal state for each test case, matching the defaults in state.lua.
local function newState()
    return {
        session = {
            role          = 'assist',
            assistAt      = 95,
            mainAssist    = '',
            iniFileName   = '',
            iniSet        = false,
            forceAlias    = true,
            loadFromIni   = false,
            parseDPSTimer = 0,
        },
        debug = {
            general=false, all=false,   buffs=false,  cast=false,
            chainpull=false, combat=false, heals=false, logging=false,
            mez=false, move=false, pet=false, pull=false, rk=false, time=false,
        },
    }
end

function M.run(TH, _MockMQ)
    local Config = require('modules.config')

    TH.setSuite('test_config_args')

    -- Empty args → defaults unchanged ------------------------------------
    do
        local s = newState()
        Config.parseArgs(s, {})
        TH.assert_eq(s.session.role,       'assist', 'empty args: role unchanged')
        TH.assert_eq(s.session.assistAt,   95,       'empty args: assistAt unchanged')
        TH.assert_eq(s.session.mainAssist, '',       'empty args: mainAssist unchanged')
    end

    -- Role: all valid roles are recognised (case-insensitive) ------------
    local roles = {'assist','tank','puller','pettank','pullertank',
                   'pullerpettank','hunter','hunterpettank','offtank','manual'}
    for _, r in ipairs(roles) do
        local s = newState()
        Config.parseArgs(s, {r})
        TH.assert_eq(s.session.role, r, 'role: ' .. r)
        -- Uppercase variant also works
        local s2 = newState()
        Config.parseArgs(s2, {r:upper()})
        TH.assert_eq(s2.session.role, r, 'role (uppercase): ' .. r)
    end

    -- Bare non-role string → MA name fallback ----------------------------
    do
        local s = newState()
        Config.parseArgs(s, {'TankName'})
        TH.assert_eq(s.session.mainAssist, 'TankName', 'bare string → mainAssist')
        TH.assert_eq(s.session.role, 'assist', 'bare string: role unchanged')
    end

    -- Role + positional MA name -----------------------------------------
    do
        local s = newState()
        Config.parseArgs(s, {'assist', 'TheTank'})
        TH.assert_eq(s.session.role,       'assist',  'role+MA: role')
        TH.assert_eq(s.session.mainAssist, 'TheTank', 'role+MA: mainAssist')
    end

    -- Role + MA + positional assistAt% ----------------------------------
    do
        local s = newState()
        Config.parseArgs(s, {'assist', 'TheTank', '80'})
        TH.assert_eq(s.session.role,       'assist',  'role+MA+pct: role')
        TH.assert_eq(s.session.mainAssist, 'TheTank', 'role+MA+pct: mainAssist')
        TH.assert_eq(s.session.assistAt,   80,        'role+MA+pct: assistAt=80')
    end

    -- Role + positional assistAt (no MA name) ---------------------------
    do
        local s = newState()
        Config.parseArgs(s, {'assist', '75'})
        TH.assert_eq(s.session.role,     'assist', 'role+pct: role')
        TH.assert_eq(s.session.assistAt, 75,       'role+pct: assistAt=75')
        TH.assert_eq(s.session.mainAssist, '',     'role+pct: mainAssist empty')
    end

    -- Positional assistAt boundary values --------------------------------
    do
        local s = newState()
        Config.parseArgs(s, {'1'})
        TH.assert_eq(s.session.assistAt, 1, 'assistAt boundary low = 1')

        local s2 = newState()
        Config.parseArgs(s2, {'100'})
        TH.assert_eq(s2.session.assistAt, 100, 'assistAt boundary high = 100')

        -- Out-of-range numbers are silently ignored
        local s3 = newState()
        Config.parseArgs(s3, {'0'})
        TH.assert_eq(s3.session.assistAt, 95, 'assistAt 0 ignored')

        local s4 = newState()
        Config.parseArgs(s4, {'101'})
        TH.assert_eq(s4.session.assistAt, 95, 'assistAt 101 ignored')
    end

    -- 'assistat' keyword -------------------------------------------------
    do
        local s = newState()
        Config.parseArgs(s, {'assistat', '70'})
        TH.assert_eq(s.session.assistAt, 70, 'assistat keyword: 70')
    end

    -- 'ma' keyword -------------------------------------------------------
    do
        local s = newState()
        Config.parseArgs(s, {'ma', 'BigTank'})
        TH.assert_eq(s.session.mainAssist, 'BigTank', 'ma keyword: mainAssist')
    end

    -- 'debug' flag -------------------------------------------------------
    do
        local s = newState()
        Config.parseArgs(s, {'debug'})
        TH.assert_true(s.debug.general,  'debug: general=true')
        TH.assert_false(s.debug.combat,  'debug: combat still false')
    end

    -- 'debugall' flag: sets every debug category -------------------------
    do
        local s = newState()
        Config.parseArgs(s, {'debugall'})
        TH.assert_true(s.debug.general,   'debugall: general')
        TH.assert_true(s.debug.combat,    'debugall: combat')
        TH.assert_true(s.debug.heals,     'debugall: heals')
        TH.assert_true(s.debug.pull,      'debugall: pull')
        TH.assert_true(s.debug.cast,      'debugall: cast')
    end

    -- 'ini' keyword ------------------------------------------------------
    do
        local s = newState()
        Config.parseArgs(s, {'ini', 'MyCustomConfig.ini'})
        TH.assert_eq(s.session.iniFileName, 'MyCustomConfig.ini', 'ini: filename set')
        TH.assert_true(s.session.iniSet,                          'ini: iniSet=true')
    end

    -- 'forcealias' keyword -----------------------------------------------
    do
        local s = newState()
        s.session.forceAlias = false   -- start from false to verify set
        Config.parseArgs(s, {'forcealias'})
        TH.assert_true(s.session.forceAlias, 'forcealias: forceAlias=true')
    end

    -- 'autoload' keyword -------------------------------------------------
    do
        local s = newState()
        Config.parseArgs(s, {'autoload'})
        TH.assert_true(s.session.loadFromIni, 'autoload: loadFromIni=true')
    end

    -- 'parse' keyword with explicit seconds ------------------------------
    do
        local s = newState()
        Config.parseArgs(s, {'parse', '120'})
        TH.assert_eq(s.session.parseDPSTimer, 120, 'parse 120: parseDPSTimer')
    end

    -- 'parse' keyword without value → defaults to 60 --------------------
    do
        local s = newState()
        Config.parseArgs(s, {'parse'})
        TH.assert_eq(s.session.parseDPSTimer, 60, 'parse (no value): default 60')
    end

    -- Combined args: role + ma keyword + assistat keyword + debug --------
    do
        local s = newState()
        Config.parseArgs(s, {'tank', 'ma', 'Warlord', 'assistat', '50', 'debug'})
        TH.assert_eq(s.session.role,       'tank',    'combined: role=tank')
        TH.assert_eq(s.session.mainAssist, 'Warlord', 'combined: mainAssist=Warlord')
        TH.assert_eq(s.session.assistAt,   50,        'combined: assistAt=50')
        TH.assert_true(s.debug.general,               'combined: debug.general')
    end
end

return M
