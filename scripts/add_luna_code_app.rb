#!/usr/bin/env ruby
# Idempotently add Code without touching the other apps' build settings.
require_relative 'xcodeproj_compat'
project = Xcodeproj::Project.open(File.expand_path('../Luna.xcodeproj', __dir__))
if project.targets.any? { |t| t.name == 'LunaCode' }
  puts 'LunaCode already exists'; exit
end
source = project.targets.find { |t| t.name == 'LunaVault' }
app = project.new_target(:application, 'LunaCode', :ios, '26.0')
app.frameworks_build_phase.files.dup.each { |f| f.remove_from_project if f.file_ref&.source_tree == 'DEVELOPER_DIR' }
app.build_configurations.each do |config|
  original = source.build_configurations.find { |c| c.name == config.name }
  config.build_settings = Marshal.load(Marshal.dump(original.build_settings))
  config.base_configuration_reference = original.base_configuration_reference
  config.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => '$(PRODUCT_BUNDLE_PREFIX).code', 'PRODUCT_NAME' => '$(TARGET_NAME)',
    'INFOPLIST_FILE' => 'LunaCode/Info.plist', 'CODE_SIGN_ENTITLEMENTS' => 'LunaCode/LunaCode.entitlements',
    'INFOPLIST_KEY_CFBundleDisplayName' => '$(DISPLAY_NAME_PREFIX) Code', 'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIconCode',
    'IPHONEOS_DEPLOYMENT_TARGET' => '26.0', 'CURRENT_PROJECT_VERSION' => '1', 'MARKETING_VERSION' => '1.0',
    'INFOPLIST_KEY_UIBackgroundModes' => '', 'TARGETED_DEVICE_FAMILY' => '1,2'
  })
end
group = project.main_group.new_group('LunaCode', 'LunaCode')
app.add_file_references([group.new_file('CodeAppDelegate.swift')])
assets = project.main_group.new_file('LunaCode/Assets.xcassets'); app.resources_build_phase.add_file_reference(assets)
code_package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference); code_package.relative_path = 'LunaCodeKit'
project.root_object.package_references << code_package
[['LunaCodeKit', 'LunaCodeUI'], ['LunaCodeKit', 'LunaCodeCore'], ['LunaLibraries', 'LunaVaultUI'], ['LunaVaultTailscale', 'LunaVaultTailscale']].each do |path, product|
  package = project.objects.find { |o| o.isa == 'XCLocalSwiftPackageReference' && o.relative_path == path }
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency); dep.package = package; dep.product_name = product
  app.package_product_dependencies << dep
  file = project.new(Xcodeproj::Project::Object::PBXBuildFile); file.product_ref = dep; app.frameworks_build_phase.files << file
end
project.save
scheme = Xcodeproj::XCScheme.new; scheme.add_build_target(app); scheme.set_launch_target(app); scheme.save_as(project.path, 'LunaCode', true)
