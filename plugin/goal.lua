local helpers = require("goal_helpers")
local ToolView = require("maki.tool_view")

local PHASE_DELIVERY = "delivery"
local PHASE_RUNNING = "running"
local PHASE_TRANSITION = "transition"

local opts = maki.api.register_options({
  max_turns = { default = 20, min = 1, desc = "Maximum agent turns for each goal." },
})

local semaphore = maki.async.semaphore(1)
local state_directory
local pending_executions = {}
local running_executions = {}
local focus_generation = 0
local id_counter = 0

local function new_id(prefix)
  id_counter = id_counter + 1
  local clock = tostring(os.clock()):gsub("%.", "")
  return table.concat({ prefix, os.time(), clock, id_counter }, "-")
end

local function execution_id(fence)
  return fence and fence.execution_id or nil
end

local function clear_fences(session_id)
  pending_executions[session_id] = nil
  running_executions[session_id] = nil
end

local function state_path(session_id)
  local filename, filename_err = helpers.session_filename(session_id)
  if not filename then
    return nil, filename_err
  end
  if not state_directory then
    local base = maki.env.state_dir()
    if not base then
      return nil, "cannot resolve state dir"
    end
    state_directory = maki.fs.joinpath(base, "goals", "sessions")
  end
  return maki.fs.joinpath(state_directory, filename)
end

local function load_state(session_id)
  local path, path_err = state_path(session_id)
  if not path then
    return nil, path_err
  end
  local metadata, metadata_err = maki.fs.metadata(path)
  if metadata_err then
    return nil, "cannot inspect goal state: " .. tostring(metadata_err)
  end
  if not metadata then
    return { path = path }
  end
  local content, read_err = maki.fs.read(path)
  if not content then
    return nil, "cannot read goal state: " .. tostring(read_err)
  end
  local document, decode_err = maki.json.decode(content)
  if not document then
    return nil, "cannot decode goal state: " .. tostring(decode_err)
  end
  local valid, validation_err = helpers.validate_document(document, session_id)
  if not valid then
    return nil, validation_err
  end
  return { path = path, document = document }
end

local function write_goal(path, session_id, record)
  local document = {
    version = 1,
    session_id = session_id,
    goal = record,
  }
  local valid, validation_err = helpers.validate_document(document, session_id)
  if not valid then
    return nil, validation_err
  end
  local encoded, encode_err = maki.json.encode(document)
  if not encoded then
    return nil, "cannot encode goal state: " .. tostring(encode_err)
  end
  local created, mkdir_err = maki.fs.mkdir(maki.fs.dirname(path), { parents = true })
  if not created then
    return nil, "cannot create goal state directory: " .. tostring(mkdir_err)
  end
  local written, write_err = maki.fs.atomic_write(path, encoded)
  if not written then
    return nil, "cannot atomically write goal state: " .. tostring(write_err)
  end
  return true
end

local function serialized(fn)
  local permit = semaphore:acquire()
  local ok, value, extra, third = pcall(fn)
  permit:release()
  if not ok then
    error(value, 0)
  end
  return value, extra, third
end

local function background(session_id, fn)
  maki.async.run(function()
    local ok, err = pcall(fn)
    if not ok then
      maki.log.warn("goal [session " .. session_id .. "]: " .. tostring(err))
    end
  end)
end

local function interrupted(session_id, record)
  return record
    and record.status == "active"
    and execution_id(pending_executions[session_id]) ~= record.execution_id
    and execution_id(running_executions[session_id]) ~= record.execution_id
end

local function read_goal(session_id)
  return serialized(function()
    local state, state_err = load_state(session_id)
    if not state then
      return nil, state_err
    end
    local record = state.document and state.document.goal or nil
    return record, nil, interrupted(session_id, record)
  end)
end

local function set_hint(record, was_interrupted)
  local text = helpers.hint(record, os.time(), was_interrupted)
  maki.ui.set_status_hint(text and { { text, "foreground" } } or nil)
end

