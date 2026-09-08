# frozen_string_literal: true

# Xcode 16/26 projects use synchronized source groups that older releases of
# the xcodeproj gem do not know how to deserialize. Keep the topology scripts
# usable on the repository's pinned gem until that gem gains native support.
#
# Each shim is skipped when the installed gem already declares the class:
# re-opening one that the gem defines with a different superclass raises
# `superclass mismatch`, which took every topology script down on xcodeproj
# 1.27.0.
require "xcodeproj"

module Xcodeproj
  class Project
    module Object
      unless const_defined?(:XCLocalSwiftPackageReference, false)
        class XCLocalSwiftPackageReference < XCRemoteSwiftPackageReference
          attribute :relative_path, String

          # A local reference has no repository URL, so the inherited
          # annotation falls back to the class name. Name the package folder
          # instead, which is what Xcode writes.
          def display_name
            relative_path ? File.basename(relative_path.to_s) : super
          end
        end
      end

      unless const_defined?(:PBXFileSystemSynchronizedBuildFileExceptionSet, false)
        class PBXFileSystemSynchronizedBuildFileExceptionSet < AbstractObject
          attribute :membership_exceptions, Array, []
          has_one :target, PBXNativeTarget
        end
      end

      unless const_defined?(:PBXFileSystemSynchronizedRootGroup, false)
        class PBXFileSystemSynchronizedRootGroup < PBXGroup
          attribute :explicit_file_types, Hash, {}
          attribute :explicit_folders, Array, []
          has_many :exceptions, PBXFileSystemSynchronizedBuildFileExceptionSet
        end
      end

      unless PBXNativeTarget.instance_methods.include?(:file_system_synchronized_groups)
        class PBXNativeTarget
          has_many :file_system_synchronized_groups, PBXFileSystemSynchronizedRootGroup
        end
      end
    end
  end
end

if Xcodeproj::Constants::LAST_KNOWN_OBJECT_VERSION < 71
  Xcodeproj::Constants.send(:remove_const, :LAST_KNOWN_OBJECT_VERSION)
  Xcodeproj::Constants.const_set(:LAST_KNOWN_OBJECT_VERSION, 71)
end
