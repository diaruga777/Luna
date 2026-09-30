//
//  PopUpKeyBezierPath.swift
//  LunaKeyboardUI
//
//  Created by Harry Sanabria on 9/9/21.
//

import Foundation
import UIKit

public enum PopUpKeyBezierPath {
  /// Normal state of the key, a rounded corner rectangle.
  case normal
  /// Popped up with only one item (the key's glyph), centered.
  case center
  /// Popped up with only one item (the key's glyph), offset to the right.
  /// Used when near the edge of the screen and `PopUpKeyBezierPath.center` doesnt fit.
  case right
  /// Popped up with only one item (the key's glyph), offset to the left.
  /// Used when near the edge of the screen and `PopUpKeyBezierPath.center` doesnt fit.
  case left
  /// Popped up with a menu of options, expanding out to the right.
  case expandRight(menuWidth: CGFloat)
  /// Popped up with a menu of options, expanding out to the left.
  case expandLeft(menuWidth: CGFloat)

  public func menuFrame(keyBounds: CGRect) -> CGRect {
    switch self {
    case .normal:
      return keyBounds
    case .center: return centerMenuFrame(keyBounds: keyBounds)
    case .right: return rightMenuFrame(keyBounds: keyBounds)
    case .left: return leftMenuFrame(keyBounds: keyBounds)
    case .expandRight(_): return expandedRightMenuFrame(keyBounds: keyBounds)
    case .expandLeft(_): return expandedLeftMenuFrame(keyBounds: keyBounds)
    }
  }

  public func path(keyBounds: CGRect, spacing: BoardSpacing) -> UIBezierPath {
    let pathGenerator: (_ keyBounds: CGRect, _ spacing: BoardSpacing) -> UIBezierPath
    switch self {
    case .normal: pathGenerator = self.normalPath
    case .center: pathGenerator = self.centerPath
    case .right: pathGenerator = self.rightPath
    case .left: pathGenerator = self.leftPath
    case .expandRight(_): pathGenerator = self.expandedRightPath
    case .expandLeft(_): pathGenerator = self.expandedLeftPath
    }
    return pathGenerator(keyBounds, spacing)
  }

  private func menuWidth(keyWidth: CGFloat) -> CGFloat {
    switch self {
    case .normal: return 0
    case .center, .right, .left:
      return keyWidth * Constants.expansionWidthMultiplier
    case .expandRight(let menuWidth), .expandLeft(let menuWidth):
      return max(menuWidth, keyWidth * Constants.expansionHeightMultiplier)
    }
  }

  public static func expansionSideBuffer(keyWidth: CGFloat) -> CGFloat {
    return keyWidth * (Constants.expansionWidthMultiplier - 1) / 2
  }

  private enum Constants {
    static let expansionWidthMultiplier: CGFloat = 1.5
    static let expansionHeightMultiplier: CGFloat = 1.2
  }
}

// MARK: Normal Path

extension PopUpKeyBezierPath {

  fileprivate func normalPath(
    keyBounds: CGRect,
    spacing: BoardSpacing
  ) -> UIBezierPath {
    return UIBezierPath(roundedRect: keyBounds, cornerRadius: spacing.keyCornerRadius)
  }
}

// MARK: Center Path

extension PopUpKeyBezierPath {

  fileprivate func centerMenuFrame(keyBounds: CGRect) -> CGRect {
    return CGRect(
      x: keyBounds.minX - PopUpKeyBezierPath.expansionSideBuffer(keyWidth: keyBounds.width),
      y: keyBounds.minY - keyBounds.height * Constants.expansionHeightMultiplier,
      width: menuWidth(keyWidth: keyBounds.width),
      height: keyBounds.height * Constants.expansionHeightMultiplier
    )
  }

  fileprivate func centerPath(
    keyBounds: CGRect,
    spacing: BoardSpacing
  ) -> UIBezierPath {
    let bezierPath = centerPathLeftHalf(keyBounds: keyBounds, spacing: spacing)

    // Mirror everything.
    let mirrored = bezierPath.mirrorX(over: keyBounds.midX).reversing()

    bezierPath.append(mirrored)

    // tape over the middle rounding errors.
    bezierPath.close()

    return bezierPath
  }

