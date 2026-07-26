#!/usr/bin/env ruby
# frozen_string_literal: true

# One-time, idempotent migration helper for UIKit literals. SwiftUI and
# AppIntents literals are extracted by the compiler; UIKit's String properties
# are not, so the obvious presentation contexts below need an explicit lookup.

ROOTS = %w[
  Luna
  LunaReaderClip
  LunaDownloaderClip
  LunaLibraries/Sources
].freeze

EXCLUDED_PATH_PARTS = %w[
  /Mail/Intents/
  /LunaIntents/
  /LunaTests/
  /Tests/
  UITest
].freeze

PRESENTATION_IMPORTS = /\bimport (?:UIKit|SwiftUI|UserNotifications)\b/
PRESENTATION_MODEL_PATHS = %r{
  LunaLibraries/Sources/
  (?:
    LunaDesignSystem/(?:AppearanceSettings|ReaderFont)\.swift|
    LunaMediaDownload/(?:AutoDownloadSettings|LiveMediaDownloadJob|MediaDownload|MediaStorageSettings|SavedMediaStore)\.swift|
    LunaModels/(?:CaptureSource|ContentModels|LunaApp|RescueHint|SaveFailureReason)\.swift|
    LunaReadingListUI/ReadingListSectioning\.swift|
    LunaStorage/DoubleSaveActionStore\.swift
  )
}x
RETURN_PATHS = %r{
  (?:
    Luna/Settings/|
    LunaReaderClip/ClipReaderViewController\.swift|
    LunaDownloaderClip/ClipDownloadViewController\.swift|
    #{PRESENTATION_MODEL_PATHS}
  )
}x

LABELED_ARGUMENT = /
  \b(
    accessibilityHint|accessibilityLabel|accessibilityValue|
    buttonTitle|cancelTitle|detail|displayName|emptyMessage|footerTitle|
    headerTitle|message|placeholder|prompt|sectionTitle|subtitle|text|title
  ):\s*
/x
PRESENTATION_ASSIGNMENT = /
  (?:
    \.(?:accessibilityHint|accessibilityLabel|accessibilityValue|placeholder|text)|
    \b(?:detail|emptyMessage|footerTitle|headerTitle|message|prompt|sectionTitle|subtitle|title)
  )\s*=
/x
PRESENTATION_CALL = /
  \b(?:NSAttributedString|Text|Label)\s*\(|
  \b(?:setTitle|showToast)\s*\(
/x
PRESENTATION_COLLECTION = /
  \bUISegmentedControl\s*\(\s*items:\s*\[
/x

def human_facing?(literal)
  value = literal[1...-1]
  return false if value.empty?
  return false unless value.match?(/[A-Za-z]/)

  true
end

def consume_string(source, start)
  return nil unless source[start] == '"'
  return nil if source[start, 3] == '"""'

  cursor = start + 1
  while cursor < source.length
    case source[cursor]
    when "\\"
      if source[cursor + 1] == "("
        cursor += 2
        depth = 1
        while cursor < source.length && depth.positive?
          if source[cursor] == '"'
            nested_end = consume_string(source, cursor)
            cursor = nested_end || cursor + 1
          elsif source[cursor] == "("
            depth += 1
            cursor += 1
          elsif source[cursor] == ")"
            depth -= 1
            cursor += 1
          elsif source[cursor] == "\\"
            cursor += 2
          else
            cursor += 1
          end
        end
      else
        cursor += 2
      end
    when '"'
      return cursor + 1
    else
      cursor += 1
    end
  end

  nil
end

def string_literal_ranges(source, start = 0)
  ranges = []
  cursor = start
  while cursor < source.length
    if source[cursor] == '"'
      finish = consume_string(source, cursor)
      if finish
        ranges << (cursor...finish)
        cursor = finish
        next
      end
    end
    cursor += 1
  end
  ranges
end

def localize_literals(fragment)
  ranges = string_literal_ranges(fragment)
  ranges.reverse_each do |range|
    literal = fragment[range]
    next unless human_facing?(literal)

    fragment = fragment[0...range.begin] + "L10n.string(#{literal})" + fragment[range.end..]
  end
  fragment
end

files = ROOTS.flat_map { |root| Dir.glob(File.join(root, "**", "*.swift")) }
files.reject! { |path| EXCLUDED_PATH_PARTS.any? { |part| path.include?(part) } }
files.select! do |path|
  source = File.read(path)
  source.match?(PRESENTATION_IMPORTS) || path.match?(PRESENTATION_MODEL_PATHS)
end

changed = []

files.each do |path|
  lines = File.readlines(path, chomp: false)
  uses_l10n = false
  previous_localized_continuation = false

  migrated = lines.map do |line|
    original = line

    unless line.include?("L10n.string(")
      # Labeled presentation arguments can occur more than once on a line.
      cursor = 0
      rebuilt = +""
      while (match = LABELED_ARGUMENT.match(line, cursor))
        rebuilt << line[cursor...match.end(0)]
        literal_range = string_literal_ranges(line, match.end(0)).first
        unless literal_range && line[match.end(0)...literal_range.begin].strip.empty?
          cursor = match.end(0)
          next
        end
        rebuilt << line[match.end(0)...literal_range.begin]
        literal = line[literal_range]
        rebuilt << (human_facing?(literal) ? "L10n.string(#{literal})" : literal)
        cursor = literal_range.end
      end
      if cursor.positive?
        rebuilt << line[cursor..]
        line = rebuilt
      end

      if (match = PRESENTATION_ASSIGNMENT.match(line))
        line = line[0...match.end(0)] + localize_literals(line[match.end(0)..])
      elsif (match = PRESENTATION_CALL.match(line))
        line = line[0...match.end(0)] + localize_literals(line[match.end(0)..])
      elsif (match = PRESENTATION_COLLECTION.match(line))
        line = line[0...match.end(0)] + localize_literals(line[match.end(0)..])
      elsif path.match?(RETURN_PATHS) && line.match?(/\breturn\s+"/)
        literal_range = string_literal_ranges(line, line.index("return") + 6).first
        next line unless literal_range
        literal = line[literal_range]
        value = literal[1...-1]
        looks_like_copy = value.match?(/\A[A-Z]/) && !value.match?(/\A[A-Z0-9_]+\z/)
        if looks_like_copy
          line = line[0...literal_range.begin] +
                 "L10n.string(#{literal})" +
                 line[literal_range.end..]
        end
      elsif previous_localized_continuation && line.match?(/^\s*\+\s*"/)
        line = localize_literals(line)
      end
    end

    uses_l10n ||= line.include?("L10n.string(")
    previous_localized_continuation =
      line.include?("L10n.string(") || (previous_localized_continuation && line.strip.start_with?("+"))
    changed << path if line != original
    line
  end

  next unless uses_l10n

  unless path.include?("/LunaModels/") || migrated.any? { |line| line.match?(/^import LunaModels\s*$/) }
    import_index = migrated.rindex { |line| line.match?(/^import\s+\w+/) }
    migrated.insert(import_index ? import_index + 1 : 0, "import LunaModels\n")
    changed << path
  end

  File.write(path, migrated.join)
end

puts changed.uniq.sort
puts "Migrated #{changed.uniq.count} files."
