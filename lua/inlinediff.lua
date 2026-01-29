local M = {}
local api = vim.api

M.ns = api.nvim_create_namespace("inlinediff")
M.enabled = false
M.last_diff_output = nil -- Cache to prevent unnecessary redraws
M.last_diff_buf = nil -- Buffer id that `last_diff_output` corresponds to

M.default_config = {
	debounce_time = 200,
	colors = {
		InlineDiffAddContext = "#182400",
		InlineDiffAddChange = "#395200",
		InlineDiffDeleteContext = "#240004",
		InlineDiffDeleteChange = "#520005",
	},
}
M.config = vim.deepcopy(M.default_config)

--------------------------------------------------------------------------------
-- 1. UTILS & COLORS
--------------------------------------------------------------------------------

local function setup_highlights()
	local c = M.config.colors
	api.nvim_set_hl(0, "InlineDiffAddContext", { bg = c.InlineDiffAddContext, default = false })
	api.nvim_set_hl(0, "InlineDiffAddChange", { bg = c.InlineDiffAddChange, default = false })
	api.nvim_set_hl(0, "InlineDiffDeleteContext", { bg = c.InlineDiffDeleteContext, default = false })
	api.nvim_set_hl(0, "InlineDiffDeleteChange", { bg = c.InlineDiffDeleteChange, default = false })
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
	if path == "" then
		return
	end

	local fullpath = vim.fn.fnamemodify(path, ":p")
	local dir = vim.fn.fnamemodify(fullpath, ":h")
	local name = vim.fn.fnamemodify(fullpath, ":t")

	-- Read buffer (unsaved) content
	local buf_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local buf_content = table.concat(buf_lines, "\n")
	if buf_content == "" or buf_content:sub(-1) ~= "\n" then
		buf_content = buf_content .. "\n"
	end

	-- Try to read the index version of the file. If it fails (untracked/new file), treat index as empty.
	local cmd = { "git", "show", ":./" .. name }
	vim.system(cmd, { cwd = dir, text = true }, function(obj)
		local index_content = ""
		if obj and obj.code == 0 and obj.stdout then
			index_content = obj.stdout
		end

		-- Produce a unified diff between index (old) and buffer (new)
		local diff_out = vim.diff(index_content, buf_content, {
			algorithm = "minimal",
			result_type = "unified",
			ctxlen = 3,
			interhunkctxlen = 4,
		})

		if diff_out and diff_out ~= "" then
			cb(diff_out)
		else
			cb(nil)
		end
	end)
end

