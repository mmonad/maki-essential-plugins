-- Watch a long-running command and let the agent hear about it later.
--
-- The job outlives the tool call that started it (scope = "plugin"), and
-- each interesting line goes to the session mailbox instead of being sent
-- as its own prompt, so a chatty watcher costs nothing until the agent
-- runs again.

local monitors = {}

-- A watcher that floods would quietly undo the point of the mailbox, so
-- each one gets a budget and then goes quiet with one line saying so.
local MAX_LINES = 200

local HINT_KEY = "Ctrl+M"
-- A watched process can exit while the picker is open, so the rows are
-- rebuilt on a tick; this is short enough that a stale row is gone before
-- the person reading it acts on it.
local TICK_MS = 250

local SCHEMA = {
  type = "object",
  properties = {
    command = {
      type = "string",
      description = "Shell command that prints one line per event, e.g. `tail -f app.log | grep --line-buffered ERROR`.",
    },
    label = {
      type = "string",
      description = "Short name for this monitor, shown with every line it reports.",
    },
    match = {
      type = "string",
      description = "Lua pattern. When set, only matching lines are reported. "
        .. "Lua has no `|` alternation; write `%|` for a literal pipe.",
    },
    wake = {
      type = "boolean",
      description = "Interrupt an idle agent instead of waiting for the next turn. Off by default; use it only for events worth stopping for.",
    },
  },
  required = { "command" },
  additionalProperties = false,
}

local function report(entry, line, prefix)
  if entry.match then
    local ok, matched = pcall(string.match, line, entry.match)
    if not ok then
      if not entry.match_error then
        entry.match_error = true
        maki.session.notify(
          string.format("[%s] invalid match pattern: %s", entry.label, tostring(matched)),
          { session = entry.session }
        )
      end
      return
    end
    if not matched then
      return
    end
  end
  entry.seen = entry.seen + 1
  if entry.seen > MAX_LINES then
    if not entry.capped then
      entry.capped = true
      maki.session.notify(
        string.format("[%s] stopped reporting after %d lines", entry.label, MAX_LINES),
        { session = entry.session }
      )
    end
    return
  end
  maki.session.notify(
    string.format("[%s] %s%s", entry.label, prefix or "", line),
    { session = entry.session, wake = entry.wake }
  )
end

-- Labels and commands are whatever the model sent, newlines and all,
-- and both get rendered a line per monitor. Left as they came, one entry
-- could draw rows of its own and invent or hide a monitor in a listing
-- someone is reading to decide what to stop.
local function one_line(s)
  return (tostring(s):gsub("%s+", " "))
end

-- Lua patterns have no `|` alternation. A caller used to regex writes
-- `DONE|progress`, which Lua reads as a literal pipe, so the monitor
-- matches nothing and stays quiet until it exits. Catch that at start.
-- `%|` still matches a literal pipe, so only a pipe that nothing escapes
-- is the mistake.
local function unescaped_pipe(pattern)
  local from = 1
  local pos = pattern:find("|", from, true)
  while pos do
    if pos == 1 or pattern:sub(pos - 1, pos - 1) ~= "%" then
      return true
    end
    from = pos + 1
    pos = pattern:find("|", from, true)
  end
  return false
end

-- One hint slot serves the whole process, so it counts the monitors of
-- the session in front of the person and follows focus when that moves.
-- It reads like the task hint does: the count, then the key that opens
-- the list, so "2 monitors Ctrl+M" says what runs and where to look.
local function refresh_hint()
  local session = maki.session.current()
  local count = 0
  for _, entry in pairs(monitors) do
    if entry.session == session then
      count = count + 1
    end
  end
  if count == 0 then
    maki.ui.set_status_hint(nil)
    return
  end
  maki.ui.set_status_hint({
    { string.format(" %d %s ", count, count == 1 and "monitor" or "monitors"), "foreground" },
    { HINT_KEY, "keybind_key" },
    { " ", "" },
  })
end

