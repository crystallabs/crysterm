require "../src/crysterm"

module Crysterm
  include Tput::Namespace
  include Widgets

  s = Screen.new(
    optimization: :smart_csr,
    always_propagate: [Tput::Key::CtrlQ], title: "Crysterm Tech Demo"
  )

  box = ScrollableBox.new(
    parent: s,
    name: "box",
    scrollable: true,
    left: "center",
    top: "center",
    width: "80%",
    height: "80%",
    scrollbar: true,
    style: Style.new(
      bg: "green",
      border: true,
    ),
    content: "foobar",
    keys: true,
    vi: true,
    always_scroll: true,
    # scrollbar: {
    #	ch: " ",
    #	inverse: true,
    # },
  )

  text = ScrollableBox.new(
    parent: box,
    name: "text",
    content: "hello1\nhello2\nhello3\nhello4",
    style: Style.new(
      bg: "red",
      padding: 2,
    ),
    left: 2,
    top: 30,
    width: "50%",
    height: 6,
  )

  text2 = ScrollableBox.new(
    parent: box,
    name: "text2",
    content: "world",
    style: Style.new(
      bg: "red",
      padding: 1,
    ),
    left: 2,
    top: 50,
    width: "50%",
    height: 3,
  )

  box2 = ScrollableBox.new(
    parent: box,
    name: "box2",
    scrollable: true,
    content: "foo-one\nfoo-two\nfoo-three",
    left: "center",
    top: 20,
    width: "80%",
    height: 9,
    style: Style.new(
      bg: "magenta",
      # focus: {
      #	bg: "blue",
      # },
      # hover: {
      #	bg: "red",
      # },
      border: true,
      padding: 2,
    ),
    keys: true,
    vi: true,
    always_scroll: true,
  )

  box3 = ScrollableBox.new(
    parent: box2,
    name: "box3",
    scrollable: true,
    left: 3,
    top: 3,
    content: "foo",
    height: 4,
    width: 5,
    style: Style.new(
      bg: "yellow",
      # focus: {
      #	bg: "blue",
      # },
      # hover: {
      #	bg: "red",
      # },
      border: true,
    ),
    keys: true,
    vi: true,
    always_scroll: true,
  )

  box.focus

  s.on(Event::KeyPress) do |e|
    # e.accept
    if e.key == ::Tput::Key::CtrlQ || e.char == 'q'
      s.destroy
      exit
    end
  end

  s.exec
end
