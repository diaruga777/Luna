#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds the `LunaWriterTests` unit-test bundle and hands it the Writer package
# links. The bundle hosts on the `LunaWriter` app, so the Writer tier stays out
# of the central app's kit: `LunaKit` carries `LunaWriterModels` and `LunaGaze`
# for the Reader's eye tracking and nothing else from the Writer stack.
# `LunaTests` keeps every non-Vault, non-Writer suite and hosts on `Luna`.
#
# `LunaWriter` is a STATIC client, so the bundle links the same static products
# the app links. Xcode promotes the shared ones to frameworks in a Debug test
# build, exactly as it does for `LunaVaultTests`.
#
# The script is idempotent: it creates what is missing and re-applies the
# settings, the links, the target dependency, the two test plans and the
# `LunaWriter` scheme's Test action on every run.
require_relative "xcodeproj_compat"

PROJECT = File.expand_path("../Luna.xcodeproj", __dir__)
TEST_TARGET = "LunaWriterTests"
UI_TEST_TARGET = "LunaWriterUITests"
HOST_TARGET = "LunaWriter"

# Exactly what the `LunaWriter` app links. The moved suites import the seven
# Writer tiers plus LunaGaze, LunaModels and LunaDesignSystem; everything else
# they reach (LunaStorage, SwiftSoup) arrives as a package-target dependency.
LIBRARY_PRODUCTS = %w[
  LunaDesignSystem
  LunaGaze
  LunaModels
  LunaWriterEditor
  LunaWriterLibraryUI
  LunaWriterModels
  LunaWriterReadAlong
  LunaWriterStorage
  LunaWriterText
  LunaWriterVoice
].freeze

# `LunaWriter.xctestplan` is the scheme's default plan and names the unit
# bundle; `LunaWriterUI.xctestplan` carries the scripted XCUITest driver, which
# is run on demand (`-testPlan LunaWriterUI`) and never as part of the suite.
UNIT_PLAN = "LunaWriter.xctestplan"
UI_PLAN = "LunaWriterUI.xctestplan"
SCHEME = File.expand_path("../Luna.xcodeproj/xcshareddata/xcschemes/LunaWriter.xcscheme", __dir__)
# A test bundle gets no scheme of its own (the rule `LunaVaultTests` follows).
STALE_SCHEME = File.expand_path(
  "../Luna.xcodeproj/xcshareddata/xcschemes/LunaWriterTests.xcscheme", __dir__)

project = Xcodeproj::Project.open(PROJECT)

host = project.native_targets.find { |t| t.name == HOST_TARGET }
abort "Missing #{HOST_TARGET} target" unless host
luna_tests = project.native_targets.find { |t| t.name == "LunaTests" }
abort "Missing LunaTests target" unless luna_tests
ui_tests = project.native_targets.find { |t| t.name == UI_TEST_TARGET }
abort "Missing #{UI_TEST_TARGET} target" unless ui_tests

def local_package(project, name)
  reference = project.objects
                     .select { |object| object.isa == "XCLocalSwiftPackageReference" }
                     .find { |object| object.relative_path.to_s.split("/").last == name }
  abort "Missing local package reference #{name}" unless reference
  reference
end

def package_product(project, package, product_name)
  existing = project.objects.find do |object|
    object.isa == "XCSwiftPackageProductDependency" &&
      object.product_name == product_name && object.package == package
  end
  return existing if existing

  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.package = package
  dependency.product_name = product_name
  dependency
end

def link_product(project, target, package, product_name)
  return if target.package_product_dependencies.any? { |d| d.product_name == product_name }

  # Xcode shares one product-dependency object between the targets that link
  # the same product, so reuse the project's own object when it has one.
  dependency = package_product(project, package, product_name)
  target.package_product_dependencies << dependency

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  target.frameworks_build_phase.files << build_file
end

# Every product here is shared with the `LunaWriter` app, so the dependency
# object outlives this target's link edge. Drop the edge, then prune only the
# objects no target refers to any more.
def prune_orphan_products(project)
  referenced = project.native_targets.flat_map { |t| t.package_product_dependencies.to_a }
  referenced += project.objects
                       .select { |o| o.isa == "PBXBuildFile" }
                       .map(&:product_ref).compact
  orphans = project.objects
                   .select { |o| o.isa == "XCSwiftPackageProductDependency" } - referenced.uniq
  orphans.each(&:remove_from_project)
  orphans.size
end

# Older xcodeproj releases invent brittle iPhoneOS<version> framework
# references when a target is created. Drop them once nothing links them.
def remove_implicit_sdk_framework_links(project, target)
  references = []
  target.frameworks_build_phase.files.dup.each do |build_file|
    reference = build_file.file_ref
    next unless reference&.source_tree == "DEVELOPER_DIR"
    next unless reference.path&.end_with?(".framework")

    references << reference
    build_file.remove_from_project
  end
  references.uniq.each do |reference|
    still_linked = project.objects.any? do |object|
      object.is_a?(Xcodeproj::Project::Object::PBXBuildFile) && object.file_ref == reference
    end
    reference.remove_from_project unless still_linked
  end
end

