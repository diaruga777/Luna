#!/usr/bin/env ruby
# Idempotently add the three input share surfaces without linking app-only services.
require_relative 'xcodeproj_compat'
project = Xcodeproj::Project.open(File.expand_path('../Luna.xcodeproj', __dir__))
root = File.expand_path('..', __dir__)
package = project.objects.find { |o| o.isa == 'XCLocalSwiftPackageReference' && o.relative_path == 'LunaLibraries' }
def link(project, target, package, name)
  dep = target.package_product_dependencies.find { |d| d.product_name == name }
  return if dep
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = package; dep.product_name = name; target.package_product_dependencies << dep
  file = project.new(Xcodeproj::Project::Object::PBXBuildFile); file.product_ref = dep
  target.frameworks_build_phase.files << file
end
%w[Keyboard Music Writer].each do |app_name|
  name = "Luna#{app_name}Share"
  app = project.targets.find { |t| t.name == "Luna#{app_name}" }
  target = project.targets.find { |t| t.name == name } || project.new_target(:app_extension, name, :ios, '26.0')
  target.frameworks_build_phase.files.dup.each do |f|
    next unless f.file_ref&.source_tree == 'DEVELOPER_DIR'
    f.remove_from_project
  end
  target.build_configurations.each do |c|
    c.build_settings.merge!({
      'PRODUCT_BUNDLE_IDENTIFIER' => "$(PRODUCT_BUNDLE_PREFIX).#{app_name.downcase}.share",
      'PRODUCT_NAME' => '$(TARGET_NAME)', 'GENERATE_INFOPLIST_FILE' => 'YES',
      'INFOPLIST_FILE' => "#{name}/Info.plist", 'CODE_SIGN_ENTITLEMENTS' => "#{name}/#{name}.entitlements",
      'INFOPLIST_KEY_CFBundleDisplayName' => "$(DISPLAY_NAME_PREFIX) #{app_name}",
      'CODE_SIGN_STYLE' => 'Automatic', 'IPHONEOS_DEPLOYMENT_TARGET' => '26.0',
      'SWIFT_VERSION' => '5.0', 'CURRENT_PROJECT_VERSION' => app.build_configurations.first.build_settings['CURRENT_PROJECT_VERSION'],
      'MARKETING_VERSION' => app.build_configurations.first.build_settings['MARKETING_VERSION'],
      'TARGETED_DEVICE_FAMILY' => '1,2', 'APPLICATION_EXTENSION_API_ONLY' => 'YES', 'SKIP_INSTALL' => 'YES',
      'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
    })
  end
  group = project.main_group.groups.find { |g| g.path == name } || project.main_group.new_group(name, name)
  Dir.glob(File.join(root, name, '*.swift')).each do |path|
    ref = group.files.find { |f| f.path == File.basename(path) } || group.new_file(File.basename(path))
    target.source_build_phase.add_file_reference(ref, true)
  end
  link(project, target, package, 'LunaCompanionSharing')
  app.add_dependency(target) unless app.dependencies.any? { |d| d.target == target }
  phase = app.copy_files_build_phases.find { |p| p.name == 'Embed Foundation Extensions' } || app.new_copy_files_build_phase('Embed Foundation Extensions')
  phase.symbol_dst_subfolder_spec = :plug_ins
  unless phase.files.any? { |f| f.file_ref == target.product_reference }
    file = phase.add_file_reference(target.product_reference, true)
    file.settings = {'ATTRIBUTES' => ['RemoveHeadersOnCopy']}
  end
  # Embedding must precede the existing signing repair phase.
  signing = app.shell_script_build_phases.find { |p| p.name == 'Re-sign embedded extensions (debug)' }
  unless signing
    source = project.targets.find { |t| t.name == 'LunaReader' }.shell_script_build_phases.find { |p| p.name == 'Re-sign embedded extensions (debug)' }
    signing = app.new_shell_script_build_phase(source.name)
    signing.shell_script = source.shell_script; signing.always_out_of_date = source.always_out_of_date
  end
  app.build_phases.delete(signing); app.build_phases << signing
end
link(project, project.targets.find { |t| t.name == 'LunaMusic' }, package, 'LunaCompanionSharing')
link(project, project.targets.find { |t| t.name == 'LunaMusicTests' }, package, 'LunaCompanionSharing')
%w[LunaWriter LunaMusicTests LunaWriterTests].each { |name| link(project, project.targets.find { |t| t.name == name }, package, 'LunaCompanionShareCore') }
project.save
