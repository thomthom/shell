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

  # @param [Array<Sketchup::Entity>] input_entities
  def validate(input_entities)
    input_entities.any? { |entity| entity.is_a?(Sketchup::Face) }
  end

  # @param [Sketchup::Model] model
  # @param [Sketchup::ComponentDefinition] definition
  def run(model, definition)
    faces = definition.control_entities.grep(Sketchup::Face)
    distance = definition.get_attribute(ID, 'thickness', 500.mm)

    return if faces.empty? || distance == 0

    # ...
  end

end if Sketchup.respond_to?(:register_procedure)

Sketchup.register_procedure(ShellProcedure.instance) if Sketchup.respond_to?(:register_procedure)

end # module
