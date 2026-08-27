#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds the standalone Luna Vault host and its dedicated Share extension.
#
# This project uses Xcode's newer synchronized-group object types, while the
# repository's system xcodeproj gem predates them. The small compatibility
# declarations below let this topology helper preserve those objects while
# adding conventional groups for Vault's intentionally slim shell.
require_relative "xcodeproj_compat"

PROJECT = File.expand_path("../Luna.xcodeproj", __dir__)
project = Xcodeproj::Project.open(PROJECT)

if project.targets.any? { |target| target.name == "LunaVault" }
  puts "LunaVault already exists — skipping."
  exit 0
end

def configure_target(target, bundle_id, info_plist, entitlements, icon_name = nil)
  target.build_configurations.each do |configuration|
    settings = configuration.build_settings
    settings["PRODUCT_BUNDLE_IDENTIFIER"] = bundle_id
    settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
    settings["INFOPLIST_FILE"] = info_plist
    settings["CODE_SIGN_ENTITLEMENTS"] = entitlements
    settings["CODE_SIGN_STYLE"] = "Automatic"
    settings["DEVELOPMENT_TEAM"] = "MM5QBNLXR6"
    settings["CURRENT_PROJECT_VERSION"] = "1"
    settings["MARKETING_VERSION"] = "0.1"
    settings["IPHONEOS_DEPLOYMENT_TARGET"] = "18.0"
    settings["SWIFT_VERSION"] = "5.0"
    settings["SWIFT_EMIT_LOC_STRINGS"] = "YES"
    settings["GENERATE_INFOPLIST_FILE"] = "YES"
    settings["TARGETED_DEVICE_FAMILY"] = "1,2"
    settings["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/Frameworks"]
    settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = icon_name if icon_name
  end
end

def add_source_group(project, name, files)
  group = project.main_group.new_group(name)
  group.path = name
  group.source_tree = "<group>"
  refs = files.map { |file| group.new_file(file) }
  [group, refs]
end

def remove_implicit_sdk_framework_links(target)
  removed_refs = []
  target.frameworks_build_phase.files.dup.each do |build_file|
    reference = build_file.file_ref
    next unless reference&.source_tree == "DEVELOPER_DIR"
    next unless reference.path&.end_with?(".framework")

    removed_refs << reference
    build_file.remove_from_project
  end
  removed_refs
end

def clone_shell_phase(project, source_target, destination, name)
  source = source_target.build_phases.find do |phase|
    phase.is_a?(Xcodeproj::Project::Object::PBXShellScriptBuildPhase) && phase.name == name
  end
  abort "Missing '#{name}' on #{source_target.name}" unless source

  phase = project.new(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
  phase.name = source.name
  phase.shell_path = source.shell_path
  phase.shell_script = source.shell_script
  phase.always_out_of_date = source.always_out_of_date
  phase.input_paths = source.input_paths
  phase.output_paths = source.output_paths
  destination.build_phases << phase
end

# Vault host: no shared URL/reader/media shell files and no central package
# graph. Feature services are introduced by later Vault stages.
app = project.new_target(:application, "LunaVault", :ios, "18.0")
generated_framework_refs = remove_implicit_sdk_framework_links(app)
configure_target(app, '$(PRODUCT_BUNDLE_PREFIX).vault', "LunaVault/Info.plist", "LunaVault/LunaVault.entitlements", "AppIconVault")
app.build_configurations.each { |configuration| configuration.build_settings["INFOPLIST_KEY_CFBundleDisplayName"] = "$(DISPLAY_NAME_PREFIX) Vault" }
_group, refs = add_source_group(project, "LunaVault", %w[VaultAppDelegate.swift VaultSceneDelegate.swift KindWiring+Vault.swift])
app.add_file_references(refs)
# Add the catalog (rather than the child appiconset) so Xcode runs actool and
# emits the Vault icon into Assets.car. The target's icon setting selects only
# AppIconVault; the other app icons remain unused by this host.
asset_ref = project.main_group.new_file("Luna/Assets.xcassets")
app.resources_build_phase.add_file_reference(asset_ref)
strings_ref = project.files.find do |reference|
  reference.path == "LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings"
end
abort "Missing shared Localizable.strings file reference" unless strings_ref
app.resources_build_phase.add_file_reference(strings_ref)

# Dedicated Share extension. It is a bounded handoff placeholder and does not
# import Vault storage or initialise indexing/provider work in the extension.
share = project.new_target(:app_extension, "LunaVaultShare", :ios, "18.0")
generated_framework_refs.concat(remove_implicit_sdk_framework_links(share))
configure_target(share, '$(PRODUCT_BUNDLE_PREFIX).vault.share', "LunaVaultShare/Info.plist", "LunaVaultShare/LunaVaultShare.entitlements")
share.build_configurations.each do |configuration|
  configuration.build_settings["INFOPLIST_KEY_CFBundleDisplayName"] = "$(DISPLAY_NAME_PREFIX) Vault"
  configuration.build_settings["APPLICATION_EXTENSION_API_ONLY"] = "YES"
  configuration.build_settings["SKIP_INSTALL"] = "YES"
  configuration.build_settings["LD_RUNPATH_SEARCH_PATHS"] = ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"]
end
_share_group, share_refs = add_source_group(project, "LunaVaultShare", ["VaultShareViewController.swift"])
share.add_file_references(share_refs)

app.add_dependency(share)
embed = project.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
embed.name = "Embed Foundation Extensions"
embed.symbol_dst_subfolder_spec = :plug_ins
build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.file_ref = share.product_reference
build_file.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }
embed.files << build_file
app.build_phases << embed

central = project.targets.find { |target| target.name == "Luna" }
abort "Missing central Luna target" unless central
clone_shell_phase(project, central, app, "Re-sign embedded extensions (debug)")
clone_shell_phase(project, central, app, "Verify bundled strings table")

# Swift imports system frameworks without explicit SDK-path references. Older
# xcodeproj releases create brittle iPhoneOS14.0/18.0 file references when a
# target is added; remove those generated references once no build phase uses
# them so the project remains independent of the installed SDK version.
generated_framework_refs.uniq.each do |reference|
  still_linked = project.objects.any? do |object|
    object.is_a?(Xcodeproj::Project::Object::PBXBuildFile) && object.file_ref == reference
  end
  reference.remove_from_project unless still_linked
end

project.save
puts "Created LunaVault (#{app.uuid}) and LunaVaultShare (#{share.uuid})"
