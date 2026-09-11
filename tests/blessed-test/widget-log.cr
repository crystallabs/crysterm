require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

logger = CW::Log.new \
  top: "center",
  left: "center",
  width: "50%",
  height: "50%",
  parse_tags: false,
  keys: false,
  # vi_keys: true,
  # mouse: true,
  max_lines: 100,
  style: CT::Style.new(
    border: true,
    scrollbar: CT::Style.new(
      fill_char: ' ',
      track: CT::Style.new(
        bg: "yellow"
      )
    )
  )

CT::Window.global.append logger
# Seed one line so the still capture / first frame isn't an empty box (the
# timer below only starts logging after 0.5s).
logger.add "Hello world: #{Time.utc}."
# logger.focus

logger.window.on(CT::Event::KeyPress) do |e|
  if e.char == 'q' || e.key == Tput::Key::CtrlQ
    logger.window.destroy
    exit
  end
end

spawn do
  i = 0
  loop do
    sleep 0.5.seconds
    # logger.add "Hello {#0fe1ab-fg}world{/}: {bold}#{Time.utc}{/bold}."
    logger.add "Hello world: #{Time.utc}."
    if rand < 0.3
      logger.add({"foo" => {"bar" => {"baz" => i}}})
    end
    i += 1
  end
end

logger.window.exec
