#!/usr/bin/env ruby
# One-shot: wire the local package product `LunaURLRescue` into the Xcode targets
# that need it — the three app targets (Luna / LunaDownloader / LunaPriceTracker),
# which import it via Luna/URLRescueWiring.swift, and LunaTests, which
# `@testable import`s the engine. Idempotent per target.
require 'xcodeproj'

PRODUCT = 'LunaURLRescue'
PACKAGE = 'LunaLibraries'
APP_TARGETS  = %w[Luna LunaDownloader LunaPriceTracker]
TEST_TARGETS = %w[LunaTests]

proj = Xcodeproj::Project.open('Luna.xcodeproj')

pkg = proj.root_object.package_references.find do |ref|
  ref.respond_to?(:relative_path) ? ref.relative_path == PACKAGE || ref.relative_path&.end_with?(PACKAGE) : false
end
# Local packages are XCLocalSwiftPackageReference; match by any reference whose
# products already include a Luna* target.
pkg ||= proj.root_object.package_references.first

(APP_TARGETS + TEST_TARGETS).each do |name|
  target = proj.targets.find { |t| t.name == name }
  unless target
    puts "! target #{name} not found — skipping"
    next
  end
  already = target.package_product_dependencies.any? { |d| d.product_name == PRODUCT }
  if already
    puts "= #{name} already links #{PRODUCT}"
    next
  end
  target.add_swift_package_product(pkg, PRODUCT, true) if pkg.is_a?(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  # For local packages, build the product dependency + build file manually.
  dep = proj.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = PRODUCT
  dep.package = pkg if pkg
  target.package_product_dependencies << dep

  build_file = proj.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dep
  frameworks = target.frameworks_build_phase
  frameworks.files << build_file
  puts "+ #{name} now links #{PRODUCT}"
end

proj.save
puts 'saved'
