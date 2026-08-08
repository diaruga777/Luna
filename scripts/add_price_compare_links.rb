#!/usr/bin/env ruby
# Links the `LunaPriceCompare` package product into every target that needs it:
# the two product-handling apps, their share/action extensions, ALL FOUR Safari
# appexes (the constrained fan-out runs there), and the test bundle.
#
# Idempotent — a target that already links the product is skipped, so this can be
# re-run after adding an app target.
require 'xcodeproj'

PRODUCT = 'LunaPriceCompare'
TARGETS = %w[
  Luna
  LunaPriceTracker
  LunaShare
  LunaAction
  LunaPriceTrackerShare
  LunaPriceTrackerAction
  LunaSafari
  LunaReaderSafari
  LunaDownloaderSafari
  LunaPriceTrackerSafari
  LunaTests
].freeze

proj = Xcodeproj::Project.open('Luna.xcodeproj')
PBX = Xcodeproj::Project::Object

# The local package reference every existing package product dependency hangs off.
package_ref = proj.objects
                  .select { |o| o.isa == 'XCLocalSwiftPackageReference' }
                  .find { |o| o.relative_path.to_s.include?('LunaLibraries') }
raise 'LunaLibraries local package reference not found' if package_ref.nil?

TARGETS.each do |name|
  target = proj.targets.find { |t| t.name == name }
  raise "target #{name} not found" if target.nil?

  if target.package_product_dependencies.any? { |d| d.product_name == PRODUCT }
    puts "#{name}: already links #{PRODUCT}"
    next
  end

  dep = proj.new(PBX::XCSwiftPackageProductDependency)
  dep.package = package_ref
  dep.product_name = PRODUCT
  target.package_product_dependencies << dep

  build_file = proj.new(PBX::PBXBuildFile)
  build_file.product_ref = dep
  target.frameworks_build_phase.files << build_file
  puts "#{name}: linked #{PRODUCT}"
end

proj.save
puts 'saved Luna.xcodeproj'
