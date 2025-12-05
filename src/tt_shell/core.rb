#-------------------------------------------------------------------------------
#
# Thomas Thomassen
# thomas[at]thomthom[dot]net
#
#-------------------------------------------------------------------------------

require 'sketchup.rb'

require 'tt_shell/geom3d.rb'
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
