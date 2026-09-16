#!/usr/bin/env ruby
require_relative 'xcodeproj_compat'
project = Xcodeproj::Project.open(File.expand_path('../Luna.xcodeproj', __dir__))
name = 'LunaVaultConnectionTests'
target = project.targets.find { |t| t.name == name } || project.new_target(:unit_test_bundle, name, :ios, '26.0')
group = project.main_group.groups.find { |g| g.path == name } || project.main_group.new_group(name, name)
Dir.glob(File.expand_path("../#{name}/*.swift", __dir__)).each do |path|
  ref = group.files.find { |f| f.path == File.basename(path) } || group.new_file(File.basename(path))
  target.source_build_phase.add_file_reference(ref, true)
end
%w[LunaVaultUI LunaVaultMacPeer LunaVaultTailscale].each do |product|
  dep = project.objects.find { |o| o.isa == 'XCSwiftPackageProductDependency' && o.product_name == product }
  abort "Missing #{product}" unless dep
  unless target.package_product_dependencies.include?(dep)
    target.package_product_dependencies << dep
    file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    file.product_ref = dep; target.frameworks_build_phase.files << file
  end
end
target.build_configurations.each do |config|
  config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  config.build_settings['MACH_O_TYPE'] = 'mh_bundle'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.hsanabria.luna.vault.connectiontests'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['TEST_HOST'] = ''
  config.build_settings['BUNDLE_LOADER'] = ''
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.add_test_target(target)
scheme.save_as(project.path, name, true)
