require 'sketchup.rb'

require 'tt_shell/settings.rb'
require 'tt_shell/tool.rb'


module TT::Plugins::Shell

  @settings = Settings.new( PLUGIN_ID )
  @settings.set_default( :thickness, 500.mm )

  def self.settings; @settings; end


  unless file_loaded?( __FILE__ )
    m = UI.menu( 'Tools' )
    m.add_item( 'Shell' ) { self.activate_shell_tool }
    file_loaded( __FILE__ )
  end


  def self.activate_shell_tool
    Sketchup.active_model.select_tool( ShellTool.new )
  end


  # @note Debug method to reload the extension.
  #
  # @example
  #   TT::Plugins::Shell.reload
  #
  # @return [Integer] Number of files reloaded.
  def self.reload
    original_verbose = $VERBOSE
    $VERBOSE = nil
    # Core file (this)
    load __FILE__
    # Supporting files
    if defined?( PATH ) && File.exist?( PATH )
      x = Dir.glob( File.join(PATH, '*.{rb,rbs}') ).each { |file|
        load file
      }
      x.length + 1
    else
      1
    end
  ensure
    $VERBOSE = original_verbose
  end

end # module
