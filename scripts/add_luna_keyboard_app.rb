#!/usr/bin/env ruby
# frozen_string_literal: true
require_relative 'xcodeproj_compat'
project = Xcodeproj::Project.open(File.expand_path('../Luna.xcodeproj', __dir__))
root = File.expand_path('..', __dir__)
package = project.objects.find { |o| o.isa == 'XCLocalSwiftPackageReference' && o.relative_path.to_s.end_with?('LunaLibraries') }
kit = project.objects.find { |o| o.isa == 'XCSwiftPackageProductDependency' && o.product_name == 'LunaKeyboardKit' } || project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
kit.package = package
kit.product_name = 'LunaKeyboardKit'
app = nil
extension = nil
tests = nil
[['LunaKeyboard', :application, ''], ['LunaKeyboardExtension', :app_extension, '.extension'], ['LunaKeyboardTests', :unit_test_bundle, '.tests']].each do |name, type, suffix|
  target = project.targets.find { |t| t.name == name } || project.new_target(type, name, :ios, '26.0')
  app = target if type == :application
  extension = target if type == :app_extension
  tests = target if type == :unit_test_bundle
  target.frameworks_build_phase.files.dup.each do |f|
    next unless f.file_ref&.source_tree == 'DEVELOPER_DIR'
    f.remove_from_project
  end
  target.build_configurations.each do |c|
    c.build_settings.merge!({
      'PRODUCT_BUNDLE_IDENTIFIER' => "$(PRODUCT_BUNDLE_PREFIX).keyboard#{suffix}",
      'PRODUCT_NAME' => '$(TARGET_NAME)', 'GENERATE_INFOPLIST_FILE' => 'YES',
      'CODE_SIGN_STYLE' => 'Automatic',
      'IPHONEOS_DEPLOYMENT_TARGET' => '26.0', 'SWIFT_VERSION' => '5.0',
      'CURRENT_PROJECT_VERSION' => '1', 'MARKETING_VERSION' => '1.0',
      'TARGETED_DEVICE_FAMILY' => '1,2', 'SUPPORTS_MACCATALYST' => 'NO',
      'INFOPLIST_KEY_UIBackgroundModes' => '',
      'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks', '@loader_path/Frameworks']
    })
    if type != :unit_test_bundle
      c.build_settings.merge!({'INFOPLIST_FILE' => "#{name}/Info.plist", 'CODE_SIGN_ENTITLEMENTS' => "#{name}/#{name}.entitlements", 'INFOPLIST_KEY_CFBundleDisplayName' => '$(DISPLAY_NAME_PREFIX) Keyboard'})
    end
    if type == :application
      c.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIconKeyboard'
      c.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
    elsif type == :app_extension
      c.build_settings['APPLICATION_EXTENSION_API_ONLY'] = 'YES'
      c.build_settings['SKIP_INSTALL'] = 'YES'
    else
      c.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/LunaKeyboard.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/LunaKeyboard'
      c.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
    end
  end
  group = project.main_group.groups.find { |g| g.path == name } || project.main_group.new_group(name, name)
  Dir.glob(File.join(root, name, '**', '*.swift')).sort.each do |path|
    relative = path.delete_prefix(File.join(root, name) + '/')
    ref = group.files.find { |f| f.path == relative } || group.new_file(relative)
    target.source_build_phase.add_file_reference(ref, true)
  end
  target.package_product_dependencies << kit unless target.package_product_dependencies.include?(kit)
  next if target.frameworks_build_phase.files.any? { |f| f.product_ref == kit }
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = kit
  target.frameworks_build_phase.files << build_file
end
app.add_dependency(extension) unless app.dependencies.any? { |d| d.target == extension }
tests.add_dependency(app) unless tests.dependencies.any? { |d| d.target == app }
project.root_object.attributes['TargetAttributes'] ||= {}
project.root_object.attributes['TargetAttributes'][tests.uuid] = {'TestTargetID' => app.uuid}
[['Embed Frameworks', :frameworks, kit, :product_ref], ['Embed Foundation Extensions', :plug_ins, extension.product_reference, :file_ref]].each do |name, destination, ref, key|
  phase = app.copy_files_build_phases.find { |p| p.name == name } || app.new_copy_files_build_phase(name)
  next if phase.files.any? { |f| f.send(key) == ref }
  phase.symbol_dst_subfolder_spec = destination
  file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  file.send("#{key}=", ref)
  file.settings = {'ATTRIBUTES' => ['CodeSignOnCopy','RemoveHeadersOnCopy']}
  phase.files << file
end
icon = project.files.find { |f| f.path == 'LunaKeyboard/Assets.xcassets' } || project.main_group.new_file('LunaKeyboard/Assets.xcassets')
app.resources_build_phase.add_file_reference(icon, true)
source = project.targets.find { |t| t.name == 'Luna' }.shell_script_build_phases.find { |p| p.name == 'Re-sign embedded extensions (debug)' }
phase = app.shell_script_build_phases.find { |p| p.name == source.name } || app.new_shell_script_build_phase(source.name)
phase.shell_script = source.shell_script
phase.always_out_of_date = source.always_out_of_date
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.add_test_target(tests)
scheme.save_as(project.path, 'LunaKeyboard', true)
puts 'Configured LunaKeyboard, LunaKeyboardExtension, and LunaKeyboardTests.'
