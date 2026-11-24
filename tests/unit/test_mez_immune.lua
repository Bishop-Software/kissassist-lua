-- tests/unit/test_mez_immune.lua
-- Tests the per-zone MezImmune list in modules/mez.lua (#322): parsing, alert
-- list 4 commands, isImmuneName, loadZoneLists and addImmuneName.
local M = {}

function M.run(TH, MockMQ)
    local Config = require('modules.config')
    local Mez    = require('modules.mez')

    TH.setSuite('test_mez_immune')

    -- Info INI values the utils stub returns, by key.
    local ini = {}
    local utils = {
        debug      = function() end,
        zoneIniGet = function(_file, _zone, key) return ini[key] end,
    }
    local function newState()
        return {
            session = { zoneName = 'Lavastorm', infoFileName = 'KissAssist_Info.ini', iAmAMezClass = false },
            mez     = { immuneIDs = '', immuneList = '', aaImmune = false, immuneNotified = {} },
        }
    end
    local function rec(list) return function(c) list[#list + 1] = c end end

    MockMQ.reset()
    Config._setCfg({})
    local st = newState()
    Mez.init(st, utils, {}, nil)  -- also runs loadZoneLists (no list yet)

    -- ── parseImmuneList ─────────────────────────────────────────────────────
    local p = Mez.parseImmuneList('a fire snake, a lava crawler ,, ')
    TH.assert_eq(#p, 2, 'parse: two names, empties dropped')
    TH.assert_eq(p[2], 'a lava crawler', 'parse: names trimmed')
    TH.assert_eq(#Mez.parseImmuneList('NULL'), 0, 'parse: NULL → none')
    TH.assert_eq(#Mez.parseImmuneList(
        'List up to 10 mobs. Use full names i.e. a green snake,a blue tiger,a wide eye ooze or NULL'), 0,
        'parse: the mac placeholder text → none')
    TH.assert_eq(#Mez.parseImmuneList('a goblin,12:34'), 1, 'parse: entries with ":" skipped')
    TH.assert_eq(#Mez.parseImmuneList(nil), 0, 'parse: nil → none')

    -- ── alertCommands ───────────────────────────────────────────────────────
    local a = Mez.alertCommands({ 'a fire snake', '*crawler*' })
    TH.assert_eq(a[1], '/squelch /alert clear 4', 'alert: clears list 4 first')
    TH.assert_eq(a[2], '/squelch /alert add 4 "=a fire snake"', 'alert: exact name with =')
    TH.assert_eq(a[3], '/squelch /alert add 4 "crawler"', 'alert: * entry added as a partial name')
    TH.assert_eq(#Mez.alertCommands({}), 1, 'alert: empty list → only the clear')

    -- ── loadZoneLists ───────────────────────────────────────────────────────
    ini = { MezImmune = 'a fire snake,*crawler*', AAMezImmune = '1' }
    local sent = {}
    Mez.loadZoneLists(rec(sent))
    TH.assert_eq(st.mez.immuneList, 'a fire snake,*crawler*', 'load: list in state')
    TH.assert_true(st.mez.aaImmune, 'load: AAMezImmune=1')
    TH.assert_eq(#sent, 3, 'load: clear + two alert adds')

    ini = {}
    sent = {}
    Mez.loadZoneLists(rec(sent))
    TH.assert_eq(st.mez.immuneList, '', 'load: no list → empty')
    TH.assert_false(st.mez.aaImmune, 'load: AAMezImmune defaults off')
    TH.assert_eq(sent[1], '/squelch /alert clear 4', 'load: alert 4 still cleared for a zone with no list')

    -- ── isImmuneName ────────────────────────────────────────────────────────
    st.mez.immuneList = 'a fire snake,*crawler*'
    TH.assert_true(Mez.isImmuneName('A Fire Snake'), 'isImmune: exact name, any case')
    TH.assert_true(Mez.isImmuneName('a lava crawler'), 'isImmune: * entry matches part of the name')
    TH.assert_false(Mez.isImmuneName('a fire snakeling'), 'isImmune: exact entries need the whole name')
    TH.assert_false(Mez.isImmuneName(''), 'isImmune: empty name → false')
    TH.assert_false(Mez.isImmuneName(nil), 'isImmune: nil → false')

    -- ── addImmuneName ───────────────────────────────────────────────────────
    st.mez.immuneList = ''
    sent = {}
    TH.assert_true(Mez.addImmuneName('a magma bat', rec(sent)), 'add: new name → true')
    TH.assert_eq(st.mez.immuneList, 'a magma bat', 'add: first name becomes the list')
    TH.assert_eq(sent[1], '/ini "KissAssist_Info.ini" "Lavastorm" "MezImmune" "a magma bat"',
        'add: written to the Info INI under the zone')
    TH.assert_eq(sent[2], '/squelch /alert add 4 "=a magma bat"', 'add: added to alert list 4 at once')

    sent = {}
    TH.assert_false(Mez.addImmuneName('A Magma Bat', rec(sent)), 'add: already listed (any case) → false')
    TH.assert_eq(#sent, 0, 'add: nothing written for a duplicate')

    Mez.addImmuneName('a fire giant', rec({}))
    TH.assert_eq(st.mez.immuneList, 'a magma bat,a fire giant', 'add: appended with a comma')

    st.session.infoFileName = ''
    sent = {}
    Mez.addImmuneName('a salamander', rec(sent))
    TH.assert_eq(#sent, 1, 'add: no Info file → only the alert add')
    TH.assert_false(Mez.addImmuneName('  ', rec({})), 'add: blank name → false')
end

return M
