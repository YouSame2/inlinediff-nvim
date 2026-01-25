local M = {}
local api = vim.api

M.ns = api.nvim_create_namespace('inlinediff')
M.enabled = false

M.default_config = {
  colors = {
    InlineDiffAddContext = "#182400",
    InlineDiffAddChange = "#395200",
    InlineDiffDeleteContext = "#240004",
    InlineDiffDeleteChange = "#520005",
  }
}
M.config = vim.deepcopy(M.default_config)

--------------------------------------------------------------------------------
-- 1. UTILS & COLORS
--------------------------------------------------------------------------------

local function setup_highlights()
  local c = M.config.colors
  api.nvim_set_hl(0, 'InlineDiffAddContext', { bg = c.InlineDiffAddContext, default = false })
  api.nvim_set_hl(0, 'InlineDiffAddChange', { bg = c.InlineDiffAddChange, default = false })
  api.nvim_set_hl(0, 'InlineDiffDeleteContext', { bg = c.InlineDiffDeleteContext, default = false })
  api.nvim_set_hl(0, 'InlineDiffDeleteChange', { bg = c.InlineDiffDeleteChange, default = false })
end

-- UTF-8 Safe Split
local function split_utf8(str)
  local t = {}
  for char in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    table.insert(t, char)
  end
  return t
end

