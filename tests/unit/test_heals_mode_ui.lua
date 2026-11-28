-- tests/unit/test_heals_mode_ui.lua
-- Healing tab Heals dropdown (#358): HealsOn is a mode 0-4, so the combo shows
-- every mode and maps its 1-based index back to the same number.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_heals_mode_ui')
    MockMQ.reset()
    local HealingUI = require('modules.ui.healing')
    local idx = HealingUI.healsModeIndex

    TH.assert_eq(#HealingUI.HEALS_MODE_LABELS, 5, 'a label for each mode 0-4')
    for v = 0, 4 do
        TH.assert_eq(idx(v), v + 1, 'HealsOn ' .. v .. ' shows as combo item ' .. (v + 1))
        TH.assert_eq(idx(v) - 1, v, 'combo item ' .. (v + 1) .. ' sets HealsOn ' .. v)
    end
    TH.assert_eq(idx('3'), 4, 'a string value maps like its number')
    TH.assert_eq(idx(nil), 1, 'nil shows as Off')
    TH.assert_eq(idx(-1), 1, 'below 0 shows as Off')
    TH.assert_eq(idx(9), 5, 'above 4 shows as Self only')
end

return M
