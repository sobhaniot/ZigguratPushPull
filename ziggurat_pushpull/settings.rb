# frozen_string_literal: true

module ZigguratPushPull
  module Settings
    extend self

    DICTIONARY = 'ZigguratPushPull'
    DEFAULTS = {
      finish: 'Thicken',
      borders: 'Contour',
      selection_scope: 'Surface',
      soften: 'Yes',
      result_group: 'Yes',
      output_mode: 'Create New Group',
      component_scope: 'Make Unique',
      taper_percent: 100.0,
      vector_axis: 'Blue (Z)',
      last_vector: '0.0,0.0,1.0'
    }.freeze

    def load
      DEFAULTS.each_with_object({}) do |(key, fallback), values|
        values[key] = Sketchup.read_default(DICTIONARY, key.to_s, fallback)
      end
    end

    def prompt
      current = load
      prompts = [
        'Finish', 'Side borders', 'Click selection', 'Output mode',
        'Component behavior', 'Taper (%)', 'Soften generated edges', 'Vector direction'
      ]
      defaults = [
        current[:finish], current[:borders], current[:selection_scope], current[:output_mode],
        current[:component_scope], current[:taper_percent], current[:soften], current[:vector_axis]
      ]
      lists = [
        'Thicken|Offset surface', 'Contour|Grid|None', 'Surface|All connected|Single face',
        'Create New Group|Modify Original', 'Make Unique|All Instances', '',
        'Yes|No', 'Red (X)|Green (Y)|Blue (Z)'
      ]
      answer = UI.inputbox(prompts, defaults, lists, 'ZigguratPushPull Options')
      return nil unless answer

      result = {
        finish: answer[0], borders: answer[1], selection_scope: answer[2], output_mode: answer[3],
        component_scope: answer[4], taper_percent: answer[5].to_f, soften: answer[6], vector_axis: answer[7]
      }
      result.each { |key, value| Sketchup.write_default(DICTIONARY, key.to_s, value) }
      result
    end

    def save(values)
      values.each { |key, value| Sketchup.write_default(DICTIONARY, key.to_s, value) }
      load
    end

    def engine_options(overrides = {})
      values = load
      {
        finish: values[:finish] == 'Thicken' ? :thicken : :surface,
        borders: values[:borders].downcase.to_sym,
        selection_scope: selection_scope_for(values[:selection_scope]),
        soften: values[:soften] == 'Yes',
        result_group: values[:output_mode] != 'Modify Original',
        output_mode: values[:output_mode] == 'Modify Original' ? :modify : :group,
        component_scope: values[:component_scope] == 'All Instances' ? :all : :unique,
        taper: [[values[:taper_percent].to_f / 100.0, 0.0].max, 10.0].min,
        vector: vector_for(values[:vector_axis])
      }.merge(overrides)
    end

    def vector_for(name)
      case name
      when 'Red (X)' then Geom::Vector3d.new(1, 0, 0)
      when 'Green (Y)' then Geom::Vector3d.new(0, 1, 0)
      else Geom::Vector3d.new(0, 0, 1)
      end
    end

    def selection_scope_for(name)
      case name
      when 'All connected' then :connected
      when 'Single face' then :face
      else :surface
      end
    end

    def last_vector
      parts = load[:last_vector].to_s.split(',').map(&:to_f)
      vector = parts.length == 3 ? Geom::Vector3d.new(*parts) : Z_AXIS.clone
      vector.length > 1.0e-9 ? vector.normalize : Z_AXIS.clone
    end

    def store_last_vector(vector)
      return if vector.nil? || vector.length < 1.0e-9
      normalized = vector.normalize
      save(last_vector: [normalized.x, normalized.y, normalized.z].join(','))
      normalized
    end
  end
end
