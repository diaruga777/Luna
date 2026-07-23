#!/usr/bin/env ruby
# Adds one standalone Luna app target (sharing the Luna app-shell sources) plus its
# three universal extensions (share / action / safari), reusing the existing source
# folders, Info.plists, and entitlements via shared synchronized groups. Per-app inputs:
#   APP=<suffix>     e.g. downloader            (bundle id = $(PRODUCT_BUNDLE_PREFIX).<suffix>)
#   NAME=<TargetName> e.g. LunaDownloader      (Xcode target / product name, no spaces)
#   DISPLAY=<words>  e.g. "Downloader"           (visible name -> "$(DISPLAY_NAME_PREFIX) <words>")
#
# Idempotent: skips creation if the app target already exists.
require 'xcodeproj'

SUFFIX  = ENV.fetch('APP')
NAME    = ENV.fetch('NAME')
DISPLAY = ENV.fetch('DISPLAY')

proj = Xcodeproj::Project.open('Luna.xcodeproj')

if proj.targets.any? { |t| t.name == NAME }
  puts "Target #{NAME} already exists — skipping."
  exit 0
end

PBX = Xcodeproj::Project::Object

clip      = proj.targets.find { |t| t.name == 'Luna' }
share_src = proj.targets.find { |t| t.name == 'LunaShare' }
safari_src = proj.targets.find { |t| t.name == 'LunaSafari' }
action_src = proj.targets.find { |t| t.name == 'LunaAction' }

# Synchronized source groups (reused across apps), keyed by display name.
sync = {}
proj.objects.select { |o| o.isa == 'PBXFileSystemSynchronizedRootGroup' }.each { |g| sync[g.display_name] = g }

def clone_settings(src_target)
  out = {}
  src_target.build_configurations.each { |c| out[c.name] = c.build_settings.dup }
  out
end

# Add `group` (a synchronized root group) to `target`, with an Info.plist membership
# exception so the plist isn't double-built — mirroring how the source target uses it.
def attach_sync_group(proj, target, group)
  target.file_system_synchronized_groups << group
  ex = proj.new(Xcodeproj::Project::Object::PBXFileSystemSynchronizedBuildFileExceptionSet)
  ex.target = target
  ex.membership_exceptions = ['Info.plist']
  group.exceptions << ex
end

# Reuse the source target's package product dependency OBJECTS (shared) and create
# this target's own frameworks build files referencing them.
def link_same_packages(proj, target, src_target)
  fw = target.frameworks_build_phase
  src_target.package_product_dependencies.each do |dep|
    target.package_product_dependencies << dep
    bf = proj.new(Xcodeproj::Project::Object::PBXBuildFile)
    bf.product_ref = dep
    fw.files << bf
  end
end

