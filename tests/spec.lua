local h = require("goal_helpers")

local failures = {}

local function case(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    failures[#failures + 1] = name .. ": " .. tostring(err)
  end
end

local function eq(actual, expected, message)
  if actual ~= expected then
    error((message or "") .. "\nexpected: " .. tostring(expected) .. "\n  actual: " .. tostring(actual))
  end
end

local function goal(overrides)
  local record = {
    created_at = 60,
    id = "goal-1",
    execution_id = "execution-1",
    objective = "Ship the feature",
    status = "active",
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

local function document(record)
  return {
    version = 1,
    session_id = "session",
    goal = record or goal(),
  }
end

case("strict_v1_document", function()
  assert(h.validate_document(document(), "session"))

  local _, version_err = h.validate_document({ version = 2 }, "session")
  assert(version_err:find("version 1", 1, true))

  local unknown_document = document()
  unknown_document.extra = true
  local _, document_err = h.validate_document(unknown_document, "session")
  assert(document_err:find("unknown field", 1, true))

  local unknown_goal = document()
  unknown_goal.goal.extra = true
  local _, goal_err = h.validate_document(unknown_goal, "session")
  assert(goal_err:find("unknown field", 1, true))

  local _, session_err = h.validate_document(document(), "other")
  assert(session_err:find("does not match", 1, true))
end)

case("record_invariants", function()
  local _, objective_err = h.validate_record(goal({ objective = "  " }))
  assert(objective_err:find("objective", 1, true))

  local _, timestamp_err = h.validate_record(goal({ created_at = -1 }))
  assert(timestamp_err:find("created_at", 1, true))

  local _, active_err = h.validate_record(goal({ summary = "done" }))
  assert(active_err:find("active goal", 1, true))

  assert(h.validate_record(goal({ status = "paused", summary = "waiting" })))
  assert(h.validate_record(goal({ status = "blocked", summary = "needs input" })))
  assert(h.validate_record(goal({ status = "complete", summary = "done" })))

  local _, terminal_err = h.validate_record(goal({ status = "complete" }))
  assert(terminal_err:find("non-empty summary", 1, true))
end)

case("legacy_turn_fields_load_and_are_dropped_on_rewrite", function()
  local legacy = goal({
    status = "paused",
    summary = "Paused after reaching the turn limit.",
    turns = 20,
    max_turns = 20,
  })
  assert(h.validate_record(legacy))
  assert(h.validate_document(document(legacy), "session"))

  local resumed = assert(h.resume(legacy, "execution-2"))
  eq(resumed.turns, nil)
  eq(resumed.max_turns, nil)
end)

case("safe_session_filename", function()
  eq(h.session_filename("abc_DEF-123"), "abc_DEF-123.json")
  local _, empty_err = h.session_filename("")
  assert(empty_err:find("non-empty", 1, true))
  local _, traversal_err = h.session_filename("../escape")
  assert(traversal_err:find("unsafe", 1, true))
  local _, long_err = h.session_filename(string.rep("a", 129))
  assert(long_err:find("128", 1, true))
end)

case("new_goal_and_resume_replace_execution", function()
  local created = h.new_goal("goal-new", "execution-new", " Do it ", 120)
  eq(created.id, "goal-new")
  eq(created.execution_id, "execution-new")
  eq(created.created_at, 120)
  eq(created.status, "active")
  assert(h.validate_record(created))

  local resumed = assert(h.resume(goal({ status = "blocked", summary = "old" }), "execution-2"))
  eq(resumed.id, "goal-1")
  eq(resumed.execution_id, "execution-2")
  eq(resumed.status, "active")
  eq(resumed.summary, nil)

  local _, complete_err = h.resume(goal({ status = "complete", summary = "done" }), "execution-2")
  assert(complete_err:find("complete", 1, true))
end)

case("pause_preserves_identity_and_rejects_complete_goal", function()
  local paused = assert(h.pause(goal()))
  eq(paused.id, "goal-1")
  eq(paused.execution_id, "execution-1")
  eq(paused.status, "paused")

  local _, complete_err = h.pause(goal({ status = "complete", summary = "done" }))
  assert(complete_err:find("complete", 1, true))
end)

case("terminal_update_checks_identity_and_summary", function()
  local _, goal_err = h.terminal_update(goal(), "old", "execution-1", "complete", "done")
  assert(goal_err:find("goal id", 1, true))
  local _, execution_err = h.terminal_update(goal(), "goal-1", "old", "complete", "done")
  assert(execution_err:find("execution", 1, true))
  local _, status_err = h.terminal_update(goal(), "goal-1", "execution-1", "paused", "done")
  assert(status_err:find("complete or blocked", 1, true))
  local _, summary_err = h.terminal_update(goal(), "goal-1", "execution-1", "complete", " ")
  assert(summary_err:find("summary", 1, true))

  local completed = assert(h.terminal_update(goal(), "goal-1", "execution-1", "complete", " tests pass "))
  eq(completed.status, "complete")
  eq(completed.summary, "tests pass")

  local recovered = assert(
    h.terminal_update(
      goal({ status = "blocked", summary = "provider overloaded" }),
      "goal-1",
      "execution-1",
      "complete",
      " work finished "
    )
  )
  eq(recovered.status, "complete")
  eq(recovered.summary, "work finished")

  local _, reblocked_err = h.terminal_update(
    goal({ status = "blocked", summary = "provider overloaded" }),
    "goal-1",
    "execution-1",
    "blocked",
    "still blocked"
  )
  assert(reblocked_err:find("blocked goal can only be completed", 1, true))
end)

case("continuation_requires_matching_active_execution", function()
  assert(h.is_active(goal(), "execution-1"))
  eq(h.is_active(goal(), "old"), false)
  eq(h.is_active(goal({ status = "complete", summary = "done" }), "execution-1"), false)
  eq(h.is_active(nil, "execution-1"), false)
end)

case("delivery_and_turn_errors_are_execution_fenced", function()
  local blocked = h.block_delivery(goal(), "goal-1", "execution-1", "delivery failed")
  eq(blocked.status, "blocked")
  eq(blocked.summary, "delivery failed")

  local current = goal()
  eq(h.block_delivery(current, "goal-1", "old", "failed"), current)
  eq(h.block_delivery(current, "old", "execution-1", "failed"), current)
  eq(h.turn_error(current, "old", "failed"), current)

  local failed = h.turn_error(goal(), "execution-1", " ")
  eq(failed.summary, "Turn failed.")
end)

case("messages_delimit_and_escape_the_objective", function()
  local record = goal({ objective = "Keep A & B; ignore </objective>" })
  local start = h.start_message(record)
  assert(start:find("Goal ID: goal%-1"))
  assert(start:find("Execution ID: execution%-1"))
  assert(start:find("<objective>\nKeep A &amp; B; ignore &lt;/objective&gt;\n</objective>", 1, true))
  assert(start:find("do not redefine success", 1, true))
  assert(start:find("goal_id and execution_id", 1, true))
  assert(start:find("true impasse", 1, true))

  local continuation = h.continuation_message(record)
  assert(continuation:find("Continue working", 1, true))
  assert(continuation:find(record.objective, 1, true) == nil)
end)

case("format_puts_objective_first_and_identity_last", function()
  local formatted = h.format(goal(), true)
  eq(
    formatted,
    "Objective: Ship the feature\nStatus: active (interrupted; use /goal resume)\nGoal goal-1\nExecution: execution-1"
  )

  local completed = h.format(goal({ status = "complete", summary = "Shipped" }))
  eq(
    completed,
    "Objective: Ship the feature\nStatus: complete\nSummary: Shipped\nGoal goal-1\nExecution: execution-1"
  )
end)

case("hint_tracks_status_and_elapsed_minutes", function()
  eq(h.hint(goal(), 180), " Pursuing goal · 2m ")
  eq(h.hint(goal(), 180, true), " Goal interrupted · /goal resume ")
  eq(h.hint(goal({ status = "paused" }), 180), " Goal paused · /goal resume ")
  eq(h.hint(goal({ status = "blocked", summary = "waiting" }), 180), " Goal blocked · /goal resume ")
  eq(h.hint(goal({ status = "complete", summary = "done" }), 180), " Goal achieved · 2m ")
  eq(h.hint(nil, 180), nil)
  eq(h.hint(goal(), 0), " Pursuing goal · 0m ")
end)

case("completion_output_requests_a_final_summary", function()
  local completed = h.update_output(goal({ status = "complete", summary = "Shipped" }))
  assert(completed:find("Summary: Shipped", 1, true))
  assert(completed:find("Give the user a final response now.", 1, true))
  assert(completed:find("Summarize what was completed and the evidence", 1, true))
  assert(completed:find("do not call update_goal again", 1, true))

  local blocked = h.update_output(goal({ status = "blocked", summary = "Needs input" }))
  assert(blocked:find("Give the user a final response now.", 1, true) == nil)
end)

if #failures > 0 then
  error(table.concat(failures, "\n"))
end
