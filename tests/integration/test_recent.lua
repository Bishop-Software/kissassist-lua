-- tests/integration/test_recent.lua
-- Live checks for recent PRs that don't need a fight (issue #246):
--   #317 / #324  the mac's aliases exist in MacroQuest.ini; delete-list and
--                KissTell aliases are gone, /ktdismount stays
--   #319         the window title matches WinTitleText
--   #327         CheckStuckGems leaves a normal (not stuck) client alone; the
--                Origin AA and CastingWindow lookups resolve
--   #328         petHoldCommand follows the live Companion's Discipline rank;
--                stopMoving returns at once when standing still; with a pet and
--                PetHoldOn, the hold command really puts the pet on hold
--
-- Run in-game while kissassist is running: /kactl test recent
local M = {}

local D = 500  -- ms to let a command take effect

local function readMQIni(mq)
    local f = io.open(mq.configDir .. '/MacroQuest.ini', 'r')
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    return text
end

function M.run(mq, State, TH)
    TH.setSuite('test_recent')
    local Aliases = require('modules.aliases')
    local Binds   = require('modules.binds')
    local Startup = require('modules.startup')
    local Cast    = require('modules.cast')
    local Utils   = require('modules.utils')

    -- ── #317 / #324: aliases ────────────────────────────────────────────────
    local text = readMQIni(mq)
    TH.assert_not_nil(text, 'aliases: MacroQuest.ini readable')
    local current = Aliases.parse(text)
    local missing, wrong = {}, {}
    for _, a in ipairs(Aliases.LIST) do
        local name, target = a[1], a[2]
        if not Binds.isBound(name) then
            local have = current[name:lower()]
            if not have then
                missing[#missing + 1] = name
            elseif have:lower() ~= target:lower() then
                wrong[#wrong + 1] = name .. ' = ' .. have
            end
        end
    end
    TH.assert_eq(#missing, 0, 'aliases: every mac alias exists (missing: ' .. table.concat(missing, ', ') .. ')')
    TH.assert_eq(#wrong, 0, 'aliases: every alias has the mac\'s text (' .. table.concat(wrong, '; ') .. ')')
    local leftover = {}
    for _, name in ipairs(Aliases.DELETES) do
        if current[name:lower()] then leftover[#leftover + 1] = name end
    end
    TH.assert_eq(#leftover, 0, 'aliases: delete list is gone (left: ' .. table.concat(leftover, ', ') .. ')')
    TH.assert_nil(current['/kthail'], 'aliases: /kthail deleted (KissTell won\'t do)')
    TH.assert_eq(current['/ktdismount'], '/echo KTDismount', 'aliases: /ktdismount kept')
    TH.assert_eq(current['/peton'], '/togglevariable PetOn', 'aliases: /peton is the mac alias')

    -- ── #319: window title ──────────────────────────────────────────────────
    local wt = State.misc.winTitleText
    if wt and wt ~= '' and wt:lower() ~= 'null' then
        TH.assert_true(Startup.setWinTitle(), 'title: setWinTitle sets a title')
        mq.delay(D)
        TH.assert_eq(mq.TLO.EverQuest.WinTitle(), mq.parse(wt), 'title: window title = parsed WinTitleText')
    else
        TH.assert_false(Startup.setWinTitle(), 'title: WinTitleText null -> title left alone')
    end

    -- ── #327: CheckStuckGems ────────────────────────────────────────────────
    TH.assert_type(mq.TLO.Window('CastingWindow').Open(), 'boolean', 'stuck gems: CastingWindow lookup works')
    TH.assert_true((mq.TLO.Me.AltAbility('Origin').ID() or 0) > 0, 'stuck gems: Origin AA found by name')
    if (mq.TLO.Me.Casting.ID() or 0) == 0 then
        TH.assert_false(Cast.checkStuckGems(), 'stuck gems: not casting -> nothing done')
    end

    -- ── #328: pet hold type and stopMoving ──────────────────────────────────
    local rank = mq.TLO.Me.AltAbility("Companion's Discipline").Rank()
    TH.assert_type(rank, 'number', 'pet hold: Companion\'s Discipline rank readable')
    local expect = (rank or 0) > 1 and '/pet ghold on' or '/pet hold on'
    TH.assert_eq(Utils.petHoldCommand(), expect, 'pet hold: command follows the live rank')

    if not mq.TLO.Me.Moving() then
        local t0 = os.clock()
        Cast.stopMoving()
        TH.assert_true(os.clock() - t0 < 1, 'stopMoving: returns at once when not moving')
    end

    if (mq.TLO.Me.Pet.ID() or 0) ~= 0 and (State.pet.holdOn or 0) ~= 0 then
        mq.cmd(Utils.petHoldCommand())
        mq.delay(D)
        local onHold = (rank or 0) > 1 and mq.TLO.Pet.GHold() or mq.TLO.Pet.Hold()
        TH.assert_true(onHold == true, 'pet hold: pet is on ' .. ((rank or 0) > 1 and 'ghold' or 'hold'))
    end
end

return M
