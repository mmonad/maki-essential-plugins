# Maki essential plugins

Lua plugins for [Maki](https://github.com/tontinton/maki):

- `goal`: Run a session-scoped objective across agent turns.
- `monitor`: Watch a background command and report new output to its session.
  `/monitors` or Ctrl+M opens the list of running monitors.

## Install

Add the package to `~/.config/maki/init.lua`:

```lua
maki.pack.add({ "https://github.com/laudney/maki-essential-plugins" })
```

Maki installs managed packages in its XDG data directory, normally
`~/.local/share/maki/site/pack/core/`. The package is loaded at startup. Maki
will separately ask for the file and command permissions in `plugin.toml`.

Use `/packupdate maki-essential-plugins` to review updates.

## Commands and tools

The package adds `/goal` and `/monitors`, plus the `get_goal`, `update_goal`,
`monitor`, `monitor_list`, and `monitor_stop` tools.
