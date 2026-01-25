local wezterm = require("wezterm")
local config = wezterm.config_builder()

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
config.enable_tab_bar = false

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
	{ key = "t", mods = "LEADER", action = wezterm.action.ShowTabNavigator },

	-- Resizing (Leader + Shift + hjkl)
	{ key = "H", mods = "LEADER", action = wezterm.action.AdjustPaneSize({ "Left", 5 }) },
	{ key = "J", mods = "LEADER", action = wezterm.action.AdjustPaneSize({ "Down", 5 }) },
	{ key = "K", mods = "LEADER", action = wezterm.action.AdjustPaneSize({ "Up", 5 }) },
	{ key = "L", mods = "LEADER", action = wezterm.action.AdjustPaneSize({ "Right", 5 }) },

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
