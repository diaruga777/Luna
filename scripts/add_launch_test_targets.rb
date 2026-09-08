#!/usr/bin/env ruby
# Add the two cold-launch UI-test targets, cloned from LunaWriterUITests.
#
#   LunaLaunchTests        TEST_TARGET_NAME = Luna
#   LunaReaderLaunchTests  TEST_TARGET_NAME = LunaReader
#
# Both compile the single file in LunaLaunchTests/. Each target needs its OWN
# PBXBuildFile for that file reference: a target with an empty Sources phase
# builds but cannot be installed by the test-variant graph.
#
# Run from the repository root:
#   ruby -r ./scripts/xcodeproj_compat.rb <this file>

PROJECT = File.expand_path("Luna.xcodeproj", Dir.pwd)
project = Xcodeproj::Project.open(PROJECT)

template = project.targets.find { |t| t.name == "LunaWriterUITests" }
raise "LunaWriterUITests is missing — it is the template" unless template

# ------------------------------------------------------------------ sources
group = project.main_group.children.find { |c| c.display_name == "LunaLaunchTests" }
group ||= project.main_group.new_group("LunaLaunchTests", "LunaLaunchTests")
source_name = "LaunchPerformanceTests.swift"
file_ref = group.files.find { |f| f.path == source_name }
file_ref ||= group.new_reference(source_name)

NEW_TARGETS = {
  "LunaLaunchTests" => { host: "Luna", bundle_id: "$(PRODUCT_BUNDLE_PREFIX).launchtests" },
  "LunaReaderLaunchTests" => { host: "LunaReader", bundle_id: "$(PRODUCT_BUNDLE_PREFIX).reader.launchtests" },
}

NEW_TARGETS.each do |name, spec|
  if project.targets.any? { |t| t.name == name }
    puts "#{name}: already present, skipping"
    next
  end

  host = project.targets.find { |t| t.name == spec[:host] }
  raise "host target #{spec[:host]} is missing" unless host

  target = project.new_target(:ui_test_bundle, name, :ios, nil, project.products_group, :swift)

  # new_target seeds a Foundation.framework link against a hardcoded
  # iPhoneOS14.0 SDK path. The template links nothing; match it.
  target.frameworks_build_phase.clear

  # Clone the template's settings verbatim, then re-point the two that identify
  # this target. Replace the seeded defaults wholesale so the three UI-test
  # bundles cannot drift apart.
  target.build_configurations.each do |config|
    source = template.build_configurations.find { |c| c.name == config.name }
    raise "template has no #{config.name} configuration" unless source
    config.build_settings = source.build_settings.dup
    config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = spec[:bundle_id]
    config.build_settings["TEST_TARGET_NAME"] = spec[:host]
    config.base_configuration_reference = source.base_configuration_reference
  end

  target.source_build_phase.add_file_reference(file_ref)
  target.add_dependency(host)

  puts "#{name}: host=#{spec[:host]} sources=#{target.source_build_phase.files.count} " \
       "frameworks=#{target.frameworks_build_phase.files.count} " \
       "phases=#{target.build_phases.map { |p| p.class.name.split('::').last }.join(',')}"
end

project.save
puts "saved #{PROJECT}"
