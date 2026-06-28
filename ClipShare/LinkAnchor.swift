//
//  LinkAnchor.swift
//  ClipShare
//
//  This target's code lives entirely in linked libraries (principal class
//  `ClipShareSurface.ShareViewController`), so it would otherwise have no compiled
//  sources. A source-less app-extension target links via Xcode's "stub executor"
//  path, which fails to produce an executable once the link closure includes the
//  ClipTransitions/Metal facade (the appex ends up missing its bundle executable and
//  install fails). One trivial source forces the normal link path, which handles the
//  closure correctly — exactly like the main app target does. Do not remove.
//

import Foundation

enum ClipShareLinkAnchor {}