-- Map linear string indices to line/byte positions
-- (Simplified for single-line usage, but kept robust)
local function map_indices(chars)
  local map = {}
  local current_byte = 0
  for _, char in ipairs(chars) do
     table.insert(map, { byte = current_byte, char_len = #char })
     current_byte = current_byte + #char
  end
  return map
end

--------------------------------------------------------------------------------
-- 2. GIT SOURCE
--------------------------------------------------------------------------------

local function run_git_diff(bufnr, cb)
  local path = api.nvim_buf_get_name(bufnr)
  if path == '' then return end
  path = vim.fn.fnamemodify(path, ':p')
  
  local cmd = { 'git', 'diff', '--no-color', '--no-ext-diff', '-U3', '--', path }
  vim.system(cmd, { text = true }, function(obj)
     if obj.code == 0 then cb(obj.stdout) end
  end)
end

local function parse_hunks(output)
  local hunks = {}
  local lines = vim.split(output, '\n', { trimempty = true })
  local i = 1
  
  while i <= #lines do
    local line = lines[i]
    if line:match("^@@") then
      local ns, nc = line:match("@@ .* %+(%d+),?(%d*) @@")
      if ns then
          local hunk = { new_start = tonumber(ns), lines = {} }
          i = i + 1
          while i <= #lines do
            local l = lines[i]
            if l:match("^diff") or l:match("^index") or l:match("^@@") then
               i = i - 1
               break
            end
            local prefix = l:sub(1,1)
            if prefix == ' ' or prefix == '+' or prefix == '-' then
               table.insert(hunk.lines, l)
            end
            i = i + 1
          end
          table.insert(hunks, hunk)
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return hunks
end

--------------------------------------------------------------------------------
-- 3. CORE LOGIC & RENDERING
--------------------------------------------------------------------------------

local function render_hunk(bufnr, hunk)
    local buf_line_idx = hunk.new_start - 1 -- 0-based index in buffer
    
    local p_old = {}
    local p_new = {}
    
    -- "Padding" to ensure highlights reach screen edge
    local padding_text = string.rep(" ", 300) 

    local function flush_change()
        if #p_old == 0 and #p_new == 0 then return end
        
        -- Logic: 1-to-1 Pairing for precise diffs
        -- Excess lines are strictly pure add/del (Dimmed)
        
        local min_len = math.min(#p_old, #p_new)
        local virts_old = {} -- List of { {text, hl}, ... }
        
        -- 1. Initialize Old Map with Context (Dimmed) DEFAULT
        for i, line_content in ipairs(p_old) do
             virts_old[i] = { { line_content, 'InlineDiffDeleteContext' } }
        end
        
        -- 2. Apply Default Context Highlight to New Lines
        for j = 0, #p_new - 1 do
            local l = buf_line_idx + j
            api.nvim_buf_set_extmark(bufnr, M.ns, l, 0, {
                end_line = l + 1,
                hl_group = 'InlineDiffAddContext',
                hl_eol = true,
                priority = 100
            })
        end

        -- 3. Calculate Char Diffs for pairs
        -- CRITICAL: Get actual buffer lines for NEW content to ensure byte offsets are correct
        local buf_lines_new = {}
        if #p_new > 0 then
            buf_lines_new = api.nvim_buf_get_lines(bufnr, buf_line_idx, buf_line_idx + #p_new, false)
        end
        
        for i = 1, min_len do
             local s_old = p_old[i]
             -- Use actual buffer content for NEW lines
             local s_new = buf_lines_new[i] or p_new[i]
             local c_old = split_utf8(s_old)
             local c_new = split_utf8(s_new)
             
             if #c_old > 0 and #c_new > 0 then
                 local diffs = vim.diff(table.concat(c_old, "\n"), table.concat(c_new, "\n"), {
                     algorithm = 'minimal',
                     result_type = 'indices',
                     ctxlen = 0,
                     interhunkctxlen = 4,
                     indent_heuristic = false,
                     linematch = 0
                 })
                 
                 if diffs then
                     -- A. OLD / DELETE Chunks
                     local old_mask = {}
                     local chgd_old = 0
                     for _, d in ipairs(diffs) do
                         local start, count = d[1], d[2]
                         for k=0, count-1 do old_mask[start+k] = true; chgd_old = chgd_old + 1 end
                     end
                     
                     -- Only show Bright if NOT a full line replacement
                     if chgd_old < #c_old then
                         local chunks = {}
                         local cur_hl, cur_txt = nil, {}
                         for k, char in ipairs(c_old) do
                             local hl = old_mask[k] and 'InlineDiffDeleteChange' or 'InlineDiffDeleteContext'
                             if hl ~= cur_hl then
                                 if #cur_txt > 0 then table.insert(chunks, { table.concat(cur_txt), cur_hl }) end
                                 cur_txt = { char }
                                 cur_hl = hl
                             else
                                 table.insert(cur_txt, char)
                             end
                         end
                         if #cur_txt > 0 then table.insert(chunks, { table.concat(cur_txt), cur_hl }) end
                         virts_old[i] = chunks
                     end
                     
                     -- B. NEW / ADD Highlights
                     local new_mask = {}
                     local chgd_new = 0
                     for _, d in ipairs(diffs) do
                         local start, count = d[3], d[4]
                         for k=0, count-1 do new_mask[start+k] = true; chgd_new = chgd_new + 1 end
                     end
                     
                     -- Only show Bright if NOT a full line replacement
                     if chgd_new < #c_new then
                         local map = map_indices(c_new)
                         local abs_line = buf_line_idx + (i - 1)
                         for k, char in ipairs(c_new) do
                             if new_mask[k] then
                                 local info = map[k]
                                 api.nvim_buf_set_extmark(bufnr, M.ns, abs_line, info.byte, {
                                     end_col = info.byte + info.char_len,
                                     hl_group = 'InlineDiffAddChange',
                                     priority = 120
                                 })
                             end
                         end
                     end
                 end
             end
        end
        
        -- 4. Render Virtual Lines (with Padding)
        local final_virt = {}
        for _, chunks in ipairs(virts_old) do
            table.insert(chunks, { padding_text, 'InlineDiffDeleteContext' })
            table.insert(final_virt, chunks)
        end
        
        if #final_virt > 0 then
            api.nvim_buf_set_extmark(bufnr, M.ns, buf_line_idx, 0, {
                virt_lines = final_virt,
                virt_lines_above = true
            })
        end

        -- Advance
        buf_line_idx = buf_line_idx + #p_new
        p_old = {}
        p_new = {}
    end
    
    for _, l in ipairs(hunk.lines) do
        local pre, content = l:sub(1,1), l:sub(2)
        if pre == ' ' then
            flush_change()
            buf_line_idx = buf_line_idx + 1
        elseif pre == '-' then
            table.insert(p_old, content)
        elseif pre == '+' then
            table.insert(p_new, content)
        end
    end
    
    flush_change()
end

--------------------------------------------------------------------------------
-- 4. PUBLIC API
--------------------------------------------------------------------------------

M.refresh = function()
   local bufnr = api.nvim_get_current_buf()
   if not M.enabled then return end
   api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
   
   run_git_diff(bufnr, vim.schedule_wrap(function(output)
      if not output or output == '' then return end
      local hunks = parse_hunks(output)
      for _, h in ipairs(hunks) do render_hunk(bufnr, h) end
   end))
end

function M.toggle()
  M.setup(M.config) -- Reload highlights on toggle to ensure freshness
  if M.enabled then
    M.enabled = false
    api.nvim_buf_clear_namespace(0, M.ns, 0, -1)
  else
    M.enabled = true
    M.refresh()
  end
end

M.setup = function(opts)
  M.config = vim.tbl_deep_extend("force", M.default_config, opts or {})
  setup_highlights()
end

return M
