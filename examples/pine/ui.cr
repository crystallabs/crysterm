# The reusable TUI of the Pine/Alpine-style client: the frame, the shared and
# transient chrome, the full-screen views and the helpers that switch between
# them. Nothing here knows about mail, flags or the screen flows; those live in
# pine.cr. Relies on the aliases and includes declared there (`CT`, `CW`,
# `Tput::Namespace`, `Widget::Pine::DSL`).
#
# The chrome is arranged by *layout* engines, not by fixed top/left/width/height:
# one `Border` frame docks the header on top and a `VBox` footer (status line +
# the two-row command bar) at the bottom, and hands what is left — the body
# rectangle — to every full-screen view. Only the two things that deliberately
# *float* over the body, the MAIN MENU panel and the demo banner, carry
# coordinates.
class PineUI
  getter window : CT::Window

  # Shared chrome.
  getter header : CW::PineHeaderBar
  getter status : CW::PineStatusBar
  getter confirm : KeyPrompt
  getter progress : CW::PineProgressBar
  getter key_menu : KeyMenu
  getter banner : CW::Box

  # The full-screen views.
  getter main_menu : MainMenu
  getter index : MessageIndex
  getter view : CW::PineMessageView
  getter compose : CW::PineCompose
  getter help : TextView
  getter setup : Setup
  getter config : OptionList
  getter folders : FolderList
  getter addrbook : AddressBook
  getter sortpick : ListSelect(String)
  getter flagpick : ListSelect(String)
  getter filebrowser : FileBrowser
  getter all_views : Array(CT::Widget)

  # The full-screen view currently shown.
  getter active_view : CT::Widget

  # Whether the status-line yes/no prompt currently owns the keyboard.
  getter? prompt_active = false

  def initialize(
    @window,
    *,
    menu_options : Array(MainMenu::Option),
    messages : Array(MessageIndex::Message),
    help_text : String,
    setup_options : Array(Setup::Option),
    config_options : Array(OptionList::Option),
    folders : Array(FolderList::Folder),
    contacts : Array(AddressBook::Contact),
    sort_orders : Array(String),
    flag_names : Array(String),
  )
    # A single `Border` layout carves the terminal into Alpine's regions: the
    # header on top, a three-row footer at the bottom, and the body — every
    # full-screen view — in the center. `Window` is not a `Widget`, so the frame
    # is a full-screen `Box` on the window that everything else hangs off.
    #
    # It doubles as the backdrop. Created first, it sits behind every other
    # widget, and it paints the cells its regions leave over (e.g. around the
    # centered MAIN MENU). Without it those cells are left to the window's erase
    # path; on a transparent terminal profile they render slightly differently,
    # making the menu look like a distinct rectangle rather than part of the
    # screen.
    frame = CW::Box.new parent: @window, width: "100%", height: "100%",
      layout: CT::Layout::Dock.new

    # ----------------------------------------------------------- shared chrome

    @header = CW::PineHeaderBar.new(
      parent: frame,
      layout_hint: :top,
      title_content: "ALPINE 2.26",
      section_content: "MAIN MENU",
      info_content: "Folder: INBOX",
    )

    # The footer is the one edge where several bars stack, so the `Border`'s
    # bottom region is itself a `VBox`: the status line above the two-row
    # command bar. Only the footer declares a height (the extent it takes off
    # the bottom edge); everything inside it, and the body above it, follows
    # from that.
    footer = CW::Box.new parent: frame, height: 3, layout: CT::Layout::VBox.new,
      layout_hint: :bottom

    @status = CW::PineStatusBar.new(parent: footer, status_content: "")

    # -------------------------------------------------------- transient chrome
    #
    # A yes/no prompt and a percent-done bar, which take over the status line
    # while active — just as Alpine asks and reports on its message line. They
    # are *siblings* of the status line in the footer rather than boxes floating
    # over it, so the row belongs to whichever of the three is standing: a
    # hidden child releases its slot back to the `VBox`, so showing one and
    # hiding the other two hands the row to the winner. Declared here, ahead of
    # the command bar, because a `VBox` stacks children in the order they were
    # added.

    @confirm = KeyPrompt.new(parent: footer, width: "100%", height: 1, visible: false)
    @progress = CW::PineProgressBar.new(parent: footer, width: "100%", height: 1, visible: false, value: 0)

    @key_menu = KeyMenu.new(parent: footer)

    # A yellow "this is only a demo" banner, shown on MAIN MENU only. It is not
    # a region: it floats over the body's third row, the way the MAIN MENU
    # itself floats over the body. Docking it under the header would push the
    # body down a row on every *other* screen too, where it is never shown — so
    # it keeps its coordinate, on the window's default `Layout::Manual`.
    @banner = CW::Box.new(
      parent: @window, top: 3, left: 0, width: "100%", height: 1,
      align: :hcenter, parse_tags: true, visible: false,
      content: "{#ffff00-fg}** VISUAL DEMO - ALL CONTENT IS IN MEMORY - THERE IS NO DISK OR EMAIL ACCESS **{/#ffff00-fg}",
    )

    # Make the bottom command bar clickable: a click on a hint replays the
    # hint's key as the matching keypress (`KeyPress.parse` understands the same
    # labels the bar displays), so it flows through the same handlers as the
    # physical key.
    @key_menu.on(CT::Event::Activated) do |e|
      CT::Event::KeyPress.parse(e.value.to_s).try { |kp| @window.emit kp }
    end

    # --------------------------------------------------------------- the views
    #
    # Every list/text view is a `Border` *center* child. The five-region carve
    # leaves exactly one rectangle — whatever the header and footer did not
    # take — and the engine hands it to each of them; `show_only` (below)
    # decides which one paints, since only one screen is ever up. That is their
    # entire geometry: not one names a row, a column or a size, and none has to
    # reserve room for the chrome around it.

    body_opts = {parent: frame, layout_hint: :center}

    # MAIN MENU is the deliberate exception. Alpine centers it in the
    # *terminal*, floating over the body rather than filling it — and "centered
    # on something other than my own slot" is not something a layout region can
    # say (centering it in the body region would sit it a row off). So, like a
    # modal panel, it stays a free-floating child of the window on the default
    # `Layout::Manual`.
    @main_menu = MainMenu.new(
      parent: @window, top: "center", left: "center", width: 66, height: 13,
      options: menu_options)

    @index = MessageIndex.new(**body_opts, messages: messages, visible: false)
    @view = CW::PineMessageView.new(**body_opts, visible: false)
    @compose = CW::PineCompose.new(**body_opts, visible: false)
    @help = TextView.new(**body_opts, visible: false, content: help_text)
    @setup = Setup.new(**body_opts, visible: false, options: setup_options)
    @config = OptionList.new(**body_opts, visible: false, options: config_options)
    @folders = FolderList.new(**body_opts, visible: false, folders: folders)
    @addrbook = AddressBook.new(**body_opts, visible: false, contacts: contacts)

    @sortpick = ListSelect(String).new(**body_opts, visible: false,
      items: sort_orders, label: ->(o : String) { o }, multi: false)

    @flagpick = ListSelect(String).new(**body_opts, visible: false,
      items: flag_names, label: ->(f : String) { f }, multi: true)

    @filebrowser = FileBrowser.new(**body_opts, visible: false, cwd: Dir.current)

    @all_views = [@main_menu, @index, @view, @compose, @help, @setup, @config,
                  @folders, @addrbook, @sortpick, @flagpick, @filebrowser] of CT::Widget
    @active_view = @main_menu
  end

  # Hand the shared status row to exactly one of its three occupants.
  def status_line(w : CT::Widget) : Nil
    {@status, @confirm, @progress}.each { |x| x == w ? x.show : x.hide }
  end

  def show_status(text : String) : Nil
    @status.status.content = text
  end

  def set_keys(entries : Array(KeyMenu::Entry)) : Nil
    @key_menu.entries = entries
  end

  # Show one full-screen view, hide the others and the banner, focus it.
  def show_only(w : CT::Widget) : Nil
    status_line @status
    @banner.hide
    @all_views.each { |v| v == w ? v.show : v.hide }
    @active_view = w
    w.focus
  end

  # Refocus whatever full-screen view is current (after a transient prompt is
  # dismissed).
  def refocus : Nil
    @active_view.focus
  end

  # Dismiss the status-line yes/no prompt and hand focus back to the view.
  def dismiss_prompt : Nil
    @prompt_active = false
    status_line @status
    refocus
  end

  # Pop up a Pine-style yes/no prompt on the status line; the block runs if the
  # user presses Y. N or Escape just dismisses it.
  def ask_yes_no(question : String, &on_yes : ->) : Nil
    @confirm.question = question
    @confirm.choices = [
      KeyPrompt::Choice.new("Y", "Yes") { dismiss_prompt; on_yes.call; nil },
      KeyPrompt::Choice.new("N", "No") { dismiss_prompt; nil },
    ]
    status_line @confirm
    @confirm.focus
    @prompt_active = true
  end

  # Show the percent-done bar and animate it to 100% (mocking a background
  # task): a timer steps the bar without ever blocking the event loop.
  def run_progress(label : String) : Nil
    @header.info.content = label
    @progress.value = 0
    status_line @progress
    @window.every(35.milliseconds) do |timer|
      @progress.value += 10
      if @progress.value >= 100
        timer.stop
        status_line @status
      end
    end
  end
end
