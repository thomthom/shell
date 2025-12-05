# Wrapper for +Sketchup.read_default+ and +Sketchup.write_default+.
#
# To initialize defaults:
#   @settings = Settings.new('FooBar')
#   @settings.set_default( :foo, false )
#   @settings.set_default( :bar, true )
#   # Read
#   read_value = @settings[ :foo ]
#   # Write
#   @settings[:bar] = false
#
module TT::Plugins::Shell
class Settings

  # Creates a new Settings instance that read and writes values to +section+
  # in SketchUp's preferences.
  #
  # @param [String] section
  def initialize(section)
    @section = section
    @cache = {}
  end


  # Type casts read values based on the default value given where
  # +Sketchup.read_default+ would otherwise not do so.
  #
  # Custom type casts: +Length+, +Symbol+
  #
  # @param [String, Symbol] key
  # @param [mixed] default
  #
  # @return [mixed]
  def [](key, default = nil)
    if @cache.key?(key)
      x = @cache[key]
    else
      begin
        x = Sketchup.read_default(@section, key.to_s, default)
      rescue SyntaxError
        puts "#<#{self.class.name}> Error reading setting! - Returning default value."
        puts "> #{@section.inspect} - #{key.to_s.inspect} (#{default.inspect})"
        x = default
      end
      x = x.to_l if default.is_a?(Length)
      x = x.intern if x.is_a?(String) && default.is_a?(Symbol)
      @cache[key] = x
      x
    end
  end


  # Converts +Length+ to +Float+.
  #
  # Converts +Symbol+ to +String+.
  #
  # @param [String, Symbol] key
  # @param [mixed] value
  #
  # @return [mixed]
  def []=(key, value)
    @cache[key] = value
    value = value.to_f if value.is_a?(Length)
    value = value.to_s if value.is_a?(Symbol)
    Sketchup.write_default(@section, key.to_s, value)
    value
  end


  # Type casts read values based on the default value given where
  # +Sketchup.read_default+ would otherwise not do so.
  #
  # Preferred over +settings[key, default]+ for setting defaults.
  #
  # Custom type casts: +Length+, +Symbol+
  #
  # @param [String, Symbol] key
  # @param [mixed] default
  #
  # @return [mixed]
  def set_default(key, default = nil)
    self.[](key, default)
  end


  # Creates a sub-section.
  #
  # @deprecated Untested on OSX. Creates sub-keys under Windows.
  #
  # @param [String] sub_section
  #
  # @return [Settings]
  def sub_section( sub_section )
    self.new( "#{@section}\\#{sub_section}" )
  end

end # class
end # module
