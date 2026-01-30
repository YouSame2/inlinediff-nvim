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
	ignored_buftype = { "terminal", "nofile" },
	ignored_filetype = { "TelescopePrompt", "NvimTree", "dap-repl", "neo-tree" },
}
M.config = vim.deepcopy(M.default_config)

-- Constants for extmark priorities and rendering
local PRIORITY_CONTEXT = 100
local PRIORITY_CHANGE = 120
local MIN_PADDING_LENGTH = 40
local MAX_PADDING_LENGTH = 300

local DIFF_PREFIX = { UNCHANGED = " ", DELETED = "-", ADDED = "+" }

local function setup_highlights()
	local c = M.config.colors
	for name, color in pairs(c) do
		api.nvim_set_hl(0, name, { bg = color, default = false })
	end
end
local function build_char_array(s)
	local chars = {}
	local n = vim.str_utfindex(s, "utf-8") or 0
	for i = 0, n - 1 do
		table.insert(chars, vim.fn.strcharpart(s, i, 1))
	end
	return chars
end

local function byte_map_for(s)
	local map = {}
	local n = vim.str_utfindex(s, "utf-8") or 0
	for i = 0, n - 1 do
		local start = vim.str_byteindex(s, "utf-8", i, false)
		local finish = vim.str_byteindex(s, "utf-8", i + 1, false)
		table.insert(map, { byte = start, char_len = finish - start })
	end
	return map
end

local function is_in_list(value, list)
	for _, v in ipairs(list or {}) do
		if value == v then
			return false
		end
	end
	return true
end

local function is_buffer_valid(bufnr)
	if not api.nvim_buf_is_valid(bufnr) or not api.nvim_buf_is_loaded(bufnr) then
		return false
	end

	local ok, buftype = pcall(api.nvim_buf_get_option, bufnr, "buftype")
	if ok and buftype ~= "" and not is_in_list(buftype, M.config.ignored_buftype) then
		return false
	end

	local ok2, ft = pcall(api.nvim_buf_get_option, bufnr, "filetype")
	if ok2 and ft ~= "" and not is_in_list(ft, M.config.ignored_filetype) then
		return false
	end

	local ok3, listed = pcall(api.nvim_buf_get_option, bufnr, "buflisted")
	if not ok3 or not listed then
		return false
	end

	if api.nvim_buf_get_name(bufnr) == "" then
		local ok4, mod = pcall(api.nvim_buf_get_option, bufnr, "modifiable")
		return ok4 and mod
	end

	return true
end

local function compute_unified_diff(old_content, new_content)
	local diff_out = vim.diff(old_content, new_content, {
		algorithm = "minimal",
		result_type = "unified",
		ctxlen = 3,
		interhunkctxlen = 4,
	})

	return (diff_out and diff_out ~= "") and diff_out or nil
end

