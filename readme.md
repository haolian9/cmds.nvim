an interface to define usercmd and its completions


## design choices/limits/features
* there will be only one positional argument
* the flag pattern: '--{flag-flag}='
* no abbrev for flags
* no repeating flags
* generate completions for flags and argument based on user-defined providers


## status
* it is usable yet far from stable


## todo
* the use of its API is too verbose, i am not happy with that.
* expand expr: %:p:h, @a
* honor the flag.required constraint
* complete no duplicate items for arg
* path complete
* generate completefn for {flag,arg}.type={true,boolean}


## an usage example

(which is copied from my config)

```
do
  local function root_default()
    local project = require("infra.project")
    return project.git_root() or project.working_root()
  end
  local sort_comp = cmds.FlagComp.constant("sort", { "none", "path", "modified", "accessed", "created" })
  -- see: rg --type-list
  local type_comp = cmds.FlagComp.constant("type", { "c", "go", "h", "lua", "py", "sh", "systemd", "vim", "zig" })
  local function is_extra_flag(flag) return flag ~= "root" and flag ~= "pattern" end

  local spell = cmds.Spell("Rg", function(args)
    local extra = {}
    local iter = fn.filtern(is_extra_flag, fn.items(args))
    for key, val in iter do
      if val == true then table.insert(extra, string.format("--%s", key)) end
      table.insert(extra, string.format("--%s=%s", key, val))
    end

    require("grep").rg(args.root, args.pattern, extra)
  end)

  -- stylua: ignore
  do
    spell:add_flag("root",          "string", false, root_default, common_root_comp)
    spell:add_flag("fixed-strings", "true",   false)
    spell:add_flag("hidden",        "true",   false)
    spell:add_flag("max-depth",     "number", false)
    spell:add_flag("multiline",     "true",   false)
    spell:add_flag("no-ignore",     "true",   false)
    spell:add_flag("sort",          "string", false, nil,          sort_comp)
    spell:add_flag("sortr",         "string", false, nil,          sort_comp)
    spell:add_flag("type",          "string", false, nil,          type_comp)
  end

  spell:add_arg("pattern", "string", true)
  cmds.cast(spell)
end
```


## notes
* i drew some inspirations from python's argparse
* this repo used to be named as `cwdwizard`, that's why there are terms like cast, spell
