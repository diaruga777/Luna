#!/usr/bin/env ruby
# Generate only in a disposable directory; never modify Luna.xcodeproj.
require_relative '../../scripts/xcodeproj_compat'
require 'fileutils'
output, bundle, build = ARGV
abort 'usage: generate.rb OUTPUT BUNDLE BUILD' unless output && bundle && build
FileUtils.mkdir_p(output)
FileUtils.cp(File.join(__dir__, 'Probe.swift'), File.join(output, 'Probe.swift'))
FileUtils.cp(File.join(__dir__, 'Info.plist'), File.join(output, 'Info.plist'))
project = Xcodeproj::Project.new(File.join(output, 'InstallProbe.xcodeproj'))
target = project.new_target(:application, 'InstallProbe', :ios, '26.0')
target.add_file_references([project.main_group.new_file('Probe.swift')])
target.build_configurations.each do |config|
  config.build_settings.merge!({
    'SWIFT_VERSION' => '5.0', 'PRODUCT_BUNDLE_IDENTIFIER' => bundle,
    'INFOPLIST_FILE' => 'Info.plist', 'CODE_SIGN_STYLE' => 'Automatic',
    'CURRENT_PROJECT_VERSION' => build, 'MARKETING_VERSION' => '1.0',
    'TARGETED_DEVICE_FAMILY' => '1,2', 'IPHONEOS_DEPLOYMENT_TARGET' => '26.0'
  })
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(project.path, 'InstallProbe', true)
