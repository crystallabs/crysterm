require "./box"
require "../mixin/action_bar"

module Crysterm
  class Widget
    # Horizontal bar of selectable commands/tabs (Blessed called this a
    # "listbar"; it is a command strip, not an item view).
    #
    # Each command is rendered as a small `Box` laid out left-to-right; one is
    # "selected" at a time. Commands can be navigated with the arrow keys (or vi
    # `h`/`l`), triggered with Enter, the mouse, per-command hotkeys
    # (`Command#shortcuts`), or — when `auto_command_keys` is on — the number keys
    # `1`..`9`/`0`.
    #
    # Qt has no `QCommandBar`; the shared command model lives in `Mixin::ActionBar`.
    #
    # ```
    # bar = Widget::CommandBar.new keys: true, mouse: true, auto_command_keys: true
    # bar.add_item("open") { open_file }
    # bar.add_item("quit", shortcuts: ["q"]) { exit }
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![CommandBar screenshot](../../tests/widget/command_bar/command_bar.5s.apng)
    # <!-- /widget-examples:capture -->
    class CommandBar < Box
      include Mixin::ActionBar

      def initialize(
        commands : Array(Mixin::ActionBar::Command) | Array(String)? = nil,
        *,
        @mouse = false,
        @auto_command_keys = false,
        **widget,
      )
        super **widget

        setup_action_bar

        commands.try { |c| self.items = c }
      end
    end
  end
end