def make_target(proj, name, product_type, settings_by_config)
  t = proj.new(Xcodeproj::Project::Object::PBXNativeTarget)
  proj.targets << t
  t.name = name
  t.product_name = name
  t.product_type = product_type
  # Product reference
  ext = (product_type == 'com.apple.product-type.application') ? 'app' : 'appex'
  ftype = (ext == 'app') ? 'wrapper.application' : 'wrapper.app-extension'
  product = proj.new(Xcodeproj::Project::Object::PBXFileReference)
  product.path = "#{name}.#{ext}"
  product.explicit_file_type = ftype
  product.include_in_index = '0'
  product.source_tree = 'BUILT_PRODUCTS_DIR'
  proj.products_group.children << product
  t.product_reference = product
  # Config list
  cl = proj.new(Xcodeproj::Project::Object::XCConfigurationList)
  cl.default_configuration_is_visible = '0'
  cl.default_configuration_name = 'Release'
  %w[Debug Release].each do |cfg|
    bc = proj.new(Xcodeproj::Project::Object::XCBuildConfiguration)
    bc.name = cfg
    bc.build_settings = settings_by_config[cfg]
    cl.build_configurations << bc
  end
  t.build_configuration_list = cl
  # Standard phases
  t.build_phases << proj.new(Xcodeproj::Project::Object::PBXSourcesBuildPhase)
  t.build_phases << proj.new(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
  t.build_phases << proj.new(Xcodeproj::Project::Object::PBXResourcesBuildPhase)
  t
end

bundle = ->(suffix) { "$(PRODUCT_BUNDLE_PREFIX).#{suffix}" }

# ---- Extensions ----------------------------------------------------------------
ext_specs = [
  { key: 'share',  src: share_src,  group: sync['LunaShare'],            name: "#{NAME}Share"  },
  { key: 'action2', src: action_src, group: sync['Luna Action Extension'], name: "#{NAME}Action" },
  { key: 'safari', src: safari_src, group: sync['LunaSafari'],           name: "#{NAME}Safari" },
]

ext_targets = ext_specs.map do |spec|
  settings = clone_settings(spec[:src])
  settings.each_value do |s|
    s['PRODUCT_BUNDLE_IDENTIFIER'] = bundle.call("#{SUFFIX}.#{spec[:key]}")
    s['INFOPLIST_KEY_CFBundleDisplayName'] = "$(DISPLAY_NAME_PREFIX) #{DISPLAY}" if s.key?('INFOPLIST_KEY_CFBundleDisplayName')
  end
  t = make_target(proj, spec[:name], 'com.apple.product-type.app-extension', settings)
  attach_sync_group(proj, t, spec[:group])
  link_same_packages(proj, t, spec[:src])
  t
end

# ---- App -----------------------------------------------------------------------
app_settings = clone_settings(clip)
app_settings.each_value do |s|
  s['PRODUCT_BUNDLE_IDENTIFIER'] = bundle.call(SUFFIX)
  s['INFOPLIST_KEY_CFBundleDisplayName'] = "$(DISPLAY_NAME_PREFIX) #{DISPLAY}"
end
app = make_target(proj, NAME, 'com.apple.product-type.application', app_settings)
attach_sync_group(proj, app, sync['Luna'])
link_same_packages(proj, app, clip)

# Keep future standalone apps in sync with the three existing ones: before Copy
# Bundle Resources, ensure each app has current PiP clips recorded from the shared
# UIKit onboarding illustration. The script itself hashes that one isolated source
# file, so this phase is normally a fast no-op.
guide_src = clip.build_phases.find { |p| p.respond_to?(:shell_script) && p.display_name == 'Record onboarding PiP guides' }
guide = proj.new(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
guide.name = 'Record onboarding PiP guides'
guide.shell_path = '/bin/sh'
guide.shell_script = guide_src.shell_script
guide.always_out_of_date = '1'
resources_index = app.build_phases.index { |phase| phase.isa == 'PBXResourcesBuildPhase' }
app.build_phases.insert(resources_index, guide)

# Target dependencies on the three extensions (so they build before embedding).
ext_targets.each { |et| app.add_dependency(et) }

# Embed Foundation Extensions copy-files phase (dstSubfolderSpec 13 = PlugIns).
embed = proj.new(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase)
embed.name = 'Embed Foundation Extensions'
embed.symbol_dst_subfolder_spec = :plug_ins
embed.dst_path = ''
ext_targets.each do |et|
  bf = proj.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.file_ref = et.product_reference
  bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
  embed.files << bf
end
app.build_phases << embed

# Re-sign embedded extensions (debug) — copy the exact script from the Luna target.
resign_src = clip.build_phases.find { |p| p.respond_to?(:shell_script) && p.display_name.start_with?('Re-sign') }
resign = proj.new(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
resign.name = 'Re-sign embedded extensions (debug)'
resign.shell_path = '/bin/sh'
resign.shell_script = resign_src.shell_script
resign.always_out_of_date = '1'
app.build_phases << resign

proj.save
puts "Created #{NAME} (#{bundle.call(SUFFIX)}) + #{ext_targets.map(&:name).join(', ')}"
