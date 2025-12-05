#-------------------------------------------------------------------------------
#
# Thomas Thomassen
# thomas[at]thomthom[dot]net
#
#-------------------------------------------------------------------------------

require 'sketchup.rb'

require 'tt_shell/geom3d.rb'
require 'tt_shell/settings.rb'


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


  class ShellTool

    PARENT = TT::Plugins::Shell # Shorthand alias

    COLOR_FILL = Sketchup::Color.new( 255, 255, 255, 200 )
    COLOR_EDGE = Sketchup::Color.new(   0,   0,   0, 200 )

    def initialize
      # Gather faces and vertices.
      @meshes = []
      model = Sketchup.active_model
      for instance in model.selection
        next unless instance.is_a?( Sketchup::ComponentInstance ) || instance.is_a?( Sketchup::Group )
        definition = instance.definition
        faces = []
        vertices = []
        for entity in definition.entities
          next unless entity.is_a?( Sketchup::Face )
          faces << entity
          vertices << entity.outer_loop.vertices
        end
        vertices.flatten!
        vertices.uniq!
        @meshes << [ definition.entities, faces, vertices, instance.transformation ]
      end
      # Cached data used by draw()
      @offsets = {} # Key: Vertex - Value: Point3d
      @polygons = []
      # Settings
      @thickness = PARENT.settings[:thickness]
      @cached_thickness = @thickness
      # User Input
      @ip_mouse = Sketchup::InputPoint.new
      @ip_start = Sketchup::InputPoint.new
    end

    def enableVCB?
      return true
    end

    def activate
      cache_preview()
      Sketchup.active_model.active_view.invalidate
      update_ui()
    end

    def deactivate( view )
      view.invalidate
    end

    def resume( view )
      view.invalidate
      update_ui()
    end

    def onUserText( text, view )
      thickness = text.to_l
      @thickness = thickness
      @cached_thickness = @thickness
      PARENT.settings[:thickness] = @thickness
      cache_preview()
      view.invalidate
    ensure
      update_ui()
      @ip_start.clear
    end

    # Pressing enter when the thickness has not changed will commit the offset.
    #
    def onReturn(view)
      offset_mesh()
      view.model.select_tool( nil )
    end

    def onCancel( reason, view )
      @ip_start.clear
      @thickness = @cached_thickness
      update_ui()
      cache_preview()
      view.invalidate
    end

    def onLButtonDoubleClick( flags, x, y, view )
      offset_mesh()
      view.model.select_tool( nil )
    end

    def onLButtonDown( flags, x, y, view )
      if @ip_start.valid?
        # Second point picked.
        update_input()
        @cached_thickness = @thickness
        @ip_start.clear
      else
        # First point picked.
        @ip_start.copy!( @ip_mouse )
      end
      view.invalidate
    end

    def onMouseMove( flags, x, y, view )
      @ip_mouse.pick( view, x, y )
      view.tooltip = @ip_mouse.tooltip
      if @ip_start.valid?
        update_ui()
        update_input()
      end
      view.invalidate
    end

    def draw( view )
      # Geometry Preview
      unless @thickness == 0.to_l || @polygons.empty?
        view.line_stipple = ''
        view.line_width = 1

        for polygon in @polygons
          view.drawing_color = COLOR_EDGE
          view.draw( GL_LINE_LOOP, polygon )

          view.drawing_color = COLOR_FILL
          view.draw( GL_POLYGON, polygon )
        end
      end
      # User Input
      @ip_mouse.draw( view) if @ip_mouse.display?
      if @ip_start.valid?
        @ip_start.draw( view ) if @ip_start.display?
        view.line_stipple = '-'
        view.line_width = 1
        view.set_color_from_line( @ip_start.position, @ip_mouse.position )
        view.draw_line( @ip_start.position, @ip_mouse.position )
      end
    end

    private

    # @return [Nil]
    def reset
      @ip_start.clear
      nil
    end

    # @return [Nil]
    def update_ui
      Sketchup.status_text = 'Enter a thickness and double click to complete.'
      Sketchup.vcb_label = 'Thickness'
      Sketchup.vcb_value = @thickness
      nil
    end

    # @return [Nil]
    def update_input
      @thickness = @ip_start.position.distance( @ip_mouse.position )
      update_ui()
      cache_preview()
      nil
    end

    # @return [Boolean]
    def cache_preview
      return false if @thickness == 0.to_l
      @polygons = offset_polygons()
      true
    end

    # Offset vertex into world co-ordinates.
    #
    # @param [Length] thickness
    # @param [Array<Sketchup::Vertex>] vertices
    # @param [Geom::Transformation] transformation
    #
    # @return [Hash]
    def offset_vertices( thickness, vertices, transformation )
      offsets = {}
      for vertex in vertices
        pt = PARENT.offset_vertex( vertex, thickness )
        offsets[ vertex ] = pt.transform!( transformation )
      end
      offsets
    end

    # Generates an array of offset polygons.
    #
    # @return [Array<Array<Geom::Point3d>>]
    def offset_polygons
      thickness = @thickness
      polygons = []
      for mesh in @meshes
        entities, faces, vertices, transformation = mesh
        cached_vertices = offset_vertices( thickness, vertices, transformation )
        for face in faces
          polygons << face.vertices.map { |vertex| cached_vertices[vertex] }
        end
      end
      polygons
    end

    # @return [Boolean]
    def offset_mesh
      return false if @thickness == 0.to_l
      model = Sketchup.active_model
      time_start = Time.now
      model.start_operation( "Shell #{@thickness}", true )
      for mesh in @meshes
        entities, faces, vertices, transformation = mesh
        PARENT.shell( entities, @thickness )
      end
      model.commit_operation
      puts "Shell took #{Time.now-time_start}s"
      true
    rescue
      model.abort_operation
      raise
    end

  end # class ShellTool


  # @todo Option to add shell directly to the entities instead of a separate
  #   group. Maybe just call explode afterwards? (Explode might be slow. Check
  #   if it will be slower than adding the entities directly.)
  #
  # @param [Sketchup::Entities] entities
  #
  # @return [Sketchup::Group]
  def self.shell( entities, thickness, use_builder: true )
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
    offsets_pt = {}
    for vertex in vertices
      point = self.offset_vertex( vertex, thickness )
      offsets[ vertex ] = point
      offsets_pt[ vertex.position.to_a ] = point
    end
    # Build the shell geometry.
    shell = entities.add_group
    shell_entities = shell.entities
    if use_builder && shell_entities.respond_to?(:build)
      shell_entities.build { |builder|
        self.offset_faces(builder, shell_entities, faces, offsets, offsets_pt)
      }
    else
      self.offset_faces(shell_entities, shell_entities, faces, offsets, offsets_pt)
    end
    shell
  end

  def self.offset_faces(builder, shell_entities, faces, offsets, offsets_pt)
    for face in faces
      # Offset face. Only the outer loop is used - any inner holes are ignored
      # for now. The offset loop is reversed from the source in order to reverse
      # the normal of the offset face.
      points = face.outer_loop.vertices.reverse!.map { |vertex|
        offsets[ vertex ]
      }
      # (!) Error catch
      #     Error: #<ArgumentError: Points are not planar>
      begin
        offset_face = builder.add_face( points )
      rescue ArgumentError => e
        # (!) Recreate with triangulated PolygonMesh.

        mesh = face.mesh
        for i in ( 1..mesh.count_points )
          pt = offsets_pt[ mesh.point_at(i).to_a ]
          mesh.set_point( i, pt )
        end
        shell_entities.add_faces_from_mesh( mesh, 0, face.material, face.back_material )

        puts e.message
        next
      end
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
        self.add_border_face( builder, points )
      end
    end
  end


  # @param [Sketchup::Entities] entities
  # @param [Array<Geom::Point3d>] points
  #
  # @return [Nil]
  def self.add_border_face( entities, points )
    edges = []
    if Geom3d.planar_points?( points )
      face = entities.add_face( points )
      if face.nil?
        puts 'failed to create face'
        p points
        return
      end
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
