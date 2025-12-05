module TT::Plugins::Shell

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

end # module
