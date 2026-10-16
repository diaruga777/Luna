#!/usr/bin/env ruby
# frozen_string_literal: true
# Idempotently wires the standalone library player, widgets and hosted tests.
require_relative 'xcodeproj_compat'
project = Xcodeproj::Project.open(File.expand_path('../Luna.xcodeproj', __dir__))
root = File.expand_path('..', __dir__)
package = project.objects.find { |o| o.isa == 'XCLocalSwiftPackageReference' && o.relative_path.to_s.end_with?('LunaLibraries') }
abort 'Missing LunaLibraries' unless package

def configure(project, name, type, suffix)
  target = project.targets.find { |t| t.name == name } || project.new_target(type, name, :ios, '26.0')
  target.frameworks_build_phase.files.dup.each do |f|
    ref = f.file_ref
    next unless ref&.source_tree == 'DEVELOPER_DIR'
    f.remove_from_project
    ref.remove_from_project if project.objects.none? { |o| o.isa == 'PBXBuildFile' && o.file_ref == ref }
  end
  target.build_configurations.each do |c|
    c.build_settings.merge!({
      'PRODUCT_BUNDLE_IDENTIFIER' => "$(PRODUCT_BUNDLE_PREFIX).music#{suffix}",
      'PRODUCT_NAME' => '$(TARGET_NAME)', 'GENERATE_INFOPLIST_FILE' => 'YES',
      'CODE_SIGN_STYLE' => 'Automatic',
      'IPHONEOS_DEPLOYMENT_TARGET' => '26.0', 'SWIFT_VERSION' => '5.0',
      'CURRENT_PROJECT_VERSION' => '1', 'MARKETING_VERSION' => '1.0',
      'TARGETED_DEVICE_FAMILY' => '1,2', 'SUPPORTS_MACCATALYST' => 'NO',
      'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks']
    })
  end
  target
end

def sources(project, target, root, folder, excluded = [])
  group = project.main_group.groups.find { |g| g.path == folder } || project.main_group.new_group(folder, folder)
  Dir.glob(File.join(root, folder, '**', '*.swift')).sort.each do |path|
    relative = path.delete_prefix(File.join(root, folder) + '/')
    next if excluded.include?(relative)
    ref = group.files.find { |f| f.path == relative } || group.new_file(relative)
    target.source_build_phase.add_file_reference(ref, true)
  end
end

def embed(project, target, dependency, name, destination)
  phase = target.copy_files_build_phases.find { |p| p.name == name }
  unless phase
    phase = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
    phase.name = name
    phase.symbol_dst_subfolder_spec = destination
    target.build_phases << phase
  end
  key = dependency.isa == 'XCSwiftPackageProductDependency' ? :product_ref : :file_ref
  return if phase.files.any? { |f| f.send(key) == dependency }
  file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  file.send("#{key}=", dependency)
  file.settings = {'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy']}
  phase.files << file
end

