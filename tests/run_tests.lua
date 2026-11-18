-- tests/run_tests.lua
-- KissAssist unit test runner.
-- Invoke with: /lua run kissassist-lua test
--
-- Unit tests run with a programmable mock injected into package.loaded['mq'],
-- so the modules under test get the mock instead of the real MacroQuest mq module.
-- After each test file the real mq is restored.
--
-- Integration tests (tests/integration/) are listed separately and require
-- kissassist to already be running on the character. Run them individually via
-- mq_eval rather than through this runner.

local mq     = require('mq')
local MockMQ = require('tests.mock_mq')
local TH     = require('tests.test_helpers')

-- Clear module cache entries before a test that needs a fresh require.
local function clearCache(names)
    for _, n in ipairs(names) do
        package.loaded[n] = nil
    end
end

-- Unit test descriptors.
-- useMock:      inject MockMQ into package.loaded['mq'] before requiring the test file.
-- clearModules: modules to evict from package.loaded so they re-require with the mock.
local unitTests = {
    {
        name         = 'test_state',
        path         = 'tests.unit.test_state',
        useMock      = false,
        clearModules = {},
    },
    {
        name         = 'test_utils',
        path         = 'tests.unit.test_utils',
        useMock      = false,
        clearModules = {},
    },
    {
        name         = 'test_cast_rank',
        path         = 'tests.unit.test_cast_rank',
        useMock      = true,
        clearModules = { 'modules.utils' },
    },
    {
        name         = 'test_buffs_parse',
        path         = 'tests.unit.test_buffs_parse',
        useMock      = true,
        clearModules = { 'modules.buffs' },
    },
    {
        name         = 'test_weave',
        path         = 'tests.unit.test_weave',
        useMock      = true,
        clearModules = { 'modules.combat.settings', 'modules.cast', 'modules.config', 'modules.utils' },
    },
    {
        name         = 'test_helpers',
        path         = 'tests.unit.test_helpers_module',
        useMock      = false,
        clearModules = { 'modules.helpers' },
    },
    {
        name         = 'test_cond',
        path         = 'tests.unit.test_cond',
        useMock      = true,
        clearModules = { 'modules.cond', 'modules.config' },
    },
    {
        name         = 'test_config_args',
        path         = 'tests.unit.test_config_args',
        useMock      = true,
        clearModules = { 'modules.config' },
    },
    {
        name         = 'test_config_cond',
        path         = 'tests.unit.test_config_cond',
        useMock      = true,
        clearModules = { 'modules.config' },
    },
    {
        name         = 'test_config_burn',
        path         = 'tests.unit.test_config_burn',
        useMock      = true,
        clearModules = { 'modules.config' },
    },
    {
        name         = 'test_charm',
        path         = 'tests.unit.test_charm',
        useMock      = true,
        clearModules = { 'modules.charm', 'modules.config' },
    },
    {
        name         = 'test_buffs',
        path         = 'tests.unit.test_buffs',
        useMock      = false,
        clearModules = {},
    },
    {
        name         = 'test_healing_rez',
        path         = 'tests.unit.test_healing_rez',
        useMock      = true,
        clearModules = { 'modules.healing', 'modules.config' },
    },
    {
        name         = 'test_healing_xtar',
        path         = 'tests.unit.test_healing_xtar',
        useMock      = true,
        clearModules = { 'modules.healing', 'modules.config' },
    },
    {
        name         = 'test_healing_pet',
        path         = 'tests.unit.test_healing_pet',
        useMock      = true,
        clearModules = { 'modules.healing', 'modules.config' },
    },
    {
        name         = 'test_healing_med',
        path         = 'tests.unit.test_healing_med',
        useMock      = true,
        clearModules = { 'modules.healing', 'modules.config' },
    },
    {
        name         = 'test_pull_hold',
        path         = 'tests.unit.test_pull_hold',
        useMock      = true,
        clearModules = { 'modules.pull', 'modules.pull.util', 'modules.config' },
    },
    {
        name         = 'test_comms_announce',
        path         = 'tests.unit.test_comms_announce',
        useMock      = true,
        clearModules = { 'modules.comms' },
    },
    {
        name         = 'test_merc',
        path         = 'tests.unit.test_merc',
        useMock      = true,
        clearModules = { 'modules.merc', 'modules.config' },
    },
    {
        name         = 'test_dps_immune',
        path         = 'tests.unit.test_dps_immune',
        useMock      = true,
        clearModules = { 'modules.cast', 'modules.config' },
    },
    {
        name         = 'test_pull_aggro',
        path         = 'tests.unit.test_pull_aggro',
        useMock      = true,
        clearModules = { 'modules.utils', 'modules.config' },
    },
    {
        name         = 'test_pull_arc',
        path         = 'tests.unit.test_pull_arc',
        useMock      = true,
        clearModules = { 'modules.pull', 'modules.pull.util', 'modules.config' },
    },
    {
        name         = 'test_pull_ready',
        path         = 'tests.unit.test_pull_ready',
        useMock      = true,
        clearModules = { 'modules.pull', 'modules.pull.util', 'modules.config' },
    },
    {
        name         = 'test_pull_wait',
        path         = 'tests.unit.test_pull_wait',
        useMock      = true,
        clearModules = { 'modules.pull', 'modules.pull.util', 'modules.config' },
    },
    {
        name         = 'test_pull_range',
        path         = 'tests.unit.test_pull_range',
        useMock      = true,
        clearModules = { 'modules.pull', 'modules.pull.util', 'modules.config' },
    },
    {
        name         = 'test_pull_ignore',
        path         = 'tests.unit.test_pull_ignore',
        useMock      = true,
        clearModules = { 'modules.pull', 'modules.pull.util', 'modules.config' },
    },
    {
        name         = 'test_pull_map',
        path         = 'tests.unit.test_pull_map',
        useMock      = true,
        clearModules = { 'modules.pull', 'modules.pull.util', 'modules.config' },
    },
    {
        name         = 'test_pull_ranking',
        path         = 'tests.unit.test_pull_ranking',
        useMock      = true,
        clearModules = { 'modules.pull', 'modules.pull.util', 'modules.config' },
    },
    {
        name         = 'test_pull_move',
        path         = 'tests.unit.test_pull_move',
        useMock      = true,
        clearModules = { 'modules.pull', 'modules.pull.util', 'modules.config' },
    },
    {
        name         = 'test_pull_level',
        path         = 'tests.unit.test_pull_level',
        useMock      = true,
        clearModules = { 'modules.pull', 'modules.pull.util', 'modules.config' },
    },
    {
        name         = 'test_pull_pause',
        path         = 'tests.unit.test_pull_pause',
        useMock      = true,
        clearModules = { 'modules.pull', 'modules.pull.util', 'modules.config' },
    },
    {
        name         = 'test_pull_role',
        path         = 'tests.unit.test_pull_role',
        useMock      = true,
        clearModules = { 'modules.pull', 'modules.pull.util', 'modules.config' },
    },
    {
        name         = 'test_pull_chain',
        path         = 'tests.unit.test_pull_chain',
        useMock      = true,
        clearModules = { 'modules.pull', 'modules.pull.util', 'modules.config' },
    },
    {
        name         = 'test_pull_on_return',
        path         = 'tests.unit.test_pull_on_return',
        useMock      = true,
        clearModules = { 'modules.pull', 'modules.pull.util', 'modules.config' },
    },
    {
        name         = 'test_pull_locs',
        path         = 'tests.unit.test_pull_locs',
        useMock      = true,
        clearModules = { 'modules.pull', 'modules.pull.util', 'modules.config' },
    },
    {
        name         = 'test_pull_hunter_role',
        path         = 'tests.unit.test_pull_hunter_role',
        useMock      = true,
        clearModules = { 'modules.pull', 'modules.pull.util', 'modules.config' },
    },
    {
        name         = 'test_pull_puller_role',
        path         = 'tests.unit.test_pull_puller_role',
        useMock      = true,
        clearModules = { 'modules.pull', 'modules.pull.util', 'modules.movement', 'modules.config' },
    },
    {
        name         = 'test_afk_camp_on_death',
        path         = 'tests.unit.test_afk_camp_on_death',
        useMock      = true,
        clearModules = { 'modules.afk' },
    },
    {
        name         = 'test_config_scan_ini',
        path         = 'tests.unit.test_config_scan_ini',
        useMock      = true,
        clearModules = { 'modules.config' },
    },
    {
        name         = 'test_comms_chat_relay',
        path         = 'tests.unit.test_comms_chat_relay',
        useMock      = true,
        clearModules = { 'modules.comms', 'modules.config' },
    },
    {
        name         = 'test_groupwatch',
        path         = 'tests.unit.test_groupwatch',
        useMock      = true,
        clearModules = { 'modules.groupwatch', 'modules.config' },
    },
}

