require "../src/crysterm"

module Crysterm
  include Tput::Namespace

  # p = Application.new
  # s = Screen.new p
  s = Screen.new optimization: OptimizationFlag::SmartCSR

  b = BigText.new \
    parent: s,
    content: "Hello",
    #parse_tags: true,
    resizable: true,
    width: "80%",
    height: "resizable",
    border: BorderType::Line,

    #shadow: true,
    style: Style.new(
      fg: "red",
      bg: "blue",
      bold: false,
      #fchar: ' ',
      char: '\u2592',
    )

  b.focus
  s.render

  s.on(KeyPressEvent) do |e|
    e.accept!
    if e.char == 'q'
      s.destroy
      exit
    end
  end

  sleep
end
