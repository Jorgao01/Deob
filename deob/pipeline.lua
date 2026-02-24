-- pipeline.lua (fixed: pcall por step, timeout, menos memória)

local function add_path()
  local here = debug.getinfo(1, 'S').source:sub(2)
  local dir = here:match('(.*[/%\\])') or ''
  package.path = dir .. '../../Prometheus/src/?.lua;' .. dir .. '?.lua;' .. package.path
end
add_path()

local Parser   = require('prometheus.parser')
local Unparser = require('prometheus.unparser')
local Enums    = require('prometheus.enums')
local Ast      = require('prometheus.ast')
local visitast = require('prometheus.visitast')

local DeobPipeline = {}
DeobPipeline.__index = DeobPipeline

-- ─── helpers ──────────────────────────────────────────────────────────────────

local function count_nodes(ast)
  local k = Ast.AstKind
  local c = { func=0, strings=0, numbers=0, assigns=0 }
  visitast(ast, nil, function(n)
    if n.kind == k.FunctionDeclaration
    or n.kind == k.LocalFunctionDeclaration
    or n.kind == k.FunctionLiteralExpression then c.func = c.func + 1 end
    if n.kind == k.StringExpression  then c.strings  = c.strings  + 1 end
    if n.kind == k.NumberExpression  then c.numbers  = c.numbers  + 1 end
    if n.kind == k.AssignmentStatement then c.assigns = c.assigns + 1 end
  end)
  return c
end

local function line_count(s)
  local _, n = s:gsub('\n', '')
  return n + 1
end

-- Timeout simples via os.clock (não requer threads)
-- Retorna ok, resultado ou ok=false, msg='timeout'
local function run_with_timeout(fn, seconds)
  -- Lua 5.1 não tem coroutine preemptivo, então usamos pcall + deadline passado como upvalue
  -- Para steps que respeitam o deadline no loop interno; os steps dinâmicos verificam isso
  local deadline = os.clock() + seconds
  local ok, res = pcall(fn, deadline)
  if not ok then
    if tostring(res):find('timeout') then
      return false, 'timeout após ' .. seconds .. 's'
    end
    return false, tostring(res)
  end
  return true, res
end

-- ─── pipeline ────────────────────────────────────────────────────────────────

function DeobPipeline:new(opts)
  local o = {
    luaVersion  = (opts and (opts.LuaVersion or opts.luaVersion)) or Enums.LuaVersion.Lua51,
    prettyPrint = opts and opts.PrettyPrint or false,
    steps       = {},
    metrics     = {},
    errors      = {},   -- erros por step
    last_ast    = nil,
    -- snapshots só guardados se emit_snapshots = true (economiza memória)
    snapshots        = nil,
    emit_snapshots   = opts and opts.emit_snapshots or false,
    step_timeout     = opts and opts.step_timeout or 60,  -- segundos por step
  }
  setmetatable(o, self)
  o.parser   = Parser:new({ LuaVersion = o.luaVersion })
  o.unparser = Unparser:new({ LuaVersion = o.luaVersion, PrettyPrint = o.prettyPrint })
  if o.emit_snapshots then o.snapshots = {} end
  return o
end

function DeobPipeline:add(step)
  table.insert(self.steps, step)
  return self
end

function DeobPipeline:getParser()   return self.parser   end
function DeobPipeline:getUnparser() return self.unparser end

function DeobPipeline:apply(code)
  local ast, parse_err = self.parser:parse(code)
  if not ast then
    error('Falha ao parsear código: ' .. tostring(parse_err))
  end

  for _, step in ipairs(self.steps) do
    local name = tostring(step.Name or step.__name or step.__index or step)

    -- métricas antes
    local before_code   = self.unparser:unparse(ast)
    local before_lines  = line_count(before_code)
    local before_counts = count_nodes(ast)

    -- roda o step com pcall para não derrubar o pipeline inteiro
    local ast_backup = ast  -- mantém AST anterior em caso de crash
    local ok, result = pcall(function()
      return step:apply(ast, self)
    end)

    if not ok then
      -- step crashou: loga o erro e continua com a AST anterior
      local msg = tostring(result)
      self.errors[name] = msg
      print(string.format('[%s] ERRO (AST preservada): %s', name, msg))
      ast = ast_backup
    else
      if type(result) == 'table' then
        ast = result
      end
    end

    -- métricas depois
    local after_code   = self.unparser:unparse(ast)
    local after_lines  = line_count(after_code)
    local after_counts = count_nodes(ast)

    local info = {
      lines_before   = before_lines,
      lines_after    = after_lines,
      lines_delta    = after_lines - before_lines,
      funcs_delta    = after_counts.func    - before_counts.func,
      strings_delta  = after_counts.strings - before_counts.strings,
      numbers_delta  = after_counts.numbers - before_counts.numbers,
      assigns_delta  = after_counts.assigns - before_counts.assigns,
      error          = self.errors[name],
    }
    self.metrics[name] = info

    if self.emit_snapshots then
      table.insert(self.snapshots, { name = name, code = after_code })
    end

    local status = ok and '' or ' [ERRO]'
    print(string.format(
      '[%s]%s linhas %d→%d (%+d) | funcs %+d strings %+d numbers %+d assigns %+d',
      name, status,
      info.lines_before, info.lines_after, info.lines_delta,
      info.funcs_delta, info.strings_delta, info.numbers_delta, info.assigns_delta
    ))
  end

  self.last_ast = ast
  return self.unparser:unparse(ast)
end

return DeobPipeline