  fileprivate func centerPathLeftHalf(
    keyBounds: CGRect,
    spacing: BoardSpacing
  ) -> UIBezierPath {
    let base = keyBounds.width
    let keyCornerRadius = spacing.keyCornerRadius
    let menuCornerRadius = spacing.keyCornerRadius + spacing.betweenKeys
    let menuFrame = menuFrame(keyBounds: keyBounds)

    let bezierPath = UIBezierPath()

    // Start in the bottom, in the middle. We will go clockwise.
    let current = PointTracker.start(base / 2, keyBounds.height)
    bezierPath.move(to: current.point)
    // bottom to left
    bezierPath.addLine(to: current.next(keyCornerRadius, keyBounds.height))
    // bottom left corner
    bezierPath.addArc(
      withCenter: current.point.offset(y: -keyCornerRadius),
      radius: keyCornerRadius,
      startAngle: .pi / 2,
      endAngle: .pi,
      clockwise: true
    )
    current.move(-keyCornerRadius, -keyCornerRadius)
    // up the left side of the key
    bezierPath.addLine(to: current.next(0, keyCornerRadius))
    // First part of the curve from key to menu
    bezierPath.addCurve(
      to: current.next(current.x - (0.138 * base), current.y - (0.363 * base)),
      controlPoint1: current.point.offset(x: 0.138 * base, y: 0.207 * base),
      controlPoint2: current.point.offset(x: 0.057 * base, y: 0.0625 * base)
    )
    // Second part of the curve from key to menu
    bezierPath.addCurve(
      to: current.next(current.x - (0.112 * base), current.y - (0.34 * base)),
      controlPoint1: current.point.offset(x: 0.039 * base, y: 0.262 * base),
      controlPoint2: current.point.offset(y: 0.125 * base)
    )
    // up the left side of the menu
    bezierPath.addLine(to: current.next(current.x, -menuFrame.height + menuCornerRadius))
    // top left corner
    bezierPath.addArc(
      withCenter: current.point.offset(x: menuCornerRadius),
      radius: menuCornerRadius,
      startAngle: .pi,
      endAngle: .pi * 3 / 2,
      clockwise: true
    )
    current.move(menuCornerRadius, -menuCornerRadius)
    // The top left
    bezierPath.addLine(to: current.move(menuFrame.width / 2 - menuCornerRadius, 0))

    return bezierPath
  }
}

// MARK: Left/Right Path

extension PopUpKeyBezierPath {

  fileprivate func rightMenuFrame(keyBounds: CGRect) -> CGRect {
    return PopUpKeyBezierPath.center.menuFrame(keyBounds: keyBounds).offsetBy(
      dx: PopUpKeyBezierPath.expansionSideBuffer(keyWidth: keyBounds.width),
      dy: 0
    )
  }

  fileprivate func leftMenuFrame(keyBounds: CGRect) -> CGRect {
    return PopUpKeyBezierPath.center.menuFrame(keyBounds: keyBounds).offsetBy(
      dx: -PopUpKeyBezierPath.expansionSideBuffer(keyWidth: keyBounds.width),
      dy: 0
    )
  }

  fileprivate func rightPath(
    keyBounds: CGRect,
    spacing: BoardSpacing
  ) -> UIBezierPath {
    return PopUpKeyBezierPath.left.leftPath(
      keyBounds: keyBounds,
      spacing: spacing
    ).mirrorX(over: keyBounds.midX)
  }

