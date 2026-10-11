require "./spec_helper"
require "file_utils"

# `Reactive.config_property` / `.link_config`: a `Property` and a Superconf
# option following each other, so a menu entry bound to the property and a
# settings file loaded at run time set the same value.

module Superconf
  option "rxspec.level", 3, description: "reactive config spec option"
  option "rxspec.theme", Crysterm::CSS::Theme::Choice::Terminal, description: "reactive config spec option"
end

describe "Reactive.config_property" do
  it "starts at the option's value and sets the option when assigned" do
    Crysterm::Config.set "rxspec.level", 5
    prop = Crysterm::Reactive.config_property "rxspec.level", Int32
    prop.value.should eq 5
    prop.value = 7
    Crysterm::Config.get("rxspec.level", Int32).should eq 7
    Crysterm::Config["rxspec.level"].source.should eq Superconf::Source::Runtime
  ensure
    Crysterm::Config.reset "rxspec.level"
  end

  it "follows the option when a file is loaded at run time, or the option is reset" do
    prop = Crysterm::Reactive.config_property "rxspec.theme", Crysterm::CSS::Theme::Choice
    seen = [] of Crysterm::CSS::Theme::Choice
    prop.on_change { seen << prop.value }
    Crysterm::Config.load_yaml "rxspec: {theme: dark}", "spec", Superconf::Source::Runtime
    prop.value.should eq Crysterm::CSS::Theme::Choice::Dark
    Crysterm::Config.rxspec_theme = Crysterm::CSS::Theme::Choice::Light
    prop.value.should eq Crysterm::CSS::Theme::Choice::Light
    Crysterm::Config.reset "rxspec.theme"
    prop.value.should eq Crysterm::CSS::Theme::Choice::Terminal
    seen.should eq [Crysterm::CSS::Theme::Choice::Dark, Crysterm::CSS::Theme::Choice::Light, Crysterm::CSS::Theme::Choice::Terminal]
  ensure
    Crysterm::Config.reset "rxspec.theme"
  end

  it "leaves a load at file precedence below a value the property set" do
    prop = Crysterm::Reactive.config_property "rxspec.level", Int32
    prop.value = 9
    Crysterm::Config.load_yaml "rxspec: {level: 1}", "spec"
    prop.value.should eq 9
  ensure
    Crysterm::Config.reset "rxspec.level"
  end

  it "links an existing property, putting the option's value in first" do
    Crysterm::Config.set "rxspec.level", 4
    prop = Crysterm::Reactive::Property.new 0
    changes = 0
    prop.on_change { changes += 1 }
    Crysterm::Reactive.link_config(prop, "rxspec.level").should be prop
    prop.value.should eq 4
    changes.should eq 1
    prop.value = 4 # unchanged: no echo into the option, no notification
    changes.should eq 1
    Crysterm::Config.set "rxspec.level", 4 # the value it holds: no notification
    changes.should eq 1
    prop.value = 6
    Crysterm::Config.get("rxspec.level", Int32).should eq 6
    changes.should eq 2
  ensure
    Crysterm::Config.reset "rxspec.level"
  end
end

describe "Crysterm.configure! with defer_dump" do
  it "notes the dump for the first window instead of exiting" do
    Crysterm.configure!("", env: false, argv: ["--crysterm-dump-config", "pretty"], defer_dump: true)
    Superconf.pending_dump.should eq Superconf::Format::Pretty
  ensure
    Superconf.pending_dump = nil
  end
end

describe "Crysterm.default_log_file" do
  it "fills an empty log.file as its default, leaving the option unconfigured" do
    previous = Crysterm::Config.log_file
    Crysterm::Config.reset "log.file"
    dir = File.tempname("crysterm-log-spec")
    saved = ENV["XDG_CACHE_HOME"]?
    ENV["XDG_CACHE_HOME"] = dir
    path = Crysterm.default_log_file("specapp")
    path.should eq File.join(dir, "specapp", "specapp.log")
    Crysterm::Config.log_file.should eq path
    Crysterm::Config.configured?("log.file").should be_false
    Crysterm::Config.set "log.file", "/elsewhere.log"
    Crysterm.default_log_file("specapp").should eq "/elsewhere.log" # a named file is kept
  ensure
    if saved
      ENV["XDG_CACHE_HOME"] = saved
    else
      ENV.delete "XDG_CACHE_HOME"
    end
    Crysterm::Config.reset "log.file"
    Crysterm::Config.set_default "log.file", ""
    Crysterm::Config.set "log.file", previous if previous && !previous.empty?
    FileUtils.rm_rf dir if dir
  end
end
