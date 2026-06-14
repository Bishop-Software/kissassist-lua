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
