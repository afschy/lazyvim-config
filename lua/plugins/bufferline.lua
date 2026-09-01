-- Move the current buffer to the far left/right of the bufferline.
--
-- bufferline's own `move_to()` swaps the current buffer with the one at the
-- target index instead of shifting the rest along, so step with adjacent
-- moves (`BufferLineMovePrev`/`Next`) until the boundary is reached.
local function move_to_end(dir)
  local state = require("bufferline.state")
  local commands = require("bufferline.commands")
  local groups = require("bufferline.groups")

  local index, element = commands.get_current_element_index(state)
  if not index or not element then
    return
  end

  -- Pinned buffers form their own block at the left; keep the move inside
  -- whichever block the current buffer belongs to, so pinning still holds.
  local pinned_count = 0
  for _, item in ipairs(state.components) do
    local el = item:as_element()
    if not (el and groups._is_pinned(el)) then
      break
    end
    pinned_count = pinned_count + 1
  end

  local target
  if groups._is_pinned(element) then
    target = dir < 0 and 1 or pinned_count
  else
    target = dir < 0 and pinned_count + 1 or #state.components
  end

  for _ = 1, math.abs(target - index) do
    commands.move(dir)
  end
end

return {
  "akinsho/bufferline.nvim",
  keys = {
    { "<leader>b[", function() move_to_end(-1) end, desc = "Move Buffer to Start" },
    { "<leader>b]", function() move_to_end(1) end, desc = "Move Buffer to End" },
  },
}
