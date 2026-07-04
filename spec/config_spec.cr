require "./spec_helper"

# `Crysterm::Config` is a transparent alias of the shared `Superconf` registry.
# Registry mechanics are covered by superconf's own spec; these verify the
# integration: Crysterm's options, tput's options, and the alias all work
# through one combined registry.
describe "Crysterm config integration" do
  it "registers Crysterm's builtin options with typed accessors (via the alias)" do
    Crysterm::Config.window_resize_interval.should eq 0.2.seconds
    Crysterm::Config.cursor_glyph.should eq '▮'
    Crysterm::Config.render_csr_threshold.should eq 40
  end

  it "includes tput's options in the same registry (the unified list)" do
    Crysterm::Config["tput.read_timeout"]?.should_not be_nil
    Crysterm::Config["tput.use_buffer"]?.should_not be_nil
    Crysterm::Config["window.resize_interval"]?.should_not be_nil
  end

  it "brands env vars with CRYSTERM_ for both crysterm and tput options" do
    Superconf.env_name(Crysterm::Config["window.resize_interval"]).should eq "CRYSTERM_WINDOW_RESIZE_INTERVAL"
    Superconf.env_name(Crysterm::Config["tput.read_timeout"]).should eq "CRYSTERM_TPUT_READ_TIMEOUT"
  end

  it "uses crysterm as the default config app name" do
    saved = ENV["XDG_CONFIG_HOME"]?
    ENV.delete "XDG_CONFIG_HOME"
    Crysterm::Config.default_config_path.should eq "#{Path.home}/.config/crysterm/config.yml"
  ensure
    ENV["XDG_CONFIG_HOME"] = saved if saved
  end

  it "dumps crysterm and tput options together" do
    yaml = Crysterm::Config.to_yaml
    yaml.should contain "tput:"
    yaml.should contain "window:"
  end

  it "resolves image.backend, including 'auto' detection" do
    # Set from a string (as a config file / dump would) to prove the enum reloads from its rendered form.
    Crysterm::Config["media.backend"].set_from_string "kitty", Superconf::Source::Runtime, "spec"
    Crysterm::Widget::Media.default_type.should eq Crysterm::Widget::Media::Type::Kitty

    # 'auto' resolves against a constructed Tput, independent of the host
    # terminal and any global screen.
    Crysterm::Config.set "media.backend", Crysterm::Widget::Media::Backend::Auto
    ti = (Unibilium.from_env rescue Unibilium.from_terminal("xterm"))
    # probe: false — emulator facts are set explicitly below; suppress the live
    # terminal probe, which would otherwise write query sequences into spec output.
    tput = Tput.new(terminfo: ti, input: STDIN, output: STDOUT, probe: false)

    # Picks Kitty when the terminal speaks the kitty graphics protocol...
    tput.emulator.kitty = true
    Crysterm::Widget::Media.resolve(Crysterm::Widget::Media::Content::Image, tput)
      .should eq Crysterm::Widget::Media::Type::Kitty

    # ...excluding it (image.exclude) lets the next-best win...
    Crysterm::Config.set "media.exclude", "kitty,sixel"
    Crysterm::Widget::Media.resolve(Crysterm::Widget::Media::Content::Image, tput)
      .should_not eq Crysterm::Widget::Media::Type::Kitty
    Crysterm::Config.set "media.exclude", ""

    # ...with no graphics protocol it falls back to a cell backend.
    tput.emulator.kitty = false
    fallback = Crysterm::Widget::Media.resolve(Crysterm::Widget::Media::Content::Image, tput)
    [Crysterm::Widget::Media::Type::Glyph, Crysterm::Widget::Media::Type::Ansi].should contain fallback
  ensure
    Crysterm::Config.set "media.exclude", ""
    Crysterm::Config.set "media.backend", Crysterm::Widget::Media::Backend::Auto # restore
  end

  it "forces a compatible media.backend pin uniformly, but never one a category can't use" do
    # A pinned backend is authoritative everywhere backend selection happens —
    # `resolve` (all content kinds) and `default_type` alike — bypassing the
    # terminal-capability gate, so `Graph::Canvas`/`Video`/images can't diverge
    # from each other or silently downgrade to a cell backend. No tput handle is
    # passed: with 'auto' this would fall to a cell backend, so getting Sixel
    # proves the pin overrides both content ranking and capability.
    Crysterm::Config.set "media.backend", Crysterm::Widget::Media::Backend::Sixel
    {Crysterm::Widget::Media::Content::Painter,
     Crysterm::Widget::Media::Content::Image,
     Crysterm::Widget::Media::Content::Video}.each do |content|
      Crysterm::Widget::Media.resolve(content).should eq Crysterm::Widget::Media::Type::Sixel
    end
    Crysterm::Widget::Media.default_type.should eq Crysterm::Widget::Media::Type::Sixel

    # ...but a background composites *under* text, and sixel can't — so the pin
    # is ignored for `Background` and it resolves to a background-capable backend
    # (cell grid here, since no terminal advertises Kitty). This is the category
    # constraint (`candidates_for(Background)`) winning over the pin.
    bg = Crysterm::Widget::Media.resolve(Crysterm::Widget::Media::Content::Background)
    bg.should_not eq Crysterm::Widget::Media::Type::Sixel
    [Crysterm::Widget::Media::Type::Kitty,
     Crysterm::Widget::Media::Type::Glyph,
     Crysterm::Widget::Media::Type::Ansi].should contain bg
  ensure
    Crysterm::Config.set "media.backend", Crysterm::Widget::Media::Backend::Auto # restore
  end

  it "routes animated-image extensions to the AnimatedImage ranking (iTerm over Kitty)" do
    Crysterm::Widget::Media.animated_image?("a.gif").should be_true
    Crysterm::Widget::Media.animated_image?("a.APNG").should be_true # case-insensitive
    Crysterm::Widget::Media.animated_image?("a.png").should be_false

    ti = (Unibilium.from_env rescue Unibilium.from_terminal("xterm"))
    tput = Tput.new(terminfo: ti, input: STDIN, output: STDOUT, probe: false)
    tput.emulator.kitty = true  # kitty graphics available
    tput.emulator.iterm2 = true # iTerm2 inline images available

    # Same terminal, different content category: a still image prefers Kitty; an
    # animated one prefers iTerm (native GIF animation). Proves the AnimatedImage
    # branch of `candidates_for` is actually reached, not dead.
    Crysterm::Widget::Media.resolve(Crysterm::Widget::Media::Content::Image, tput)
      .should eq Crysterm::Widget::Media::Type::Kitty
    Crysterm::Widget::Media.resolve(Crysterm::Widget::Media::Content::AnimatedImage, tput)
      .should eq Crysterm::Widget::Media::Type::Iterm
  end

  it "validates and tracks source through the alias" do
    Crysterm::Config.set "render.fps_window", 60
    Crysterm::Config.render_fps_window.should eq 60
    Crysterm::Config["render.fps_window"].source.should eq Superconf::Source::Runtime
    expect_raises(Superconf::Error) { Crysterm::Config.set "render.fps_window", 0 }
  ensure
    Crysterm::Config.set "render.fps_window", 30
  end
end
