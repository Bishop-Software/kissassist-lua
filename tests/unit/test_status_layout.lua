-- tests/unit/test_status_layout.lua
-- Status.buttonLayout: the status button row fits every label, wrapping onto
-- balanced rows when the window (e.g. mini mode) is too narrow.
local M = {}

function M.run(TH, MockMQ)
    TH.setSuite('test_status_layout')
    MockMQ.reset()
    local Status = require('modules.ui.status')
    local L = Status.buttonLayout

    local per, bw = L(700, 80, 8, 7)
    TH.assert_eq(per, 7, 'wide window: all 7 on one row')
    TH.assert_eq(bw, 93, 'wide window: width shares the row (700 - 6*8) / 7')

    per, bw = L(480, 75, 8, 7)
    TH.assert_eq(per, 4, 'mini width: 5 would fit, balanced to 4 + 3')
    TH.assert_eq(bw, 114, 'mini width: (480 - 3*8) / 4')
    TH.assert_true(bw >= 75, 'mini width: every label fits')

    per, bw = L(600, 80, 8, 7)
    TH.assert_eq(per, 4, '6 fit a row: balanced to 4 + 3, not 6 + 1')
    TH.assert_eq(bw, 144, '600 wide: (600 - 3*8) / 4')

    per, bw = L(50, 80, 8, 7)
    TH.assert_eq(per, 1, 'narrower than one label: one per row')
    TH.assert_eq(bw, 50, 'narrower than one label: full width')

    per, bw = L(700, 80, 8, 0)
    TH.assert_eq(per, 0, 'no buttons: nothing')
    TH.assert_eq(bw, 0, 'no buttons: width 0')
end

return M
