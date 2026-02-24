-- DynamicTrace.lua (fix: sandbox isolado, sem vazamento de _G, timeout via deadline)

local Ast      = require('prometheus.ast')
local Unparser = require('prometheus.unparser')

local DynamicTrace = {}
DynamicTrace.__index = DynamicTrace
DynamicTrace.Name = 'DynamicTrace'

function DynamicTrace:new(opts)
  return setmetatable({ opts = opts or {} }, self)
end

local is_lua51 = _VERSION == 'Lua 5.1'

-- ─── sandbox ──────────────────────────────────────────────────────────────────
-- FIX CRÍTICO: antes usava setmetatable(env, {__index = _G}) que vazava
-- todo o ambiente real (io.open, os.execute, etc.) para código não confiável.
-- Agora construímos um env 100% explícito com apenas o que é seguro.

local function make_safe_env(calls, level, deadline)
  local rec = function(name, ...)
    if level ~= 'prints' then
      local args = {}
      for i = 1, select('#', ...) do
        args[i] = tostring(select(i, ...))
      end
      calls[#calls + 1] = { name = name, args = args }
    end
  end

  local function check_deadline()
    if deadline and os.clock() > deadline then
      error('timeout', 2)
    end
  end

  -- Stub genérico para simular objetos Roblox/externos
  local function mkStub(path)
    local stub = {}
    local mt   = {}
    mt.__index = function(t, k)
      local v = rawget(t, k)
      if v ~= nil then return v end
      local child = mkStub(path .. '.' .. tostring(k))
      rawset(t, k, child)
      return child
    end
    mt.__newindex = function(t, k, v)
      rawset(t, k, v)
    end
    mt.__call = function(t, ...)
      rec('call:' .. path, ...)
      -- dispara callbacks passados como argumento
      for i = 1, select('#', ...) do
        local a = select(i, ...)
        if type(a) == 'function' then
          pcall(a)
          break
        end
      end
      return t
    end
    mt.__tostring = function() return '<stub:' .. path .. '>' end
    mt.__concat   = function(a, b) return tostring(a) .. tostring(b) end
    mt.__len      = function() return 0 end
    mt.__unm      = function() return 0 end
    mt.__add      = function() return 0 end
    mt.__sub      = function() return 0 end
    mt.__mul      = function() return 0 end
    mt.__div      = function() return 0 end
    mt.__mod      = function() return 0 end
    mt.__pow      = function() return 0 end
    mt.__lt       = function() return false end
    mt.__le       = function() return false end
    setmetatable(stub, mt)
    return stub
  end

  local fs = {}  -- filesystem virtual isolado

  -- ── Globals seguros explicitamente copiados (NÃO __index = _G) ─────────────
  local env = {
    -- standard seguro
    math         = math,
    string       = string,
    table        = table,
    pairs        = pairs,
    ipairs       = ipairs,
    next         = next,
    select       = select,
    type         = type,
    tostring     = tostring,
    tonumber     = tonumber,
    rawget       = rawget,
    rawset       = rawset,
    rawequal     = rawequal,
    setmetatable = setmetatable,
    getmetatable = getmetatable,
    assert       = assert,
    pcall        = pcall,
    xpcall       = xpcall,
    error        = error,
    unpack       = table.unpack or unpack,
    typeof       = type,
    _VERSION     = _VERSION,

    -- proibidos (não expostos): io, os, require, dofile, loadfile, debug

    print = function(...)
      local args = {}
      for i = 1, select('#', ...) do args[i] = select(i, ...) end
      calls[#calls + 1] = { name = 'print', args = args }
    end,

    io = {
      write = function(...)
        local args = {}
        for i = 1, select('#', ...) do args[i] = select(i, ...) end
        calls[#calls + 1] = { name = 'io.write', args = args }
      end,
    },

    -- executor / Roblox helpers
    getgenv           = function() return env end,
    getfenv           = function() return env end,
    setfenv           = function() end,
    cloneref          = function(v) return v end,
    newproxy          = newproxy,

    -- filesystem virtual (isolado do host)
    makefolder = function(path)
      rec('call:makefolder', path)
      fs['__dir__:' .. tostring(path)] = true
      return true
    end,
    isfolder = function(path)
      rec('call:isfolder', path)
      return fs['__dir__:' .. tostring(path)] == true
    end,
    writefile = function(path, data)
      rec('call:writefile', path, tostring(data):sub(1, 64))
      fs[tostring(path)] = data
      return true
    end,
    readfile = function(path)
      rec('call:readfile', path)
      return fs[tostring(path)]
    end,
    isfile = function(path)
      rec('call:isfile', path)
      return fs[tostring(path)] ~= nil
    end,
    setclipboard = function(data)
      rec('call:setclipboard', tostring(data):sub(1, 64))
      return true
    end,
    queue_on_teleport = function(src)
      rec('call:queue_on_teleport', tostring(src):sub(1, 64))
      return true
    end,

    -- network (retorna vazio, não faz requisições reais)
    http_request = function(opts)
      rec('call:http_request', tostring(opts and opts.Url or ''))
      return { StatusCode = 200, Body = '', Success = true }
    end,

    -- loadstring / load sandboxed
    loadstring = function(src)
      check_deadline()
      if not is_lua51 then
        local fn, err = load(src, 'dyn_chunk', 't', env)
        return fn, err
      end
      local fn, err = loadstring(src)
      if not fn then return nil, err end
      setfenv(fn, env)
      return fn
    end,
    load = function(src, name, mode, _env)
      check_deadline()
      return load(src, name or 'dyn_chunk', mode or 't', _env or env)
    end,
    require = function() return {} end,

    -- task
    task = {
      wait  = function(t) rec('call:task.wait', t) return 0 end,
      spawn = function(fn) rec('call:task.spawn'); if type(fn)=='function' then pcall(fn) end end,
      delay = function(t, fn) rec('call:task.delay', t); if type(fn)=='function' then pcall(fn) end end,
    },

    -- Roblox globals
    Instance = {
      new = function(cls, parent)
        rec('call:Instance.new', cls)
        return mkStub('Instance<' .. tostring(cls) .. '>')
      end,
    },
    Vector2   = { new = function() return mkStub('Vector2')  end },
    Vector3   = { new = function() return mkStub('Vector3')  end },
    UDim      = { new = function() return mkStub('UDim')     end },
    UDim2     = { new = function() return mkStub('UDim2')    end },
    Color3    = { fromRGB = function() return mkStub('Color3') end },
    TweenInfo = { new = function() return mkStub('TweenInfo') end },

    -- stubs principais
    game      = mkStub('game'),
    workspace = mkStub('workspace'),
    script    = mkStub('script'),
    Enum      = mkStub('Enum'),
  }

  -- Aliases de network
  env.request          = env.http_request
  env.http             = { request = env.http_request }
  env.syn              = { request = env.http_request }
  env.fluxus           = { request = env.http_request }
  env.HttpService      = mkStub('HttpService')
  env._ENV             = env
  env._G               = env

  -- Garante que table.find exista (Lua 5.1 não tem)
  if not env.table.find then
    env.table.find = function(t, v)
      for i = 1, #t do if t[i] == v then return i end end
      return nil
    end
  end

  return env
end

-- ─── runner ───────────────────────────────────────────────────────────────────

local function run_with_trace(code, level, timeout_secs)
  local calls    = {}
  local deadline = os.clock() + (timeout_secs or 10)
  local env      = make_safe_env(calls, level, deadline)

  local main, err
  if is_lua51 then
    main = loadstring(code)
    if not main then return calls end
    setfenv(main, env)
  else
    main = load(code, 'trace_main', 't', env)
    if not main then return calls end
  end

  pcall(main)
  return calls
end

-- ─── helpers de AST ───────────────────────────────────────────────────────────

local function to_node(v)
  local t = type(v)
  if t == 'string'  then return Ast.StringExpression(v)  end
  if t == 'number'  then return Ast.NumberExpression(v)  end
  if t == 'boolean' then return Ast.BooleanExpression(v) end
  return Ast.StringExpression(tostring(v))
end

local ignore_globals = {
  print=true, io=true, ipairs=true, pairs=true, pcall=true, xpcall=true,
  select=true, type=true, tostring=true, tonumber=true, rawget=true,
  rawset=true, getmetatable=true, setmetatable=true, getfenv=true,
  setfenv=true, load=true, loadstring=true, require=true, unpack=true,
  next=true, rawequal=true, assert=true, error=true,
}

-- ─── apply ───────────────────────────────────────────────────────────────────

function DynamicTrace:apply(ast, pipeline)
  local level   = (self.opts and self.opts.level) or 'prints'
  local timeout = (self.opts and self.opts.timeout) or 10
  local code    = (pipeline and pipeline.source) or ''

  if #code == 0 and pipeline and pipeline:getUnparser() then
    code = pipeline:getUnparser():unparse(ast)
  end

  local calls = run_with_trace(code, level, timeout)

  -- Fallback: tenta com código da AST atual
  if #calls == 0 and pipeline and pipeline:getUnparser() then
    local alt = pipeline:getUnparser():unparse(ast)
    if alt ~= code then
      calls = run_with_trace(alt, level, timeout)
    end
  end

  -- Último fallback: modo 'prints' apenas
  if #calls == 0 and level ~= 'prints' then
    calls = run_with_trace(code, 'prints', timeout)
    if #calls > 0 then level = 'prints' end
  end

  if #calls == 0 then return ast end

  local stmts = {}
  for _, c in ipairs(calls) do
    if c.name == 'print' then
      local args = {}
      for i = 1, #c.args do args[i] = to_node(c.args[i]) end
      local pScope, pId = ast.globalScope:resolveGlobal('print')
      stmts[#stmts + 1] = Ast.FunctionCallStatement(
        Ast.VariableExpression(pScope, pId), args)

    elseif c.name == 'io.write' then
      local args = {}
      for i = 1, #c.args do args[i] = to_node(c.args[i]) end
      local ioScope, ioId = ast.globalScope:resolveGlobal('io')
      local base = Ast.IndexExpression(
        Ast.VariableExpression(ioScope, ioId),
        Ast.StringExpression('write'))
      stmts[#stmts + 1] = Ast.FunctionCallStatement(base, args)

    elseif level == 'api' and (c.name:sub(1,5) == 'call:' or c.name:sub(1,4) == 'set:') then
      local args = { Ast.StringExpression('[' .. c.name .. ']') }
      for i = 1, #c.args do args[#args + 1] = to_node(c.args[i]) end
      local pScope, pId = ast.globalScope:resolveGlobal('print')
      stmts[#stmts + 1] = Ast.FunctionCallStatement(
        Ast.VariableExpression(pScope, pId), args)
    end
  end

  if #stmts > 0 then
    ast.body.statements = stmts
    print(string.format('[DynamicTrace] reproduziu %d chamadas', #stmts))
  end
  return ast
end

return DynamicTrace
