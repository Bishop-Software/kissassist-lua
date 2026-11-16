-- tests/unit/test_config_scan_ini.lua
-- #243: /kisscheck runs the mac's INI spell-name check (ScanIni mac:12972-13088).
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_config_scan_ini')
    MockMQ.reset()
    local Config = require('modules.config')

    -- Known names: book spells, an AA, a disc, an item, a skill
    local known = {
        ['Book:Healing Light'] = 1, ['Book:Shield of Words Rk. II'] = 1,
        ['AA:Divine Arbitration'] = 1, ['Disc:Fortitude Discipline'] = 1,
        ['Item:=Staff of Truth'] = 1, ['Skill:Kick'] = 1,
    }
    local function look(kind) return function(name) return function() return known[kind .. ':' .. name] end end end
    MockMQ.set('TLO.Me.Book', look('Book'))
    MockMQ.set('TLO.Me.CombatAbility', look('Disc'))
    MockMQ.set('TLO.Me.Skill', look('Skill'))
    -- Proxies with .ID / .RankName members
    local function idProxy(kind)
        return function(name)
            return { ID = function() return known[kind .. ':' .. name] end }
        end
    end
    MockMQ.set('TLO.Me.AltAbility', idProxy('AA'))
    MockMQ.set('TLO.FindItem', idProxy('Item'))
    MockMQ.set('TLO.Spell', function(name)
        return { RankName = function() return name == 'Shield of Words' and 'Shield of Words Rk. II' or name end }
    end)

    local cfg = {
        Buffs = { Buffs = {
            'Shield of Words',                 -- ranked spell, found via RankName
            'Summoned Bread|summon|Fresh Bread', -- summon entry: skipped
            'Fresh Bread',                     -- the summoned item: skipped
            'Misspelt Buff',                   -- error
            'null', '',
        } },
        DPS   = { DPS = { 'Kick|90', 'Command:/echo hi|50', ';Healing Light', 'Bogus Nuke|80' } },
        Heals = { Heals = { 'Healing Light|70', 'Divine Arbitration|40' } },
        AE    = { AE = { 'Burn|2' } },
        Cures = { Cures = { 'null' } },
        Aggro = { Aggro = { 'Fortitude Discipline|1' } },
        GoM   = { GoMSpell = { 'Gift of Mana|Healing Light' } },
        Burn  = { Burn = { 'Staff of Truth' } },
        Pet   = { PetSpell = 'Not A Pet', PetShrinkSpell = '', PetBreakMezSpell = 'null', PetBuffs = {} },
        Mez   = { MezSpell = '', MezAESpell = '' },
        Pull  = { PullWith = 'Melee' },
    }
    Config._setCfg(cfg)

    local errs = Config.scanIni('all')
    TH.assert_eq(errs, 3, 'all sections: 3 errors (Misspelt Buff, Bogus Nuke, Not A Pet)')

    TH.assert_eq(Config.scanIni('Buffs'), 1, 'Buffs: only the misspelt buff; summon entry and its item skipped')
    TH.assert_eq(Config.scanIni('DPS'), 1, 'DPS: skill ok, Command: and ;comment skipped, bogus flagged')
    TH.assert_eq(Config.scanIni('Heals'), 0, 'Heals: book spell and AA found')
    TH.assert_eq(Config.scanIni('AE'), 0, 'AE: Burn entry skipped')
    TH.assert_eq(Config.scanIni('GoM'), 0, 'GoM: Gift of Mana skipped')
    TH.assert_eq(Config.scanIni('Aggro'), 0, 'Aggro: disc found')
    TH.assert_eq(Config.scanIni('Burn'), 0, 'Burn: item found')
    TH.assert_eq(Config.scanIni('Pet'), 1, 'Pet: PetSpell not found')
    TH.assert_eq(Config.scanIni('pull'), 0, 'Pull: Melee skipped (case-insensitive section name)')
    TH.assert_eq(Config.scanIni('Heals|DPS'), 1, 'two sections at once')

    cfg.Pull.PullWith = 'Nope Bolt'
    TH.assert_eq(Config.scanIni('Pull'), 1, 'Pull: unknown PullWith flagged')

    Config._setCfg(nil)
end

return M
