#!/usr/bin/env ruby
# Links the `LunaTranscribe` package product into the two targets that need it:
# the central Luna app (whose composition root starts the transcription runner)
# and the test bundle. No other target links it — the sibling apps run no
# plugins and so never queue a transcription (`claudedocs/plans/transcription-plugins.md` §5).
#
# Idempotent — a target that already links the product is skipped.
require 'xcodeproj'

PRODUCT = 'LunaTranscribe'
TARGETS = %w[
  Luna
  LunaTests
].freeze

proj = Xcodeproj::Project.open('Luna.xcodeproj')
PBX = Xcodeproj::Project::Object

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
