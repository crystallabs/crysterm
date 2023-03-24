require "../src/crysterm"

class X
  include Crysterm
  include EventHandler

  def initialize
    s = Screen.new always_propagate: [::Tput::Key::CtrlQ]

    # parent: l,
    i = Widget::TextArea.new \
      width: "100%",
      height: "100%",
      style: Style.new(border: true),
      input_on_focus: true,
      content: "
{center}center{/center}
{left}left{/left}
{right}right{/right}
{normal}normal{/normal}"
    # and {default}default{/default}
    # {bold}bold{/bold}
    # {underline}underline{/underline}, {underlined}underlined{/underlined}, and {ul}ul{/ul}
    # {blink}blink{/blink}
    # {inverse}inverse{/inverse}
    # {invisible}invisible{/invisible}
    #
    # {default-bg}          default         {/default-bg}
    # {black-bg}            black           {/black-bg}
    # {blue-bg}             blue            {/blue-bg}
    # {bright black-bg}     bright black    {/bright black-bg}
    # {bright blue-bg}      bright blue     {/bright blue-bg}
    # {bright cyan-bg}      bright cyan     {/bright cyan-bg}
    # {bright gray-bg}      bright gray     {/bright gray-bg}
    # {bright green-bg}     bright green    {/bright green-bg}
    # {bright grey-bg}      bright grey     {/bright grey-bg}
    # {bright magenta-bg}   bright magenta  {/bright magenta-bg}
    # {bright red-bg}       bright red      {/bright red-bg}
    # {bright white-bg}     bright white    {/bright white-bg}
    # {bright yellow-bg}    bright yellow   {/bright yellow-bg}
    # {cyan-bg}             cyan            {/cyan-bg}
    # {gray-bg}             gray            {/gray-bg}
    # {green-bg}            green           {/green-bg}
    # {grey-bg}             grey            {/grey-bg}
    # {light black-bg}      light black     {/light black-bg}
    # {light blue-bg}       light blue      {/light blue-bg}
    # {light cyan-bg}       light cyan      {/light cyan-bg}
    # {light gray-bg}       light gray      {/light gray-bg}
    # {light green-bg}      light green     {/light green-bg}
    # {light grey-bg}       light grey      {/light grey-bg}
    # {light magenta-bg}    light magenta   {/light magenta-bg}
    # {light red-bg}        light red       {/light red-bg}
    # {light white-bg}      light white     {/light white-bg}
    # {light yellow-bg}     light yellow    {/light yellow-bg}
    # {magenta-bg}          magenta         {/magenta-bg}
    # {red-bg}              red             {/red-bg}
    # {white-bg}            white           {/white-bg}
    # {yellow-bg}           yellow          {/yellow-bg}
    # "

    s.append i

    s.on(Crysterm::Event::KeyPress) do |e|
      if e.char == 'q' || e.key == ::Tput::Key::CtrlQ
        s.destroy
        exit
      end
    end

    s.render

    s.exec
  end
end

X.new
