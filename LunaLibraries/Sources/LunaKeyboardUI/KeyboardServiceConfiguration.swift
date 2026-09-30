import Foundation

// Existing public client identifier retained for the original GIPHY integration.
enum KeyboardServiceConfiguration {
  static let giphyKey = [
    112, 105, 72, 111, 81, 77, 49, 66, 49, 89, 109, 76, 103, 81, 55, 114, 87, 83, 80, 121, 82, 122,
    49, 56, 101, 99, 115, 74, 67, 57, 76, 75,
  ].compactMap { UnicodeScalar($0) }.map(String.init).joined()
}
