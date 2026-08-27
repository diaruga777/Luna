# frozen_string_literal: true

# Xcode 16/26 projects use synchronized source groups that older releases of
# the xcodeproj gem do not know how to deserialize. Keep the topology scripts
# usable on the repository's pinned gem until that gem gains native support.
require "xcodeproj"

module Xcodeproj
  class Project
    module Object
      class XCLocalSwiftPackageReference < XCRemoteSwiftPackageReference
        attribute :relative_path, String
      end

      class PBXFileSystemSynchronizedBuildFileExceptionSet < AbstractObject
        attribute :membership_exceptions, Array, []
        has_one :target, PBXNativeTarget
      end

      class PBXFileSystemSynchronizedRootGroup < PBXGroup
        attribute :explicit_file_types, Hash, {}
        attribute :explicit_folders, Array, []
        has_many :exceptions, PBXFileSystemSynchronizedBuildFileExceptionSet
      end

      class PBXNativeTarget
        has_many :file_system_synchronized_groups, PBXFileSystemSynchronizedRootGroup
      end
    end
  end
end

Xcodeproj::Constants.send(:remove_const, :LAST_KNOWN_OBJECT_VERSION)
Xcodeproj::Constants.const_set(:LAST_KNOWN_OBJECT_VERSION, 71)
