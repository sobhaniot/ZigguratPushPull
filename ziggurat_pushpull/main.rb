# frozen_string_literal: true

require 'sketchup.rb'
require_relative 'settings'
require_relative 'geometry'
require_relative 'tool'
require_relative 'launcher'

module ZigguratPushPull
  EXTENSION_NAME = 'ZigguratPushPull' unless const_defined?(:EXTENSION_NAME)
  EXTENSION_VERSION = '0.5.0' unless const_defined?(:EXTENSION_VERSION)

  def self.activate(mode)
    options = Settings.engine_options(mode: mode)
    Sketchup.active_model.select_tool(Tool.new(Sketchup.active_model, mode, options))
  end

  def self.command(title, icon, tooltip, &block)
    item = UI::Command.new(title, &block)
    path = File.join(__dir__, 'icons', icon)
    item.small_icon = path
    item.large_icon = path
    item.tooltip = tooltip
    item.status_bar_text = tooltip
    item
  end

  def self.about
    UI.messagebox(
      "ZigguratPushPull #{EXTENSION_VERSION}\n\n" \
      "Independent multi-face offset, taper and thickening extension.\n" \
      "Modes: Joint Surface, Individual Faces, Directional Extrude and Free Vector.\n" \
      "Supports nested Groups/Components and safe-distance preview warnings.\n\n" \
      "An independent multi-face modeling extension for SketchUp."
    )
  end

  unless file_loaded?(__FILE__)
    joint = command('Joint Surface', 'joint.svg', 'Offset a surface while keeping all selected faces joined.') { activate(:joint) }
    normal = command('Individual Faces', 'normal.svg', 'Offset every selected face independently along its own normal.') { activate(:normal) }
    extrude = command('Directional Extrude', 'extrude.svg', 'Extrude the selected surface without changing its overall shape.') { activate(:extrude) }
    vector = command('Free Vector', 'vector.svg', 'Pick a direction from an edge, face normal, two points or the last vector.') { activate(:vector) }
    launcher = command('Quick Launcher', 'launcher.svg', 'Open the ZigguratPushPull tool and settings panel.') { Launcher.show }

    menu = UI.menu('Extensions').add_submenu(EXTENSION_NAME)
    menu.add_item(joint)
    menu.add_item(normal)
    menu.add_item(extrude)
    menu.add_item(vector)
    menu.add_separator
    menu.add_item(launcher)
    menu.add_item('Options...') { Settings.prompt }
    menu.add_item('About') { about }

    UI.add_context_menu_handler do |context_menu|
      next if Sketchup.active_model.selection.grep(Sketchup::Face).empty?
      submenu = context_menu.add_submenu(EXTENSION_NAME)
      submenu.add_item(joint)
      submenu.add_item(normal)
      submenu.add_item(extrude)
      submenu.add_item(vector)
    end

    toolbar = UI::Toolbar.new(EXTENSION_NAME)
    [joint, normal, extrude, vector, launcher].each { |item| toolbar.add_item(item) }
    toolbar.restore
    file_loaded(__FILE__)
  end
end