local function refresh_hint(session_id, generation)
  generation = generation or focus_generation
  if maki.session.current() ~= session_id then
    return
  end
  local record, err, was_interrupted = read_goal(session_id)
  if err then
    if maki.session.current() == session_id and generation == focus_generation then
      maki.ui.set_status_hint(nil)
    end
    maki.log.warn("goal [session " .. session_id .. "]: cannot refresh hint: " .. tostring(err))
    return
  end
  if maki.session.current() == session_id and generation == focus_generation then
    set_hint(record, was_interrupted)
  end
end

local function background_refresh(session_id)
  background(session_id, function()
    refresh_hint(session_id)
  end)
end

local function background_with_refresh(session_id, fn)
  background(session_id, function()
    local ok, err = pcall(fn)
    refresh_hint(session_id)
    if not ok then
      error(err, 0)
    end
  end)
end

local function block_delivery(session_id, expected, message)
  local state, state_err = load_state(session_id)
  if not state then
    return nil, state_err
  end
  if not state.document then
    return true
  end
  local current = state.document.goal
  local blocked = helpers.block_delivery(current, expected.id, expected.execution_id, message)
  if blocked == current then
    return true
  end
  return write_goal(state.path, session_id, blocked)
end

local function deliver(session_id, record, message)
  clear_fences(session_id)
  pending_executions[session_id] = {
    execution_id = record.execution_id,
    phase = PHASE_DELIVERY,
  }
  local delivered, delivery_err = maki.session.notify(message, {
    session = session_id,
    wake = true,
  })
  if delivered then
    return true
  end
  clear_fences(session_id)
  local blocked, block_err = block_delivery(session_id, record, "Goal delivery failed: " .. tostring(delivery_err))
  if not blocked then
    return nil, tostring(delivery_err) .. "; failed to block goal: " .. tostring(block_err)
  end
  return nil, tostring(delivery_err)
end

local function focused_session(require_idle)
  local session_id, current_err = maki.session.current()
  if not session_id then
    return nil, current_err
  end
  if not require_idle then
    return session_id
  end
  local live, live_err = maki.session.live()
  if not live then
    return nil, live_err
  end
  for _, session in ipairs(live) do
    if session.id == session_id then
      if session.status ~= "idle" then
        return nil, "the focused session must be idle"
      end
      return session_id
    end
  end
  return nil, "the focused session is not live"
end

local function start_goal(objective)
  local session_id, session_err = focused_session(true)
  if not session_id then
    return nil, session_err
  end
  local record = helpers.new_goal(new_id("goal"), new_id("execution"), objective, opts.max_turns, os.time())
  clear_fences(session_id)
  local persisted, err = serialized(function()
    local state, state_err = load_state(session_id)
    if not state then
      return nil, state_err
    end
    local written, write_err = write_goal(state.path, session_id, record)
    if not written then
      return nil, write_err
    end
    local delivered, delivery_err = deliver(session_id, record, helpers.start_message(record))
    if not delivered then
      return nil, delivery_err
    end
    return record
  end)
  return persisted, err, session_id
end

local function pause_goal()
  local session_id, session_err = focused_session(false)
  if not session_id then
    return nil, session_err
  end
  clear_fences(session_id)
  local record, err = serialized(function()
    local state, state_err = load_state(session_id)
    if not state then
      return nil, state_err
    end
    if not state.document then
      return nil, "no goal is set for this session"
    end
    local paused, pause_err = helpers.pause(state.document.goal)
    if not paused then
      return nil, pause_err
    end
    local written, write_err = write_goal(state.path, session_id, paused)
    if not written then
      return nil, write_err
    end
    return paused
  end)
  return record, err, session_id
end

local function resume_goal()
  local session_id, session_err = focused_session(true)
  if not session_id then
    return nil, session_err
  end
  clear_fences(session_id)
  local record, err = serialized(function()
    local state, state_err = load_state(session_id)
    if not state then
      return nil, state_err
    end
    if not state.document then
      return nil, "no goal is set for this session"
    end
    local resumed, resume_err = helpers.resume(state.document.goal, new_id("execution"))
    if not resumed then
      return nil, resume_err
    end
    local written, write_err = write_goal(state.path, session_id, resumed)
    if not written then
      return nil, write_err
    end
    local delivered, delivery_err = deliver(session_id, resumed, helpers.continuation_message(resumed))
    if not delivered then
      return nil, delivery_err
    end
    return resumed
  end)
  return record, err, session_id