  fileprivate func leftPath(
    keyBounds: CGRect,
    spacing: BoardSpacing
  ) -> UIBezierPath {
    let base = keyBounds.width
    let keyCornerRadius = spacing.keyCornerRadius
    let menuCornerRadius = spacing.keyCornerRadius + spacing.betweenKeys
    let menuFrame = menuFrame(keyBounds: keyBounds)

    let bezierPath = UIBezierPath()

    // Start in the bottom, in the middle. We will go clockwise.
    let current = PointTracker.start(base / 2, keyBounds.height)
    bezierPath.move(to: current.point)
    // bottom to left
    bezierPath.addLine(to: current.next(keyCornerRadius, keyBounds.height))
    // bottom left corner
    bezierPath.addArc(
      withCenter: current.point.offset(y: -keyCornerRadius),
      radius: keyCornerRadius,
      startAngle: .pi / 2,
      endAngle: .pi,
      clockwise: true
    )
    current.move(-keyCornerRadius, -keyCornerRadius)
    // up the left side of the key
    bezierPath.addLine(to: current.next(0, keyCornerRadius * 2))
    // First part of the curve from key to menu
    bezierPath.addCurve(
      to: current.next(current.x - (0.25 * base), current.y - (0.609 * base)),
      controlPoint1: current.point.offset(x: 0.25 * base, y: 0.25 * base),
      controlPoint2: current.point.offset(x: 0.187 * base, y: 0.266 * base)
    )
    // Second part of the curve from key to menu
    bezierPath.addCurve(
      to: current.next(current.x - (0.25 * base), current.y - (0.547 * base)),
      controlPoint1: current.point.offset(x: 0.063 * base, y: 0.328 * base),
      controlPoint2: current.point.offset(y: 0.266 * base)
    )
    // up the left side of the menu
    bezierPath.addLine(to: current.next(current.x, -menuFrame.height + menuCornerRadius))
    // top left corner
    bezierPath.addArc(
      withCenter: current.point.offset(x: menuCornerRadius),
      radius: menuCornerRadius,
      startAngle: .pi,
      endAngle: .pi * 3 / 2,
      clockwise: true
    )
    current.move(menuCornerRadius, -menuCornerRadius)
    // The top
    bezierPath.addLine(to: current.move(menuFrame.width - (menuCornerRadius * 2), 0))
    // top right corner
    bezierPath.addArc(
      withCenter: current.point.offset(y: menuCornerRadius),
      radius: menuCornerRadius,
      startAngle: .pi * 3 / 2,
      endAngle: .pi * 2,
      clockwise: true
    )
    current.move(menuCornerRadius, menuCornerRadius)
    // the full right side
    bezierPath.addLine(to: current.next(base, keyBounds.height - keyCornerRadius))
    // bottom right corner
    bezierPath.addArc(
      withCenter: current.point.offset(x: -keyCornerRadius),
      radius: keyCornerRadius,
      startAngle: 0,
      endAngle: .pi / 2,
      clockwise: true
    )
    current.move(-menuCornerRadius, menuCornerRadius)
    // And complete the bottom
    bezierPath.close()

    return bezierPath
  }
}

// MARK: Left/Right Expanded Path

extension PopUpKeyBezierPath {

  fileprivate func expandedRightMenuFrame(keyBounds: CGRect) -> CGRect {
    let centerFrame = PopUpKeyBezierPath.center.menuFrame(keyBounds: keyBounds)
    return CGRect(
      x: centerFrame.minX,
      y: centerFrame.minY,
      width: menuWidth(keyWidth: keyBounds.width),
      height: centerFrame.height
    )
  }

  fileprivate func expandedLeftMenuFrame(keyBounds: CGRect) -> CGRect {
    let centerFrame = PopUpKeyBezierPath.center.menuFrame(keyBounds: keyBounds)
    let menuWidth = self.menuWidth(keyWidth: keyBounds.width)
    return CGRect(
      x: centerFrame.maxX - menuWidth,
      y: centerFrame.minY,
      width: menuWidth,
      height: centerFrame.height
    )
  }

  fileprivate func expandedRightPath(
    keyBounds: CGRect,
    spacing: BoardSpacing
  ) -> UIBezierPath {
    return PopUpKeyBezierPath.expandLeft(
      menuWidth: menuWidth(keyWidth: keyBounds.width)
    ).expandedLeftPath(
      keyBounds: keyBounds,
      spacing: spacing
    ).mirrorX(over: keyBounds.midX)
  }

