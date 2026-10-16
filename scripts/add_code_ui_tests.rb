#!/usr/bin/env ruby
require_relative 'xcodeproj_compat'
p = Xcodeproj::Project.open(File.expand_path('../Luna.xcodeproj', __dir__))
host = p.targets.find { |t| t.name == 'LunaCode' }
t = p.targets.find { |t| t.name == 'LunaCodeUITests' } || p.new_target(:ui_test_bundle, 'LunaCodeUITests', :ios, '26.0')
g = p.main_group.groups.find { |g| g.path == 'LunaCodeUITests' } || p.main_group.new_group('LunaCodeUITests', 'LunaCodeUITests')
f = g.files.find { |f| f.path == 'CodeEditorUITests.swift' } || g.new_file('CodeEditorUITests.swift')
t.source_build_phase.add_file_reference(f, true)
t.add_dependency(host) unless t.dependencies.any? { |d| d.target == host }
t.build_configurations.each { |c| c.build_settings.merge!({'PRODUCT_BUNDLE_IDENTIFIER'=>'$(PRODUCT_BUNDLE_PREFIX).code.uitests','PRODUCT_NAME'=>'$(TARGET_NAME)','GENERATE_INFOPLIST_FILE'=>'YES','SWIFT_VERSION'=>'5.0','TEST_TARGET_NAME'=>'LunaCode','CODE_SIGN_STYLE'=>'Automatic','TARGETED_DEVICE_FAMILY'=>'1,2'}) }
p.save
s = Xcodeproj::XCScheme.new;s.add_build_target(host);s.set_launch_target(host);s.add_test_target(t);s.save_as(p.path,'LunaCode',true)
