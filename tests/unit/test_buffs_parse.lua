-- tests/unit/test_buffs_parse.lua
-- Buffs._parseEntry (mac:4233-4272 parse + Dual normalization) and the #298
-- Dual + Mana/End extension (Buffs._dualRegen).
local M = {}

function M.run(TH, _MockMQ)
    TH.setSuite('test_buffs_parse')
    local Buffs = require('modules.buffs')

    local function parse(entry)
        local s, p2, p3, p4, p5 = Buffs._parseEntry(entry)
        return { s = s, p2 = p2, p3 = p3, p4 = p4, p5 = p5 }
    end

    -- Plain and existing tags are unchanged.
    local r = parse('Xenacious\' Skin')
    TH.assert_eq(r.s, 'Xenacious\' Skin', 'plain: spellToCast')
    TH.assert_eq(r.p2, '', 'plain: no tag')

    r = parse('Unified Phoenix Feather|Mana|80')
    TH.assert_eq(r.s, 'Unified Phoenix Feather', 'mana: spellToCast')
    TH.assert_eq(r.p2, 'mana', 'mana: tag')
    TH.assert_eq(r.p3, '80', 'mana: threshold in p3')

    r = parse('Dark Lord\'s Unity (Azia)|Dual|Penumbral Call|me')
    TH.assert_eq(r.p2, 'dualme', 'Dual|..|me -> dualme')
    TH.assert_eq(r.p3, 'Penumbral Call', 'dualme: buff name in p3')

    r = parse('Some Buff|Dual|Other Buff')
    TH.assert_eq(r.p2, 'dual', 'Dual without a 4th field stays dual')

    r = parse('Foo|alias')
    TH.assert_eq(r.p2, 'alias', 'alias tag reported for skip')

    r = parse('Shield of Fate|class|WAR,PAL,SHD')
    TH.assert_eq(r.p5, 'WAR,PAL,SHD', 'class: list copied to p5')

    -- #298: Dual + Mana / End.
    r = parse('Unified Phoenix Feather|Dual|Grace of Unity|Mana|80')
    TH.assert_eq(r.s, 'Unified Phoenix Feather', 'dualmana: cast name')
    TH.assert_eq(r.p2, 'dualmana', 'Dual|..|Mana -> dualmana')
    TH.assert_eq(r.p3, 'Grace of Unity', 'dualmana: buff to check in p3')
    TH.assert_eq(r.p5, '80', 'dualmana: threshold in p5')

    r = parse('Some Clicky|dual|Some Song|END|30')
    TH.assert_eq(r.p2, 'dualend', 'dual|..|END (any case) -> dualend')
    TH.assert_eq(r.p5, '30', 'dualend: threshold in p5')

    -- Buff on me: skip. Otherwise hand off to the plain tag with the threshold.
    TH.assert_nil(Buffs._dualRegen('dualmana', '80', true), 'dualRegen: buff on me -> skip')
    local tag, thresh = Buffs._dualRegen('dualmana', '80', false)
    TH.assert_eq(tag, 'mana', 'dualRegen: dualmana -> mana')
    TH.assert_eq(thresh, '80', 'dualRegen: dualmana threshold')
    tag, thresh = Buffs._dualRegen('dualend', '30', false)
    TH.assert_eq(tag, 'end', 'dualRegen: dualend -> end')
    TH.assert_eq(thresh, '30', 'dualRegen: dualend threshold')
end

return M
