#!/usr/bin/env ruby
# frozen_string_literal: true

# Gives every app target a final build phase that repairs any bundled strings
# table that has gone stale, so the build ships the real copy instead of just
# reporting that it wouldn't have.
#
# The one strings file reaches a built app through several INDEPENDENT copy
# tasks (LunaModels' SwiftPM resource bundle, embedded once per nested
# extension/widget, plus the app's own `CopyStringsFile` copy added by
# add_strings_to_app_bundles.rb). Each is a separate up-to-date decision, and a
# build that is interrupted part-way — or a products directory holding an app
# this build did not rebuild — leaves copies disagreeing with the source with
# nothing to say so. A stale table reads as "my copy edit didn't take", which
# invites re-editing copy that was already right, so the phase rewrites it in
# place rather than only flagging it. The one case it can't fix this way — a
# bundle root missing its OWN en.lproj copy, meaning the Resources phase
# reference itself is missing — still fails the build with instructions.
#
# The phase runs `scripts/check_bundled_strings.py` over the app bundle after
# every embed phase, on EVERY build (it is deliberately always-out-of-date —
# the thing it distrusts is exactly the incremental logic that would skip it).
# It costs ~0.1s. Re-run this script after adding an app target; it is
# idempotent, and it rewrites the phase in place if the recipe below changes.

require_relative 'xcodeproj_compat'

PROJECT = File.expand_path('../Luna.xcodeproj', __dir__)
PHASE_NAME = 'Verify bundled strings table'

# Only the five APPS. Everything else that carries a copy — the share/action/
# safari extensions, both Live Activity widgets — is embedded inside one of
# them, so walking the .app covers it. The unit-test bundle is
# skipped by the checker itself (see SKIPPED_SUFFIXES there).
APPS = %w[Luna LunaReader LunaDownloader LunaPriceTracker LunaVault LunaWriter].freeze

SCRIPT = <<~SH
  # Rewrites any bundled copy of the one strings table that has drifted from
  # the source. See scripts/add_strings_check_phase.rb and claudedocs/strings.md
  # ("The build-level guarantee").
  python3 "${SRCROOT}/scripts/check_bundled_strings.py" \\
      "${SRCROOT}/LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings" \\
      "${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
SH

PBXPROJ = File.join(PROJECT, 'project.pbxproj')

# The xcodeproj gem re-emits the whole file, and it writes two things
# differently from Xcode itself: it expands every `PBXFileSystemSynchronizedRoot
# Group` one-liner into a multi-line block, and it rewrites each exception set's
# `/* … */` comment into a prose description. Both are cosmetic, and both are
# ~200 lines of churn in the ONE file most likely to be edited concurrently, so
# they get put back. Only the sections this script does not touch are restored,
# and only when both versions describe the same objects.
def restore_untouched_formatting(original, updated)
  updated = updated.gsub(/\/\* Exceptions for "[^"]*" folder in "[^"]*" target \*\//,
                         '/* PBXFileSystemSynchronizedBuildFileExceptionSet */')
  section = %r{/\* Begin PBXFileSystemSynchronizedRootGroup section \*/.*?/\* End PBXFileSystemSynchronizedRootGroup section \*/}m
  before, after = original[section], updated[section]
  return updated if before.nil? || after.nil?
  # Same objects, only laid out differently? Then the old layout is as good.
  identifiers = ->(text) { text.scan(/^\t\t(\w+) \/\*/).flatten.sort }
  return updated unless identifiers.call(before) == identifiers.call(after)

  updated.sub(section, before)
end

original_text = File.read(PBXPROJ)
project = Xcodeproj::Project.open(PROJECT)
changed = false

APPS.each do |name|
  target = project.targets.find { |t| t.name == name }
  unless target
    warn "!! no target named #{name} — skipping"
    next
  end

  phase = target.build_phases.find do |p|
    p.is_a?(Xcodeproj::Project::Object::PBXShellScriptBuildPhase) && p.name == PHASE_NAME
  end

  if phase.nil?
    phase = target.new_shell_script_build_phase(PHASE_NAME)
    changed = true
    puts "#{name}: added '#{PHASE_NAME}'"
  end

  # The phase has to run after every embed phase, so the nested extensions
  # and widgets are already inside the .app when it walks it.
  unless target.build_phases.last == phase
    target.build_phases.delete(phase)
    target.build_phases << phase
    changed = true
    puts "#{name}: moved '#{PHASE_NAME}' last"
  end

  desired = {
    shell_path: '/bin/sh',
    shell_script: SCRIPT,
    # No outputs and nothing to compare: this must run every single build.
    # Saying so explicitly is also what keeps Xcode from emitting a "will be
    # run during every build" note about it.
    always_out_of_date: '1',
    input_paths: ['$(SRCROOT)/LunaLibraries/Sources/LunaModels/Resources/en.lproj/Localizable.strings',
                  '$(SRCROOT)/scripts/check_bundled_strings.py'],
    output_paths: [],
  }
  desired.each do |attribute, value|
    next if phase.send(attribute) == value

    phase.send("#{attribute}=", value)
    changed = true
    puts "#{name}: set #{attribute}"
  end
end

if changed
  project.save
  File.write(PBXPROJ, restore_untouched_formatting(original_text, File.read(PBXPROJ)))
  puts 'project saved'
else
  puts 'no changes needed'
end
