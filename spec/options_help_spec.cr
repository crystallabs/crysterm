require "./spec_helper"

module Superconf
  option "helpspec.width", 80, description: "a width"
  option "helpspec.wrap", true, description: "whether to wrap"
end

# `Crysterm.options_help`: an application's own options laid out as the
# toolkit's are, under the application's banner.
describe "Crysterm.options_help" do
  it "lists the given options with their defaults and a boolean's negation" do
    options = [Crysterm::Config["helpspec.width"], Crysterm::Config["helpspec.wrap"]]
    text = Crysterm.options_help("Settings for the spec:", options)
    text.should start_with "Settings for the spec:\n"
    text.should contain "--helpspec-width=VALUE"
    text.should contain "a width (default: 80)"
    text.should contain "--helpspec-wrap "
    text.should contain "--no-helpspec-wrap"
    text.should contain "Disable helpspec.wrap"
    text.should_not contain "--colors-theme"                              # only the given options
    Crysterm.toolkit_options_help.should contain "--helpspec-width=VALUE" # which the toolkit's list has too
  end
end
