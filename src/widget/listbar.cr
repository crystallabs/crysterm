require "./box"
require "../mixin/action_bar"

module Crysterm
  class Widget
    # Horizontal bar of selectable commands/tabs, a.k.a. a "listbar".
    #
    # Port of Blessed's `listbar` element. Each command is rendered as a small
    # `Box` laid out left-to-right; one is "selected" at a time. Commands can be
    # navigated with the arrow keys (or vi `h`/`l`), triggered with Enter, the
    # mouse, per-command hotkeys (`Command#keys`), or — when
    # `auto_command_keys` is on — the number keys `1`..`9`/`0`.
    #
    # Qt has no `QListBar`; the shared command model lives in `Mixin::ActionBar`
    # (which `MenuBar`/`ToolBar` also include). `ListBar` stays a usable concrete
    # widget — a `Box` that includes the mixin, a peer of `MenuBar`/`ToolBar`.
    #
    # ```
    # bar = Widget::ListBar.new keys: true, mouse: true, auto_command_keys: true
    # bar.add "open", -> { open_file }
    # bar.add "quit", -> { exit }, keys: ["q"]
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![ListBar screenshot](../../tests/widget/listbar/listbar.5s.apng)
    # <!-- /widget-examples:capture -->
    class ListBar < Box
      include Mixin::ActionBar

      def initialize(
        commands = nil,
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
