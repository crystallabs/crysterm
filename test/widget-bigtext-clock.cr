require "../src/crysterm"

module Crysterm
  include Tput::Namespace

  s = Screen.new optimization: OptimizationFlag::SmartCSR

  b = Widget::BigText.new \
    content: time,
    # parse_tags: true,
    resizable: true,
    top: "center",
    left: "center",
    style: Style.new(
      # fg: "white",
      # bg: "gray",
      # char: '\u2592',
      fg: "white",
      alpha: 0.8,
    )

  s.append b
  b.focus
  s.render

  s.on(Event::KeyPress) do |e|
    e.accept
    if e.char == 'q'
      s.destroy
      exit
    end
  end

  spawn do
    loop do
      sleep 1.second
      b.content = time
      s.render
    end
  end

  s.exec

  def self.time
    Time.utc.to_s "%H:%M:%S"
  end
end
