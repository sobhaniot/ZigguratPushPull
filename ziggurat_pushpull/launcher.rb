# frozen_string_literal: true

require 'json'

module ZigguratPushPull
  module Launcher
    extend self

    WIDTH = 410
    HEIGHT = 610

    def show
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        return
      end

      @dialog = UI::HtmlDialog.new(
        dialog_title: 'ZigguratPushPull — Quick Launcher',
        preferences_key: 'ZigguratPushPullLauncher',
        scrollable: true,
        resizable: true,
        width: WIDTH,
        height: HEIGHT,
        min_width: 360,
        min_height: 500,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      @dialog.set_file(File.join(__dir__, 'launcher.html'))
      @dialog.add_action_callback('ready') { |_context| sync }
      @dialog.add_action_callback('launch') do |_context, json|
        data = JSON.parse(json)
        save_dialog_options(data)
        ZigguratPushPull.activate(data.fetch('mode').to_sym)
      rescue JSON::ParserError, KeyError => error
        UI.messagebox("ZigguratPushPull Launcher:\n#{error.message}")
      end
      @dialog.add_action_callback('save') do |_context, json|
        save_dialog_options(JSON.parse(json))
        sync
      rescue JSON::ParserError => error
        UI.messagebox("ZigguratPushPull Launcher:\n#{error.message}")
      end
      @dialog.set_on_closed { @dialog = nil }
      @dialog.show
    end

    def sync
      return unless @dialog
      values = Settings.load
      payload = {
        finish: values[:finish],
        borders: values[:borders],
        selection_scope: values[:selection_scope],
        soften: values[:soften],
        output_mode: values[:output_mode],
        component_scope: values[:component_scope],
        taper_percent: values[:taper_percent],
        vector_axis: values[:vector_axis]
      }
      @dialog.execute_script("window.setOptions(#{JSON.generate(payload)})")
    end

    private

    def save_dialog_options(data)
      Settings.save(
        finish: data.fetch('finish', 'Thicken'),
        borders: data.fetch('borders', 'Contour'),
        selection_scope: data.fetch('selection_scope', 'Surface'),
        output_mode: data.fetch('output_mode', 'Create New Group'),
        component_scope: data.fetch('component_scope', 'Make Unique'),
        taper_percent: data.fetch('taper_percent', 100).to_f,
        soften: data.fetch('soften', 'Yes'),
        vector_axis: data.fetch('vector_axis', 'Blue (Z)')
      )
    end
  end
end
