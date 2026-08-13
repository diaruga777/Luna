//
//  LinkAnchor.swift
//  LunaShare
//
//  This target's code lives entirely in linked libraries (principal class
//  `LunaShareSurface.ShareViewController`), so without this file the target
//  would compile no sources of its own. A source-less app-extension target
//  links through Xcode's stub-executor path, which fails to produce an
//  executable once the link closure includes the LunaTransitions/Metal facade
//  — the appex ends up missing its bundle executable, and install fails. One
//  trivial source file forces the normal link path instead, the same one the
//  main app target uses. Do not remove this file.
//

import Foundation

enum LunaShareLinkAnchor {}
