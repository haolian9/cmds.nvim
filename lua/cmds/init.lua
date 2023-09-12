--design choices/limits/features
--* there will be only one positional argument
--* the flag pattern: '--{flag}='
--* no abbrev for flags
--* no repeating flags
--
--todo: expand expr: %:p:h, @a
--todo: support specifying value type of a flag
--todo: normalize value when parsing the final args
--todo: honor the flag.required constraint
--todo: complete no duplicate item for arg
--todo: path complete

local M = {}

local fn = require("infra.fn")
local jelly = require("infra.jellyfish")("grep", "debug")
local listlib = require("infra.listlib")
local strlib = require("infra.strlib")

local api = vim.api

do
  local default_attrs = { nargs = 0 }

  ---@param name string
  ---@param handler fun(args: infra.cmds.Args)|string
  ---@param attrs? infra.cmds.Attrs
  function M.create(name, handler, attrs)
    attrs = attrs or default_attrs
    api.nvim_create_user_command(name, handler, attrs)
  end
end

do
  local ArgComp = {}

  local function enum_values(provider)
    local pt = type(provider)
    if pt == "function" then return provider() end
    if pt == "table" then return provider end
    error("unreachable")
  end

  ---@param provider string[]|fun(): string[]
  ---@return fun(prompt: string): string[]
  function ArgComp.constant(provider)
    local enum = enum_values(provider)

    if #enum == 0 then return function() return {} end end

    return function(prompt)
      if #prompt == 0 then return enum end
      return fn.tolist(fn.filter(function(i) return strlib.startswith(i, prompt) end, enum))
    end
  end

  ---@param provider fun(): string[]
  ---@return fun(prompt: string): string[]
  function ArgComp.variable(provider)
    return function(prompt)
      local enum = enum_values(provider)
      if #enum == 0 then return {} end

      if #prompt == 0 then return enum end
      return fn.tolist(fn.filter(function(i) return strlib.startswith(i, prompt) end, enum))
    end
  end

  M.ArgComp = ArgComp
end

do
  local FlagComp = {}

  ---@param flag string
  ---@param provider string[]|fun(): string[]
  ---@return string[]
  local function enum_values(flag, provider)
    return fn.tolist(fn.map(
      function(i) return string.format("--%s=%s", flag, i) end,
      (function()
        local pt = type(provider)
        if pt == "function" then return provider() end
        if pt == "table" then return provider end
        error("unreachable: " .. pt)
      end)()
    ))
  end

  ---@param provider string[]|fun(): string[]
  ---@return fun(prompt: string): string[]
  function FlagComp.constant(flag, provider)
    local enum = enum_values(flag, provider)

    if #enum == 0 then return function() return {} end end

    return function(prompt)
      if #prompt == 0 then return enum end
      return fn.tolist(fn.filter(function(i) return strlib.startswith(i, prompt) end, enum))
    end
  end

  ---@param flag string
  ---@param provider fun(): string[]
  ---@return fun(prompt: string): string[]
  function FlagComp.variable(flag, provider)
    return function(prompt)
      local enum = enum_values(flag, provider)
      if #enum == 0 then return {} end
      if #prompt == 0 then return enum end
      return fn.tolist(fn.filter(function(i) return strlib.startswith(i, prompt) end, enum))
    end
  end

  M.FlagComp = FlagComp
end

do
  ---@class infra.cmds.SpellFlag
  ---@field required boolean
  ---@field default? any|fun(): any
  ---@field complete? infra.cmds.CompFn

  ---@class infra.cmds.SpellArg
  ---@field name string
  ---@field required boolean
  ---@field default? any|fun(): any
  ---@field complete? infra.cmds.CompFn

  ---@alias infra.cmds.SpellDefault (fun(): any)|string|integer|boolean

  ---@class infra.cmds.Spell
  ---@field name   string
  ---@field action fun(args: infra.cmds.ParsedArgs, ctx: infra.cmds.Args)
  ---@field flags  {[string]: infra.cmds.SpellFlag}
  ---@field arg?   infra.cmds.SpellArg
  ---@field attrs  {range?: true}
  local Spell = {}
  Spell.__index = Spell

  ---@param attr 'range'
  function Spell:enable(attr) self.attrs[attr] = true end

  ---@param name      string
  ---@param required  boolean
  ---@param default?  infra.cmds.SpellDefault
  ---@param complete? infra.cmds.CompFn
  function Spell:add_flag(name, required, default, complete)
    assert(not (self.arg and self.arg.name == name), "this name has been taken by the arg")
    assert(self.flags[name] == nil, "this name has been taken by a flag")

    self.flags[name] = { default = default, required = required, complete = complete }
  end

  ---@param name      string
  ---@param required  boolean
  ---@param default?  infra.cmds.SpellDefault
  ---@param complete? infra.cmds.CompFn
  function Spell:add_arg(name, required, default, complete)
    assert(self.arg == nil, "re-defining arg")
    assert(self.flags[name] == nil, "this name has been taken by a flag")
    assert(not (required and default ~= nil), "required and default are mutual exclusive")

    self.arg = { name = name, default = default, required = required, complete = complete }
  end

  ---@param name string
  ---@param action fun(args: infra.cmds.ParsedArgs, ctx: infra.cmds.Args)
  ---@return infra.cmds.Spell
  function M.Spell(name, action) return setmetatable({ name = name, action = action, flags = {}, attrs = {} }, Spell) end
end