local function parse_hunks(output)
	local hunks = {}
	local lines = vim.split(output, "\n", { trimempty = true })
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
					local prefix = l:sub(1, 1)
					if prefix == " " or prefix == "+" or prefix == "-" then
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
		if #p_old == 0 and #p_new == 0 then
			return
		end

		-- Logic: 1-to-1 Pairing for precise diffs
		-- Excess lines are strictly pure add/del (Dimmed)

		local min_len = math.min(#p_old, #p_new)
		local virts_old = {} -- List of { {text, hl}, ... }

		-- 1. Initialize Old Map with Context (Dimmed) DEFAULT
		for i, line_content in ipairs(p_old) do
			virts_old[i] = { { line_content, "InlineDiffDeleteContext" } }
		end

		-- 2. Apply Default Context Highlight to New Lines
		for j = 0, #p_new - 1 do
			local l = buf_line_idx + j
			api.nvim_buf_set_extmark(bufnr, M.ns, l, 0, {
				end_line = l + 1,
				hl_group = "InlineDiffAddContext",
				hl_eol = true,
				priority = 100,
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
					algorithm = "minimal",
					result_type = "indices",
					ctxlen = 0,
					interhunkctxlen = 4,
					indent_heuristic = false,
					linematch = 0,
				})

				if diffs then
					-- A. OLD / DELETE Chunks
					local old_mask = {}
					local chgd_old = 0
					for _, d in ipairs(diffs) do
						local start, count = d[1], d[2]
						for k = 0, count - 1 do
							old_mask[start + k] = true
							chgd_old = chgd_old + 1
						end
					end

					-- Only show Bright if NOT a full line replacement
					if chgd_old < #c_old then
						local chunks = {}
						local cur_hl, cur_txt = nil, {}
						for k, char in ipairs(c_old) do
							local hl = old_mask[k] and "InlineDiffDeleteChange" or "InlineDiffDeleteContext"
							if hl ~= cur_hl then
								if #cur_txt > 0 then
									table.insert(chunks, { table.concat(cur_txt), cur_hl })
								end
								cur_txt = { char }
								cur_hl = hl
							else
								table.insert(cur_txt, char)
							end
						end
						if #cur_txt > 0 then
							table.insert(chunks, { table.concat(cur_txt), cur_hl })
						end
						virts_old[i] = chunks
					end

					-- B. NEW / ADD Highlights
					local new_mask = {}
					local chgd_new = 0
					for _, d in ipairs(diffs) do
						local start, count = d[3], d[4]
						for k = 0, count - 1 do
							new_mask[start + k] = true
							chgd_new = chgd_new + 1
						end
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
									hl_group = "InlineDiffAddChange",
									priority = 120,
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
			table.insert(chunks, { padding_text, "InlineDiffDeleteContext" })
			table.insert(final_virt, chunks)
		end

		if #final_virt > 0 then
			api.nvim_buf_set_extmark(bufnr, M.ns, buf_line_idx, 0, {
				virt_lines = final_virt,
				virt_lines_above = true,
			})
		end

		-- Advance
		buf_line_idx = buf_line_idx + #p_new
		p_old = {}
		p_new = {}
	end

	for _, l in ipairs(hunk.lines) do
		local pre, content = l:sub(1, 1), l:sub(2)
		if pre == " " then
			flush_change()
			buf_line_idx = buf_line_idx + 1
		elseif pre == "-" then
			table.insert(p_old, content)
		elseif pre == "+" then
			table.insert(p_new, content)
		end
	end

	flush_change()
end

--------------------------------------------------------------------------------
-- 4. PUBLIC API
--------------------------------------------------------------------------------

M.refresh = function(bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	if not M.enabled then
		return
	end

	run_git_diff(
		bufnr,
		vim.schedule_wrap(function(output)
			-- Only redraw if the diff has actually changed for this buffer
			if M.last_diff_buf == bufnr and output == M.last_diff_output then
				return
			end

			-- Update cache for this buffer
			M.last_diff_output = output
			M.last_diff_buf = bufnr

			api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)

			if not output or output == "" then
				return
			end
			local hunks = parse_hunks(output)
			for _, h in ipairs(hunks) do
				render_hunk(bufnr, h)
			end
		end)
	)
end

local debounce_timer = nil
local augroup = nil

local function setup_autocmds()
	if augroup then
		api.nvim_del_augroup_by_id(augroup)
	end

	augroup = api.nvim_create_augroup("InlineDiffAuto", { clear = true })

	local function debounced_refresh()
		if not M.enabled or (M.config.debounce_time or 0) == 0 then
			return
		end

		if debounce_timer then
			debounce_timer:stop()
			if not debounce_timer:is_closing() then
				debounce_timer:close()
			end
		end

		debounce_timer = vim.loop.new_timer()
		debounce_timer:start(
			M.config.debounce_time,
			0,
			vim.schedule_wrap(function()
				if debounce_timer then
					if not debounce_timer:is_closing() then
						debounce_timer:close()
					end
					debounce_timer = nil
				end
				if M.enabled then
					M.refresh()
				end
			end)
		)
	end

	-- Trigger on text changes in normal mode, insert mode, and paste
	api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
		group = augroup,
		callback = debounced_refresh,
	})

	-- Clear cache when buffers unload or are deleted to avoid stale references
	api.nvim_create_autocmd({ "BufUnload", "BufDelete" }, {
		group = augroup,
		callback = function(ctx)
			local b = ctx.buf or ctx.bufnr
			if M.last_diff_buf == b then
				M.last_diff_buf = nil
				M.last_diff_output = nil
			end
		end,
	})
end

local function clear_autocmds()
	if augroup then
		api.nvim_del_augroup_by_id(augroup)
		augroup = nil
	end
	if debounce_timer then
		debounce_timer:stop()
		if not debounce_timer:is_closing() then
			debounce_timer:close()
		end
		debounce_timer = nil
	end
end

function M.toggle()
	M.setup(M.config) -- Reload highlights on toggle to ensure freshness
	if M.enabled then
		M.enabled = false
		M.last_diff_output = nil -- Clear cache on disable
		M.last_diff_buf = nil
		clear_autocmds()
		-- Clear highlights/virt_lines in all loaded buffers
		for _, b in ipairs(api.nvim_list_bufs()) do
			if api.nvim_buf_is_loaded(b) then
				pcall(api.nvim_buf_clear_namespace, b, M.ns, 0, -1)
			end
		end
	else
		M.enabled = true
		M.last_diff_output = nil -- Clear cache on enable to force initial render
		M.last_diff_buf = nil
		setup_autocmds()
		M.refresh()
	end
end

M.setup = function(opts)
	M.config = vim.tbl_deep_extend("force", M.default_config, opts or {})
	setup_highlights()

	-- Create user command `:InlineDiff [toggle|refresh]`
	pcall(function()
		api.nvim_create_user_command("InlineDiff", function(cmdopts)
			local arg = (cmdopts.args or ""):match("^%s*(%S*)") or ""
			if arg == "" or arg == "toggle" then
				M.toggle()
			elseif arg == "refresh" then
				M.refresh()
			else
				print('InlineDiff: unknown arg "' .. arg .. '". Use "toggle" or "refresh"')
			end
		end, {
			nargs = "?",
			complete = function(ArgLead, _, _)
				local opts = { "toggle", "refresh" }
				local res = {}
				for _, v in ipairs(opts) do
					if v:sub(1, #ArgLead) == ArgLead then
						table.insert(res, v)
					end
				end
				return res
			end,
			desc = "InlineDiff commands: toggle or refresh",
			-- force option not present in older neovim; using pcall wrapper to avoid errors
		})
	end)
end

return M
