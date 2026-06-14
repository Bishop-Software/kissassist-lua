-- tests/unit/test_config_cond.lua
-- Tests Config.parseCondArray with case-insensitive |CondN detection (issue #172).
local M = {}

function M.run(TH, _MockMQ)
    local Config = require('modules.config')

    TH.setSuite('test_config_cond')

    -- Lowercase canonical form ----------------------------------------
    do
        local out = Config.parseCondArray({ 'Boastful Bellow|98|cond001' })
        TH.assert_eq(out[1].name,   'Boastful Bellow|98', 'lowercase: name stripped')
        TH.assert_eq(out[1].condNo, 1,                    'lowercase: condNo=1')
    end

    -- Uppercase Cond (migrated from .mac) --------------------------------
    do
        local out = Config.parseCondArray({ 'Boastful Bellow|98|Cond1' })
        TH.assert_eq(out[1].name,   'Boastful Bellow|98', 'uppercase: name stripped')
        TH.assert_eq(out[1].condNo, 1,                    'uppercase: condNo=1')
    end

    -- Uppercase Cond in position 4 (target present) ----------------------
    do
        local out = Config.parseCondArray({ 'Lyrical Prankster|99|Mob|Cond3' })
        TH.assert_eq(out[1].name,   'Lyrical Prankster|99|Mob', 'uppercase pos4: name')
        TH.assert_eq(out[1].condNo, 3,                          'uppercase pos4: condNo=3')
    end

    -- Uppercase Cond with two-digit number -------------------------------
    do
        local out = Config.parseCondArray({ 'Cacophony|99|Cond10' })
        TH.assert_eq(out[1].condNo, 10, 'uppercase two-digit: condNo=10')
        TH.assert_eq(out[1].name,   'Cacophony|99', 'uppercase two-digit: name')
    end

    -- No cond suffix → condNo=0 -----------------------------------------
    do
        local out = Config.parseCondArray({ 'Aureates Bane|100' })
        TH.assert_eq(out[1].condNo, 0,                'no cond: condNo=0')
        TH.assert_eq(out[1].name,   'Aureates Bane|100', 'no cond: name unchanged')
    end

    -- Mixed-case array: entries with and without cond --------------------
    do
        local arr = {
            'SpellA|95',
            'SpellB|90|Cond2',
            'SpellC|80|cond003',
        }
        local out = Config.parseCondArray(arr)
        TH.assert_eq(out[1].condNo, 0, 'mixed[1]: no cond')
        TH.assert_eq(out[2].condNo, 2, 'mixed[2]: Cond2 → 2')
        TH.assert_eq(out[3].condNo, 3, 'mixed[3]: cond003 → 3')
        TH.assert_eq(out[2].name,   'SpellB|90', 'mixed[2]: name')
        TH.assert_eq(out[3].name,   'SpellC|80', 'mixed[3]: name')
    end
end

return M
