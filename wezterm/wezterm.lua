-- Pull in the wezterm API
local wezterm = require("wezterm")

-- This will hold the configuration.
local config = wezterm.config_builder()

-- This is where you actually apply your config choices.

-- For example, changing the initial geometry for new windows:
-- config.initial_cols = 120
-- config.initial_rows = 28

-- or, changing the font size and color scheme.
config.font = wezterm.font_with_fallback({
	"JetBrainsMonoNL Nerd Font",
	"JetBrains Mono Nerd Font",
	"JetBrains Mono",
})
config.font_size = 13
config.color_scheme = "Tokyo Night Day"

config.enable_tab_bar = false

-- Force light window frame colors
-- config.window_frame = {
-- 	active_titlebar_bg = "#e1e2e7",
-- 	inactive_titlebar_bg = "#e1e2e7",
-- }

config.inactive_pane_hsb = {
	saturation = 1.0,
	brightness = 1.0,
}

config.leader = { key = "b", mods = "CTRL" }
config.keys = {
	{ key = "\\", mods = "LEADER", action = wezterm.action.SplitHorizontal({ domain = "CurrentPaneDomain" }) },
	{ key = "-", mods = "LEADER", action = wezterm.action.SplitVertical({ domain = "CurrentPaneDomain" }) },
	{ key = "Enter", mods = "SHIFT", action = wezterm.action.SendString("\x1b\r") },

	-- Vim-style pane navigation
	{ key = "h", mods = "LEADER", action = wezterm.action.ActivatePaneDirection("Left") },
	{ key = "j", mods = "LEADER", action = wezterm.action.ActivatePaneDirection("Down") },
	{ key = "k", mods = "LEADER", action = wezterm.action.ActivatePaneDirection("Up") },
	{ key = "l", mods = "LEADER", action = wezterm.action.ActivatePaneDirection("Right") },

	-- Pane selection mode (more flexible than numbered keys)
	{ key = "q", mods = "LEADER", action = wezterm.action.PaneSelect({ alphabet = "1234567890" }) },

	-- Pane zoom toggle (maximize/restore current pane)
	{ key = "z", mods = "LEADER", action = wezterm.action.TogglePaneZoomState },

	-- Show tab navigator
	{ key = "t", mods = "LEADER", action = wezterm.action.ShowTabNavigator },

	-- Vim-style pane resizing (Shift+hjkl)
	{ key = "H", mods = "LEADER", action = wezterm.action.AdjustPaneSize({ "Left", 5 }) },
	{ key = "J", mods = "LEADER", action = wezterm.action.AdjustPaneSize({ "Down", 5 }) },
	{ key = "K", mods = "LEADER", action = wezterm.action.AdjustPaneSize({ "Up", 5 }) },
	{ key = "L", mods = "LEADER", action = wezterm.action.AdjustPaneSize({ "Right", 5 }) },

	-- Enter copy mode (vim-like scrolling)
	{ key = "[", mods = "LEADER", action = wezterm.action.ActivateCopyMode },
}

-- Custom window title showing current directory basename
-- Note: Cannot use run_child_process in format-window-title (synchronous event)
-- Commented out to allow shell integration to control window title with git repository names
-- wezterm.on("format-window-title", function(tab, pane, tabs, panes, config)
-- 	local cwd = pane.current_working_dir
-- 	if not cwd then
-- 		return nil
-- 	end

-- 	-- Extract the file path from the URL object and decode URI-encoded characters
-- 	local path = cwd.file_path or ""
-- 	if path == "" then
-- 		return nil
-- 	end

-- 	-- Decode URI-encoded characters (e.g., %20 for spaces)
-- 	path = path:gsub("%%(%x%x)", function(hex)
-- 		return string.char(tonumber(hex, 16))
-- 	end)

-- 	-- Get basename (last component of path)
-- 	local basename = path:match("([^/]+)/?$") or path

-- 	return basename
-- end)

-- Enable clickable URLs
local is_windows = wezterm.target_triple == "x86_64-pc-windows-msvc"

-- Set default domain to WSL on Windows
if is_windows then
	config.default_domain = "WSL:Ubuntu-24.04"
end

config.mouse_bindings = {
	{
		event = { Up = { streak = 1, button = "Left" } },
		mods = is_windows and "CTRL" or "CMD",
		action = wezterm.action.OpenLinkAtMouseCursor,
	},
}

-- Finally, return the configuration to wezterm:
return config
