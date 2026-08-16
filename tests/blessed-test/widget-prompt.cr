require "../../src/crysterm"

include Crysterm
include Crysterm::Widgets

s = Window.new

prompt = InputDialog.new(
  style: Style.new(border: true),
  shrink_to_fit: true,
  width: "50%",
  top: "center",
  left: "center",
  label: " {blue-fg}InputDialog{/blue-fg} ",
  parse_tags: true,
  keys: true,
  # vi_keys: true
)

question = MessageBox.new(
  style: Style.new(border: true),
  shrink_to_fit: true,
  width: "50%",
  top: "center",
  left: "center",
  label: " {blue-fg}Question{/blue-fg} ",
  parse_tags: true,
  keys: true,
  # vi_keys: true
)

msg = MessageBox.new(
  style: Style.new(border: true),
  shrink_to_fit: true,
  width: "50%",
  top: "center",
  left: "center",
  label: " {blue-fg}MessageBox{/blue-fg} ",
  parse_tags: true,
  keys: true,
  visible: false,
  # vi_keys: true
)

loader = Loading.new(
  style: Style.new(border: true),
  shrink_to_fit: true,
  width: "50%",
  top: "center",
  left: "center",
  label: " {blue-fg}Loader{/blue-fg} ",
  parse_tags: true,
  keys: true,
  visible: false,
  # vi_keys: true
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

prompt.open("Question?", "") do |_|
  STDERR.puts :q1
  question.open("Question?") do |_|
    STDERR.puts :q2
    msg.open("Hello world!", 3.seconds) do          # |err|
      msg.open("Hello world again!", -1.seconds) do # |err|
        loader.start("Loading...")
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
