-- tests/unit/test_startup.lua
-- Tests [StartupCommands] and WinTitle (#318): Startup.parse, runCommands,
-- setWinTitle, and the Config read / one-time backfill of the section.
local M = {}

function M.run(TH, MockMQ)
    local Config  = require('modules.config')
    local Startup = require('modules.startup')

    TH.setSuite('test_startup')

    local DEFAULT_TITLE = '${Me.Name} (Lvl:${Me.Level} ${Zone.ShortName})'

    -- Wires Startup to a fresh state and a cond stub: conds[n] = true/false.
    local function setup(conds, title)
        local state = { misc = { winTitleText = title or DEFAULT_TITLE } }
        Startup.init(state, { eval = function(n) return conds[n] ~= false end })
        return state
    end

    local function setCommands(lines, size)
        Config._setCfg({ StartupCommands = {
            CommandSize = tostring(size or #lines), Command = lines,
        } })
    end

    -- Runs runCommands, returning the commands sent, the delays and the count.
    local function run()
        local sent, delays = {}, {}
        local n = Startup.runCommands(function(c) sent[#sent + 1] = c end,
            function(ms) delays[#delays + 1] = ms end)
        return sent, delays, n
    end

    -- ── parse ───────────────────────────────────────────────────────────────
    TH.assert_eq(Startup.parse('').kind, 'skip', 'parse: empty → skip')
    TH.assert_eq(Startup.parse(nil).kind, 'skip', 'parse: nil → skip')
    TH.assert_eq(Startup.parse('  NULL ').kind, 'skip', 'parse: null (any case) → skip')
    TH.assert_eq(Startup.parse('|cond3').kind, 'skip', 'parse: only a cond suffix → skip')

    local a = Startup.parse('/plugin mq2melee')
    TH.assert_eq(a.kind, 'cmd', 'parse: plain command → cmd')
    TH.assert_eq(a.cmd, '/plugin mq2melee', 'parse: plain command unchanged')
    TH.assert_eq(a.condNo, 0, 'parse: no suffix → condNo 0')

    a = Startup.parse('/burn off|cond12')
    TH.assert_eq(a.cmd, '/burn off', 'parse: |condN stripped from the command')
    TH.assert_eq(a.condNo, 12, 'parse: condN number recorded')
    TH.assert_eq(Startup.parse('/burn off |Cond7').condNo, 7, 'parse: Cond suffix is case-insensitive')

    a = Startup.parse('/noparse /varset WinTitleText ${Me.Name} (${Me.Class.ShortName})')
    TH.assert_eq(a.kind, 'title', 'parse: /noparse /varset WinTitleText → title')
    TH.assert_eq(a.text, '${Me.Name} (${Me.Class.ShortName})', 'parse: title expression kept unparsed')
    TH.assert_eq(Startup.parse('/VARSET wintitletext Box1').kind, 'title',
        'parse: /varset WinTitleText without /noparse, any case → title')

    a = Startup.parse('/varset ReturnToCamp 1')
    TH.assert_eq(a.kind, 'cmd', 'parse: other /varset → cmd')
    TH.assert_eq(a.cmd, '/togglevariable ReturnToCamp 1', 'parse: other /varset → /togglevariable')
    TH.assert_eq(Startup.parse('/noparse /varset MeleeOn').cmd, '/togglevariable MeleeOn',
        'parse: /varset with no value → /togglevariable with no value')
    TH.assert_eq(Startup.parse('/noparse /echo ${Me.Name}').cmd, '/noparse /echo ${Me.Name}',
        'parse: /noparse on a non-/varset command is left for MQ')

    -- ── runCommands ─────────────────────────────────────────────────────────
    setup({})
    setCommands({ '/plugin mq2melee', '', '/burn off', 'null' })
    local sent, delays, n = run()
    TH.assert_eq(n, 2, 'run: empty and null lines skipped')
    TH.assert_eq(sent[1], '/plugin mq2melee', 'run: first command first')
    TH.assert_eq(sent[2], '/burn off', 'run: second command second')
    TH.assert_eq(#delays, 2, 'run: one delay per command run')
    TH.assert_eq(delays[1], 500, 'run: 500 ms delay (mac /delay 5)')

    setup({ [3] = false, [4] = true })
    setCommands({ '/echo a|cond3', '/echo b|cond4', '/echo c' })
    sent = run()
    TH.assert_eq(#sent, 2, 'run: line with a false cond skipped')
    TH.assert_eq(sent[1], '/echo b', 'run: line with a true cond runs, suffix stripped')

    setup({})
    setCommands({ '/echo 1', '/echo 2', '/echo 3' }, 2)
    n = select(3, run())
    TH.assert_eq(n, 2, 'run: stops at CommandSize')

    setup({})
    setCommands({ '/echo 1' }, 5)
    n = select(3, run())
    TH.assert_eq(n, 1, 'run: CommandSize larger than the list is safe')

    setup({})
    Config._setCfg({})
    n = select(3, run())
    TH.assert_eq(n, 0, 'run: no [StartupCommands] section → nothing runs')

    -- A title line sets the text and applies it straight away; no delay.
    local state = setup({})
    MockMQ.set('parse:${Me.Name} [box]', 'Toon [box]')
    setCommands({ '/noparse /varset WinTitleText ${Me.Name} [box]' })
    sent, delays, n = run()
    TH.assert_eq(state.misc.winTitleText, '${Me.Name} [box]', 'run: title line sets winTitleText')
    TH.assert_eq(n, 0, 'run: title line is not counted as a command')
    TH.assert_eq(#delays, 0, 'run: no delay for a title line')
    TH.assert_eq(sent[1], '/setwintitle Toon [box]', 'run: changed title applied straight away')

    state = setup({})
    setCommands({ '/varset WinTitleText' })
    sent = run()
    TH.assert_eq(state.misc.winTitleText, 'null', 'run: empty WinTitleText → null')
    TH.assert_eq(#sent, 0, 'run: null title sends no /setwintitle')

    -- ── setWinTitle ─────────────────────────────────────────────────────────
    local titles = {}
    local function rec(c) titles[#titles + 1] = c end
    setup({})
    MockMQ.set('parse:' .. DEFAULT_TITLE, 'Toon (Lvl:60 poknowledge)')
    TH.assert_true(Startup.setWinTitle(rec), 'title: default expression sets the title')
    TH.assert_eq(titles[1], '/setwintitle Toon (Lvl:60 poknowledge)', 'title: expression parsed before /setwintitle')

    titles = {}
    setup({}, 'null')
    TH.assert_false(Startup.setWinTitle(rec), 'title: null leaves the title alone')
    setup({}, '')
    TH.assert_false(Startup.setWinTitle(rec), 'title: empty leaves the title alone')
    setup({}, '${Bogus}')
    MockMQ.set('parse:${Bogus}', 'NULL')
    TH.assert_false(Startup.setWinTitle(rec), 'title: expression parsing to NULL is not applied')
    TH.assert_eq(#titles, 0, 'title: nothing sent for null / empty / NULL')

    -- ── Config.readStartupCommands ──────────────────────────────────────────
    local function iniReader(tbl)
        return function(section, key) return tbl[section .. '.' .. key] end
    end
    TH.assert_nil(Config.readStartupCommands(iniReader({})), 'read: no CommandSize → nil')
    local sc = Config.readStartupCommands(iniReader({
        ['StartupCommands.CommandSize'] = '3',
        ['StartupCommands.Command1']    = '/plugin mq2melee',
        ['StartupCommands.Command3']    = '/burn off',
    }))
    TH.assert_eq(sc.CommandSize, '3', 'read: CommandSize kept as a string')
    TH.assert_eq(#sc.Command, 3, 'read: missing line padded so the list has no holes')
    TH.assert_eq(sc.Command[2], '', 'read: missing line is empty')
    TH.assert_eq(sc.Command[3], '/burn off', 'read: lines kept in order')

    -- ── Config.backfillStartupCommands ──────────────────────────────────────
    MockMQ.configDir = 'C:/MQ/config'
    local asked = {}
    local function fakeIni(files)
        return function(file, section, key)
            asked[file] = true
            local f = files[file]
            return f and f[section .. '.' .. key]
        end
    end

    local cfg = { StartupCommands = { CommandSize = '1', Command = { '/echo keep' } } }
    TH.assert_false(Config.backfillStartupCommands(cfg, 'KissAssist_X.ini', fakeIni({})),
        'backfill: section already in the pickle → no change')
    TH.assert_eq(cfg.StartupCommands.Command[1], '/echo keep', 'backfill: existing section untouched')

    cfg = {}
    TH.assert_true(Config.backfillStartupCommands(cfg, 'KissAssist_X.ini', fakeIni({
        ['KissAssist_X.ini'] = { ['StartupCommands.CommandSize'] = '1', ['StartupCommands.Command1'] = '/echo ini' },
    })), 'backfill: imports from the INI')
    TH.assert_eq(cfg.StartupCommands.Command[1], '/echo ini', 'backfill: INI line imported')

    cfg = {}
    Config.backfillStartupCommands(cfg, 'KissAssist_X.ini', fakeIni({
        ['C:/MQ/config/KissAssist_X.ini.bak'] = {
            ['StartupCommands.CommandSize'] = '1', ['StartupCommands.Command1'] = '/echo bak' },
    }))
    TH.assert_eq(cfg.StartupCommands.Command[1], '/echo bak', 'backfill: falls back to the migrated .bak')

    cfg = {}
    for k in pairs(asked) do asked[k] = nil end
    TH.assert_true(Config.backfillStartupCommands(cfg, 'KissAssist_X.ini', fakeIni({})),
        'backfill: nothing to import still marks the pickle dirty')
    TH.assert_eq(cfg.StartupCommands.CommandSize, '0', 'backfill: empty section written so it runs once')
    TH.assert_true(asked['KissAssist_X.ini'] and asked['C:/MQ/config/KissAssist_X.ini.bak'],
        'backfill: checked both the INI and the .bak')

    -- ── defaultCfg keeps the section (purgeOrphanedFields uses it as schema) ──
    local def = Config.defaultCfg().StartupCommands
    TH.assert_not_nil(def, 'defaultCfg: has StartupCommands')
    TH.assert_eq(def and def.CommandSize, '0', 'defaultCfg: CommandSize 0')
end

return M
