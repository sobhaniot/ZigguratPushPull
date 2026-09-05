# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module ZigguratPushPull
  EXTENSION_NAME = 'ZigguratPushPull'
  EXTENSION_VERSION = '0.5.0'
  LOADER_PATH = File.join(__dir__, 'ziggurat_pushpull', 'main')

  unless file_loaded?(__FILE__)
    extension = SketchupExtension.new(EXTENSION_NAME, LOADER_PATH)
    extension.description = 'Interactive multi-face offset, taper and thickening tools with nested component support.'
    extension.version = EXTENSION_VERSION
    extension.creator = 'Ziggurat'
    extension.copyright = 'Copyright 2026'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
