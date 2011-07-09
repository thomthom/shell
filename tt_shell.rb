#-------------------------------------------------------------------------------
#
# Thomas Thomassen
# thomas[at]thomthom[dot]net
#
#-------------------------------------------------------------------------------

require 'sketchup.rb'
require 'TT_Lib2/core.rb'

TT::Lib.compatible?('2.5.4', 'TT Shell')

#-------------------------------------------------------------------------------


module TT::Plugins::Shell
  
  ### CONSTANTS ### ------------------------------------------------------------
  
  # Plugin information
  ID          = 'TT_Shell'.freeze
  VERSION     = '0.1.0'.freeze # Alpha
  PLUGIN_NAME = 'Shell'.freeze
  
  
  ### MODULE VARIABLES ### -----------------------------------------------------
  
  # Preference
  @settings = TT::Settings.new( ID )
  @settings[:thickness, 500.mm]
  
  
  ### MENU & TOOLBARS ### ------------------------------------------------------
  
  unless file_loaded?( __FILE__ )
    # Menus
    m = TT.menu( 'Plugin' )
    m.add_item( 'Shell' ) { self.shell_selection }
    
    # Context menu
    #UI.add_context_menu_handler { |context_menu|
    #  model = Sketchup.active_model
    #  selection = model.selection
    #  # ...
    #}
    
    # Toolbar
    #toolbar = UI::Toolbar.new( PLUGIN_NAME )
    #toolbar.add_item( ... )
    #if toolbar.get_last_state == TB_VISIBLE
    #  toolbar.restore
    #  UI.start_timer( 0.1, false ) { toolbar.restore } # SU bug 2902434
    #end
  end 
  
  
  ### MAIN SCRIPT ### ----------------------------------------------------------
  
  def self.shell_selection
    # Prompt user for input.
    prompts = [ 'Thickness: ' ]
    defaults = [ @settings[:thickness] ]
    results = UI.inputbox( prompts, defaults, 'Shell' )
    return unless results
    # Process input.
    thickness = results[0]
    return if thickness == 0
    @settings[:thickness] = thickness
    # Shell the current selection.
    time_start = Time.now
    model = Sketchup.active_model
    TT::Model.start_operation( 'Shell' )
    for entity in model.selection
      next unless TT::Instance.is?( entity )
      definition = TT::Instance.definition( entity )
      self.shell( definition.entities, thickness )
    end
    model.commit_operation
    puts "Shell took #{Time.now-time_start}s"
  end
  
  
  # @param [Sketchup::Entities] entities
  #
  # @return [Sketchup::Group]
  def self.shell( entities, thickness )
    # Gather faces and vertices.
    faces = []
    vertices = []
    for entity in entities
      next unless entity.is_a?( Sketchup::Face )
      faces << entity
      vertices << entity.outer_loop.vertices
    end
    vertices.flatten!
    vertices.uniq!
    # Offset vertices - generate a hash that links the source vertices with the
    # offset vertices.
    offsets = {}
    for vertex in vertices
      offsets[ vertex ] = self.offset_vertex( vertex, thickness )
    end
    # Build the shell geometry.
    shell = entities.add_group
    shell_entities = shell.entities
    for face in faces
      # Offset face. Only the outer loop is used - any inner holes are ignored
      # for now. The offset loop is reversed from the source in order to reverse
      # the normal of the offset face.
      points = face.outer_loop.vertices.reverse!.map { |vertex|
        offsets[ vertex ]
      }
      # (!) Error catch
      offset_face = shell_entities.add_face( points )
      # Transfer edge properties from the source face to the destination face.
      self.copy_soft_smooth( face, offset_face ) # + 0.03s
      # Add border faces. A border edge only has one edge connected.
      for edge in face.edges
        next unless edge.faces.size == 1
        edge_points = edge.vertices { |vertex| vertex.position }
        offset_points = edge.vertices.map { |vertex|
          offsets[ vertex ]
        }.reverse! # Reversed in order to generate a proper loop for the face.
        points = edge_points + offset_points
        self.add_border_face( shell_entities, points )
      end
    end
    shell
  end
  
  
  # @param [Sketchup::Entities] entities
  # @param [Array<Geom::Point3d>] points
  #
  # @return [Nil]
  def self.add_border_face( entities, points )
    edges = []
    if TT::Geom3d.planar_points?( points )
      face = entities.add_face( points )
      edges = face.edges
    else
      tri1 = [ points[0], points[1], points[2] ]
      tri2 = [ points[2], points[3], points[0] ]
      face1 = entities.add_face( tri2 )
      face2 = entities.add_face( tri1 )
      divider = self.smooth_border_segment( face1, face2 )
      edges = ( face1.edges + face2.edges ) - [ divider ]
    end
    for edge in edges
      edge.soft = false
      edge.smooth = false
    end
    nil
  end
  
  
  # @param [Sketchup::Vertex] vertex
  # @param [Length] distance
  #
  # @return [Geom::Point3d,Nil] Nil upon failure.
  def self.offset_vertex( vertex, distance )
    faces = vertex.faces
    # Can't offset vertex without any connected face.
    return nil if faces.empty?
    # If there is only one face connected, simply offset using the face's
    # normal.
    position = vertex.position
    if faces.size == 1
      return position.offset( faces[0].normal.reverse!, distance )
    end
    # Calculate the planes for each face connected to `vertex` offset by
    # `distance`.
    planes = vertex.faces.map { |face|
      pt = face.vertices[0].position
      offset_pt = pt.offset( face.normal.reverse, distance )
      offset_normal = pt.vector_to( offset_pt )
      offset_plane = [ offset_pt, offset_normal ]
    }
    # Fetch a plane. From this intersections will be attempted to be found.
    plane1 = planes.shift
    plane2 = nil
    # Find intersecting line with other plane. If found, the offset point
    # should be somewhere along this line.
    # Search the stack of planes for other planes that is not coplanar to
    # `plane1`.
    until planes.empty?
      plane2 = planes.shift
      line = Geom.intersect_plane_plane( plane1, plane2 )
      break if line
    end
    # If we got no line then it means all the other planes where coplanar.
    # Offset straight based on one of the vertex faces's normal - they will all
    # be the same.
    unless line
      return position.offset( faces[0].normal.reverse!, distance )
    end
    # An intersection was found, meaning there was at least two non-planar
    # planes.
    # If there are no more planes left then the vertex offset is between the
    # normal of the two planes.
    if planes.empty?
      return position.project_to_line( line )
    end
    # If there are more planes, check for intersection with the line. The
    # resulting point should be the correct offset.
    # Look for planes that intersect `line` - if there are no found, then they
    # are all planar with `plane1` or `plane2`.
    until planes.empty?
      plane3 = planes.shift
      point = Geom.intersect_line_plane( line, plane3 )
      return point if point
    end
    # The remaining planes where coplanar, treat it as there are only two faces.
    return position.project_to_line( line )
  end
  
  
  # @param [Sketchup::Face] face1
  # @param [Sketchup::Face] face2
  #
  # @return [Sketchup::Edge] Edge dividing the faces.
  def self.smooth_border_segment( face1, face2 )
    divider = ( face1.edges & face2.edges)[0]
    divider.soft = true
    divider.smooth = true
    divider
  end
  
  
  # @param [Sketchup::Face] source
  # @param [Sketchup::Face] destination
  #
  # @return [Nil]
  def self.copy_soft_smooth( source, destination )
    loop1 = source.outer_loop.vertices
    loop2 = destination.outer_loop.vertices.reverse!
    for index in 0...loop1.size
      end_index = ( index + 1 ) % loop1.size
      # Source
      v1 = loop1[ index ]
      v2 = loop1[ end_index ]
      source_edge = v1.common_edge( v2 )
      # Destination
      v1 = loop2[ index ]
      v2 = loop2[ end_index ]
      destination_edge = v1.common_edge( v2 )
      # Transfer properties
      destination_edge.soft   = source_edge.soft?
      destination_edge.smooth = source_edge.smooth?
      destination_edge.hidden = source_edge.hidden?
    end
    nil
  end
  
  
  ### DEBUG ### ----------------------------------------------------------------
  
  # @note Debug method to reload the plugin.
  #
  # @example
  #   TT::Plugins::Shell.reload
  #
  # @param [Boolean] tt_lib
  #
  # @return [Integer]
  # @since 1.0.0
  def self.reload( tt_lib = false )
    original_verbose = $VERBOSE
    $VERBOSE = nil
    TT::Lib.reload if tt_lib
    # Core file (this)
    load __FILE__
    # Supporting files
    1
  ensure
    $VERBOSE = original_verbose
  end
  
  
end # module

#-------------------------------------------------------------------------------

file_loaded( __FILE__ )

#-------------------------------------------------------------------------------