end

local function clear_goal()
  local session_id, session_err = focused_session(false)
  if not session_id then
    return nil, session_err
  end
  clear_fences(session_id)
  local cleared, err = serialized(function()
    local path, path_err = state_path(session_id)
    if not path then
      return nil, path_err
    end
    local removed, remove_err = maki.fs.rm(path, { force = true })
    if not removed then
      return nil, "cannot delete goal state: " .. tostring(remove_err)
    end
    return true
  end)
  return cleared, err, session_id
end

local function command(command_opts)
  local arg = helpers.trim(command_opts.args or "")
  local session_id
  local record, err, was_interrupted
  if arg == "" then
    session_id, err = focused_session(false)
    if session_id then
      record, err, was_interrupted = read_goal(session_id)
    end
  elseif arg == "pause" then
    record, err, session_id = pause_goal()
  elseif arg == "resume" then
    record, err, session_id = resume_goal()
  elseif arg == "clear" then
    _, err, session_id = clear_goal()
  else
    record, err, session_id = start_goal(arg)
  end
  if err then
    if session_id then
      refresh_hint(session_id)
    end
    maki.ui.flash("Goal error: " .. tostring(err))
    return
  end
  refresh_hint(session_id)
  if arg == "clear" then
    maki.ui.flash("Goal cleared.")
  else
    maki.ui.flash(helpers.format(record, was_interrupted))
  end
end

maki.api.register_command({
  name = "/goal",
  description = "Set, inspect, pause, resume, or clear a session goal.",
  nargs = "*",
  handler = command,
})

maki.api.register_prompt_hint({
  slot = "tool_usage",
  content = "- When goal mode is active, use get_goal to inspect it and update_goal to mark it complete or blocked.",
})

maki.api.register_tool({
  name = "get_goal",
  description = "Get the current session's persisted goal and progress.",
  kind = "read",
  audiences = { "main" },
  schema = {
    type = "object",
    properties = {},
    additionalProperties = false,
  },
  handler = function(_, ctx)
    local session_id, session_err = ctx:session_id()
    if not session_id then
      return { llm_output = session_err or "this run has no session", is_error = true }
    end
    local record, err, was_interrupted = read_goal(session_id)
    if err then
      return { llm_output = err, is_error = true }
    end
    refresh_hint(session_id)
    return helpers.format(record, was_interrupted)
  end,
})

local function goal_body(text)
  return ToolView.restore(text, {
    max_lines = math.huge,
    max_expand_lines = math.huge,
    keep = "head",
  })
end

maki.api.register_tool({
  name = "update_goal",
  description = "Mark an active goal complete or blocked, or correct a blocked goal to complete.",
  kind = "execute",
  audiences = { "main" },
  restore = function(_, output)
    return goal_body(output)
  end,
  schema = {
    type = "object",
    properties = {
      goal_id = { type = "string" },
      execution_id = { type = "string" },
      status = { type = "string", enum = { "complete", "blocked" } },
      summary = { type = "string" },
    },
    required = { "goal_id", "execution_id", "status", "summary" },
    additionalProperties = false,
  },
  handler = function(input, ctx)
    local session_id, session_err = ctx:session_id()
    if not session_id then
      return { llm_output = session_err or "this run has no session", is_error = true }
    end
    local record, err = serialized(function()
      local state, state_err = load_state(session_id)
      if not state then
        return nil, state_err
      end
      if not state.document then
        return nil, "no goal is set for this session"
      end
      local updated, update_err =
        helpers.terminal_update(state.document.goal, input.goal_id, input.execution_id, input.status, input.summary)
      if not updated then
        return nil, update_err
      end
      if
        state.document.goal.status == "active"
        and execution_id(running_executions[session_id]) ~= input.execution_id
      then
        return nil, "goal execution is not running; use /goal resume"
      end
      clear_fences(session_id)
      local written, write_err = write_goal(state.path, session_id, updated)
      if not written then
        return nil, write_err
      end
      return updated
    end)
    refresh_hint(session_id)
    if err then
      return { llm_output = err, is_error = true }
    end
    return {
      llm_output = helpers.update_output(record),
      body = goal_body(helpers.format(record)),
    }
  end,
})

