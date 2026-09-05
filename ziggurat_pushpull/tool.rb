# frozen_string_literal: true

module ZigguratPushPull
  class Tool
    SELECTED_COLOR = Sketchup::Color.new(35, 145, 245, 70)
    SELECTED_EDGE_COLOR = Sketchup::Color.new(20, 105, 210)
    HOVER_COLOR = Sketchup::Color.new(65, 220, 120, 85)
    HOVER_EDGE_COLOR = Sketchup::Color.new(20, 145, 65)
    VECTOR_PICK_COLOR = Sketchup::Color.new(25, 220, 230, 95)
    ERROR_PREVIEW = Sketchup::Color.new(245, 55, 55)
    JOINT_PREVIEW = Sketchup::Color.new(255, 135, 20)
    NORMAL_PREVIEW = [
      Sketchup::Color.new(255, 205, 30), Sketchup::Color.new(55, 205, 100),
      Sketchup::Color.new(20, 185, 220)
    ].freeze
    VECTOR_PREVIEW = Sketchup::Color.new(30, 215, 225)
    EXTRUDE_PREVIEW = Sketchup::Color.new(220, 65, 225)
    AXIS_COLORS = {
      red: Sketchup::Color.new(230, 45, 45), green: Sketchup::Color.new(20, 170, 70),
      blue: Sketchup::Color.new(35, 100, 235), free: Sketchup::Color.new(245, 155, 25),
      edge: Sketchup::Color.new(20, 215, 225), face: Sketchup::Color.new(255, 190, 30),
      points: Sketchup::Color.new(235, 70, 210), last: Sketchup::Color.new(150, 100, 240)
    }.freeze
    SCOPES = %i[face surface connected].freeze
    MAX_PREVIEW_POLYGONS = 1800
    MAX_HOVER_FACES = 5000

    def initialize(model, mode, options)
      @model = model
      @mode = mode
      @options = options.merge(mode: mode)
      @scope = @options.fetch(:selection_scope, :surface)
      @faces = valid_selected_faces
      @target_instance = nil
      @target_entities = model.active_entities
      @anchor_face = @faces.max_by(&:area)
      @hover_face = nil
      @hover_faces = []
      @hover_edge = nil
      @vector_hover_face = nil
      @input_point = Sketchup::InputPoint.new
      @vector_origin = nil
      @vector_pick_mode = :auto
      @axis_lock = nil
      @axis_name = nil
      @distance = 0.to_l
      @preview = []
      @transform = model.edit_transform
      @hover_transform = @transform
      @hover_record = nil
      @analysis = { severity: :ok, message: nil, safe_distance: nil }
      @last_mouse = nil
      @shift_down = false
      @ctrl_down = false
      @phase = @faces.empty? ? :selecting : next_phase
    end

    def activate
      update_status
      @model.active_view.invalidate
    end

    def deactivate(view)
      Sketchup.status_text = ''
      view.invalidate
    end

    def resume(view)
      update_status
      view.invalidate
    end

    def onMouseMove(_flags, x, y, view)
      @last_mouse = [x, y]
      case @phase
      when :selecting then update_selection_hover(view, x, y)
      when :vector_pick, :vector_second then update_vector_hover(view, x, y)
      when :dragging then update_distance(view, x, y)
      end
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      case @phase
      when :selecting then accept_face_click(view, x, y)
      when :vector_pick then accept_vector_source(view, x, y)
      when :vector_second then accept_vector_target(view, x, y)
      when :dragging then apply
      end
      view.invalidate
    end

    def onLButtonDoubleClick(_flags, x, y, view)
      return unless @phase == :selecting
      record = picked_record(view, x, y, Sketchup::Face)
      return UI.beep unless record
      set_target(record)
      face = record[:entity]
      @faces = selection_faces(face, record[:entities])
      @anchor_face = face
      advance_after_face_selection
      view.invalidate
    end

    def onUserText(text, view)
      return UI.beep unless @phase == :dragging
      begin
        value = text.to_l
        raise ArgumentError if value.to_f.abs < 0.001
        @distance = value
        refresh_preview
        apply
      rescue ArgumentError
        UI.messagebox('Enter a valid non-zero distance, for example 25mm or -3cm.')
      end
      view.invalidate
    end

    def onKeyDown(key, repeat, _flags, view)
      case key
      when VK_SHIFT
        @shift_down = true
      when VK_CONTROL
        @ctrl_down = true
        toggle_finish if @phase == :dragging && repeat.to_i <= 1
      when VK_RIGHT then select_axis(:red, X_AXIS)
      when VK_LEFT then select_axis(:green, Y_AXIS)
      when VK_UP then select_axis(:blue, Z_AXIS)
      when VK_DOWN then clear_axis_lock
      when 9 then @phase == :selecting ? cycle_selection_scope : UI.beep # Tab
      when 13 then handle_enter
      when 86 then begin_two_point_vector # V
      when 76 then use_last_vector # L
      when 84 then prompt_taper # T
      when VK_ESCAPE then handle_escape
      else return false
      end
      update_distance(view, *@last_mouse) if @phase == :dragging && @last_mouse
      update_status
      view.invalidate
      true
    end

    def onKeyUp(key, _repeat, _flags, _view)
      case key
      when VK_SHIFT then @shift_down = false
      when VK_CONTROL then @ctrl_down = false
      else return false
      end
      true
    end

    def onCancel(_reason, _view)
      handle_escape
    end

    def getMenu(menu)
      menu.add_item('Reverse direction') { reverse_direction }
      menu.add_item(@options[:finish] == :thicken ? 'Use Offset Surface' : 'Use Thickening') { toggle_finish }
      if @mode == :normal || @mode == :extrude
        menu.add_item("Set Taper... (#{(@options.fetch(:taper, 1.0) * 100).round}%)") { prompt_taper }
      end

      scope_menu = menu.add_submenu('Selection scope')
      add_scope_item(scope_menu, :face, 'Single Face')
      add_scope_item(scope_menu, :surface, 'Smooth Surface')
      add_scope_item(scope_menu, :connected, 'All Connected Faces')

      direction = menu.add_submenu('Direction')
      direction.add_item('Red axis (Right Arrow)') { select_axis(:red, X_AXIS) }
      direction.add_item('Green axis (Left Arrow)') { select_axis(:green, Y_AXIS) }
      direction.add_item('Blue axis (Up Arrow)') { select_axis(:blue, Z_AXIS) }
      direction.add_item('Free / Face Normal (Down Arrow)') { clear_axis_lock }
      if @mode == :vector
        direction.add_separator
        direction.add_item('Pick Edge or Face') { begin_auto_vector }
        direction.add_item('Pick Two Points (V)') { begin_two_point_vector }
        direction.add_item('Use Last Vector (L)') { use_last_vector }
      end

      menu.add_item('Options...') do
        next unless Settings.prompt
        @options = Settings.engine_options.merge(mode: @mode)
        @scope = @options[:selection_scope]
        refresh_hover_faces
        refresh_preview
        update_status
        @model.active_view.invalidate
      end
    end

    def draw(view)
      draw_face_fill(view, @faces, SELECTED_COLOR)
      draw_face_edges(view, @faces, SELECTED_EDGE_COLOR, 3)
      draw_face_fill(view, @hover_faces, HOVER_COLOR, @hover_transform)
      draw_face_edges(view, @hover_faces, HOVER_EDGE_COLOR, 5, @hover_transform)
      draw_vector_picker(view)
      draw_preview(view)
      draw_direction_indicator(view) if @phase == :dragging
    end

    def getExtents
      bounds = Geom::BoundingBox.new
      (@faces + @hover_faces).uniq.each do |face|
        transform = @hover_faces.include?(face) && !@faces.include?(face) ? @hover_transform : @transform
        face.vertices.each { |vertex| bounds.add(vertex.position.transform(transform)) }
      end
      @preview.each { |polygon| polygon.each { |point| bounds.add(point.transform(@transform)) } }
      bounds.add(@vector_origin.transform(@transform)) if @vector_origin
      bounds
    end

    private

    def next_phase
      @mode == :vector ? :vector_pick : :dragging
    end

    def valid_selected_faces
      @model.selection.grep(Sketchup::Face).select { |face| @model.active_entities.include?(face) }
    end

    def picked_record(view, x, y, klass)
      helper = view.pick_helper
      helper.do_pick(x, y, 7.0)
      helper.count.times do |index|
        path = helper.path_at(index)
        leaf = helper.leaf_at(index)
        next unless leaf.is_a?(klass)
        instances = (path || []).select do |entity|
          entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        end
        instance = instances.last
        entities = instance ? instance.definition.entities : @model.active_entities
        next unless entities.include?(leaf)
        transform = begin
          helper.transformation_at(index)
        rescue StandardError
          @model.edit_transform
        end
        return { entity: leaf, instance: instance, instances: instances, entities: entities, transform: transform }
      end
      nil
    end

    def picked_face(view, x, y)
      record = picked_record(view, x, y, Sketchup::Face)
      record && record[:entity]
    end

    def update_selection_hover(view, x, y)
      record = picked_record(view, x, y, Sketchup::Face)
      face = record && record[:entity]
      return if record && @hover_record && face == @hover_face && record[:instance] == @hover_record[:instance]
      @hover_record = record
      @hover_face = face
      @hover_transform = record ? record[:transform] : @transform
      @hover_faces = record ? selection_faces(face, record[:entities]) : []
      update_status
    end

    def accept_face_click(view, x, y)
      record = picked_record(view, x, y, Sketchup::Face)
      return UI.beep unless record
      face = record[:entity]
      candidates = selection_faces(face, record[:entities])
      if @shift_down
        if !@faces.empty? && !same_target?(record)
          UI.messagebox('All selected faces must belong to the same Group or Component.')
          return
        end
        set_target(record) if @faces.empty?
        if @ctrl_down
          @faces -= candidates
        else
          @faces |= candidates
        end
        @anchor_face ||= face
        update_status
        return
      end
      set_target(record)
      @faces = candidates
      @anchor_face = face
      advance_after_face_selection
    end

    def advance_after_face_selection
      return UI.beep if @faces.empty?
      @phase = next_phase
      @hover_face = nil
      @hover_faces = []
      begin_auto_vector if @phase == :vector_pick
      update_status
    end

    def selection_faces(seed, entities = @target_entities)
      return [seed] if @scope == :face
      result = []
      visited = {}
      queue = [seed]
      until queue.empty?
        face = queue.shift
        next if visited[face]
        visited[face] = true
        result << face
        break if result.length >= MAX_HOVER_FACES
        face.edges.each do |edge|
          next if @scope == :surface && !(edge.soft? || edge.smooth?)
          edge.faces.each do |neighbor|
            queue << neighbor if entities.include?(neighbor) && !visited[neighbor]
          end
        end
      end
      result
    end

    def set_target(record)
      @target_instance = record[:instance]
      @target_instances = record[:instances]
      @target_entities = record[:entities]
      @transform = record[:transform]
      @hover_transform = @transform
    end

    def same_target?(record)
      record[:instance] == @target_instance && record[:entities] == @target_entities
    end

    def update_vector_hover(view, x, y)
      @input_point.pick(view, x, y)
      if @phase == :vector_pick && @vector_pick_mode == :auto
        @hover_edge_record = picked_record(view, x, y, Sketchup::Edge)
        @hover_edge = @hover_edge_record && @hover_edge_record[:entity]
        @vector_face_record = @hover_edge ? nil : picked_record(view, x, y, Sketchup::Face)
        @vector_hover_face = @vector_face_record && @vector_face_record[:entity]
      else
        @hover_edge = nil
        @vector_hover_face = nil
      end
      update_status
    end

    def accept_vector_source(view, x, y)
      update_vector_hover(view, x, y)
      if @vector_pick_mode == :auto && @hover_edge
        edge_vector = @hover_edge.end.position - @hover_edge.start.position
        choose_vector(vector_to_target(edge_vector, @hover_edge_record[:transform]), :edge)
      elsif @vector_pick_mode == :auto && @vector_hover_face
        choose_vector(vector_to_target(@vector_hover_face.normal, @vector_face_record[:transform]), :face)
      elsif @input_point.valid?
        @vector_origin = point_to_target(@input_point.position)
        @phase = :vector_second
        @vector_pick_mode = :two_points
      else
        UI.beep
      end
    end

    def accept_vector_target(view, x, y)
      @input_point.pick(view, x, y)
      return UI.beep unless @input_point.valid? && @vector_origin
      vector = point_to_target(@input_point.position) - @vector_origin
      return UI.beep if vector.length < 0.001
      choose_vector(vector, :points)
    end

    def begin_auto_vector
      return UI.beep unless @mode == :vector
      @phase = :vector_pick
      @vector_pick_mode = :auto
      @vector_origin = nil
      @hover_edge = nil
      @vector_hover_face = nil
      @preview = []
      update_status
      @model.active_view.invalidate
    end

    def begin_two_point_vector
      return UI.beep unless @mode == :vector
      @phase = :vector_pick
      @vector_pick_mode = :two_points
      @vector_origin = nil
      @hover_edge = nil
      @vector_hover_face = nil
      @preview = []
      update_status
      @model.active_view.invalidate
    end

    def use_last_vector
      return UI.beep unless @mode == :vector
      choose_vector(Settings.last_vector, :last)
    end

    def choose_vector(vector, source)
      return UI.beep if vector.nil? || vector.length < 0.001
      @axis_lock = vector.normalize
      @axis_name = source
      @options[:vector] = @axis_lock
      Settings.store_last_vector(@axis_lock)
      @phase = :dragging
      @vector_origin = nil
      @hover_edge = nil
      @vector_hover_face = nil
      refresh_preview
      update_status
      @model.active_view.invalidate
    end

    def select_axis(name, vector)
      return UI.beep if @mode == :normal
      local_vector = vector_to_target(vector, Geom::Transformation.new)
      if @mode == :vector
        choose_vector(local_vector, name)
      else
        @axis_name = name
        @axis_lock = local_vector.normalize
        refresh_preview
      end
    end

    def point_to_target(point)
      point.transform(@transform.inverse)
    end

    def vector_to_target(vector, source_transform)
      world = vector.transform(source_transform)
      world.transform(@transform.inverse).normalize
    end

    def clear_axis_lock
      return UI.beep if @mode == :normal
      if @mode == :vector
        begin_auto_vector
      else
        @axis_name = nil
        @axis_lock = nil
        refresh_preview
      end
    end

    def drag_axis
      return @axis_lock if @axis_lock
      @anchor_face ? @anchor_face.normal.normalize : Z_AXIS
    end

    def effective_options
      values = @options.merge(
        selection_scope: @scope,
        source_entities: @target_entities,
        modify_original: @options[:output_mode] == :modify
      )
      if component_target? && @options[:component_scope] == :unique
        values[:prepare_context] = component_prepare_proc
      end
      case @mode
      when :vector, :extrude then values.merge(vector: drag_axis)
      when :joint then values.merge(vector: @axis_lock, axis_locked: !@axis_lock.nil?)
      else values
      end
    end

    def anchor_point
      @anchor_face ? @anchor_face.bounds.center : ORIGIN
    end

    def update_distance(view, x, y)
      ray_origin, ray_direction = view.pickray(x, y)
      axis = drag_axis.transform(@transform).normalize
      origin = anchor_point.transform(@transform)
      w = origin - ray_origin
      a = axis.dot(axis)
      b = axis.dot(ray_direction)
      c = ray_direction.dot(ray_direction)
      d = axis.dot(w)
      e = ray_direction.dot(w)
      denominator = a * c - b * b
      value = if denominator.abs > 1.0e-8
                (b * e - c * d) / denominator
              else
                input = Sketchup::InputPoint.new
                input.pick(view, x, y)
                input.valid? ? (input.position - origin).dot(axis) : @distance.to_f
              end
      return unless value.finite?
      @distance = value.to_l
      refresh_preview
      update_status
    rescue StandardError
      # Keep the last valid inference while the cursor passes an ambiguous area.
    end

    def refresh_preview
      if @distance.to_f.abs < 0.001 || @faces.empty?
        @preview = []
        @analysis = { severity: :ok, message: nil, safe_distance: nil }
      else
        options = effective_options
        @analysis = Geometry.analyze_preview(@faces, @distance, options)
        @preview = Geometry.preview(@faces, @distance, options)
      end
    rescue StandardError => error
      @preview = []
      @analysis = { severity: :error, message: error.message, safe_distance: nil }
    end

    def apply
      return UI.beep if @distance.to_f.abs < 0.001
      if @analysis[:severity] == :error
        UI.messagebox("ZigguratPushPull:\n#{@analysis[:message]}")
        return
      end
      result = Geometry.build(@model, @faces, @distance, effective_options)
      Sketchup.status_text = "Created #{result[:faces].length} faces at #{@distance}. Ctrl+Z to undo."
      @model.select_tool(nil)
    rescue ArgumentError => error
      UI.messagebox("ZigguratPushPull:\n#{error.message}")
    rescue StandardError => error
      UI.messagebox("ZigguratPushPull failed:\n#{error.class}: #{error.message}")
    end

    def component_prepare_proc
      path = @target_instances.dup
      child_indices = path.each_cons(2).map do |parent, child|
        parent.definition.entities.to_a.index(child)
      end
      face_signatures = @faces.map { |face| face_signature(face) }
      lambda do
        instance = path.first
        raise ArgumentError, 'The selected Component path is no longer valid.' unless instance && instance.valid?

        path.each_index do |index|
          instance.make_unique if instance.respond_to?(:make_unique)
          break if index == path.length - 1

          entities = instance.definition.entities
          instance = entities.to_a[child_indices[index]]
          unless instance.is_a?(Sketchup::Group) || instance.is_a?(Sketchup::ComponentInstance)
            raise ArgumentError, 'Could not rebuild the nested Component path after Make Unique.'
          end
        end

        entities = instance.definition.entities
        mapped = face_signatures.map do |signature|
          entities.grep(Sketchup::Face).find { |face| face_signature(face) == signature }
        end
        raise ArgumentError, 'Could not map selected faces after Make Unique.' if mapped.any?(&:nil?)
        @target_instance = instance
        @target_entities = entities
        @faces = mapped
        { entities: entities, faces: mapped }
      end
    end

    def component_target?
      (@target_instances || []).any? { |item| item.is_a?(Sketchup::ComponentInstance) }
    end

    def face_signature(face)
      face.vertices.map do |vertex|
        point = vertex.position
        [point.x.round(6), point.y.round(6), point.z.round(6)]
      end.sort
    end

    def prompt_taper
      return UI.beep unless @mode == :normal || @mode == :extrude
      current = (@options.fetch(:taper, 1.0) * 100.0).round(2)
      answer = UI.inputbox(['Taper of top surface (%)'], [current], 'ZigguratPushPull Taper')
      return unless answer
      percent = answer[0].to_f
      unless percent.between?(0.0, 1000.0)
        UI.messagebox('Taper must be between 0% and 1000%.')
        return
      end
      @options[:taper] = percent / 100.0
      Settings.save(taper_percent: percent)
      refresh_preview
      update_status
      @model.active_view.invalidate
    end

    def reverse_direction
      @distance = -@distance
      refresh_preview
      @model.active_view.invalidate
    end

    def toggle_finish
      @options[:finish] = @options[:finish] == :thicken ? :surface : :thicken
      refresh_preview
      update_status
      @model.active_view.invalidate
    end

    def handle_enter
      case @phase
      when :selecting
        return UI.beep if @faces.empty?
        @anchor_face ||= @faces.max_by(&:area)
        advance_after_face_selection
      when :vector_pick
        use_last_vector
      when :dragging
        apply
      else
        UI.beep
      end
    end

    def handle_escape
      if @phase == :vector_second
        begin_auto_vector
      elsif @phase == :vector_pick || (@phase == :dragging && @mode == :vector)
        @phase = :selecting
        @axis_lock = nil
        @axis_name = nil
        @preview = []
      elsif @phase == :dragging && !@faces.empty?
        @phase = :selecting
        @preview = []
      else
        @model.select_tool(nil)
      end
      update_status
      @model.active_view.invalidate
    end

    def cycle_selection_scope
      index = SCOPES.index(@scope) || 0
      @scope = SCOPES[(index + 1) % SCOPES.length]
      @options[:selection_scope] = @scope
      refresh_hover_faces
    end

    def add_scope_item(menu, scope, label)
      prefix = @scope == scope ? '✓ ' : ''
      menu.add_item("#{prefix}#{label}") do
        @scope = scope
        @options[:selection_scope] = scope
        refresh_hover_faces
        update_status
        @model.active_view.invalidate
      end
    end

    def refresh_hover_faces
      entities = @hover_record ? @hover_record[:entities] : @target_entities
      @hover_faces = @hover_face ? selection_faces(@hover_face, entities) : []
    end

    def draw_face_fill(view, faces, color, transform = @transform)
      return if faces.empty?
      view.drawing_color = color
      faces.first(800).each do |face|
        mesh = face.mesh(0)
        mesh.polygons.each do |indices|
          points = indices.map { |index| mesh.point_at(index.abs).transform(transform) }
          view.draw(GL_POLYGON, points) if points.length >= 3
        end
      end
    end

    def draw_face_edges(view, faces, color, width, transform = @transform)
      edges = faces.flat_map(&:edges).uniq
      return if edges.empty?
      points = edges.flat_map do |edge|
        [edge.start.position.transform(transform), edge.end.position.transform(transform)]
      end
      view.drawing_color = color
      view.line_width = width
      view.line_stipple = ''
      view.draw(GL_LINES, points)
    end

    def draw_vector_picker(view)
      return unless @phase == :vector_pick || @phase == :vector_second
      face_transform = @vector_face_record ? @vector_face_record[:transform] : @transform
      draw_face_fill(view, [@vector_hover_face].compact, VECTOR_PICK_COLOR, face_transform)
      if @hover_edge
        transform = @hover_edge_record ? @hover_edge_record[:transform] : @transform
        draw_edge = [@hover_edge.start.position.transform(transform), @hover_edge.end.position.transform(transform)]
        view.drawing_color = AXIS_COLORS[:edge]
        view.line_width = 7
        view.draw(GL_LINES, draw_edge)
      end
      @input_point.draw(view) if @input_point.valid?
      return unless @phase == :vector_second && @vector_origin && @input_point.valid?
      origin = @vector_origin.transform(@transform)
      target = @input_point.position
      view.drawing_color = AXIS_COLORS[:points]
      view.line_width = 5
      view.draw(GL_LINES, [origin, target])
      view.draw_points([origin, target], 10, 3, AXIS_COLORS[:points])
    end

    def draw_preview(view)
      return if @preview.empty?
      view.line_width = @mode == :normal ? 3 : 2
      view.line_stipple = @mode == :normal ? '.' : '-'
      @preview.first(MAX_PREVIEW_POLYGONS).each_with_index do |polygon, index|
        view.drawing_color = preview_color(index)
        transformed = polygon.map { |point| point.transform(@transform) }
        points = transformed.each_with_index.flat_map do |point, point_index|
          [point, transformed[(point_index + 1) % transformed.length]]
        end
        view.draw(GL_LINES, points)
      end
      view.line_stipple = ''
    end

    def preview_color(index)
      return ERROR_PREVIEW if @analysis[:severity] == :error || @analysis[:severity] == :warning
      case @mode
      when :normal then NORMAL_PREVIEW[index % NORMAL_PREVIEW.length]
      when :vector then VECTOR_PREVIEW
      when :extrude then EXTRUDE_PREVIEW
      else JOINT_PREVIEW
      end
    end

    def draw_direction_indicator(view)
      origin = anchor_point
      bounds = Geom::BoundingBox.new
      @faces.each { |face| face.vertices.each { |vertex| bounds.add(vertex.position) } }
      length = bounds.empty? ? 100.mm.to_f : [bounds.diagonal * 0.22, 100.mm.to_f].max
      vector = drag_axis.clone
      vector.length = length
      tip = origin.offset(vector)
      color = AXIS_COLORS.fetch(@axis_name, AXIS_COLORS[:free])
      view.drawing_color = color
      view.line_width = 5
      view.line_stipple = ''
      view.draw(GL_LINES, [origin.transform(@transform), tip.transform(@transform)])
      view.draw_points([tip.transform(@transform)], 11, 3, color)
    end

    def scope_label
      { face: 'Single Face', surface: 'Smooth Surface', connected: 'All Connected' }.fetch(@scope)
    end

    def axis_label
      return 'Each face normal' if @mode == :normal
      return 'Face Normal' unless @axis_lock
      { red: 'Red axis', green: 'Green axis', blue: 'Blue axis', edge: 'Picked edge',
        face: 'Picked face normal', points: 'Two-point vector', last: 'Last vector' }.fetch(@axis_name, 'Custom vector')
    end

    def mode_label
      { joint: 'Joint Surface', normal: 'Individual Faces', extrude: 'Directional Extrude', vector: 'Free Vector' }.fetch(@mode)
    end

    def update_status
      finish = @options[:finish] == :thicken ? 'Thicken' : 'Offset Surface'
      taper = if @mode == :normal || @mode == :extrude
                " | Taper: #{(@options.fetch(:taper, 1.0) * 100).round}% (T)"
              else
                ''
              end
      target = if @target_instance
                 name = if @target_instance.respond_to?(:definition)
                          @target_instance.name.to_s.empty? ? @target_instance.definition.name : @target_instance.name
                        else
                          @target_instance.typename
                        end
                 behavior = component_target? ? " / #{@options[:component_scope] == :unique ? 'Make Unique' : 'All Instances'}" : ''
                 " | Target: #{name.empty? ? @target_instance.typename : name}#{behavior}"
               else
                 ''
               end
      prompt = case @phase
               when :selecting
                 "#{mode_label}: click to accept | Shift adds, Ctrl+Shift removes | Scope: #{scope_label} (Tab) | #{@faces.length} selected"
               when :vector_pick
                 source = @vector_pick_mode == :two_points ? 'click first point' : 'click Edge, Face, or empty point'
                 "Free Vector: #{source} | V=two points, L=last vector, Arrows=axes"
               when :vector_second
                 'Free Vector: click second point | Esc returns to source selection'
               else
                 "#{mode_label}: #{@faces.length} face(s) | #{finish} | Direction: #{axis_label}#{taper}#{target} | type distance or click"
               end
      prompt = "#{prompt} | #{@analysis[:message]}" if @analysis[:message] && @phase == :dragging
      Sketchup.set_status_text(prompt, SB_PROMPT)
      Sketchup.set_status_text('Distance', SB_VCB_LABEL)
      Sketchup.set_status_text(@distance.to_s, SB_VCB_VALUE)
    end
  end
end
