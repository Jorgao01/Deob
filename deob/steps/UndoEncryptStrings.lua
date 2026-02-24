-- UndoEncryptStrings.lua
local Ast      = require('prometheus.ast')
local visitast = require('prometheus.visitast')

local UndoEncryptStrings = {}
UndoEncryptStrings.__index = UndoEncryptStrings
UndoEncryptStrings.Name = 'UndoEncryptStrings'

function UndoEncryptStrings:new() return setmetatable({}, self) end

local K

local function extract_numbers_from_source(src)
  local p = {}
  p.param_mul_45 = tonumber(src:match('state_45%s*%*%s*(%d+)%s*%+%s*%d+'))
  p.param_add_45 = tonumber(src:match('state_45%s*%*%s*%d+%s*%+%s*(%d+)'))
  p.param_mul_8  = tonumber(src:match('state_8%s*%*%s*(%d+)%s*%%%s*257'))
  p.secret_key_8 = tonumber(src:match('prevVal%s*=%s*(%d+)%s*;'))
  return p
end

local function build_decryptor_from_ast(ast, unparse)
  local code = unparse(ast)
  local p    = extract_numbers_from_source(code)
  if not (p and p.param_mul_45 and p.param_add_45 and p.param_mul_8 and p.secret_key_8) then
    return nil
  end
  local floor = math.floor
  local function make_decrypt(pm45, pa45, pm8, sk8)
    local function make_state(seed)
      local state_45  = seed % 35184372088832
      local state_8   = seed % 255 + 2
      local prev_vals = {}
      local function next_byte()
        if #prev_vals == 0 then
          state_45 = (state_45 * pm45 + pa45) % 35184372088832
          repeat state_8 = state_8 * pm8 % 257 until state_8 ~= 1
          local r   = state_8 % 32
          local n   = floor(state_45 / 2^(13 - (state_8 - r)/32)) % 2^32 / 2^r
          local rnd = floor(n % 1 * 2^32) + floor(n)
          local lo  = rnd % 65536
          local hi  = (rnd - lo) / 65536
          prev_vals = { lo%256, (lo-lo%256)/256, hi%256, (hi-hi%256)/256 }
        end
        return table.remove(prev_vals)
      end
      return function(enc)
        local prevVal = sk8
        local out = {}
        for i = 1, #enc do
          local byte = string.byte(enc, i)
          prevVal = (byte + next_byte() + prevVal) % 256
          out[i]  = string.char(prevVal)
        end
        return table.concat(out)
      end
    end
    return function(enc, seed) return make_state(seed)(enc) end
  end
  return make_decrypt(p.param_mul_45, p.param_add_45, p.param_mul_8, p.secret_key_8)
end

local function collect_symbols(ast)
  local decryptVar, stringsVar
  visitast(ast, nil, function(n)
    if n.kind == K.LocalVariableDeclaration then
      for _, id in ipairs(n.ids) do
        local name = n.scope:getVariableName(id)
        if name == 'DECRYPT' then decryptVar = { scope=n.scope, id=id }
        elseif name == 'STRINGS' then stringsVar = { scope=n.scope, id=id } end
      end
    end
    if n.kind == K.FunctionDeclaration
    and n.scope:getVariableName(n.id) == 'DECRYPT' then
      decryptVar = { scope=n.scope, id=n.id }
    end
  end)
  return decryptVar, stringsVar
end

function UndoEncryptStrings:apply(ast, pipeline)
  K = Ast.AstKind
  local unparse    = function(tree) return pipeline:getUnparser():unparse(tree) end
  local decryptVar, stringsVar = collect_symbols(ast)
  if not decryptVar or not stringsVar then return ast end
  local decrypt_fn = build_decryptor_from_ast(ast, unparse)
  if not decrypt_fn then return ast end
  local count = 0
  visitast(ast, nil, function(node)
    if node.kind == K.IndexExpression then
      local base, idx = node.base, node.index
      if base.kind == K.VariableExpression
      and base.scope == stringsVar.scope and base.id == stringsVar.id then
        if idx.kind == K.FunctionCallExpression
        and idx.base.kind == K.VariableExpression
        and idx.base.scope == decryptVar.scope
        and idx.base.id == decryptVar.id then
          local args = idx.args
          if #args == 2
          and args[1].kind == K.StringExpression
          and args[2].kind == K.NumberExpression then
            local ok, plaintext = pcall(decrypt_fn, args[1].value, args[2].value)
            if ok then
              count = count + 1
              return Ast.StringExpression(plaintext)
            end
          end
        end
      end
    end
  end)
  if count > 0 then print('[UndoEncryptStrings] descriptografou ' .. count .. ' strings') end
  return ast
end

return UndoEncryptStrings
