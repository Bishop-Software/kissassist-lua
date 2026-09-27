-- tests/unit/test_config_burn.lua
-- Tests Config.parseBurnEntry: .mac Burn layout SpellName|Target[|abort][|condNNN]
-- plus the legacy UI layout SpellName|HP%|Target|... (audit C6).
local M = {}

function M.run(TH, _MockMQ)
    local Config = require('modules.config')

    TH.setSuite('test_config_burn')

    do
        local spell, target, condNo = Config.parseBurnEntry('Spire of Chivalry|Me')
        TH.assert_eq(spell,  'Spire of Chivalry', 'mac: spell')
        TH.assert_eq(target, 'Me',                'mac: target')
        TH.assert_eq(condNo, 0,                   'mac: no cond')
    end

    do
        local spell, target, condNo = Config.parseBurnEntry('Frenzied Burnout|Mob|cond003')
        TH.assert_eq(spell,  'Frenzied Burnout', 'mac cond: spell')
        TH.assert_eq(target, 'Mob',              'mac cond: target')
        TH.assert_eq(condNo, 3,                  'mac cond: cond003 → 3')
    end

    do
        local _, target, condNo = Config.parseBurnEntry('Glyph of Destruction|MA|Cond12')
        TH.assert_eq(target, 'MA', 'uppercase Cond: target')
        TH.assert_eq(condNo, 12,   'uppercase Cond: Cond12 → 12')
    end

    do
        local _, target = Config.parseBurnEntry('Nuke|Mob|abort')
        TH.assert_eq(target, 'Mob', 'abort flag: target unaffected')
    end

    do
        local spell, target, condNo = Config.parseBurnEntry('Intensity|0|me|cond2')
        TH.assert_eq(spell,  'Intensity', 'legacy UI: spell')
        TH.assert_eq(target, 'me',        'legacy UI: numeric HP skipped, target recovered')
        TH.assert_eq(condNo, 2,           'legacy UI: cond')
    end

    do
        local spell, target, condNo = Config.parseBurnEntry('Epic Clicky')
        TH.assert_eq(spell,  'Epic Clicky', 'bare: spell')
        TH.assert_eq(target, '',            'bare: empty target → caller defaults to Mob')
        TH.assert_eq(condNo, 0,             'bare: no cond')
    end
end

return M
