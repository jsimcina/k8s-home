#!/usr/bin/env bash
# Claude Code PreToolUse hook for the UniFi MCP servers (unifi, unifi-2, unifi-network plugin).
# Approves read-only calls (list/get/lookup, the tool index, batch status), including reads
# dispatched through unifi_execute or unifi_batch. Everything else, mutations and their
# confirm: true calls included, gets no decision here and falls through to the normal prompt.
jq -c '
  def bare: sub("^.*__"; "") | sub("^unifi_"; "");
  def is_read: bare | test("^((list|get|lookup)_|tool_index$|load_tools$|batch_status$)");
  (.tool_name | bare) as $t
  | if $t == "execute" then (.tool_input.tool // "" | is_read)
    elif $t == "batch" then ((.tool_input.operations // []) as $ops
      | ($ops | length) > 0 and all($ops[]; (.tool // "") | is_read))
    else (.tool_name | is_read) end
  | if . then {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow",
      permissionDecisionReason: "read-only UniFi call"}} else empty end
'