printf('\n\aw[TEST]\ax Starting KissAssist unit test suite...\n')

for _, t in ipairs(unitTests) do
    -- Inject mock before any module re-requires happen.
    if t.useMock then
        package.loaded['mq'] = MockMQ
        MockMQ.reset()
    end

    -- Evict stale cached modules so they re-require fresh with the mock.
    clearCache(t.clearModules)

    -- Evict the test file itself so it re-evaluates each run (useful when
    -- run_tests is invoked multiple times in the same session).
    package.loaded[t.path] = nil

    TH.setSuite(t.name)
    local pBefore, fBefore = TH.passFail()

    local ok, err = pcall(function()
        require(t.path).run(TH, MockMQ)
    end)

    if not ok then
        TH.recordError(t.name, tostring(err))
    end

    -- Per-file summary line.
    local pAfter, fAfter = TH.passFail()
    local nPass = pAfter  - pBefore
    local nFail = fAfter  - fBefore
    local total = nPass + nFail
    if nFail == 0 then
        printf('\ag[PASS]\ax %-26s %d/%d', t.name, nPass, total)
    else
        printf('\ar[FAIL]\ax %-26s %d/%d', t.name, nPass, total)
    end

    -- Restore real mq after each mock test.
    if t.useMock then
        package.loaded['mq'] = mq
    end
end

TH.printSummary()