local function run_git_diff(bufnr, cb)
	local path = api.nvim_buf_get_name(bufnr)
	if path == "" then
		return
	end

	local fullpath = vim.fn.fnamemodify(path, ":p")
	local buf_content = table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n") .. "\n"

	vim.system(
		{ "git", "rev-parse", "--show-toplevel" },
		{ cwd = vim.fn.fnamemodify(fullpath, ":h"), text = true },
		function(root_obj)
			local index_content = ""

			if not root_obj or root_obj.code ~= 0 then
				return cb(compute_unified_diff(index_content, buf_content))
			end

			-- Compute repo-relative path
			local repo_root = root_obj.stdout:gsub("\n$", "")
			local real_fullpath = vim.loop.fs_realpath(fullpath) or fullpath
			local real_repo_root = vim.loop.fs_realpath(repo_root) or repo_root

			local relpath = real_fullpath:sub(1, #real_repo_root) == real_repo_root
					and real_fullpath:sub(#real_repo_root + 1):gsub("^/", "")
				or vim.fn.fnamemodify(fullpath, ":t")

			vim.system({ "git", "show", ":./" .. (relpath or "") }, { cwd = repo_root, text = true }, function(obj)
				if obj and obj.code == 0 and obj.stdout then
					index_content = obj.stdout
				end
				cb(compute_unified_diff(index_content, buf_content))
			end)
		end
	)
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

local function compute_char_diff(old_chars, new_chars)
	if #old_chars == 0 or #new_chars == 0 then
		return nil
	end
	return vim.diff(table.concat(old_chars, "\n"), table.concat(new_chars, "\n"), {
		algorithm = "minimal",
		result_type = "indices",
		ctxlen = 0,
		interhunkctxlen = 4,
		indent_heuristic = false,
		linematch = 0,
	})
end

local function build_change_mask(diffs, idx)
	local mask, count = {}, 0
	for _, d in ipairs(diffs) do
		for k = 0, d[idx + 1] - 1 do
			mask[d[idx] + k] = true
			count = count + 1
		end
	end
	return mask, count
end

local function build_highlight_chunks(chars, mask, ctx_hl, chg_hl)
	local chunks, cur_hl, cur_txt = {}, nil, {}
	for k, char in ipairs(chars) do
		local hl = mask[k] and chg_hl or ctx_hl
		if hl ~= cur_hl then
			if #cur_txt > 0 then
				table.insert(chunks, { table.concat(cur_txt), cur_hl })
			end
			cur_txt, cur_hl = { char }, hl
		else
			table.insert(cur_txt, char)
		end
	end
	if #cur_txt > 0 then
		table.insert(chunks, { table.concat(cur_txt), cur_hl })
	end
	return chunks
end

local function apply_char_highlights(bufnr, virts_old, old_lines, new_lines, buf_line_idx, buf_lines_new)
	for i = 1, math.min(#old_lines, #new_lines) do
		local s_old, s_new = old_lines[i], buf_lines_new[i] or new_lines[i]
		local c_old, c_new = build_char_array(s_old), build_char_array(s_new)
		local diffs = compute_char_diff(c_old, c_new)

		if diffs then
			local old_mask, chgd_old = build_change_mask(diffs, 1)
			if chgd_old < #c_old then
				virts_old[i] =
					build_highlight_chunks(c_old, old_mask, "InlineDiffDeleteContext", "InlineDiffDeleteChange")
			end

			local new_mask, chgd_new = build_change_mask(diffs, 3)
			if chgd_new < #c_new then
				local map = byte_map_for(s_new)
				for k = 1, #c_new do
					if new_mask[k] then
						local info = map[k]
						api.nvim_buf_set_extmark(bufnr, M.ns, buf_line_idx + i - 1, info.byte, {
							end_col = info.byte + info.char_len,
							hl_group = "InlineDiffAddChange",
							priority = PRIORITY_CHANGE,
						})
					end
				end
			end
		end
	end
end

local function get_padding_text()
	local win_width = vim.api.nvim_win_get_width(0)
	local padding_length = math.min(math.max(win_width, MIN_PADDING_LENGTH), MAX_PADDING_LENGTH)
	return string.rep(" ", padding_length)
end

local function flush_diff_group(bufnr, idx, old, new, padding)
	if #old == 0 and #new == 0 then
		return idx
	end

	local virts = {}
	for i, line in ipairs(old) do
		virts[i] = { { line, "InlineDiffDeleteContext" } }
	end

	for j = 0, #new - 1 do
		api.nvim_buf_set_extmark(bufnr, M.ns, idx + j, 0, {
			end_line = idx + j + 1,
			hl_group = "InlineDiffAddContext",
			hl_eol = true,
			priority = PRIORITY_CONTEXT,
		})
	end

	local buf_lines = #new > 0 and api.nvim_buf_get_lines(bufnr, idx, idx + #new, false) or {}
	apply_char_highlights(bufnr, virts, old, new, idx, buf_lines)

	if #virts > 0 then
		local final = {}
		for _, chunks in ipairs(virts) do
			table.insert(chunks, { padding, "InlineDiffDeleteContext" })
			table.insert(final, chunks)
		end
		api.nvim_buf_set_extmark(bufnr, M.ns, idx, 0, {
			virt_lines = final,
			virt_lines_above = true,
		})
	end

	return idx + #new
end

local function render_hunk(bufnr, hunk)
	local idx, old, new = hunk.new_start - 1, {}, {}
	local padding = get_padding_text()

	for _, l in ipairs(hunk.lines) do
		local prefix, content = l:sub(1, 1), l:sub(2)
		if prefix == DIFF_PREFIX.UNCHANGED then
			idx = flush_diff_group(bufnr, idx, old, new, padding) + 1
			old, new = {}, {}
		elseif prefix == DIFF_PREFIX.DELETED then
			table.insert(old, content)
		elseif prefix == DIFF_PREFIX.ADDED then
			table.insert(new, content)
		end
	end
	flush_diff_group(bufnr, idx, old, new, padding)
end

M.refresh = function(bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	if not M.enabled or not is_buffer_valid(bufnr) then
		return
	end

	run_git_diff(
		bufnr,
		vim.schedule_wrap(function(output)
			if M.last_diff_buf == bufnr and output == M.last_diff_output then
				return
			end

			M.last_diff_output, M.last_diff_buf = output, bufnr
			api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)

			if output then
				for _, h in ipairs(parse_hunks(output)) do
					render_hunk(bufnr, h)
				end
			end
		end)
	)
end

local debounce_timer, augroup = nil, nil

local function clear_cache(bufnr)
	if not bufnr or M.last_diff_buf == bufnr then
		M.last_diff_buf, M.last_diff_output = nil, nil
	end
end

local function stop_timer()
	if debounce_timer then
		pcall(function()
			debounce_timer:stop()
			if not debounce_timer:is_closing() then
				debounce_timer:close()
			end
		end)
		debounce_timer = nil
	end
end

local function start_timer(ms, cb)
	stop_timer()
	if not ms or ms == 0 then
		return
	end
	debounce_timer = vim.loop.new_timer()
	debounce_timer:start(
		ms,
		0,
		vim.schedule_wrap(function()
			stop_timer()
			if cb then
				cb()
			end
		end)
	)
end

local function setup_autocmds()
	if augroup then
		api.nvim_del_augroup_by_id(augroup)
	end
	augroup = api.nvim_create_augroup("InlineDiffAuto", { clear = true })

	api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
		group = augroup,
		callback = function()
			local bufnr = api.nvim_get_current_buf()
			if not is_buffer_valid(bufnr) then
				return
			end

			if not M.enabled or (M.config.debounce_time or 0) == 0 then
				M.refresh(bufnr)
			else
				start_timer(M.config.debounce_time, function()
					if M.enabled then
						M.refresh(bufnr)
					end
				end)
			end
		end,
	})

	api.nvim_create_autocmd({ "BufUnload", "BufDelete" }, {
		group = augroup,
		callback = function(ctx)
			clear_cache(ctx.buf or ctx.bufnr)
		end,
	})
end

function M.toggle()
	M.enabled = not M.enabled
	clear_cache()

	if M.enabled then
		if vim.fn.hlexists("InlineDiffAddContext") == 0 then
			setup_highlights()
		end
		setup_autocmds()
		M.refresh()
	else
		if augroup then
			api.nvim_del_augroup_by_id(augroup)
			augroup = nil
		end
		stop_timer()
		for _, b in ipairs(api.nvim_list_bufs()) do
			if api.nvim_buf_is_loaded(b) then
				pcall(api.nvim_buf_clear_namespace, b, M.ns, 0, -1)
			end
		end
	end
end

M.setup = function(opts)
	M.config = vim.tbl_deep_extend("force", M.default_config, opts or {})
	setup_highlights()

	if not api.nvim_get_commands({})["InlineDiff"] then
		pcall(api.nvim_create_user_command, "InlineDiff", function(cmd)
			local arg = (cmd.args or ""):match("^%s*(%S*)") or ""
			if arg == "" or arg == "toggle" then
				M.toggle()
			elseif arg == "refresh" then
				M.refresh()
			else
				print('InlineDiff: unknown arg "' .. arg .. '". Use "toggle" or "refresh"')
			end
		end, {
			nargs = "?",
			complete = function(lead)
				local res = {}
				for _, v in ipairs({ "toggle", "refresh" }) do
					if v:sub(1, #lead) == lead then
						table.insert(res, v)
					end
				end
				return res
			end,
			desc = "InlineDiff commands: toggle or refresh",
		})
	end
end

return M
