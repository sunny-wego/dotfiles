return {
  -- Temporarily disabled
  -- {
  --   "greggh/claude-code.nvim",
  --   config = function()
  --     require("claude-code").setup({
  --       window = {
  --         split_ratio = 0.5,
  --         position = "vertical",
  --       },
  --     })
  --     vim.keymap.set('n', '<leader>cc', '<cmd>ClaudeCode<CR>', { desc = 'Toggle Claude Code' })
  --   end,
  -- },
  {
    "coder/claudecode.nvim",
    config = function()
      require("claudecode").setup({
        -- Server Configuration
        port_range = { min = 10000, max = 65535 },
        auto_start = true,
        log_level = "info", -- "trace", "debug", "info", "warn", "error"
        terminal_cmd = nil, -- Custom terminal command (default: "claude")
        -- For local installations: "~/.claude/local/claude"
        -- For native binary: use output from 'which claude'

        -- Selection Tracking
        track_selection = true,
        visual_demotion_delay_ms = 50,

        -- Terminal Configuration
        terminal = {
          split_side = "right", -- "left" or "right"
          split_width_percentage = 0.50,
          provider = "auto", -- "auto", "snacks", "native", or custom provider table
          auto_close = true,
          snacks_win_opts = {}, -- Opts to pass to `Snacks.terminal.open()` - see Floating Window section below
        },

        -- Diff Integration
        diff_opts = {
          auto_close_on_accept = true,
          vertical_split = true,
          open_in_current_tab = true,
          keep_terminal_focus = false, -- If true, moves focus back to terminal after diff opens
        },
      })
      vim.keymap.set("n", "<leader>cc", "<cmd>ClaudeCode<CR>", { desc = "Toggle Claude Code" })
    end,
  },
}
