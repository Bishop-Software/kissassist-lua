-- tests/unit/test_aliases.lua
-- Tests Aliases.parse and Aliases.sync (mac LoadAliases, mac:16565-16645).
-- sync gets an injected INI reader and command recorder, so no real alias is touched.
local M = {}

function M.run(TH, _MockMQ)
    local Aliases = require('modules.aliases')

    TH.setSuite('test_aliases')

    -- Runs sync against the given INI text and returns the commands it sent.
    local function runSync(iniText, isBound)
        local sent = {}
        local w, d = Aliases.sync(isBound, function() return iniText end,
            function(line) sent[#sent + 1] = line end)
        return sent, w, d
    end

    local function contains(list, item)
        for _, v in ipairs(list) do if v == item then return true end end
        return false
    end

    -- Builds an [Aliases] section that matches LIST exactly.
    local function matchingIni()
        local lines = { '[Aliases]' }
        for _, a in ipairs(Aliases.LIST) do lines[#lines + 1] = a[1] .. '=' .. a[2] end
        return table.concat(lines, '\n')
    end

    -- ── LIST shape ──────────────────────────────────────────────────────────
    TH.assert_eq(#Aliases.LIST, 52, 'LIST has the mac\'s 59 aliases minus /switchma, /dpsspam and 5 KissTell')
    local names = {}
    for _, a in ipairs(Aliases.LIST) do names[a[1]] = a[2] end
    TH.assert_nil(names['/switchma'], '/switchma is not created (self-alias of a bound command)')
    TH.assert_nil(names['/dpsspam'], '/dpsspam is not created (the mac deletes it)')
    TH.assert_eq(names['/peton'], '/togglevariable PetOn', '/peton targets /togglevariable PetOn')
    TH.assert_eq(names['/autofireon'], '/togglevariable AutoFireOn', '/autofireon targets /togglevariable AutoFireOn')
    TH.assert_eq(#Aliases.DELETES, 16, 'DELETES has the mac\'s 11 entries plus 5 KissTell')
    TH.assert_nil(names['/kttarget'], '/kttarget is not created (KissTell won\'t do)')
    TH.assert_eq(names['/ktdismount'], '/echo KTDismount', '/ktdismount is still created')

    -- ── parse ───────────────────────────────────────────────────────────────
    local parsed = Aliases.parse(table.concat({
        '[MacroQuest]',
        '/chaseon=not an alias',
        '[ aliases ]',
        '/ChaseOn = /changevarint General ChaseAssist 1  ',
        '; /commented=/nope',
        '/targetswitch=/togglevariable TargetSwitchingOn ',
        '[Other]',
        '/camphere=/other',
    }, '\r\n'))
    TH.assert_eq(parsed['/chaseon'], '/changevarint General ChaseAssist 1',
        'parse: key lowercased, value trimmed, section name case/space-insensitive')
    TH.assert_eq(parsed['/targetswitch'], '/togglevariable TargetSwitchingOn', 'parse: trailing space trimmed')
    TH.assert_nil(parsed['/camphere'], 'parse: keys from other sections ignored')
    TH.assert_nil(parsed['; /commented'], 'parse: comment lines ignored')
    TH.assert_nil(next(Aliases.parse(nil)), 'parse(nil) returns an empty table')

    -- ── sync: fresh install ─────────────────────────────────────────────────
    local sent, w, d = runSync('')
    TH.assert_eq(w, 52, 'fresh install: writes every alias')
    TH.assert_eq(d, 0, 'fresh install: no deletes')
    TH.assert_eq(#sent, 52, 'fresh install: one command per alias')
    TH.assert_true(contains(sent, '/squelch /alias /chaseon /changevarint General ChaseAssist 1'),
        'fresh install: /chaseon command is squelched and verbatim')

    -- Missing INI file (reader returns nil) behaves like a fresh install
    w = select(2, runSync(nil))
    TH.assert_eq(w, 52, 'missing MacroQuest.ini: writes every alias')

    -- ── sync: already matching ──────────────────────────────────────────────
    sent, w, d = runSync(matchingIni())
    TH.assert_eq(#sent, 0, 'matching INI: sends nothing')
    TH.assert_eq(w + d, 0, 'matching INI: 0 written, 0 deleted')

    -- Case differences in the stored value don't trigger a rewrite
    sent = runSync((matchingIni():gsub('/togglevariable PetOn', '/TOGGLEVARIABLE peton')))
    TH.assert_eq(#sent, 0, 'stored value differing only in case is not rewritten')

    -- ── sync: one changed value ─────────────────────────────────────────────
    sent, w = runSync((matchingIni():gsub('/changevarint Melee AssistAt', '/something else')))
    TH.assert_eq(w, 1, 'changed value: exactly one rewrite')
    TH.assert_eq(sent[1], '/squelch /alias /assistat /changevarint Melee AssistAt',
        'changed value: rewrites that alias to the mac\'s target')

    -- ── sync: bound names skipped ───────────────────────────────────────────
    sent, w = runSync('', function(name) return name == '/peton' or name == '/chaseon' end)
    TH.assert_eq(w, 50, 'bound names: skipped from the 52')
    TH.assert_false(contains(sent, '/squelch /alias /peton /togglevariable PetOn'), 'bound /peton not aliased')

    -- ── sync: deletes ───────────────────────────────────────────────────────
    sent, w, d = runSync(matchingIni() .. '\n/debug=/old debug\n/DebugPull=/old\n/unrelated=/keep')
    TH.assert_eq(w, 0, 'deletes: nothing written when the aliases match')
    TH.assert_eq(d, 2, 'deletes: only the present delete-list entries')
    TH.assert_true(contains(sent, '/squelch /alias /debug delete'), 'deletes: /debug removed')
    TH.assert_true(contains(sent, '/squelch /alias /debugpull delete'), 'deletes: key match is case-insensitive')
    TH.assert_false(contains(sent, '/squelch /alias /unrelated delete'), 'deletes: other user aliases untouched')

    -- Leftover KissTell aliases from the mac or an older port are removed
    local _
    sent, _, d = runSync(matchingIni() .. '\n/kthail=/echo KTHail\n/ktdismount=/echo KTDismount')
    TH.assert_eq(d, 1, 'KissTell: leftover /kthail deleted')
    TH.assert_true(contains(sent, '/squelch /alias /kthail delete'), 'KissTell: /kthail delete sent')
    TH.assert_false(contains(sent, '/squelch /alias /ktdismount delete'), 'KissTell: /ktdismount kept')
end

return M
