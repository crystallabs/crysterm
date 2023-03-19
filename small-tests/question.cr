require "../src/crysterm"

module Crysterm
  include Tput::Namespace

  s = Screen.new
  q = Widget::Question.new \
    content: "{bold}HOT{/bold} or {underline}NOT{/underline}?",
    # visible: true,
    parse_tags: true,
    top: "20%",
    left: "20%",
    width: 30,
    height: 8,
    style: Style.new(
      fg: "yellow",
      bg: "magenta",
      border: Style.new(
        fg: "#ffffff"
      ),
      shadow: true,
    )

  s.append q
  # q.focus
  # s.render

  loop do
    q.ask { |a, b| STDERR.puts "Answered #{a}/#{b}" }
    exit
  end

  s.on(Event::KeyPress) do |e|
    e.accept!
    STDERR.puts e.inspect
    if e.char == 'q' || e.key.try(&.==(::Tput::Key::CtrlQ))
      exit
    end
  end

  sleep
end
