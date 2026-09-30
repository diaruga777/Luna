//
//  Accents.swift
//  LunaKeyboardCore
//
//  Created by Harry Sanabria on 9/10/21.
//

import Foundation

public class Accents {
  public static func accents(for str: String) -> [String] {
    switch str {
    case "e":
      return ["è", "é", "ê", "ë", "ē", "ė", "ę"]
    case "E":
      return ["È", "É", "Ê", "Ë", "Ē", "Ė", "Ę"]
    case "y":
      return ["ÿ"]
    case "Y":
      return ["Ÿ"]
    case "u":
      return ["û", "ü", "ù", "ú", "ū"]
    case "U":
      return ["Û", "Ü", "Ù", "Ú", "Ū"]
    case "i":
      return ["î", "ï", "í", "ī", "į", "ì"]
    case "I":
      return ["Î", "Ï", "Í", "Ī", "Į", "Ì"]
    case "o":
      return ["ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"]
    case "O":
      return ["Ô", "Ö", "Ò", "Ó", "Œ", "Ø", "Ō", "Õ"]
    case "a":
      return ["à", "á", "â", "ä", "æ", "ã", "å", "ā"]
    case "A":
      return ["À", "Á", "Â", "Ä", "Æ", "Ã", "Å", "Ā"]
    case "s":
      return ["ß", "ś", "š"]
    case "S":
      return ["Ś", "Š"]
    case "l":
      return ["ł"]
    case "L":
      return ["Ł"]
    case "z":
      return ["ž", "ź", "ż"]
    case "Z":
      return ["Ž", "Ź", "Ż"]
    case "c":
      return ["ç", "ć", "č"]
    case "C":
      return ["Ç", "Ć", "Č"]
    case "n":
      return ["ñ", "ń"]
    case "N":
      return ["Ñ", "Ń"]
    default:
      return NumbersAndSymbols.altSymbols(for: str)
    }
  }
}
