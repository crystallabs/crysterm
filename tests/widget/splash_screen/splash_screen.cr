# Example: Crysterm::Widget::SplashScreen
#
# Minimal, self-contained example of a single SplashScreen.
# Run it:     crystal run examples/widget/splash_screen/splash_screen.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "SplashScreen" do |screen|
  screen.stylesheet = "SplashScreen { border: solid; background-color: #11121a; color: #c0caf5; }"
  # `content` is the central widget here, not a string.
  splash = Crysterm::Widget::SplashScreen.new parent: screen, width: 50, height: 15, message_height: 1,
    content: Crysterm::Widget::Box.new(
      top: "center", left: "center", width: 44, height: 8, parse_tags: true,
      content: "{center}{bold}C R Y S T E R M{/bold}\n\nTerminal UI toolkit for Crystal\n\nv1.0.0  •  90+ widgets  •  layouts  •  effects{/center}")
  splash.show_message "Loading modules…"
end
