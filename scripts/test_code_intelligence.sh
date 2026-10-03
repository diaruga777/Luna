#!/usr/bin/env bash
# Builds a disposable UIKit app with an external package, then exercises the
# real Xcode SourceKit server without saving the virtual edits to disk.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d /tmp/LunaCodeIntelligence.XXXXXX)"
FIXTURE="$(cd "$FIXTURE" && pwd -P)"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/Support/Sources/FixtureSupport"
cat > "$FIXTURE/Support/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FixtureSupport", products: [.library(name: "FixtureSupport", targets: ["FixtureSupport"])], targets: [.target(name: "FixtureSupport")])
SWIFT
cat > "$FIXTURE/Support/Sources/FixtureSupport/Store.swift" <<'SWIFT'
public struct FixtureStore {
    public init() {}
    public var recordCount: Int { 42 }
    public func readRecord() -> String { "record" }
}
SWIFT
cat > "$FIXTURE/Main.swift" <<'SWIFT'
import UIKit
import FixtureSupport
@main final class FixtureApp: UIResponder, UIApplicationDelegate {
    let store = FixtureStore()
}
SWIFT
ruby - "$REPO" "$FIXTURE" <<'RUBY'
require File.join(ARGV[0], 'scripts/xcodeproj_compat')
p = Xcodeproj::Project.new(File.join(ARGV[1], 'Fixture.xcodeproj'))
t = p.new_target(:application, 'Fixture', :ios, '26.0')
t.add_file_references([p.main_group.new_file('Main.swift')])
t.build_configurations.each { |c| c.build_settings.merge!({'SWIFT_VERSION'=>'5.0','GENERATE_INFOPLIST_FILE'=>'YES','PRODUCT_BUNDLE_IDENTIFIER'=>'dev.luna.code.fixture','CODE_SIGN_STYLE'=>'Automatic','TARGETED_DEVICE_FAMILY'=>'1,2'}) }
r = p.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference); r.relative_path='Support';p.root_object.package_references << r
d = p.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency);d.package=r;d.product_name='FixtureSupport';t.package_product_dependencies << d
f = p.new(Xcodeproj::Project::Object::PBXBuildFile);f.product_ref=d;t.frameworks_build_phase.files << f
p.save
s=Xcodeproj::XCScheme.new;s.add_build_target(t);s.set_launch_target(t);s.save_as(p.path,'Fixture',true)
RUBY
xcodebuild build -project "$FIXTURE/Fixture.xcodeproj" -scheme Fixture \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$FIXTURE/DerivedData" \
  -resultBundlePath "$FIXTURE/BuildResult.xcresult" > "$FIXTURE/build.log" 2>&1 || { cat "$FIXTURE/build.log"; exit 1; }
LUNA_CODE_INTELLIGENCE_FIXTURE="$FIXTURE" swift test --package-path "$REPO/LunaCodeKit"
