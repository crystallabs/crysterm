require "../src/crysterm"

module Crysterm
  s = Screen.new
  include Widgets

  prompt = Prompt.new(
    screen: s,
    style: Style.new(border: true),
    resizable: true,
    width: "half",
    top: "center",
    left: "center",
    label: " {blue-fg}Prompt{/blue-fg} ",
    parse_tags: true,
    keys: true,
    # vi: true
  )

  question = Question.new(
    screen: s,
    style: Style.new(border: true),
    resizable: true,
    width: "half",
    top: "center",
    left: "center",
    label: " {blue-fg}Question{/blue-fg} ",
    parse_tags: true,
    keys: true,
    # vi: true
  )

  msg = Message.new(
    screen: s,
    style: Style.new(border: true),
    resizable: true,
    width: "half",
    top: "center",
    left: "center",
    label: " {blue-fg}Message{/blue-fg} ",
    parse_tags: true,
    keys: true,
    visible: false,
    # vi: true
  )

  loader = Loading.new(
    screen: s,
    style: Style.new(border: true),
    resizable: true,
    width: "half",
    top: "center",
    left: "center",
    label: " {blue-fg}Loader{/blue-fg} ",
    parse_tags: true,
    keys: true,
    visible: false,
    # vi: true
  )

  s.append prompt
  s.append question
  s.append msg
  s.append loader

  s.on(Event::KeyPress) do |e|
    # STDERR.puts e.inspect
    if e.char == 'q' || e.key.try(&.==(::Tput::Key::CtrlQ))
      e.accept
      s.destroy
      exit
    end
  end

  prompt.read_input("Question?", "") do |err, val|
    STDERR.puts :q1
    question.ask("Question?") do |err, val|
      STDERR.puts :q2
      msg.display("Hello world!", 3.seconds) do          # |err|
        msg.display("Hello world again!", -1.seconds) do # |err|
          loader.load("Loading...")
          spawn do
            sleep 3.seconds
            loader.stop
            s.destroy
          end
        end
      end
    end
  end

  s.exec
end