-- One Lua runtime serves every session in the UI, so this table holds
-- other sessions' monitors too and their ids are small integers anyone
-- could land on. A session may only stop its own: answer for someone
-- else's exactly as for one that was never started, so the reply says
-- nothing about what another session is watching.
local function stop(id, session)
  local entry = monitors[id]
  if not entry or entry.session ~= session then
    return false
  end
  maki.fn.jobstop(id)
  monitors[id] = nil
  refresh_hint()
  return true
end

-- The one description of what is running, so the picker and the model
-- never disagree about it: both views render these rows, one with styles
-- and one as plain text. Ids come back out of a hash table in no order,
-- and sorting the rendered lines would put 10 before 2, so sort the ids.
local function monitor_rows(session)
  local ids = {}
  for id, entry in pairs(monitors) do
    if entry.session == session then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)

  local rows = {}
  for _, id in ipairs(ids) do
    local entry = monitors[id]
    rows[#rows + 1] = {
      id = id,
      label = entry.label,
      command = one_line(entry.command),
      capped = entry.capped,
    }
  end
  return rows
end

-- The model reads plain lines, one per monitor, so the same facts reach
-- it without any of the styles the picker draws.
local function listing(session)
  local lines = {}
  for _, row in ipairs(monitor_rows(session)) do
    local line = string.format("%d  %s  %s", row.id, row.label, row.command)
    if row.capped then
      line = line .. string.format("  (quiet since %d lines)", MAX_LINES)
    end
    lines[#lines + 1] = line
  end
  return lines
end

-- Every model-facing entry point has to know which session is asking,
-- both to own what it starts and to be kept out of what it did not.
local function caller_session(ctx)
  local session, err = ctx:session_id()
  if err or not session then
    return nil,
      {
        llm_output = "error: a monitor needs a session, and this tool is not running for one",
        is_error = true,
      }
  end
  return session, nil
end

maki.api.register_tool({
  name = "monitor",
  description = "Watch a command in the background and report what it prints. "
    .. "Returns straight away; lines arrive later, with the next turn. "
    .. "Use it for a dev server, a test watcher, or a deploy, when you want "
    .. "to know what happened without asking again. Stop it with monitor_stop.",
  schema = SCHEMA,
  -- Starting a job needs the `run` permission, which a bundled plugin
  -- already has. That covers the plugin, not the command: without a scope
  -- here the model could run through this tool anything the bash tool
  -- would have had to ask about first. Always prompt rather than reuse a
  -- standing grant, because the job outlives the call it was granted to,
  -- and an "always allow" answered for a command that runs once never
  -- agreed to one that keeps running.
  permission = "run",
  permission_scopes = function(input)
    local command = input.command
    if not command or command:match("^%s*$") then
      return nil
    end
    return { scopes = { command }, force_prompt = true }
  end,
  handler = function(input, ctx)
    local command = input.command
    if not command or command:match("^%s*$") then
      return { llm_output = "error: command must not be blank", is_error = true }
    end

    local session, no_session = caller_session(ctx)
    if no_session then
      return no_session
    end

    if input.match then
      local ok, match_err = pcall(string.match, "", input.match)
      if not ok then
        return {
          llm_output = "error: invalid match pattern: " .. tostring(match_err),
          is_error = true,
        }
      end
      if unescaped_pipe(input.match) then
        return {
          llm_output = "error: match is a Lua pattern with no `|` alternation; "
            .. "use `%|` for a literal pipe or one monitor per pattern",
          is_error = true,
        }
      end
    end

    local entry = {
      command = command,
      label = input.label,
      match = input.match,
      wake = input.wake or false,
      session = session,
      seen = 0,
    }

    local id, start_err = maki.fn.jobstart(command, {
      scope = "plugin",
      on_stdout = function(job_id, line)
        local e = monitors[job_id]
        if e then
          report(e, line)
        end
      end,
      on_stderr = function(job_id, line)
        local e = monitors[job_id]
        if e then
          report(e, line, "stderr: ")
        end
      end,
      on_exit = function(job_id, code)
        local e = monitors[job_id]
        if e then
          monitors[job_id] = nil
          maki.session.notify(
            string.format("[%s] exited with %d", e.label, code),
            { session = e.session, wake = e.wake }
          )
          refresh_hint()
        end
      end,
    })
    if start_err then
      return { llm_output = "error: " .. tostring(start_err), is_error = true }
    end

    -- Naming an unnamed monitor after its own id keeps the two things the
    -- model has to keep together — what it reads in a report and what it
    -- passes to monitor_stop — from drifting apart, and needs no counter
    -- of its own to carry numbering between sessions.
    if entry.label and entry.label ~= "" then
      entry.label = one_line(entry.label)
    else
      entry.label = "monitor " .. id
    end

    monitors[id] = entry
    refresh_hint()
    return string.format("%s watching `%s` (id %d)", entry.label, command, id)
  end,
})

maki.api.register_tool({
  name = "monitor_stop",
  description = "Stop a monitor started with the monitor tool.",
  schema = {
    type = "object",
    properties = { id = { type = "integer", description = "Monitor id." } },
    required = { "id" },
    additionalProperties = false,
  },
  handler = function(input, ctx)
    local session, no_session = caller_session(ctx)
    if no_session then
      return no_session
    end
    if stop(input.id, session) then
      return "stopped monitor " .. input.id
    end
    return {
      llm_output = "error: no monitor with id " .. tostring(input.id) .. "; monitor_list shows the ones still running",
      is_error = true,
    }
  end,
})

-- A monitor is started once and stopped a turn or an hour later, by
-- which point the id it was given may have been compacted away. Without
-- somewhere to look it up the model can start watchers it has no way to
-- call off; `/monitors` shows the same list, but only to a human.
maki.api.register_tool({
  name = "monitor_list",
  description = "List the monitors running in this session, with their ids. "
    .. "Use it to find the id of a monitor you want to stop.",
  schema = { type = "object", properties = {}, additionalProperties = false },
  handler = function(_, ctx)
    local session, no_session = caller_session(ctx)
    if no_session then
      return no_session
    end
    local lines = listing(session)
    if #lines == 0 then
      return "no monitors running"
    end
    return table.concat(lines, "\n")
  end,
})

-- The model is asked before a monitor starts, but the job outlives that
-- one call, so the person who granted it needs a way to see what is
-- still running and to call it off. Ctrl+M opens this window too; the
-- status hint points at it, the way the task hint points at Ctrl+X.
--
-- Like the tasks picker it shows the focused session, which is the one
-- the hint counts: a monitor id means nothing outside the session it was
-- started in, since monitor_stop cannot reach across sessions. The rows
-- are rebuilt on a tick because a watched process can exit while the
-- window is open, and a session switch closes it rather than leave
-- another session's rows on screen.
local picker = nil

local function dispw(s)
  return utf8.len(s) or #s
end

local function picker_index(id)
  for i, row in ipairs(picker.rows) do
    if row.id == id then
      return i
    end
  end
end

local function picker_render()
  local lines = {}
  local cursor = 1
  if #picker.rows == 0 then
    lines[1] = { { "  No monitors running", "dim" } }
  end
  for _, row in ipairs(picker.rows) do
    local selected = row.id == picker.sel_id
    local base = selected and "selected" or "item"
    local dim = selected and "selected" or "dim"
    local spans = {
      { "  ", base },
      { tostring(row.id), dim },
      { "  " .. row.label, selected and "selected" or "foreground" },
    }
    if row.capped then
      spans[#spans + 1] = { string.format("  (quiet since %d lines)", MAX_LINES), dim }
    end
    spans[#spans + 1] = { "  " .. row.command, dim }
    -- Rows with nothing on the right would otherwise end short of the
    -- border and read as padding on one side only, so the bar runs the
    -- full width, the way the task rows do.
    local used = 0
    for _, span in ipairs(spans) do
      used = used + dispw(span[1])
    end
    local trail = picker.width - used
    if trail > 0 then
      spans[#spans + 1] = { string.rep(" ", trail), base }
    end
    lines[#lines + 1] = spans
    if selected then
      cursor = #lines
    end
  end
  picker.buf:set_lines(lines)
  picker.win:set_cursor(cursor)
end

local function picker_finish()
  if not picker then
    return
  end
  local closing = picker
  picker = nil
  closing.win:close()
end

-- Writing the buffer pulls the view back to the cursor, and the person
-- may have scrolled away from it with the wheel, so a tick that finds
-- the same rows has to leave the buffer alone.
local function same_rows(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if x.id ~= y.id or x.label ~= y.label or x.command ~= y.command or x.capped ~= y.capped then
      return false
    end
  end
  return true
end

local function picker_refresh()
  local rows = monitor_rows(picker.session)
  if same_rows(rows, picker.rows) then
    return
  end
  local previous = picker_index(picker.sel_id) or 1
  picker.rows = rows
  local index = math.min(previous, #picker.rows)
  picker.sel_id = picker.rows[index] and picker.rows[index].id or nil
  picker_render()
end

local function picker_move(delta, wrap)
  local count = #picker.rows
  if count == 0 then
    return
  end
  local current = picker_index(picker.sel_id) or 1
  local index
  if wrap then
    index = (current - 1 + delta) % count + 1
  else
    index = math.min(math.max(current + delta, 1), count)
  end
  picker.sel_id = picker.rows[index].id
  picker_render()
end

local function picker_key(key)
  local page = math.max(picker.height - 2, 1)
  if key == "esc" or key == "ctrl+c" or key == "ctrl+m" then
    picker_finish()
  elseif key == "up" then
    picker_move(-1, true)
  elseif key == "down" then
    picker_move(1, true)
  elseif key == "pageup" then
    picker_move(-page, false)
  elseif key == "pagedown" then
    picker_move(page, false)
  end
end

local function open_picker()
  if picker then
    return
  end
  local session = maki.session.current()
  local rows = monitor_rows(session)
  if #rows == 0 then
    maki.ui.flash("no monitors running")
    return
  end
  local buf = maki.ui.buf()
  local win = maki.ui.open_win(buf, {
    title = " Monitors ",
    width = "70%",
    height = "70%",
    border = "rounded",
    focus = true,
    footer = { { "Esc", "close" } },
  })
  picker = {
    session = session,
    win = win,
    buf = buf,
    width = win.width,
    height = win.height,
    rows = rows,
    sel_id = rows[1].id,
  }
  picker_render()

  while picker do
    local ev = picker.win:recv(TICK_MS)
    if not ev or ev.type == "close" then
      -- The window is already gone, so there is nothing left to close.
      picker = nil
    elseif ev.type == "timeout" then
      if picker.expired then
        picker_finish()
      else
        picker_refresh()
      end
    elseif ev.type == "key" then
      picker_key(ev.key)
    elseif ev.type == "resize" then
      picker.width = ev.width
      picker.height = ev.height
      picker_render()
    end
  end
end

maki.api.register_command({
  name = "/monitors",
  description = "List running monitors",
  handler = open_picker,
})

local function stop_session(ev)
  local session = ev.data and ev.data.session_id
  if not session then
    return
  end
  if picker and picker.session == session then
    picker.expired = true
  end
  for id, entry in pairs(monitors) do
    if entry.session == session then
      maki.fn.jobstop(id)
      monitors[id] = nil
    end
  end
  refresh_hint()
end

maki.api.create_autocmd("SessionEnd", { callback = stop_session })

-- The picker shows the focused session's monitors, so a switch closes it
-- instead of leaving another session's rows on screen; the hint has to
-- follow focus either way.
maki.api.create_autocmd("SessionFocusChanged", {
  callback = function()
    if picker then
      picker.expired = true
    end
    refresh_hint()
  end,
})

-- A terminal reports Ctrl+M apart from Enter only when it speaks the
-- Kitty keyboard protocol, which maki asks for at startup. Where it does
-- not, the key arrives as Enter and its usual binding still works.
maki.keymap.set("n", "<C-m>", open_picker, { desc = "Open monitors" })
