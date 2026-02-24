-- CleanupObfuscatorScaffold.lua (fix: is_rotate_for mais preciso, drop seguro)

local Ast = require('prometheus.ast')

local Cleanup = {}
Cleanup.__index = Cleanup
Cleanup.Name = 'CleanupObfuscatorScaffold'

function Cleanup:new()
  return setmetatable({}, self)
end

-- Dropa apenas locals sem expressões (ex: "local x" sem valor)
local function is_empty_local(st)
  if st.kind ~= Ast.AstKind.LocalVariableDeclaration then return false end
  return not st.expressions or #st.expressions == 0
end

-- Dropa locals cujo valor é APENAS uma FunctionLiteralExpression que não faz nada
-- (scaffold do Prometheus: local _ = function() end)
-- FIX: antes dropava QUALQUER local com função, incluindo funções legítimas
local function should_drop_localdecl(st)
  if st.kind ~= Ast.AstKind.LocalVariableDeclaration then return false end
  if #st.ids ~= 1 then return false end  -- só vars de nome único
  local exprs = st.expressions
  if not exprs or #exprs ~= 1 then return false end
  local expr = exprs[1]
  if expr.kind ~= Ast.AstKind.FunctionLiteralExpression then return false end
  -- Só dropa se o corpo da função for VAZIO (scaffold)
  local body = expr.body
  if not body or not body.statements then return true end
  return #body.statements == 0
end

-- FIX PRINCIPAL: antes dropava TODO GenericFor, incluindo código legítimo.
-- Agora só dropa se for o for de rotação do Prometheus:
--   for _, v in ipairs({ {a,b}, {c,d}, {e,f} }) do ... end
-- Critérios:
--   1. iterador é chamada de ipairs
--   2. argumento é TableConstructorExpression com entradas que são tabelas de 2 números
local function is_prometheus_rotate_for(st)
  if st.kind ~= Ast.AstKind.ForGenericStatement then return false end

  -- Verifica variáveis: deve ter exatamente 2 (_, v)
  -- (prometheus usa 2 vars no for genérico de rotação)

  -- Verifica iterador
  local iters = st.iterators
  if not iters or #iters ~= 1 then return false end
  local iter = iters[1]
  if iter.kind ~= Ast.AstKind.FunctionCallExpression then return false end

  -- Deve ser chamada a ipairs
  local base = iter.base
  if base.kind ~= Ast.AstKind.VariableExpression then return false end
  local fname = base.scope and base.scope.getVariableName
    and base.scope:getVariableName(base.id) or ''
  if fname ~= 'ipairs' then return false end

  -- Argumento deve ser uma tabela de tabelas de 2 números
  if #iter.args ~= 1 then return false end
  local arg = iter.args[1]
  if arg.kind ~= Ast.AstKind.TableConstructorExpression then return false end
  if #arg.entries < 2 then return false end

  local K = Ast.AstKind
  local pair_count = 0
  for _, entry in ipairs(arg.entries) do
    if entry.kind ~= K.TableEntry then return false end
    local v = entry.value
    if v.kind ~= K.TableConstructorExpression then return false end
    -- cada sub-tabela deve ter 2 entradas numéricas
    if #v.entries ~= 2 then return false end
    local ok = true
    for _, sub in ipairs(v.entries) do
      if sub.kind ~= K.TableEntry then ok = false; break end
      local sv = sub.value
      -- aceita NumberExpression ou UnaryMinus de número
      if sv.kind ~= K.NumberExpression then ok = false; break end
    end
    if ok then pair_count = pair_count + 1 end
  end

  return pair_count >= 2
end

-- Tabela de lookup base64 customizado do Prometheus (>= 30 entradas char->número)
local function is_base64_lookup_local(st)
  if st.kind ~= Ast.AstKind.LocalVariableDeclaration then return false end
  if #st.ids ~= 1 or not st.expressions or not st.expressions[1] then return false end
  local expr = st.expressions[1]
  if expr.kind ~= Ast.AstKind.TableConstructorExpression then return false end
  local charKeys = 0
  local K = Ast.AstKind
  for _, e in ipairs(expr.entries or {}) do
    if e.kind == K.KeyedTableEntry
    and e.key.kind == K.StringExpression
    and #e.key.value == 1 then
      charKeys = charKeys + 1
    end
  end
  return charKeys >= 30
end

function Cleanup:apply(ast)
  local out = {}
  local dropped = 0
  for _, st in ipairs(ast.body.statements) do
    if should_drop_localdecl(st)
    or is_empty_local(st)
    or is_prometheus_rotate_for(st)
    or is_base64_lookup_local(st) then
      dropped = dropped + 1
    else
      table.insert(out, st)
    end
  end
  if dropped > 0 then
    print(string.format('[CleanupObfuscatorScaffold] removeu %d statements de scaffolding', dropped))
  end
  ast.body.statements = out
  return ast
end

return Cleanup
