an interface to define usercmd and its completions


##design choices/limits/features
* there will be only one positional argument
* the flag pattern: '--{flag}='
* no abbrev for flags
* no repeating flags
* generate completions for flags and argument based on user-defined providers


## status
* it is usable yet far from stable


## todo
* the use of its API is too verbose, i am not happy with that.
* expand expr: %:p:h, @a
* support specifying value type of a flag
* normalize value when parsing the final args
* honor the flag.required constraint
* complete no duplicate item for arg
* path complete


## an simple usage example (so far)

```
cmds.cast((function()
  local spell = cmds.Spell("Blame", function(args, ctx)
    // vim.loop.spawn('git', {args = {'blame', '--porcelain=' .. args.porcelain, args.file}, cwd = args.root})
    // or
    // git blame ctx.range args.file
  end)

  spell:enable("range")

  do
    local comp = cmds.FlagComp.variable("root", function() return dictlib.keys(fn.toset({ vim.fn.expand("%:p:h"), vim.fn.getcwd(), vim.loop.cwd() })) end)
    spell:add_flag("root", false, function() return vim.fn.getcwd() end, comp)
  end

  spell:add_flag("porcelain", false, "v1", cmds.FlagComp.constant("porcelain", { "v1" }))
  spell:add_arg("file", true, nil, cmds.ArgComp.variable(function() return vim.api.nvim_list_bufs() end))

  return spell
end)())
```
