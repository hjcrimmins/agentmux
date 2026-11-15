# Merge the agentmux adapter's hooks into Claude Code settings. Idempotent: existing
# agentmux entries are replaced, everything else (other hooks, other settings) is kept.
.hooks = (reduce ($a[0].hooks | to_entries[]) as $e (.hooks // {};
  .[$e.key] = ([(.[$e.key] // [])[] | select(any(.hooks[]?; (.command // "") | test("agentmux")) | not)] + $e.value)))
