#!/usr/bin/env ruby
# frozen_string_literal: true

# Puts the one strings file into the app (and widget) bundles as well.
#
# Everything Luna draws resolves through `L10n`, which reads LunaModels'
# resource bundle — that copy arrives automatically with the package. App
# Intents metadata cannot: Xcode bakes those literals in at build time and
# resolves them against the HOST bundle at runtime, so an intent title only
# becomes editable if the same table is present there too.
#
# Rather than keep a second file in step by hand, the app targets copy the one
# file. Re-run after adding an app or widget target; it is idempotent.

require 'xcodeproj'

PROJECT = File.expand_path('../Luna.xcodeproj', __dir__)
STRINGS = 'LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings'

# Every target that hosts App Intents and so needs the table in its own bundle.
HOSTS = %w[
  Luna LunaReader LunaDownloader LunaPriceTracker
  LunaLiveActivity LunaDownloaderLiveActivity
].freeze

project = Xcodeproj::Project.open(PROJECT)

ref = project.files.find { |f| f.path == STRINGS }
unless ref
  ref = project.new(Xcodeproj::Project::Object::PBXFileReference)
  ref.path = STRINGS
  ref.source_tree = 'SOURCE_ROOT'
  ref.last_known_file_type = 'text.plist.strings'
  ref.name = 'Localizable.strings'
  project.main_group << ref
  puts "added file reference #{STRINGS}"
end

changed = false
HOSTS.each do |name|
  target = project.targets.find { |t| t.name == name }
  unless target
    warn "!! no target named #{name} — skipping"
    next
  end
  phase = target.resources_build_phase
  if phase.files_references.include?(ref)
    puts "#{name}: already present"
  else
    phase.add_file_reference(ref)
    changed = true
    puts "#{name}: added to Resources"
  end
end

project.save if changed || ref
puts changed ? 'project saved' : 'no target changes needed'
