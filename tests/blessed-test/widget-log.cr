require "../../src/crysterm"

module Crysterm
  logger = Widget::Log.new \
    top: "center",
    left: "center",
    width: "50%",
    height: "50%",
    parse_tags: false,
    keys: false,
    # vi: true,
    # mouse: true,
    scrollback: 100,
    style: Style.new(
      border: true,
      scrollbar: Style.new(
        fill_char: ' ',
        track: Style.new(
          bg: "yellow"
        )
      )
    )

  Screen.global.append logger
  # Seed one line so the still capture / first frame isn't an empty box (the
  # timer below only starts logging after 0.5s).
  logger.add "Hello world: #{Time.utc}."
  # logger.focus

  logger.screen.on(Event::KeyPress) do |e|
    if e.char == 'q' || e.key == Tput::Key::CtrlQ
      logger.screen.destroy
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

  logger.screen.exec
end
