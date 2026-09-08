#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds the `LunaVaultTests` unit-test bundle and hands it the Vault package
# links. The bundle hosts on the `LunaVault` app, so the Vault tier and the
# second local package (`LunaVaultTailscale/`) stay out of the central app's
# link set. `LunaTests` keeps every non-Vault suite and hosts on `Luna`.
#
# The script is idempotent: it creates what is missing and re-applies the
# settings, the links and the target dependency on every run.
require_relative "xcodeproj_compat"

PROJECT = File.expand_path("../Luna.xcodeproj", __dir__)
TEST_TARGET = "LunaVaultTests"
HOST_TARGET = "LunaVault"

# The Vault products the 18 Vault suites need. Everything else they import
# (LunaVaultModels/Crypto/Storage/Backend/Sync/Embeddings/IndexExtraction,
# TailscaleKit) arrives as a package-target dependency of one of these.
LIBRARY_PRODUCTS = %w[
  LunaVaultMac
  LunaVaultSearch
  LunaVaultSetup
  LunaVaultUI
  VaultTestKit
].freeze
TAILSCALE_PRODUCTS = %w[LunaVaultTailscale].freeze

# The three Vault plans name the bundle by target UUID, so the script that
# owns the target keeps them pointing at it.
TEST_PLANS = %w[LunaVault.xctestplan LunaVaultPerformance.xctestplan LunaVaultStage5.xctestplan].freeze

project = Xcodeproj::Project.open(PROJECT)

host = project.native_targets.find { |t| t.name == HOST_TARGET }
abort "Missing #{HOST_TARGET} target" unless host
luna_tests = project.native_targets.find { |t| t.name == "LunaTests" }
abort "Missing LunaTests target" unless luna_tests

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

# `LunaVaultSearch`, `LunaVaultSetup` and `LunaVaultUI` share one dependency
# object with the LunaVault app, so the object survives while another target
# still lists it; only the link edge goes.
def unlink_product(project, target, product_name)
  target.frameworks_build_phase.files.dup.each do |build_file|
    next unless build_file.product_ref&.product_name == product_name
    target.frameworks_build_phase.remove_build_file(build_file)
  end
  target.package_product_dependencies.dup.each do |dependency|
    next unless dependency.product_name == product_name
    target.package_product_dependencies.delete(dependency)
    still_used = project.native_targets.any? do |other|
      other.package_product_dependencies.include?(dependency)
    end
    dependency.remove_from_project unless still_used
  end
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
  destination.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "$(PRODUCT_BUNDLE_PREFIX).vault.tests"
end

# The sources come from a synchronized root group, the same arrangement
# LunaTests uses: a file added to or removed from `LunaVaultTests/` needs no
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
TAILSCALE_PRODUCTS.each { |name| link_product(project, tests, local_package(project, "LunaVaultTailscale"), name) }

(LIBRARY_PRODUCTS + TAILSCALE_PRODUCTS).each { |name| unlink_product(project, luna_tests, name) }

tests.add_dependency(host) unless tests.dependencies.any? { |d| d.target == host }

project.save

TEST_PLANS.each do |name|
  path = File.expand_path("../#{name}", __dir__)
  abort "Missing test plan #{name}" unless File.exist?(path)
  body = File.read(path)
  updated = body
            .gsub(/"identifier" : "[0-9A-Fa-f]+"/, %("identifier" : "#{tests.uuid}"))
            .gsub(/"name" : "LunaTests"/, %("name" : "#{TEST_TARGET}"))
  next if updated == body

  File.write(path, updated)
  puts "retargeted #{name} at #{TEST_TARGET}"
end

puts "#{TEST_TARGET} links: #{tests.package_product_dependencies.map(&:product_name).sort.join(', ')}"
puts "LunaTests links #{luna_tests.package_product_dependencies.size} products"