  fileprivate func expandedLeftPath(
    keyBounds: CGRect,
    spacing: BoardSpacing
  ) -> UIBezierPath {
    let base = keyBounds.width
    let keyCornerRadius = spacing.keyCornerRadius
    let menuCornerRadius = spacing.keyCornerRadius + spacing.betweenKeys
    let menuFrame = menuFrame(keyBounds: keyBounds)

    let bezierPath = UIBezierPath()

    // Start in the bottom, in the middle. We will go clockwise.
    let current = PointTracker.start(base / 2, keyBounds.maxY)
    bezierPath.move(to: current.point)
    // bottom to left
    bezierPath.addLine(to: current.next(keyCornerRadius, keyBounds.height))
    // bottom left corner
    bezierPath.addArc(
      withCenter: current.point.offset(y: -keyCornerRadius),
      radius: keyCornerRadius,
      startAngle: .pi / 2,
      endAngle: .pi,
      clockwise: true
    )
    current.move(-keyCornerRadius, -keyCornerRadius)
    // up the left side of the key
    bezierPath.addLine(to: current.next(0, keyCornerRadius))
    // The inner corner
    bezierPath.addArc(
      withCenter: current.point.offset(x: -menuCornerRadius),
      radius: menuCornerRadius,
      startAngle: .pi * 2,
      endAngle: .pi * 3 / 2,
      clockwise: false
    )
    current.move(-menuCornerRadius, -menuCornerRadius)
    // The bottom side of the menu.
    bezierPath.addLine(to: current.next(menuFrame.minX + menuCornerRadius, current.y))
    // The bottom left corner of the menu
    bezierPath.addArc(
      withCenter: current.point.offset(y: -menuCornerRadius),
      radius: menuCornerRadius,
      startAngle: .pi / 2,
      endAngle: .pi,
      clockwise: true
    )
    current.move(-menuCornerRadius, -menuCornerRadius)
    // up the left side of the menu
    bezierPath.addLine(to: current.next(menuFrame.minX, menuFrame.minY + menuCornerRadius))
    // top left corner
    bezierPath.addArc(
      withCenter: current.point.offset(x: menuCornerRadius),
      radius: menuCornerRadius,
      startAngle: .pi,
      endAngle: .pi * 3 / 2,
      clockwise: true
    )
    current.move(menuCornerRadius, -menuCornerRadius)
    // The top left
    bezierPath.addLine(to: current.next(base / 2, menuFrame.minY))

    // And add a mirrored version of the center menu on the right side.
    let mirroredCenter = PopUpKeyBezierPath.center.centerPathLeftHalf(
      keyBounds: keyBounds,
      spacing: spacing
    ).mirrorX(over: keyBounds.midX).reversing()

    bezierPath.append(mirroredCenter)

    // tape over the middle rounding errors.
    bezierPath.close()

    return bezierPath
  }
}

private class PointTracker {
  private(set) var point: CGPoint

  var x: CGFloat {
    return point.x
  }

  var y: CGFloat {
    return point.y
  }

  private init(_ point: CGPoint) {
    self.point = point
  }

  static func start(_ x: CGFloat, _ y: CGFloat) -> PointTracker {
    return PointTracker.init(CGPoint(x: x, y: y))
  }

  @discardableResult
  func next(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    let point = CGPoint(x: x, y: y)
    self.point = point
    return point
  }

  @discardableResult
  func move(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    return next(self.x + x, self.y + y)
  }
}

extension PopUpKeyBezierPath: Equatable {}

extension UIBezierPath {
  fileprivate func mirrorX(over offset: CGFloat) -> UIBezierPath {
    let result = copy() as! UIBezierPath
    result.apply(CGAffineTransform(translationX: -offset, y: 0))
    result.apply(CGAffineTransform(scaleX: -1, y: 1))
    result.apply(CGAffineTransform(translationX: offset, y: 0))
    return result
  }
}
