#!/usr/bin/env ruby
# Write Luna.xcodeproj/xcuserdata/<user>.xcuserdatad/xcschemes/xcschememanagement.plist
# so the Xcode scheme picker shows only the five app schemes and their
# aggregate AllLunaApps scheme.
#
# Two separate mechanisms are at play and both live in this per-user file
# (Xcode has no shared equivalent):
#
#   SuppressBuildableAutocreation — stops Xcode from inventing a scheme for a
#     target that has none. Without it, every extension / clip / live-activity
#     target grows a scheme back the next time the project is opened.
#   SchemeUserState[…].isShown — hides a scheme that already exists. This is
#     the only lever for the ~35 schemes the LunaLibraries local SwiftPM
#     package contributes; those are synthesized from Package.swift, so there
#     is no file to delete.

require "fileutils"
require "xcodeproj"

PROJECT = File.expand_path("../Luna.xcodeproj", __dir__)

APPS = ["Luna", "LunaReader", "LunaDownloader", "LunaPriceTracker", "LunaVault"]

# The six schemes a human should ever pick.
VISIBLE = APPS + ["AllLunaApps"]

# Every native target that is NOT one of the five apps, read from the project so
# adding or removing a target needs no edit here. LunaTests is deliberately in
# this set: it has no scheme of its own by design (it hosts on the central Luna
# app and runs from the Luna scheme).
SUPPRESS = Xcodeproj::Project.open(PROJECT)
                             .native_targets
                             .reject { |t| APPS.include?(t.name) }
                             .map(&:uuid)

# Ask xcodebuild what schemes exist right now, so package-target schemes are
# discovered rather than hard-coded (Package.swift changes then need no edit
# here — just a re-run).
all = `xcodebuild -list -project #{PROJECT} 2>/dev/null`
       .split(/Schemes:\n/).last.to_s.lines.map(&:strip).reject(&:empty?)
raise "could not read scheme list" if all.empty?

hidden = all - VISIBLE
puts "visible (#{VISIBLE.size}): #{VISIBLE.join(', ')}"
puts "hidden  (#{hidden.size}): #{hidden.join(', ')}"

entries = []
VISIBLE.each_with_index do |name, i|
  entries << [name, true, i]
end
hidden.each_with_index do |name, i|
  entries << [name, false, VISIBLE.size + i]
end

body = entries.map { |name, shown, order|
  <<~XML.chomp
    \t\t<key>#{name}.xcscheme_^#shared#^_</key>
    \t\t<dict>
    \t\t\t<key>isShown</key>
    \t\t\t<#{shown}/>
    \t\t\t<key>orderHint</key>
    \t\t\t<integer>#{order}</integer>
    \t\t</dict>
  XML
}.join("\n")

suppress = SUPPRESS.map { |uuid|
  "\t\t<key>#{uuid}</key>\n\t\t<dict>\n\t\t\t<key>primary</key>\n\t\t\t<true/>\n\t\t</dict>"
}.join("\n")

plist = <<~XML
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
  \t<key>SchemeUserState</key>
  \t<dict>
  #{body}
  \t</dict>
  \t<key>SuppressBuildableAutocreation</key>
  \t<dict>
  #{suppress}
  \t</dict>
  </dict>
  </plist>
XML

dirs = Dir.glob("#{PROJECT}/xcuserdata/*.xcuserdatad/xcschemes")
# On a fresh clone xcuserdata/ does not exist yet (it is gitignored), so create
# the current user's directory rather than silently writing nothing.
if dirs.empty?
  dirs = [File.join(PROJECT, "xcuserdata", "#{ENV.fetch('USER')}.xcuserdatad", "xcschemes")]
  FileUtils.mkdir_p(dirs.first)
end

dirs.each do |dir|
  path = File.join(dir, "xcschememanagement.plist")
  File.write(path, plist)
  system("plutil", "-lint", path) or raise "plist failed lint: #{path}"
  puts "wrote #{path}"
end
