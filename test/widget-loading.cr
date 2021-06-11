require "../src/crysterm"

module Crysterm
  include Tput::Namespace
  include Widgets

  s = Screen.new optimization: OptimizationFlag::SmartCSR

  loading = Loading.new \
    align: AlignFlag::HCenter,
    width: 36,
    height: 18,
    icons: ["Preparing", "Loading", "Processing", "Saving", "Analyzing"],
    content: "Please wait...",
    border: Border.new(type: BorderType::Line),
    style: Style.new(transparent: true, fg: "white", bg: "black", border: Style.new(fg: "white", bg: "black"))

  loading2 = Loading.new \
    align: AlignFlag::Center,
    compact: true,
    interval: 0.2.seconds,
    width: 36,
    height: 3,
    left: 40,
    content: "In progress!...",
    border: Border.new(type: BorderType::Line)

  s.append loading, loading2

  loading.start
  loading2.start

  s.on(Event::KeyPress) do |e|
    e.accept!
    if e.char == 'q' || e.key.try(&.==(::Tput::Key::CtrlQ))
      s.destroy
      exit
    end
  end

  s.display.exec
end
