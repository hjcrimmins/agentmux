# Remove every agentmux hook from Claude Code settings; keep everything else.
.hooks |= (with_entries(.value |= map(select(any(.hooks[]?; (.command // "") | test("agentmux")) | not)))
           | with_entries(select(.value | length > 0)))
