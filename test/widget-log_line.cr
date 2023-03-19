require "../src/crysterm"

module Crysterm
  logger = Widget::LogLine.new \
    top: "center",
    left: "center",
    width: "50%",
    height: "50%",
    parse_tags: true,
    keys: true,
    # vi: true,
    # mouse: true,
    scrollback: 100,
    style: Style.new(
      border: true,
      scrollbar: Style.new(
        char: ' ',
        track: Style.new(
          bg: "yellow"
        )
      )
    )

  logger.focus

  Screen.global.on(Event::KeyPress) do |e|
    if e.char == 'q'
      Screen.global.destroy
      exit
    end
  end

  loop do
    sleep 0.5
    logger.add "Hello {#0fe1ab-fg}world{/}: {bold}#{Time.utc}{/bold}."
    if rand < 0.3
      logger.add({"foo" => {"bar" => {"baz" => true}}})
    end
    Screen.global.render
  end
end