do
  ---@param spell infra.cmds.Spell
  local function resolve_nargs(spell)
    if next(spell.flags) == nil then
      if spell.arg == nil then return 0 end
      if spell.arg.required then return 1 end
      return "?"
    end
    for _, d in pairs(spell.flags) do
      if d.required then return "+" end
    end
    if spell.arg and spell.arg.required then return "+" end
    return "*"
  end

  ---@param spell infra.cmds.Spell
  ---@return boolean
  local function resolve_range(spell) return spell.attrs.range == true end

  local compose_complete
  do
    ---@param line string
    local function collect_seen_flags(line)
      local iter = fn.split_iter(line, " ")
      local seen = {}
      for chunk in iter do
        if chunk == "--" then break end
        if strlib.startswith(chunk, "--") then
          local flag = assert(string.match(chunk, "--(%w+)=?"))
          seen[flag] = true
        end
      end

      return seen
    end

    ---@param spell infra.cmds.Spell
    ---@param prompt string
    ---@param line string
    local function resolve_unseen_flags(spell, prompt, line)
      local seen = collect_seen_flags(string.sub(line, 1, -(#prompt + 1)))
      local unseen = {}
      for flag, _ in pairs(spell.flags) do
        if not seen[flag] then table.insert(unseen, flag) end
      end
      return unseen
    end

    ---@param spell infra.cmds.Spell
    ---@return infra.cmds.CompFn
    function compose_complete(spell)
      ---@return string[]|nil
      local function try_flags(prompt, line, cursor)
        if next(spell.flags) == nil then return end

        --shold startswith -
        if not strlib.startswith(prompt, "-") then return end
        --no flags completion after ` -- `
        if strlib.find(string.sub(line, 1, cursor + 1), " -- ") ~= nil then return end

        -- -|, --{flag}|
        if prompt == "-" or prompt == "--" or strlib.find(prompt, "=") == nil then
          local flags = resolve_unseen_flags(spell, prompt, line)
          if #flags == 0 then return end
          local comp = M.ArgComp.constant(function()
            return fn.tolist(fn.map(function(f) return string.format("--%s", f) end, flags))
          end)
          return comp(prompt)
        end

        do -- --{flag}=|, --{flag}=xx|
          local flag = assert(string.match(prompt, "^--(%w+)="))
          local decl = spell.flags[flag]
          if decl == nil then return {} end
          local comp = decl.complete
          if comp == nil then return {} end
          --if strlib.endswith(prompt, "=") then return comp("", line, cursor) end
          return comp(prompt, line, cursor)
        end
      end

      ---@param prompt string
      ---@return string[]
      local function try_arg(prompt, line, cursor)
        if spell.arg.complete == nil then return {} end
        return spell.arg.complete(prompt, line, cursor)
      end

      local function nothing() return {} end

      if next(spell.flags) == nil then
        if spell.arg == nil then return nothing end
        if spell.arg.complete == nil then return nothing end
        return spell.arg.complete
      end

      assert(spell.arg)
      return function(prompt, line, cursor) return try_flags(prompt, line, cursor) or try_arg(prompt) or {} end
    end
  end

  local compose_action
  do
    local function normalize_value(vtype, raw)
      if vtype == "string" then return raw end
      if vtype == "boolean" then
        if raw == "true" or raw == "1" then return true end
        if raw == "false" or raw == "0" then return false end
        jelly.err("vtype=%s, raw=%s", vtype, raw)
        error("value error")
      end
      if vtype == "number" then
        local num = tonumber(raw)
        jelly.err("vtype=%s, raw=%s", vtype, raw)
        if num == nil then error("value error") end
        return num
      end
      if vtype == "list" then
        if raw == "" then return {} end
        return fn.split(raw, ",")
      end
    end

    ---@param default infra.cmds.SpellDefault
    local function evaluate_default(default)
      if type(default) == "function" then return default() end
      return default
    end

    ---@alias infra.cmds.ParsedArgs {[string]: any}

    ---@param spell infra.cmds.Spell
    ---@param args string[]
    ---@return infra.cmds.ParsedArgs
    local function parse_args(spell, args)
      local parsed = {}

      do
        local iter = fn.iter(args)
        local arg_chunks = {}
        -- --verbose, --verbose=true, --porcelain=v1
        for flag in iter do
          if flag == "--" then break end
          if strlib.startswith(flag, "--") then
            if string.find(flag, "=") then
              local f, v = string.match(flag, "^--(%w+)=(.+)$")
              assert(f and v, flag)
              parsed[f] = normalize_value("string", v)
            else
              local f = string.match("^--(%w+)$", flag)
              assert(f)
              parsed[f] = true
            end
          else
            table.insert(arg_chunks, flag)
          end
        end
        listlib.extend(arg_chunks, iter)
        if spell.arg and #arg_chunks > 0 then parsed[spell.arg.name] = fn.join(arg_chunks, " ") end
      end

      do -- fill defaults
        for flag, d in pairs(spell.flags) do
          if parsed[flag] == nil and d.default ~= nil then parsed[flag] = evaluate_default(d.default) end
        end
        if spell.arg and parsed[spell.arg.name] == nil and spell.arg.default ~= nil then parsed[spell.arg.name] = evaluate_default(spell.arg.default) end
      end

      return parsed
    end

    ---@param spell infra.cmds.Spell
    function compose_action(spell)
      ---@param ctx infra.cmds.Args
      return function(ctx) spell.action(parse_args(spell, ctx.fargs), ctx) end
    end
  end

  ---@param spell infra.cmds.Spell
  function M.cast(spell)
    M.create(spell.name, compose_action(spell), {
      nargs = resolve_nargs(spell),
      range = resolve_range(spell),
      complete = compose_complete(spell),
    })
  end
end

return M
