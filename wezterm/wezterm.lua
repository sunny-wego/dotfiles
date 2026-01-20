local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- --- Appearance & UI ---
config.color_scheme = "Tokyo Night Day"
config.font = wezterm.font_with_fallback({
	"JetBrainsMonoNL Nerd Font",
	"JetBrains Mono Nerd Font",
	"JetBrains Mono",
})
config.font_size = 14

-- Modern Polish
config.window_padding = { left = 10, right = 10, top = 10, bottom = 10 }
config.window_decorations = "RESIZE" -- Removes title bar, keeps resizing
config.default_cursor_style = "BlinkingBar"
config.enable_tab_bar = false

-- Pane behavior
config.inactive_pane_hsb = {
	saturation = 1.0,
	brightness = 1.0,
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
}

-- --- Status Bar (Right Side) ---
-- Displays Leader active state, Workspace, and Time
wezterm.on("update-right-status", function(window, pane)
	local cells = {}

	-- Leader key indicator (Visual feedback for Ctrl-b)
	if window:leader_active() then
		table.insert(cells, { Background = { Color = "#e0af68" } }) -- Tokyo Night Yellow
		table.insert(cells, { Foreground = { Color = "#3760bf" } })
		table.insert(cells, { Text = " 󱊟 LEADER " })
	end

	-- Workspace Name
	table.insert(cells, { Background = { Color = "#cfd0d7" } })
	table.insert(cells, { Foreground = { Color = "#3760bf" } })
	table.insert(cells, { Text = " 󱂬 " .. window:active_workspace() .. " " })

	-- Time
	table.insert(cells, { Background = { Color = "#b7c1e3" } })
	table.insert(cells, { Foreground = { Color = "#3760bf" } })
	table.insert(cells, { Text = " 󱑎 " .. wezterm.strftime("%H:%M") .. " " })

	window:set_right_status(wezterm.format(cells))
end)

-- --- Cross-Platform & OS Specifics ---
local is_windows = wezterm.target_triple == "x86_64-pc-windows-msvc"
if is_windows then
	config.default_domain = "WSL:Ubuntu-24.04"
	config.font_size = 12
end

config.mouse_bindings = {
	{
		event = { Up = { streak = 1, button = "Left" } },
		mods = is_windows and "CTRL" or "CMD",
		action = wezterm.action.OpenLinkAtMouseCursor,
	},
}

return config
