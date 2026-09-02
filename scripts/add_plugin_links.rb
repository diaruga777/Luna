#!/usr/bin/env ruby
# Links the plugin-platform package products into the targets that run plugins.
#
# The platform is CENTRAL LUNA ONLY (plugin-platform.md decision 3): the app, its
# share and action extensions, and its Safari appex. The three sibling apps and
# their extensions link nothing here. `LunaTests` hosts on the central app, so it
# links everything.
#
# The Safari appex runs no plugin JS natively — it relays messages, serves plugin
# sources and answers bridge calls — so it takes the Foundation-only floor
# (`LunaPluginKit`) plus the bundled catalog and no runtime.
#
# Idempotent — a target that already links a product is skipped, so this can be
# re-run after adding a target.
require 'xcodeproj'

# target name => the products it links, in dependency order.
LINKS = {
  'Luna' => %w[
    LunaPluginKit
    LunaPluginRuntime
    LunaPluginIngest
    LunaPluginExport
    LunaPluginTransport
    LunaPluginUI
    LunaBundledPlugins
  ],
  'LunaShare' => %w[LunaPluginKit LunaPluginRuntime LunaPluginIngest LunaBundledPlugins],
  'LunaAction' => %w[LunaPluginKit LunaPluginRuntime LunaPluginIngest LunaBundledPlugins],
  'LunaSafari' => %w[LunaPluginKit LunaBundledPlugins],
  'LunaTests' => %w[
    LunaPluginKit
    LunaPluginRuntime
    LunaPluginIngest
    LunaPluginExport
    LunaPluginTransport
    LunaPluginUI
    LunaBundledPlugins
  ],
}.freeze

proj = Xcodeproj::Project.open('Luna.xcodeproj')
PBX = Xcodeproj::Project::Object

# The local package reference every existing package product dependency hangs off.
package_ref = proj.objects
                  .select { |o| o.isa == 'XCLocalSwiftPackageReference' }
                  .find { |o| o.relative_path.to_s.include?('LunaLibraries') }
raise 'LunaLibraries local package reference not found' if package_ref.nil?

LINKS.each do |name, products|
  target = proj.targets.find { |t| t.name == name }
  raise "target #{name} not found" if target.nil?

  products.each do |product|
    if target.package_product_dependencies.any? { |d| d.product_name == product }
      puts "#{name}: already links #{product}"
      next
    end

    dep = proj.new(PBX::XCSwiftPackageProductDependency)
    dep.package = package_ref
    dep.product_name = product
    target.package_product_dependencies << dep

    build_file = proj.new(PBX::PBXBuildFile)
    build_file.product_ref = dep
    target.frameworks_build_phase.files << build_file
    puts "#{name}: linked #{product}"
  end
end

proj.save
puts 'saved Luna.xcodeproj'
