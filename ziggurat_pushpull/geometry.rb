# frozen_string_literal: true

module ZigguratPushPull
  module Geometry
    extend self

    EPSILON = 1.0e-9
    REGULARIZATION = 1.0e-8

    def build(model, faces, distance, options = {})
      mode = options.fetch(:mode, :joint)
      model.start_operation('ZigguratPushPull', true)
      begin
        context = options[:source_entities] || model.active_entities
        if options[:prepare_context]
          prepared = options[:prepare_context].call
          faces = prepared.fetch(:faces)
          context = prepared.fetch(:entities)
        end
        validate_faces!(context, faces)
        validate_direction!(faces, mode, options)
        destination = options.fetch(:result_group, true) ? context.add_group : nil
        destination.name = result_name(mode, distance) if destination
        entities = destination ? destination.entities : context
        result = case mode
                 when :normal then build_normal(entities, faces, distance, options)
                 when :vector, :extrude then build_joined(entities, faces, distance, options, :vector)
                 else
                   offset_mode = options[:axis_locked] ? :vector : :joint
                   build_joined(entities, faces, distance, options, offset_mode)
                 end
        soften_generated_edges(entities) if options.fetch(:soften, true)
        validate_generated_group!(destination, mode, options) if destination
        result[:edges] = destination ? destination.entities.grep(Sketchup::Edge).length : nil
        result[:open_edges] = if destination
                                destination.entities.grep(Sketchup::Edge).count { |edge| edge.faces.length != 2 }
                              end
        model.commit_operation
        if destination && model.active_entities.include?(destination)
          model.selection.clear
          model.selection.add(destination)
        elsif !destination && context == model.active_entities
          model.selection.clear
          model.selection.add(result[:faces])
        end
        result.merge(group: destination, distance: distance, mode: mode)
      rescue StandardError
        model.abort_operation
        raise
      end
    end

    def preview(faces, distance, options = {})
      mode = options.fetch(:mode, :joint)
      if mode == :normal
        faces.flat_map do |face|
          map = face.vertices.each_with_object({}) do |vertex, values|
            values[vertex] = vertex.position.offset(face.normal, distance)
          end
          apply_face_taper!(face, map, options.fetch(:taper, 1.0))
          preview_polygons_for_face(face, map, true)
        end
      else
        offset_mode = if mode == :vector || mode == :extrude || options[:axis_locked]
                        :vector
                      else
                        :joint
                      end
        map = joined_points(faces, distance, offset_mode, options[:vector], taper_for(mode, options))
        faces.flat_map { |face| preview_polygons_for_face(face, map, boundary_only?(options)) }
      end
    end

    def joined_points(faces, distance, mode = :joint, vector = nil, taper = 1.0)
      vertices = faces.flat_map(&:vertices).uniq
      if mode == :vector
        points = vector_points(vertices, distance, vector)
        apply_collective_taper!(vertices, points, vector, distance, taper)
        return points
      end

      selected = faces.each_with_object({}) { |face, hash| hash[face] = true }
      vertices.each_with_object({}) do |vertex, points|
        incident = vertex.faces.select { |face| selected[face] }
        points[vertex] = joint_offset_point(vertex.position, incident, distance)
      end
    end

    def analyze_preview(faces, distance, options = {})
      mode = options.fetch(:mode, :joint)
      analysis = { severity: :ok, message: nil, safe_distance: nil }
      if options.fetch(:finish, :thicken) == :thicken && directional_mode?(mode, options)
        vector = options[:vector]
        if vector.nil? || vector.length < EPSILON
          return analysis.merge(severity: :error, message: 'Choose a valid direction.')
        end
        direction = vector.normalize
        unless faces.any? { |face| face.normal.dot(direction).abs > 1.0e-6 }
          return analysis.merge(severity: :error, message: 'Direction is tangent to the selected surface.')
        end
      end
      return analysis unless mode == :joint && faces.length > 1 && !options[:axis_locked]

      selected = faces.each_with_object({}) { |face, hash| hash[face] = true }
      shared = faces.flat_map(&:edges).uniq.select { |edge| edge.faces.count { |face| selected[face] } == 2 }
      angles = shared.map do |edge|
        pair = edge.faces.select { |face| selected[face] }
        pair[0].normal.angle_between(pair[1].normal)
      end
      bent_angles = angles.select { |angle| angle > 1.0e-4 }
      return analysis if bent_angles.empty?
      minimum_edge = faces.flat_map(&:edges).map(&:length).min.to_f
      factor = [Math.sin(bent_angles.max / 2.0).abs, 0.15].max
      safe = minimum_edge * 0.45 / factor
      analysis[:safe_distance] = safe.to_l
      if distance.to_f.abs > safe
        analysis[:severity] = :warning
        analysis[:message] = "Possible overlap; suggested maximum is #{safe.to_l}."
      end
      analysis
    end

    def joint_offset_point(position, faces, distance)
      matrix = Array.new(3) { Array.new(3, 0.0) }
      rhs = [0.0, 0.0, 0.0]
      faces.each do |face|
        normal = face.normal.normalize
        components = [normal.x, normal.y, normal.z]
        3.times do |row|
          rhs[row] += components[row] * distance.to_f
          3.times { |column| matrix[row][column] += components[row] * components[column] }
        end
      end
      3.times { |index| matrix[index][index] += REGULARIZATION }
      displacement = solve_3x3(matrix, rhs)
      Geom::Point3d.new(
        position.x + displacement[0],
        position.y + displacement[1],
        position.z + displacement[2]
      )
    end

    def solve_3x3(matrix, rhs)
      augmented = matrix.each_with_index.map { |row, index| row.dup << rhs[index] }
      3.times do |column|
        pivot = (column...3).max_by { |row| augmented[row][column].abs }
        raise ArgumentError, 'The selected surface cannot be offset at one or more vertices.' if augmented[pivot][column].abs < EPSILON

        augmented[column], augmented[pivot] = augmented[pivot], augmented[column] if pivot != column
        divisor = augmented[column][column]
        (column..3).each { |item| augmented[column][item] /= divisor }
        3.times do |row|
          next if row == column
          factor = augmented[row][column]
          (column..3).each { |item| augmented[row][item] -= factor * augmented[column][item] }
        end
      end
      augmented.map { |row| row[3] }
    end

    private

    def validate_faces!(entities, faces)
      raise ArgumentError, 'Select at least one face.' if faces.empty?
      raise ArgumentError, 'All faces must belong to the same editing context.' unless faces.all? { |face| face.valid? && entities.include?(face) }
    end

    def validate_direction!(faces, mode, options)
      return unless options.fetch(:finish, :thicken) == :thicken
      directional = directional_mode?(mode, options)
      return unless directional
      vector = options[:vector]
      raise ArgumentError, 'Choose a valid extrusion direction.' unless vector && vector.length > EPSILON
      direction = vector.normalize
      usable = faces.any? { |face| face.normal.dot(direction).abs > 1.0e-6 }
      raise ArgumentError, 'The direction is tangent to the entire selection and cannot create thickness.' unless usable
    end

    def directional_mode?(mode, options)
      mode == :vector || mode == :extrude || (mode == :joint && options[:axis_locked])
    end

    def validate_generated_group!(group, mode, options)
      return unless options.fetch(:finish, :thicken) == :thicken
      return if mode == :normal
      edges = group.entities.grep(Sketchup::Edge)
      open_edges = edges.count { |edge| edge.faces.length != 2 }
      raise ArgumentError, "The result would contain #{open_edges} open or non-manifold edges." if open_edges.positive?
      if group.respond_to?(:manifold?) && !group.manifold?
        raise ArgumentError, 'The result would not be a manifold solid. Try a shorter distance or another direction.'
      end
      volume = group.volume rescue nil
      if volume && volume.to_f <= EPSILON
        raise ArgumentError, 'The result has zero volume, usually because of overlap or self-intersection.'
      end
    end

    def result_name(mode, distance)
      "Ziggurat #{mode.to_s.capitalize} PushPull #{distance.to_l}"
    end

    def vector_points(vertices, distance, vector)
      direction = vector || Z_AXIS
      raise ArgumentError, 'Vector direction cannot be zero.' if direction.length < EPSILON
      offset = direction.normalize
      offset.length = distance.to_f.abs
      offset.reverse! if distance.to_f.negative?
      vertices.each_with_object({}) { |vertex, points| points[vertex] = vertex.position.offset(offset) }
    end

    def build_joined(entities, faces, distance, options, mode)
      point_map = joined_points(faces, distance, mode, options[:vector], taper_for(options.fetch(:mode, mode), options))
      created = []
      if options.fetch(:finish, :thicken) == :thicken && !options[:modify_original]
        faces.each { |face| created.concat(add_face_with_holes(entities, face, nil, true)) }
      end
      faces.each { |face| created.concat(add_face_with_holes(entities, face, point_map, false)) }
      created.concat(add_joined_borders(entities, faces, point_map, options))
      erase_original_faces(faces, options)
      { faces: created.grep(Sketchup::Face), vertices: point_map.length }
    end

    def build_normal(entities, faces, distance, options)
      created = []
      faces.each do |face|
        point_map = face.vertices.each_with_object({}) do |vertex, values|
          values[vertex] = vertex.position.offset(face.normal, distance)
        end
        apply_face_taper!(face, point_map, options.fetch(:taper, 1.0))
        if options.fetch(:finish, :thicken) == :thicken && !options[:modify_original]
          created.concat(add_face_with_holes(entities, face, nil, true))
        end
        created.concat(add_face_with_holes(entities, face, point_map, false))
        created.concat(add_face_borders(entities, face, point_map, options))
      end
      erase_original_faces(faces, options)
      { faces: created.grep(Sketchup::Face), vertices: faces.sum { |face| face.vertices.length } }
    end

    def taper_for(mode, options)
      (mode == :extrude || mode == :normal) ? options.fetch(:taper, 1.0).to_f : 1.0
    end

    def apply_face_taper!(face, point_map, taper)
      return point_map if (taper.to_f - 1.0).abs < EPSILON
      vertices = face.vertices
      center_vertices = face.outer_loop.vertices
      center = average_point(center_vertices.map { |vertex| point_map.fetch(vertex) })
      axis = face.normal.normalize
      vertices.each do |vertex|
        point_map[vertex] = scale_point_perpendicular(point_map.fetch(vertex), center, axis, taper)
      end
      point_map
    end

    def apply_collective_taper!(vertices, point_map, vector, distance, taper)
      return point_map if (taper.to_f - 1.0).abs < EPSILON
      axis = vector.normalize
      source_center = average_point(vertices.map(&:position))
      offset = axis.clone
      offset.length = distance.to_f.abs
      offset.reverse! if distance.to_f.negative?
      target_center = source_center.offset(offset)
      vertices.each do |vertex|
        point_map[vertex] = scale_point_perpendicular(point_map.fetch(vertex), target_center, axis, taper)
      end
      point_map
    end

    def average_point(points)
      count = points.length.to_f
      Geom::Point3d.new(
        points.sum(&:x) / count,
        points.sum(&:y) / count,
        points.sum(&:z) / count
      )
    end

    def scale_point_perpendicular(point, center, axis, taper)
      delta = point - center
      along = delta.dot(axis)
      parallel = Geom::Vector3d.new(axis.x * along, axis.y * along, axis.z * along)
      perpendicular = delta - parallel
      scaled = Geom::Vector3d.new(
        parallel.x + perpendicular.x * taper.to_f,
        parallel.y + perpendicular.y * taper.to_f,
        parallel.z + perpendicular.z * taper.to_f
      )
      center.offset(scaled)
    end

    def erase_original_faces(faces, options)
      return unless options[:modify_original] && options.fetch(:finish, :thicken) == :surface
      faces.each { |face| face.erase! if face.valid? }
    end

    def add_face_with_holes(entities, source, point_map, reverse)
      loops = source.loops
      outer = loops.find(&:outer?)
      outer_points = loop_points(outer, point_map)
      outer_points.reverse! if reverse
      face = entities.add_face(outer_points)
      return [] unless face
      copy_materials(source, face, reverse)
      created = [face]

      loops.reject(&:outer?).each do |inner|
        points = loop_points(inner, point_map)
        points.reverse! if reverse
        ring = entities.add_edges(*(points + [points.first]))
        hole_face = ring.flat_map(&:faces).uniq.find do |candidate|
          candidate.valid? && ring.all? { |edge| candidate.outer_loop.edges.include?(edge) }
        end
        hole_face.erase! if hole_face && hole_face.valid?
      end
      created.select(&:valid?)
    end

    def add_joined_borders(entities, faces, point_map, options)
      return [] if options.fetch(:borders, :contour) == :none
      selected = faces.each_with_object({}) { |face, hash| hash[face] = true }
      edges = faces.flat_map(&:edges).uniq
      edges.select! { |edge| edge.faces.count { |face| selected[face] } == 1 } if options.fetch(:borders, :contour) == :contour
      edges.flat_map { |edge| add_border_faces(entities, edge, point_map, edge.faces.find { |face| selected[face] }) }
    end

    def add_face_borders(entities, face, point_map, options)
      return [] if options.fetch(:borders, :contour) == :none
      face.loops.flat_map(&:edges).uniq.flat_map { |edge| add_border_faces(entities, edge, point_map, face) }
    end

    def add_border_faces(entities, edge, point_map, source_face)
      a = edge.start.position
      b = edge.end.position
      c = point_map[edge.end]
      d = point_map[edge.start]
      return [] unless c && d

      faces = begin
        [entities.add_face(a, b, c, d)].compact
      rescue ArgumentError
        [[a, b, c], [a, c, d]].filter_map do |points|
          next unless triangle_has_area?(points)
          begin
            entities.add_face(points)
          rescue ArgumentError
            nil
          end
        end
      end
      faces.each do |face|
        face.material = source_face.material
        face.back_material = source_face.back_material
      end
      faces
    end

    def triangle_has_area?(points)
      (points[1] - points[0]).cross(points[2] - points[0]).length > EPSILON
    end

    def loop_points(loop, point_map)
      loop.vertices.map { |vertex| point_map ? point_map.fetch(vertex) : vertex.position }
    end

    def copy_materials(source, destination, reversed)
      if reversed
        destination.material = source.back_material
        destination.back_material = source.material
      else
        destination.material = source.material
        destination.back_material = source.back_material
      end
    end

    def preview_polygons_for_face(face, point_map, include_borders)
      polygons = face.loops.map { |loop| loop_points(loop, point_map) }
      return polygons unless include_borders
      face.loops.each do |loop|
        loop.edges.each do |edge|
          polygons << [edge.start.position, edge.end.position, point_map[edge.end], point_map[edge.start]]
        end
      end
      polygons
    end

    def boundary_only?(options)
      options.fetch(:borders, :contour) != :none
    end

    def soften_generated_edges(entities)
      entities.grep(Sketchup::Edge).each do |edge|
        next unless edge.faces.length == 2
        angle = edge.faces[0].normal.angle_between(edge.faces[1].normal)
        next unless angle < 30.degrees
        edge.soft = true
        edge.smooth = true
      end
    end
  end
end