app = configure(project, 'LunaMusic', :application, '')
widget = configure(project, 'LunaMusicWidgets', :app_extension, '.widgets')
tests = configure(project, 'LunaMusicTests', :unit_test_bundle, '.tests')
ui_tests = configure(project, 'LunaMusicUITests', :ui_test_bundle, '.uitests')
app.build_configurations.each do |c|
  c.build_settings.merge!({'INFOPLIST_FILE' => 'LunaMusic/Info.plist',
    'CODE_SIGN_ENTITLEMENTS' => 'LunaMusic/LunaMusic.entitlements',
    'INFOPLIST_KEY_CFBundleDisplayName' => '$(DISPLAY_NAME_PREFIX) Music',
    'PRODUCT_MODULE_NAME' => 'LunaMusicApp',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) LUNA_MUSIC_APP',
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIconMusic'})
end
widget.build_configurations.each do |c|
  c.build_settings.merge!({'INFOPLIST_FILE' => 'LunaMusicWidgets/Info.plist',
    'CODE_SIGN_ENTITLEMENTS' => 'LunaMusicWidgets/LunaMusicWidgets.entitlements',
    'INFOPLIST_KEY_CFBundleDisplayName' => '$(DISPLAY_NAME_PREFIX) Music',
    'APPLICATION_EXTENSION_API_ONLY' => 'YES', 'SKIP_INSTALL' => 'YES',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']})
end
tests.build_configurations.each do |c|
  c.build_settings.merge!({'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/LunaMusic.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/LunaMusic',
    'BUNDLE_LOADER' => '$(TEST_HOST)', 'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']})
end
ui_tests.build_configurations.each { |c| c.build_settings['TEST_TARGET_NAME'] = 'LunaMusic' }
project.root_object.attributes['TargetAttributes'] ||= {}
[tests, ui_tests].each do |target|
  project.root_object.attributes['TargetAttributes'][target.uuid] = {'TestTargetID' => app.uuid}
end

sources(project, app, root, 'LunaMusic')
sources(project, app, root, 'LunaMusicShared')
sources(project, widget, root, 'LunaMusicWidgets')
sources(project, widget, root, 'LunaMusicShared')
sources(project, tests, root, 'LunaMusicTests')
sources(project, ui_tests, root, 'LunaMusicUITests')

kit = project.objects.find { |o| o.isa == 'XCSwiftPackageProductDependency' && o.product_name == 'LunaMusicKit' }
unless kit
  kit = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  kit.package = package
  kit.product_name = 'LunaMusicKit'
end
[app, tests].each do |t|
  t.package_product_dependencies << kit unless t.package_product_dependencies.include?(kit)
  unless t.frameworks_build_phase.files.any? { |f| f.product_ref == kit }
    f = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    f.product_ref = kit
    t.frameworks_build_phase.files << f
  end
end
embed(project, app, kit, 'Embed Frameworks', :frameworks)
app.add_dependency(widget) unless app.dependencies.any? { |d| d.target == widget }
embed(project, app, widget.product_reference, 'Embed Foundation Extensions', :plug_ins)
[tests, ui_tests].each { |t| t.add_dependency(app) unless t.dependencies.any? { |d| d.target == app } }
icon_path = 'LunaMusic/Assets.xcassets'
icon = project.files.find { |f| f.path == icon_path } || project.main_group.new_file(icon_path)
app.resources_build_phase.add_file_reference(icon, true)
# Keep incremental debug extension signing aligned with the parent app.
unless app.shell_script_build_phases.any? { |p| p.name == 'Re-sign embedded extensions (debug)' }
  source = project.targets.find { |t| t.name == 'Luna' }.shell_script_build_phases.find { |p| p.name == 'Re-sign embedded extensions (debug)' }
  phase = app.new_shell_script_build_phase(source.name)
  phase.shell_script = source.shell_script
  phase.always_out_of_date = source.always_out_of_date
end
# Music reuses the family's authenticated connection and pairing settings.
[['LunaLibraries', 'LunaVaultUI'], ['LunaVaultTailscale', 'LunaVaultTailscale']].each do |path, product|
  package_ref = project.objects.find { |o| o.isa == 'XCLocalSwiftPackageReference' && o.relative_path == path }
  abort "Missing #{path}" unless package_ref
  dep = app.package_product_dependencies.find { |d| d.product_name == product }
  unless dep
    dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dep.package = package_ref; dep.product_name = product
    app.package_product_dependencies << dep
    file = project.new(Xcodeproj::Project::Object::PBXBuildFile); file.product_ref = dep
    app.frameworks_build_phase.files << file
  end
end
Dir.glob(File.join(root, 'LunaMusicTests/Fixtures/*')).each do |path|
  relative = path.delete_prefix(root + '/')
  ref = project.files.find { |f| f.path == relative } || project.main_group.new_file(relative)
  tests.resources_build_phase.add_file_reference(ref, true)
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.add_test_target(tests)
scheme.save_as(project.path, 'LunaMusic', true)
ui_scheme = Xcodeproj::XCScheme.new
ui_scheme.add_build_target(app)
ui_scheme.set_launch_target(app)
ui_scheme.add_test_target(ui_tests)
ui_scheme.save_as(project.path, 'LunaMusicUI', true)
puts 'Configured LunaMusic, LunaMusicWidgets, LunaMusicTests and LunaMusicUITests.'
