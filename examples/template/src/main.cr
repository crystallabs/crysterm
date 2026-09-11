require "crysterm"

# The two conventional short aliases — nothing is `include`d into your
# namespace. Pick any names you like; CT/CW is the convention used in
# Crysterm's docs and examples.
alias CT = Crysterm
alias CW = CT::Widgets

window = CT::Window.new title: "myapp"

# `center: true` = `top: :center, left: :center`.
card = CW::Box.new parent: window, center: true, width: 40, height: 9,
  style: CT::Style.new(border: true)

# `tagged:` is `content:` with the {tags} parsed.
CW::Label.new parent: card, top: 1, left: 0, width: "100%", height: 1,
  tagged: "{center}Welcome to {bold}myapp{/bold}!{/center}"

button = CW::Button.new parent: card, top: 3, left: :center, width: 16, height: 3,
  content: "Click me"

clicks = 0
button.on_clicked do
  clicks += 1
  button.text = "Clicked #{clicks}x"
end

# `q` / Ctrl-Q quit by default; add your own keys like this:
window.on(CT::Event::KeyPress) do |e|
  window.quit if e.char == 'Q'
end

# Run the main loop.
window.exec
