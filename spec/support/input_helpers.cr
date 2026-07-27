# Shared input-event builders/dispatchers, hoisted out of the spec files that
# each restated the same two event-literal shapes --
# `Crysterm::Event::KeyPress.new(char, key)` and
# `::Tput::Mouse::Event.new(action, button, x, y, source: :test)` -- plus,
# verbatim across six files (drag_spec.cr, bugs8_text_editing_spec.cr,
# text_editing_keys_spec.cr, text_selection_mouse_spec.cr,
# textedit_selection_spec.cr, widget_qt_render_spec.cr), the mouse
# down/move/up dispatch trio built on top of it.
#
# NOT here, by design: a shared `press`. `press` is not one thing across the
# suite -- mouse-down in the drag/text-editing specs, `#on_keypress` dispatch
# in the ActionBar specs (bugs18_action_bar_spec.cr,
# bugsf2_actionbar_pine_spec.cr), `#emit` in bugs6_mixin_util_spec.cr,
# `#_listener` in bugs5_text_editing_spec.cr. Each of those stays a local,
# file-specific def (re-expressed in terms of `kp`/`mouse_down` where that
# helps).

# A keystroke as it really arrives: `char` set for printables, `key` set for
# control sequences (matching how the input layer builds `Event::KeyPress`).
def kp(char : Char = '\0', key : ::Tput::Key? = nil)
  Crysterm::Event::KeyPress.new char, key
end

# A synthesized mouse event, always tagged `source: :test` (matching how the
# suite's headless dispatch tests distinguish synthetic from real input).
def mouse_ev(action, x, y, button = ::Tput::Mouse::Button::Left)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

# Button-down at (x, y), dispatched straight through `Window#dispatch_mouse`.
def mouse_down(s, x, y)
  s.dispatch_mouse mouse_ev(::Tput::Mouse::Action::Down, x, y)
end

# Pointer motion at (x, y). *button* defaults to `None` (a plain hover/move,
# as tracked by the drag-and-drop sensor); pass `Button::Left` for a
# drag-to-select motion with the button still held.
def mouse_move(s, x, y, button = ::Tput::Mouse::Button::None)
  s.dispatch_mouse mouse_ev(::Tput::Mouse::Action::Move, x, y, button)
end

# Button-up at (x, y).
def mouse_up(s, x, y)
  s.dispatch_mouse mouse_ev(::Tput::Mouse::Action::Up, x, y, ::Tput::Mouse::Button::None)
end

# A full click: down then up at the same point.
def click(s, x, y)
  mouse_down(s, x, y)
  mouse_up(s, x, y)
end