maki.api.create_autocmd("SessionFocusChanged", {
  callback = function(event)
    focus_generation = focus_generation + 1
    local generation = focus_generation
    background(event.data.session_id, function()
      refresh_hint(event.data.session_id, generation)
    end)
  end,
})

maki.api.create_autocmd("TurnStart", {
  callback = function(event)
    local session_id = event.data.session_id
    local fence = pending_executions[session_id]
    running_executions[session_id] = nil
    if fence and fence.phase == PHASE_DELIVERY then
      fence.phase = PHASE_RUNNING
      pending_executions[session_id] = nil
      running_executions[session_id] = fence
    end
    background_refresh(session_id)
  end,
})

maki.api.create_autocmd({ "ToolStart", "ToolDone" }, {
  callback = function(event)
    background_refresh(event.data.session_id)
  end,
})

maki.api.create_autocmd("TurnEnd", {
  callback = function(event)
    local session_id = event.data.session_id
    local fence = running_executions[session_id]
    running_executions[session_id] = nil
    if not fence then
      background_refresh(session_id)
      return
    end
    fence.phase = PHASE_TRANSITION
    pending_executions[session_id] = fence
    background_with_refresh(session_id, function()
      serialized(function()
        if pending_executions[session_id] ~= fence then
          return
        end
        local state, state_err = load_state(session_id)
        if not state then
          pending_executions[session_id] = nil
          error(state_err, 0)
        end
        if not state.document then
          pending_executions[session_id] = nil
          return
        end
        if pending_executions[session_id] ~= fence then
          return
        end
        local current = state.document.goal
        local advanced, continue = helpers.turn_end(current, fence.execution_id)
        if advanced == current then
          pending_executions[session_id] = nil
          return
        end
        local written, write_err = write_goal(state.path, session_id, advanced)
        if not written then
          if pending_executions[session_id] == fence then
            pending_executions[session_id] = nil
          end
          error(write_err, 0)
        end
        if pending_executions[session_id] ~= fence then
          return
        end
        if continue then
          local delivered, delivery_err = deliver(session_id, advanced, helpers.continuation_message(advanced))
          if not delivered then
            error("continuation delivery failed: " .. delivery_err, 0)
          end
        else
          pending_executions[session_id] = nil
        end
      end)
    end)
  end,
})

maki.api.create_autocmd("TurnError", {
  callback = function(event)
    local session_id = event.data.session_id
    local fence = running_executions[session_id]
    running_executions[session_id] = nil
    if not fence then
      background_refresh(session_id)
      return
    end
    fence.phase = PHASE_TRANSITION
    pending_executions[session_id] = fence
    background_with_refresh(session_id, function()
      serialized(function()
        if pending_executions[session_id] ~= fence then
          return
        end
        local state, state_err = load_state(session_id)
        if not state then
          pending_executions[session_id] = nil
          error(state_err, 0)
        end
        if not state.document then
          pending_executions[session_id] = nil
          return
        end
        if pending_executions[session_id] ~= fence then
          return
        end
        local current = state.document.goal
        local blocked = helpers.turn_error(current, fence.execution_id, event.data.message)
        if blocked == current then
          pending_executions[session_id] = nil
          return
        end
        local written, write_err = write_goal(state.path, session_id, blocked)
        if not written then
          if pending_executions[session_id] == fence then
            pending_executions[session_id] = nil
          end
          error(write_err, 0)
        end
        if pending_executions[session_id] == fence then
          pending_executions[session_id] = nil
        end
      end)
    end)
  end,
})

maki.api.create_autocmd("SessionReset", {
  callback = function(event)
    clear_fences(event.data.session_id)
    maki.ui.set_status_hint(nil)
  end,
})