tests = project.native_targets.find { |t| t.name == TEST_TARGET }
if tests.nil?
  tests = project.new_target(:unit_test_bundle, TEST_TARGET, :ios, "18.0")
  remove_implicit_sdk_framework_links(project, tests)
  puts "created #{TEST_TARGET} (#{tests.uuid})"
else
  puts "#{TEST_TARGET} already exists (#{tests.uuid})"
end

# Clone LunaTests' settings, then re-point the host and the bundle id.
luna_tests.build_configurations.each do |source|
  destination = tests.build_configurations.find { |c| c.name == source.name }
  next unless destination
  destination.build_settings = source.build_settings.dup
  destination.base_configuration_reference = source.base_configuration_reference
  destination.build_settings["TEST_HOST"] =
    "$(BUILT_PRODUCTS_DIR)/#{HOST_TARGET}.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/#{HOST_TARGET}"
  destination.build_settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
  destination.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "$(PRODUCT_BUNDLE_PREFIX).writer.tests"
end

# The sources come from a synchronized root group, the same arrangement
# LunaTests uses: a file added to or removed from `LunaWriterTests/` needs no
# project edit, and the group carries no membership exception.
group = project.objects.find do |object|
  object.isa == "PBXFileSystemSynchronizedRootGroup" && object.path == TEST_TARGET
end
if group.nil?
  group = project.new(Xcodeproj::Project::Object::PBXFileSystemSynchronizedRootGroup)
  group.path = TEST_TARGET
  group.source_tree = "<group>"
  project.main_group.children << group
  puts "created synchronized group #{TEST_TARGET}"
end
unless tests.file_system_synchronized_groups.include?(group)
  tests.file_system_synchronized_groups << group
end

LIBRARY_PRODUCTS.each { |name| link_product(project, tests, local_package(project, "LunaLibraries"), name) }

tests.add_dependency(host) unless tests.dependencies.any? { |d| d.target == host }

pruned = prune_orphan_products(project)
project.save

# ------------------------------------------------------------- test plans
def write_plan(path, configuration_id, configuration_name, target_name, target_uuid)
  body = <<~JSON
    {
      "configurations" : [
        {
          "options" : {
            "performanceMetrics" : [ ]
          },
          "id" : "#{configuration_id}",
          "name" : "#{configuration_name}"
        }
      ],
      "defaultOptions" : {
        "testTimeoutsEnabled" : true
      },
      "testTargets" : [
        {
          "parallelizable" : false,
          "target" : {
            "containerPath" : "container:Luna.xcodeproj",
            "identifier" : "#{target_uuid}",
            "name" : "#{target_name}"
          }
        }
      ],
      "version" : 1
    }
  JSON
  return :unchanged if File.exist?(path) && File.read(path) == body

  File.write(path, body)
  :written
end

unit_plan_path = File.expand_path("../#{UNIT_PLAN}", __dir__)
ui_plan_path = File.expand_path("../#{UI_PLAN}", __dir__)
puts "#{UNIT_PLAN}: #{write_plan(unit_plan_path, '5C570000-0000-4000-8000-0000000000A1',
                                 'Luna Writer', TEST_TARGET, tests.uuid)}"
puts "#{UI_PLAN}: #{write_plan(ui_plan_path, '5C570000-0000-4000-8000-0000000000A2',
                               'Luna Writer UI driver', UI_TEST_TARGET, ui_tests.uuid)}"

# ------------------------------------------------------------- the scheme
# The Test action runs the two plans, so the scheme lists no testable of its
# own. `keepNever` on both attachment lifetimes matches the `Luna` and
# `LunaVault` schemes.
TEST_ACTION = <<~XML.chomp
     <TestAction
        buildConfiguration = "Debug"
        selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
        selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
        shouldUseLaunchSchemeArgsEnv = "YES"
        systemAttachmentLifetime = "keepNever"
        userAttachmentLifetime = "keepNever"
        shouldAutocreateTestPlan = "NO">
        <TestPlans>
           <TestPlanReference
              reference = "container:#{UNIT_PLAN}"
              default = "YES">
           </TestPlanReference>
           <TestPlanReference
              reference = "container:#{UI_PLAN}">
           </TestPlanReference>
        </TestPlans>
     </TestAction>
XML

scheme = File.read(SCHEME)
updated = scheme.sub(%r{^ {3}<TestAction\b.*?^ {3}</TestAction>}m, TEST_ACTION)
abort "Could not find the TestAction block in #{SCHEME}" if updated == scheme && !scheme.include?(TEST_ACTION)
if updated == scheme
  puts "LunaWriter.xcscheme: already runs the two plans"
else
  File.write(SCHEME, updated)
  puts "LunaWriter.xcscheme: Test action now runs #{UNIT_PLAN} + #{UI_PLAN}"
end

if File.exist?(STALE_SCHEME)
  File.delete(STALE_SCHEME)
  puts "deleted LunaWriterTests.xcscheme — a test bundle gets no scheme"
end

puts "#{TEST_TARGET} links: #{tests.package_product_dependencies.map(&:product_name).sort.join(', ')}"
puts "LunaTests links: #{luna_tests.package_product_dependencies.map(&:product_name).sort.join(', ')}"
puts "pruned #{pruned} unreferenced package product dependencies"
