#!/usr/bin/env ruby
# Points every content-app target at its app's ONE dynamic kit product.
#
# `LunaLibraries/Package.swift` declares four dynamic libraries — `LunaKit`,
# `LunaReaderKit`, `LunaDownloaderKit`, `LunaPriceTrackerKit` — each holding
# every package target its app group reaches. This script makes the project
# match:
#
#   * the app, each of its extensions, and the test bundle hosted on it link
#     the kit and NOTHING else from the package (a client that also links a
#     static product sharing targets with the kit makes Xcode promote every
#     doubly reached target into a framework of its own);
#   * the APP target alone embeds the kit, through an "Embed Frameworks" copy
#     phase that signs on copy;
#   * the extensions resolve the kit through their existing
#     `@executable_path/../../Frameworks` rpath and carry no copy.
#
# Vault and Writer targets are untouched — they link static products.
#
# Idempotent: run it after `scripts/add_luna_app.rb`, after adding an
# extension, or whenever a target's package links drift.
require 'xcodeproj'

PBX = Xcodeproj::Project::Object

# kit product => [app target, *every other target that links the kit]
GROUPS = {
  'LunaKit' => {
    app: 'Luna',
    clients: %w[LunaShare LunaAction LunaSafari LunaLiveActivity LunaTests],
  },
  'LunaReaderKit' => {
    app: 'LunaReader',
    clients: %w[LunaReaderShare LunaReaderAction LunaReaderSafari],
  },
  'LunaDownloaderKit' => {
    app: 'LunaDownloader',
    clients: %w[LunaDownloaderShare LunaDownloaderAction LunaDownloaderSafari
                LunaDownloaderLiveActivity],
  },
  'LunaPriceTrackerKit' => {
    app: 'LunaPriceTracker',
    clients: %w[LunaPriceTrackerShare LunaPriceTrackerAction LunaPriceTrackerSafari],
  },
}.freeze

EMBED_PHASE_NAME = 'Embed Frameworks'
EMBED_ATTRIBUTES = %w[CodeSignOnCopy RemoveHeadersOnCopy].freeze

proj = Xcodeproj::Project.open('Luna.xcodeproj')

# The local package reference every package product dependency hangs off.
package_ref = proj.objects
                  .select { |o| o.isa == 'XCLocalSwiftPackageReference' }
                  .find { |o| o.relative_path.to_s.include?('LunaLibraries') }
raise 'LunaLibraries local package reference not found' if package_ref.nil?

def target_named(proj, name)
  proj.targets.find { |t| t.name == name } or raise "target #{name} not found"
end

# Package product dependencies are SHARED between targets, so a target drops its
# own references only. Objects left with no referrer are pruned once at the end.
def strip_package_links(target, keep:)
  dropped = []
  target.package_product_dependencies.to_a.each do |dep|
    next if dep.product_name == keep

    target.package_product_dependencies.delete(dep)
    dropped << dep.product_name
  end

  target.build_phases.each do |phase|
    next unless phase.is_a?(PBX::PBXFrameworksBuildPhase) || phase.is_a?(PBX::PBXCopyFilesBuildPhase)

    phase.files.to_a.each do |file|
      ref = file.product_ref
      next if ref.nil? || !ref.is_a?(PBX::XCSwiftPackageProductDependency)
      next if ref.product_name == keep

      phase.files.delete(file)
      file.remove_from_project
    end
  end
  dropped.uniq.sort
end

def link_kit(proj, target, kit, package_ref)
  dep = target.package_product_dependencies.find { |d| d.product_name == kit }
  if dep.nil?
    dep = proj.new(PBX::XCSwiftPackageProductDependency)
    dep.package = package_ref
    dep.product_name = kit
    target.package_product_dependencies << dep
  end

  linked = target.frameworks_build_phase.files.any? { |f| f.product_ref == dep }
  unless linked
    file = proj.new(PBX::PBXBuildFile)
    file.product_ref = dep
    target.frameworks_build_phase.files << file
  end
  dep
end

# Xcode does not auto-embed a dynamic package product. The app needs its own
# copy phase; without it the framework is missing at launch.
def embed_kit(proj, target, dep)
  phase = target.build_phases.find do |p|
    p.is_a?(PBX::PBXCopyFilesBuildPhase) && p.name == EMBED_PHASE_NAME
  end

  if phase.nil?
    phase = proj.new(PBX::PBXCopyFilesBuildPhase)
    phase.name = EMBED_PHASE_NAME
    phase.dst_path = ''
    phase.symbol_dst_subfolder_spec = :frameworks
    phase.run_only_for_deployment_postprocessing = '0'
    # After "Embed Foundation Extensions" so the app's own products are in
    # place before the debug re-sign phase runs.
    extensions = target.build_phases.index do |p|
      p.is_a?(PBX::PBXCopyFilesBuildPhase) && p.name == 'Embed Foundation Extensions'
    end
    insert_at = extensions.nil? ? target.build_phases.size : extensions + 1
    target.build_phases.insert(insert_at, phase)
    created = true
  end

  return created ? :created : :present if phase.files.any? { |f| f.product_ref == dep }

  file = proj.new(PBX::PBXBuildFile)
  file.product_ref = dep
  file.settings = { 'ATTRIBUTES' => EMBED_ATTRIBUTES.dup }
  phase.files << file
  :embedded
end

touched_targets = []

GROUPS.each do |kit, group|
  ([group[:app]] + group[:clients]).each do |name|
    target = target_named(proj, name)
    dropped = strip_package_links(target, keep: kit)
    link_kit(proj, target, kit, package_ref)
    touched_targets << target
    puts "#{name}: links #{kit}#{dropped.empty? ? '' : " (dropped #{dropped.size}: #{dropped.join(', ')})"}"
  end

  app = target_named(proj, group[:app])
  dep = app.package_product_dependencies.find { |d| d.product_name == kit }
  puts "#{group[:app]}: embed #{kit} — #{embed_kit(proj, app, dep)}"
end

# Prune dependency objects nothing refers to any more.
referenced = proj.targets.flat_map { |t| t.package_product_dependencies.to_a }
referenced += proj.objects.select { |o| o.isa == 'PBXBuildFile' }.map(&:product_ref).compact
referenced = referenced.uniq
orphans = proj.objects.select { |o| o.isa == 'XCSwiftPackageProductDependency' } - referenced
orphans.each(&:remove_from_project)
puts "pruned #{orphans.size} unreferenced package product dependencies"

proj.save
puts 'saved Luna.xcodeproj'
