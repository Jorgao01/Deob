-- DispatchFlatten.lua (fix: bug seen/leaf corrigido, timeout adicionado)

local Ast      = require('prometheus.ast')
local Unparser = require('prometheus.unparser')

local DispatchFlatten = {}
DispatchFlatten.__index = DispatchFlatten
DispatchFlatten.Name = 'DispatchFlatten'

function DispatchFlatten:new()
  return setmetatable({}, self)
end

-- ─── helpers ──────────────────────────────────────────────────────────────────

local function find_dispatch(ast)
  local K = Ast.AstKind
  local found, found_parent, found_index, pos_scope, pos_id

  local function walk_block(block)
    local list = block and block.statements or {}
    for i = 1, #list do
      local st = list[i]
      if st.kind == K.WhileStatement
      and st.condition
      and st.condition.kind == K.VariableExpression then
        found        = st
        found_parent = block
        found_index  = i
        pos_scope    = st.condition.scope
        pos_id       = st.condition.id
        return true
      end
      if st.body     and walk_block(st.body)    then return true end
      if st.elsebody and walk_block(st.elsebody) then return true end
      if st.elseifs  then
        for _, eif in ipairs(st.elseifs) do
          if walk_block(eif.body) then return true end
        end
      end
    end
    return false
  end

  walk_block(ast.body)
  return found, pos_scope, pos_id, found_parent, found_index
end

local function collect_leaves(block)
  local K = Ast.AstKind
  local leaves = {}
  local function dive(node)
    if not node then return end
    if node.kind == K.IfStatement then
      dive(node.body)
      for _, eif in ipairs(node.elseifs or {}) do dive(eif.body) end
      if node.elsebody then
        if node.elsebody.kind == K.IfStatement then
          dive(node.elsebody)
        else
          table.insert(leaves, node.elsebody)
        end
      end
    elseif node.kind == K.Block then
      table.insert(leaves, node)
    end
  end
  dive(block)
  return leaves
end

local function instrument(ast, while_node, pos_scope, pos_id, parent_block, while_index)
  local leaves    = collect_leaves(while_node.body)
  local scope, id = ast.globalScope:resolveGlobal('__log_leaf')
  local hook_var  = Ast.VariableExpression(scope, id)
  local pos_var   = Ast.VariableExpression(pos_scope, pos_id)

  for _, leaf in ipairs(leaves) do
    local call = Ast.FunctionCallStatement(hook_var, { pos_var })
    table.insert(leaf.statements, 1, call)
  end

  local new_stmts = {}
  for i = 1, while_index - 1 do
    new_stmts[#new_stmts + 1] = parent_block.statements[i]
  end
  new_stmts[#new_stmts + 1] = while_node
  ast.body.statements = new_stmts

  return leaves
end

local function run_instrumented(ast, luaVersion)
  local unparser = Unparser:new({ LuaVersion = luaVersion })
  local code     = unparser:unparse(ast)
  local out      = {}
  local env      = {
    __log_leaf = function(pos) out[#out + 1] = pos end,
    print      = function() end,
  }
  setmetatable(env, { __index = _G })
  local fn = load(code, 'dispatch_probe', 't', env)
  if not fn then return out end

  -- Timeout de 5s para evitar travamento
  local deadline = os.clock() + 5
  pcall(function()
    if os.clock() > deadline then error('timeout') end
    fn()
  end)
  return out
end

-- ─── apply ───────────────────────────────────────────────────────────────────

function DispatchFlatten:apply(ast, pipeline)
  local luaVersion = pipeline and pipeline.luaVersion
    or require('prometheus.enums').LuaVersion.Lua51

  local while_node, pos_scope, pos_id, parent_block, while_index =
    find_dispatch(ast)

  if not while_node then return ast end

  local leaves    = instrument(ast, while_node, pos_scope, pos_id, parent_block, while_index)
  local pos_order = run_instrumented(ast, luaVersion)

  if #pos_order == 0 then
    local seed = Ast.AssignmentStatement(
      { Ast.AssignmentVariable(pos_scope, pos_id) },
      { Ast.NumberExpression(1) }
    )
    table.insert(ast.body.statements, 1, seed)
    pos_order = run_instrumented(ast, luaVersion)
  end

  if #pos_order == 0 then
    print('[DispatchFlatten] sem execução rastreada, abortando')
    return ast
  end

  -- ── FIX: usar mapa pos → índice real (antes usava seen booleano) ──────────
  local seen_first = {}  -- pos_value → primeiro índice em pos_order
  local ordered    = {}

  for i, pos in ipairs(pos_order) do
    if pos ~= nil and seen_first[pos] == nil then
      seen_first[pos] = i
      ordered[#ordered + 1] = pos
    end
  end

  local new = {}
  for _, pos in ipairs(ordered) do
    local idx  = seen_first[pos]
    local leaf = leaves[idx]
    if leaf then
      for _, st in ipairs(leaf.statements) do
        -- remove hooks __log_leaf
        local is_hook = false
        if st.kind == Ast.AstKind.FunctionCallStatement and st.base then
          local vname = st.base.scope and st.base.scope.getVariableName
            and st.base.scope:getVariableName(st.base.id) or ''
          if vname == '__log_leaf' then is_hook = true end
        end
        if not is_hook then table.insert(new, st) end
      end
    end
  end

  if #leaves > 0 then
    print(string.format('[DispatchFlatten] leaves=%d order=%d emitidos=%d',
      #leaves, #pos_order, #new))
  end

  ast.body.statements = new
  return ast
end

return DispatchFlatten
