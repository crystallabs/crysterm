require "./spec_helper"

# `Crysterm.strip_toolkit_args`: `ARGV` as an application's own option
# parser should see it, with the toolkit's options taken out the way
# `QApplication` takes its own from `argv`. `Crysterm.toolkit_options_help`
# prints those options for the application's help.

private def bool_flag : String
  Crysterm::Config["tput.use_buffer"].cli
end

private def valued_flag : String
  Crysterm::Config["window.resize_interval"].cli
end

describe "Crysterm.strip_toolkit_args" do
  it "drops the toolkit's flags with their values, keeping the rest in order" do
    argv = ["a.md", bool_flag, "--no-#{bool_flag.lchop("--")}", "#{valued_flag}=1s", valued_flag, "2s", "-", "--mine"]
    Crysterm.strip_toolkit_args(argv).should eq ["a.md", "-", "--mine"]
  end

  it "leaves the input array as it was" do
    argv = ["x", bool_flag]
    Crysterm.strip_toolkit_args(argv)
    argv.should eq ["x", bool_flag]
  end

  it "passes everything from -- on through, toolkit flags included" do
    argv = [bool_flag, "--", bool_flag, "#{valued_flag}=1s"]
    Crysterm.strip_toolkit_args(argv).should eq ["--", bool_flag, "#{valued_flag}=1s"]
  end

  it "drops the config file and dump flags, with their values" do
    argv = ["--crysterm-config=c.yml", "--crysterm-config", "d.yml", "--crysterm-dump-config", "yaml", "--crysterm-dump-config", bool_flag, "--crysterm-dump-config=json", "f"]
    Crysterm.strip_toolkit_args(argv).should eq ["f"]
    # A word after the dump flag is its format only when it names one.
    Crysterm.strip_toolkit_args(["--crysterm-dump-config", "JSON", "g"]).should eq ["g"]
    Crysterm.strip_toolkit_args(["--crysterm-dump-config", "-x", "g"]).should eq ["-x", "g"]
  end

  it "leaves the application's file after a bare dump flag, as Superconf does" do
    Crysterm.strip_toolkit_args(["--crysterm-dump-config", "notes.md"]).should eq ["notes.md"]
    Crysterm.strip_toolkit_args(["a.md", "--crysterm-dump-config", "notes.md", "b.md"]).should eq ["a.md", "notes.md", "b.md"]
  end

  it "leaves the application's own dump flag its format, as the toolkit reads the arguments" do
    argv = ["--crysterm-dump-config", "--dump-config", "json"]
    Crysterm.strip_toolkit_args(argv).should eq ["--dump-config", "json"]
    Crysterm.configure!("", env: false, argv: argv, defer_dump: true)
    Superconf.pending_dump.should eq Superconf::Format::Yaml
    Crysterm.configure!("", env: false, argv: ["--crysterm-dump-config", "json", "--dump-config", "env"], defer_dump: true)
    Superconf.pending_dump.should eq Superconf::Format::Json
  ensure
    Superconf.pending_dump = nil
  end

  it "keeps the flags the application names as its own" do
    argv = [bool_flag, "--crysterm-config=c.yml", "f"]
    Crysterm.strip_toolkit_args(argv, except: {bool_flag, "--crysterm-config"}).should eq [bool_flag, "--crysterm-config=c.yml", "f"]
  end

  it "is Application.arguments under Qt's name" do
    argv = ["a", bool_flag, "b"]
    Crysterm::Application.arguments(argv).should eq ["a", "b"]
    Crysterm::Application.arguments(argv, except: {bool_flag}).should eq argv
  end

  it "defaults to ARGV" do
    Crysterm.strip_toolkit_args.should eq Crysterm.strip_toolkit_args(ARGV)
  end
end

describe "Crysterm.toolkit_options_help" do
  it "lists every toolkit option with its description and default, and the file and dump flags" do
    help = Crysterm.toolkit_options_help
    help.should start_with "Crysterm toolkit options."
    help.should contain "crysterm/config.yml"
    help.should contain "CRYSTERM_*"
    help.should contain bool_flag
    help.should contain "--no-#{bool_flag.lchop("--")}"
    help.should contain "#{valued_flag}=VALUE"
    help.should contain Crysterm::Config["window.resize_interval"].description.split(' ').first
    help.should contain "(default: "
    help.should contain "--crysterm-config=FILE"
    help.should contain "--crysterm-dump-config [FORMAT]"
  end

  it "lists a negation another option spells as its own flag once, as Superconf registers it" do
    Superconf.register("spectestcolor", true, description: "Color")
    Superconf.register("no_spectestcolor", true, description: "No color")
    help = Crysterm.toolkit_options_help
    # `--no-spectestcolor` is no_spectestcolor's own flag, not spectestcolor's
    # negation as well: once, as the option.
    help.scan(/--no-spectestcolor\b/).size.should eq 1
    help.should contain "--no-no-spectestcolor"
    Crysterm.strip_toolkit_args(["--spectestcolor", "--no-spectestcolor", "--no-no-spectestcolor", "f"]).should eq ["f"]
  end

  it "leaves out the flags the application names as its own" do
    help = Crysterm.toolkit_options_help(except: {bool_flag, "--crysterm-dump-config"})
    help.should_not contain "#{bool_flag} "
    help.should_not contain "--crysterm-dump-config [FORMAT]"
    help.should contain valued_flag
  end
end
