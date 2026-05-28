-- tests/test_helpers.lua
-- Assertion utilities and pass/fail tracker for the KissAssist test runner.
--
-- Each test file calls TH.assert_* to record results.
-- The runner reads TH.passFail() before and after each file for per-file counts.
-- TH.printSummary() prints the final totals and any failure messages.

local TH = {}

local _pass     = 0
local _fail     = 0
local _failures = {}
local _suite    = 'unknown'

function TH.setSuite(name)
    _suite = name
end

local function pass()
    _pass = _pass + 1
end

local function fail(msg)
    _fail = _fail + 1
    local entry = string.format('[%s] %s', _suite, msg)
    _failures[#_failures + 1] = entry
    printf('\ar[FAIL]\ax %s', entry)
end

-- Assertions -----------------------------------------------------------

function TH.assert_true(val, msg)
    if val then
        pass()
    else
        fail((msg or 'expected true') .. ' (got: ' .. tostring(val) .. ')')
    end
end

function TH.assert_false(val, msg)
    if not val then
        pass()
    else
        fail((msg or 'expected false') .. ' (got: ' .. tostring(val) .. ')')
    end
end

function TH.assert_eq(actual, expected, msg)
    if actual == expected then
        pass()
    else
        fail(string.format('%s — expected %s, got %s',
            msg or 'assert_eq', tostring(expected), tostring(actual)))
    end
end

function TH.assert_ne(actual, unexpected, msg)
    if actual ~= unexpected then
        pass()
    else
        fail(string.format('%s — expected NOT %s, got %s',
            msg or 'assert_ne', tostring(unexpected), tostring(actual)))
    end
end

function TH.assert_near(actual, expected, epsilon, msg)
    epsilon = epsilon or 0.001
    if math.abs(actual - expected) <= epsilon then
        pass()
    else
        fail(string.format('%s — expected ~%s (±%s), got %s',
            msg or 'assert_near', tostring(expected), tostring(epsilon), tostring(actual)))
    end
end

function TH.assert_nil(val, msg)
    if val == nil then
        pass()
    else
        fail((msg or 'expected nil') .. ' (got: ' .. tostring(val) .. ')')
    end
end

function TH.assert_not_nil(val, msg)
    if val ~= nil then
        pass()
    else
        fail(msg or 'expected non-nil, got nil')
    end
end

function TH.assert_type(val, expected_type, msg)
    if type(val) == expected_type then
        pass()
    else
        fail(string.format('%s — expected type %s, got %s',
            msg or 'assert_type', expected_type, type(val)))
    end
end

-- Record a pcall error as a test failure (used by run_tests.lua).
function TH.recordError(suite, err)
    _fail = _fail + 1
    local entry = string.format('[%s] runtime error: %s', suite, err)
    _failures[#_failures + 1] = entry
    printf('\ar[ERROR]\ax %s', entry)
end

-- Returns current pass/fail counts (runner uses these before+after each file).
function TH.passFail()
    return _pass, _fail
end

-- Print final suite summary.
function TH.printSummary()
    local total = _pass + _fail
    if _fail == 0 then
        printf('\n\ag[TEST]\ax Suite complete: \ag%d/%d passed\ax', _pass, total)
    else
        printf('\n\ar[TEST]\ax Suite complete: \ag%d passed\ax, \ar%d FAILED\ax (of %d total)',
            _pass, _fail, total)
        printf('\ar--- Failures ---\ax')
        for _, f in ipairs(_failures) do
            printf('\ar  >> %s\ax', f)
        end
    end
end

return TH
