require 'json'

module TT::Plugins::Shell

class ShellProcedure < Sketchup::Procedure

  ID = 'thomthom.shell.procedure'
  VERSION = 1

  # @return [ShellProcedure]
  def self.instance
    @instance ||= ShellProcedure.new
    @instance
  end

  def initialize
    super(ID, 'Shell procedure', 'Shell Component', VERSION)
  end

  def self.id
    ID
  end

  def declare_params_and_ui
    data = {
      thickness: {
        widget_type: 'text',
        value_type: 'int',
        label:  'Thickness', # Localized
        min_value: 2
      }
    }
    JSON.pretty_generate(data)
  end

  # @param [Array<Sketchup::Entity>] input_entities
  # @param [Hash{Symbol => Integer, Float, String, Boolean}] parameters
  def validate(input_entities, parameters)
    input_entities.any? { |entity| entity.is_a?(Sketchup::Face) }
  end

  # @param [Sketchup::Model] model
  # @param [Sketchup::ComponentDefinition] definition
  # @param [Hash{Symbol => Integer, Float, String, Boolean}] parameters
  def run(model, definition, parameters)
    thickness = parameters[:thickness].to_l
    faces = definition.control_entities.grep(Sketchup::Face)
    # thickness = definition.get_attribute(ID, 'thickness', 500.mm)

    return if faces.empty? || thickness == 0

    p [:control_entities, definition.control_entities, definition.control_entities.size]
    p [:entities, definition.entities, definition.entities.size]
    # TODO: Generate the offset geometry directly into the definition.

    puts "Running ShellProcedure with thickness #{thickness}"
    TT::Plugins::Shell.shell(definition.entities, @thickness)

    p [:control_entities, definition.control_entities, definition.control_entities.size]
    p [:entities, definition.entities, definition.entities.size]
  end

end if Sketchup.respond_to?(:register_procedure)

if Sketchup.respond_to?(:register_procedure)
  puts "Registering ShellProcedure..."
  Sketchup.register_procedure(ShellProcedure.instance)
end

end # module
