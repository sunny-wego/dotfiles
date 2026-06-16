local wezterm = require("wezterm")
local config = wezterm.config_builder()
local act = wezterm.action

-- Format a CWD path: replace home with ~, strip trailing slash, detect worktree name.
-- Returns (formatted_path, worktree_name) — either may be nil.
local function format_cwd(cwd)
	if not cwd then
		return nil, nil
	end

	local home = wezterm.home_dir
	if home and cwd:sub(1, #home) == home then
		cwd = "~" .. cwd:sub(#home + 1)
	end

	if #cwd > 1 and cwd:sub(-1) == "/" then
		cwd = cwd:sub(1, -2)
	end

	local worktree = cwd:match("/worktrees/[^/]+/([^/]+)$") or cwd:match("/worktrees/([^/]+)$")

	return cwd, worktree
end

local function get_git_branch(cwd)
	if not cwd then
		return nil
	end
	local success, stdout = wezterm.run_child_process({ "git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD" })
	if success and stdout then
		return stdout:gsub("%s+$", "")
	end
	return nil
end

local function equal_cell_sizes(total, count)
	local base = math.floor(total / count)
	local remainder = total - (base * count)
	local sizes = {}
	for i = 1, count do
		sizes[i] = base
		if i <= remainder then
			sizes[i] = sizes[i] + 1
		end
	end
	return sizes
end

local function panes_by_index(panes_info)
	local map = {}
	for _, info in ipairs(panes_info) do
		map[info.index] = info
	end
	return map
end

local function adjust_boundary(window, pane, pane_index, direction, cells)
	if cells <= 0 then
		return
	end
	window:perform_action(act.ActivatePaneByIndex(pane_index), pane)
	window:perform_action(act.AdjustPaneSize({ direction, cells }), pane)
end

local function rebalance_groups(window, pane, tab, axis)
	local panes_info = tab:panes_with_info()
	local groups = {}

	for _, info in ipairs(panes_info) do
		local key
		if axis == "width" then
			key = tostring(info.top) .. ":" .. tostring(info.height)
		else
			key = tostring(info.left) .. ":" .. tostring(info.width)
		end
		groups[key] = groups[key] or {}
		table.insert(groups[key], info)
	end

	for _, group in pairs(groups) do
		if #group > 1 then
			if axis == "width" then
				table.sort(group, function(a, b)
					return a.left < b.left
				end)
			else
				table.sort(group, function(a, b)
					return a.top < b.top
				end)
			end

			local total_size = 0
			for _, info in ipairs(group) do
				total_size = total_size + (axis == "width" and info.width or info.height)
			end
			local targets = equal_cell_sizes(total_size, #group)

			for i = 1, #group - 1 do
				local info_map = panes_by_index(tab:panes_with_info())
				local current = info_map[group[i].index]
				local next_info = info_map[group[i + 1].index]

				if current and next_info then
					local current_size = axis == "width" and current.width or current.height
					local delta = targets[i] - current_size

					if delta > 0 then
						local direction = axis == "width" and "Right" or "Down"
						adjust_boundary(window, pane, next_info.index, direction, delta)
					elseif delta < 0 then
						local direction = axis == "width" and "Left" or "Up"
						adjust_boundary(window, pane, next_info.index, direction, -delta)
					end
				end
			end
		end
	end
end

local function rebalance_tab_panes(window, pane)
	local tab = pane:tab()
	if not tab then
		return
	end

	local panes_info = tab:panes_with_info()
	if #panes_info < 2 then
		return
	end

	local active_index = nil
	local is_zoomed = false
	for _, info in ipairs(panes_info) do
		if info.is_active then
			active_index = info.index
		end
		if info.is_zoomed then
			is_zoomed = true
		end
	end

	if is_zoomed then
		window:perform_action(act.TogglePaneZoomState, pane)
	end

	rebalance_groups(window, pane, tab, "width")
	rebalance_groups(window, pane, tab, "height")
	rebalance_groups(window, pane, tab, "width")

	if active_index ~= nil then
		window:perform_action(act.ActivatePaneByIndex(active_index), pane)
	end
end

-- --- Appearance & UI ---
config.color_scheme = "Tokyo Night Day"
config.font = wezterm.font_with_fallback({
	"JetBrainsMono NFM",
	"JetBrainsMono Nerd Font Mono",
	"JetBrainsMono Nerd Font",
	"JetBrains Mono Nerd Font",
})
config.font_size = 14

-- Modern Polish
config.window_padding = { left = 20, right = 20, top = 20, bottom = 20 }
config.default_cursor_style = "BlinkingBar"
config.cursor_blink_ease_in = "EaseIn"
config.cursor_blink_ease_out = "EaseOut"
config.enable_tab_bar = true
config.tab_bar_at_bottom = false
config.use_fancy_tab_bar = true
config.show_new_tab_button_in_tab_bar = false
config.window_frame = {
	font = wezterm.font({ family = "JetBrainsMono NFM", weight = "Bold" }),
	font_size = 11.0,
	active_titlebar_bg = "#e1e2e7",
	inactive_titlebar_bg = "#e1e2e7",
}
config.colors = {
	tab_bar = {
		active_tab = {
			bg_color = "#c8c9ce",
			fg_color = "#3760bf",
		},
		inactive_tab = {
			bg_color = "#e1e2e7",
			fg_color = "#8990b3",
		},
		inactive_tab_hover = {
			bg_color = "#d5d6db",
			fg_color = "#3760bf",
		},
		new_tab = {
			bg_color = "#e1e2e7",
			fg_color = "#8990b3",
		},
		new_tab_hover = {
			bg_color = "#d5d6db",
			fg_color = "#3760bf",
		},
	},
}

-- Pane behavior
config.inactive_pane_hsb = {
	saturation = 0.95,
	brightness = 0.9,
}

-- --- Leader Key & Mappings ---
config.leader = { key = "b", mods = "CTRL" }
config.keys = {
	-- Split Panes
	{ key = "\\", mods = "LEADER", action = wezterm.action.SplitHorizontal({ domain = "CurrentPaneDomain" }) },
	{ key = "-", mods = "LEADER", action = wezterm.action.SplitVertical({ domain = "CurrentPaneDomain" }) },
	{ key = "Enter", mods = "SHIFT", action = wezterm.action.SendString("\x1b\r") },

	-- Navigation (Vim-style)
	{ key = "h", mods = "LEADER", action = wezterm.action.ActivatePaneDirection("Left") },
	{ key = "j", mods = "LEADER", action = wezterm.action.ActivatePaneDirection("Down") },
	{ key = "k", mods = "LEADER", action = wezterm.action.ActivatePaneDirection("Up") },
	{ key = "l", mods = "LEADER", action = wezterm.action.ActivatePaneDirection("Right") },

	-- Management
	{ key = "q", mods = "LEADER", action = wezterm.action.PaneSelect({ alphabet = "1234567890" }) },
	{ key = "z", mods = "LEADER", action = wezterm.action.TogglePaneZoomState },
	-- Workspace Switcher
	{
		key = "t",
		mods = "LEADER",
		action = wezterm.action_callback(function(window, pane)
			local current_workspace = window:active_workspace()
			local current_tab_id = pane:tab():tab_id()

			local choices = {}
			local tab_map = {}

			for _, mux_win in ipairs(wezterm.mux.all_windows()) do
				local ws = mux_win:get_workspace()
				for tab_index, mux_tab in ipairs(mux_win:tabs()) do
					local active_pane = mux_tab:active_pane()
					local uri = active_pane and active_pane:get_current_working_dir()
					local cwd = uri and uri.file_path or nil

					local path, worktree = format_cwd(cwd)
					local context = worktree or get_git_branch(cwd)
					local label = path or ws
					if context then
						label = "[" .. context .. "] " .. label
					end

					local pane_count = #mux_tab:panes()
					if pane_count > 1 then
						label = label .. " (" .. pane_count .. " panes)"
					end

					if mux_tab:tab_id() == current_tab_id then
						label = label .. " *"
					end

					local key = tostring(mux_tab:tab_id())
					tab_map[key] = { workspace = ws, tab_index = tab_index - 1 }
					table.insert(choices, { label = label, id = key })
				end
			end

			window:perform_action(
				wezterm.action.InputSelector({
					title = "Switch Tab",
					choices = choices,
					fuzzy = true,
					action = wezterm.action_callback(function(inner_window, inner_pane, id, label)
						if not id then
							return
						end

						local entry = tab_map[id]
						if not entry then
							return
						end

						local actions = {}
						if entry.workspace ~= inner_window:active_workspace() then
							table.insert(actions, wezterm.action.SwitchToWorkspace({ name = entry.workspace }))
						end
						table.insert(actions, wezterm.action.ActivateTab(entry.tab_index))

						inner_window:perform_action(wezterm.action.Multiple(actions), inner_pane)
					end),
				}),
				pane
			)
		end),
	},

	-- Resizing (Leader + Shift + hjkl)
	{ key = "H", mods = "LEADER", action = wezterm.action.AdjustPaneSize({ "Left", 5 }) },
	{ key = "J", mods = "LEADER", action = wezterm.action.AdjustPaneSize({ "Down", 5 }) },
	{ key = "K", mods = "LEADER", action = wezterm.action.AdjustPaneSize({ "Up", 5 }) },
	{ key = "L", mods = "LEADER", action = wezterm.action.AdjustPaneSize({ "Right", 5 }) },
	{ key = "=", mods = "LEADER", action = wezterm.action_callback(rebalance_tab_panes) },

	-- Copy Mode
	{ key = "[", mods = "LEADER", action = wezterm.action.ActivateCopyMode },

	-- Quick Select (Hints)
	{ key = "s", mods = "LEADER", action = wezterm.action.QuickSelect },

	-- Project Launcher
	{
		key = "p",
		mods = "LEADER",
		action = wezterm.action_callback(function(window, pane)
			local projects = {}
			local home = wezterm.home_dir
			local project_dir = home .. "/projects"

			-- Simple list of projects (can be expanded with a proper glob)
			local success, stdout, stderr = wezterm.run_child_process({ "ls", project_dir })
			if success then
				for line in stdout:gmatch("([^\n]+)") do
					table.insert(projects, { label = line, id = project_dir .. "/" .. line })
				end
			end

			window:perform_action(
				wezterm.action.InputSelector({
					title = "Projects",
					choices = projects,
					action = wezterm.action_callback(function(inner_window, inner_pane, id, label)
						if id then
							inner_window:perform_action(
								wezterm.action.SwitchToWorkspace({
									name = label,
									spawn = { cwd = id },
								}),
								inner_pane
							)
						end
					end),
				}),
				pane
			)
		end),
	},
}

-- --- Hyperlinks ---
config.hyperlink_rules = wezterm.default_hyperlink_rules()
-- GitHub repo clickable: user/repo
table.insert(config.hyperlink_rules, {
	regex = [[["]?([\w\d]{1}[-\w\d]+)(/){1}([-\w\d\.]+)["]?]],
	format = "https://www.github.com/$1/$3",
})

-- --- Cross-Platform & OS Specifics ---
local is_windows = wezterm.target_triple == "x86_64-pc-windows-msvc"
if is_windows then
	config.default_domain = "WSL:Ubuntu-24.04"
	config.font_size = 12
	config.cell_width = 0.95
	config.front_end = "WebGpu"
else
	config.window_decorations = "RESIZE"
end

config.mouse_bindings = {
	{
		event = { Up = { streak = 1, button = "Left" } },
		mods = is_windows and "CTRL" or "CMD",
		action = wezterm.action.OpenLinkAtMouseCursor,
	},
}

return config
