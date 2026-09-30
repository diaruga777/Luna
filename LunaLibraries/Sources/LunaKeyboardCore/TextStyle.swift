//
//  TextStyle.swift
//  LunaKeyboardCore
//
//  Created by Harry Sanabria on 9/7/21.
//

import Foundation

public enum TextStyle: String, CaseIterable {
  case regular
  case bold
  case italic
  case boldItalic
  case underscore
  case strikethrough
  case gothic
  case gothicBold
  case monospace
  case spaced
  case script
  case superscript
  case boxed
  case inverseBoxed
  case circled
  case doubleStroke
  case zalgo
  case ransom
  case spongeBob = "SpongeBob"
}

extension TextStyle {

  public static var shortcutCases: [TextStyle] {
    return [
      .regular,
      .bold,
      .italic,
      .underscore,
      .monospace,
      .strikethrough,
    ]
  }
}

extension TextStyle {

  public func style(_ str: String, preceding: String = "") -> String {
    if self == .spongeBob {
      var history = Array(String(preceding.suffix(256)).styleErased.filter { $0.isUppercase || $0.isLowercase }.suffix(2))
      var result = ""
      func appendCased(_ letter: Character) {
        guard letter.isUppercase || letter.isLowercase else { result.append(letter); return }
        let forceOpposite = history.count == 2 && history[0].isUppercase == history[1].isUppercase
          && history[1].isUppercase == letter.isUppercase
        let output = forceOpposite ? (letter.isUppercase ? String(letter).lowercased() : String(letter).uppercased()) : String(letter)
        // Unicode case mappings can expand into several letters (ß, ﬃ).
        if output.count > 1 { for expanded in output { appendCased(expanded) }; return }
        result += output
        history = Array((history + Array(output)).suffix(2))
      }
      for character in str.styleErased {
        let output = Bool.random() ? String(character).uppercased() : String(character).lowercased()
        for letter in output { appendCased(letter) }
      }
      return result
    }
    guard str.count == 1 else {
      return str.asArray.map({ style($0) }).joined()
    }
    if self == .regular {
      return TextStyle.reverseMap[str] ?? str
    }
    if self == .ransom {
      return (TextStyle.allCases.filter { $0 != .ransom && $0 != .spongeBob }.randomElement() ?? .regular).style(str)
    }
    guard let index = TextStyle.stylables.firstIndex(of: str.styleErased) else {
      return str
    }
    return TextStyle.stylableMaps[self]![index]
  }

  private static let stylables =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890!@#$%^&*()-_=+[{]}\\|;:'\",<.>/?`~ "
    .asArray

  private static let stylableMaps: [TextStyle: [String]] = [
    bold:
      "𝐚𝐛𝐜𝐝𝐞𝐟𝐠𝐡𝐢𝐣𝐤𝐥𝐦𝐧𝐨𝐩𝐪𝐫𝐬𝐭𝐮𝐯𝐰𝐱𝐲𝐳𝐀𝐁𝐂𝐃𝐄𝐅𝐆𝐇𝐈𝐉𝐊𝐋𝐌𝐍𝐎𝐏𝐐𝐑𝐒𝐓𝐔𝐕𝐖𝐗𝐘𝐙𝟏𝟐𝟑𝟒𝟓𝟔𝟕𝟖𝟗𝟎!@#$%^&*()-_=+[{]}\\|;:'\",<.>/?`~ "
      .asArray,
    italic:
      "𝘢𝘣𝘤𝘥𝘦𝘧𝘨𝘩𝘪𝘫𝘬𝘭𝘮𝘯𝘰𝘱𝘲𝘳𝘴𝘵𝘶𝘷𝘸𝘹𝘺𝘻𝘈𝘉𝘊𝘋𝘌𝘍𝘎𝘏𝘐𝘑𝘒𝘓𝘔𝘕𝘖𝘗𝘘𝘙𝘚𝘛𝘜𝘝𝘞𝘟𝘠𝘡1234567890!@#$%^&*()-_=+[{]}\\|;:'\",<.>/?`~ "
      .asArray,
    boldItalic:
      "𝙖𝙗𝙘𝙙𝙚𝙛𝙜𝙝𝙞𝙟𝙠𝙡𝙢𝙣𝙤𝙥𝙦𝙧𝙨𝙩𝙪𝙫𝙬𝙭𝙮𝙯𝘼𝘽𝘾𝘿𝙀𝙁𝙂𝙃𝙄𝙅𝙆𝙇𝙈𝙉𝙊𝙋𝙌𝙍𝙎𝙏𝙐𝙑𝙒𝙓𝙔𝙕1234567890!@#$%^&*()-_=+[{]}\\|;:'\",<.>/?`~ "
      .asArray,
    underscore:
      "a̲b̲c̲d̲e̲f̲g̲h̲i̲j̲k̲l̲m̲n̲o̲p̲q̲r̲s̲t̲u̲v̲w̲x̲y̲z̲A̲B̲C̲D̲E̲F̲G̲H̲I̲J̲K̲L̲M̲N̲O̲P̲Q̲R̲S̲T̲U̲V̲W̲X̲Y̲Z̲1̲2̲3̲4̲5̲6̲7̲8̲9̲0̲!̲@̲#̲$̲%̲^̲&̲*̲(̲)̲-̲_̲=̲+̲[̲{̲]̲}̲\\̲|̲;̲:̲'̲\"̲,̲<̲.̲>̲/̲?̲`̲~̲ ̲"
      .asArray,
    strikethrough:
      "a̶b̶c̶d̶e̶f̶g̶h̶i̶j̶k̶l̶m̶n̶o̶p̶q̶r̶s̶t̶u̶v̶w̶x̶y̶z̶A̶B̶C̶D̶E̶F̶G̶H̶I̶J̶K̶L̶M̶N̶O̶P̶Q̶R̶S̶T̶U̶V̶W̶X̶Y̶Z̶1̶2̶3̶4̶5̶6̶7̶8̶9̶0̶!̶@̶#̶$̶%̶^̶&̶*̶(̶)̶-̶_̶=̶+̶[̶{̶]̶}̶\\̶|̶;̶:̶'̶\"̶,̶<̶.̶>̶/̶?̶`̶~̶ ̶"
      .asArray,
    gothic:
      "𝔞𝔟𝔠𝔡𝔢𝔣𝔤𝔥𝔦𝔧𝔨𝔩𝔪𝔫𝔬𝔭𝔮𝔯𝔰𝔱𝔲𝔳𝔴𝔵𝔶𝔷𝔄𝔅ℭ𝔇𝔈𝔉𝔊ℌℑ𝔍𝔎𝔏𝔐𝔑𝔒𝔓𝔔ℜ𝔖𝔗𝔘𝔙𝔚𝔛𝔜ℨ1234567890!@#$%^&*()-_=+[{]}\\|;:'\",<.>/?`~ "
      .asArray,
    gothicBold:
      "𝖆𝖇𝖈𝖉𝖊𝖋𝖌𝖍𝖎𝖏𝖐𝖑𝖒𝖓𝖔𝖕𝖖𝖗𝖘𝖙𝖚𝖛𝖜𝖝𝖞𝖟𝕬𝕭𝕮𝕯𝕰𝕱𝕲𝕳𝕴𝕵𝕶𝕷𝕸𝕹𝕺𝕻𝕼𝕽𝕾𝕿𝖀𝖁𝖂𝖃𝖄𝖅1234567890!@#$%^&*()-_=+[{]}\\|;:'\",<.>/?`~ "
      .asArray,
    monospace:
      "𝚊𝚋𝚌𝚍𝚎𝚏𝚐𝚑𝚒𝚓𝚔𝚕𝚖𝚗𝚘𝚙𝚚𝚛𝚜𝚝𝚞𝚟𝚠𝚡𝚢𝚣𝙰𝙱𝙲𝙳𝙴𝙵𝙶𝙷𝙸𝙹𝙺𝙻𝙼𝙽𝙾𝙿𝚀𝚁𝚂𝚃𝚄𝚅𝚆𝚇𝚈𝚉𝟷𝟸𝟹𝟺𝟻𝟼𝟽𝟾𝟿𝟶!@#$%^&*()-_=+[{]}\\|;:'\",<.>/?`~ "
      .asArray,
    spaced:
      "ａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺ１２３４５６７８９０！＠＃＄％^＆＊（）－_＝＋[{]}\\|；：＇\"，<．>／？`~ "
      .asArray,
    script:
      "𝒶𝒷𝒸𝒹𝑒𝒻𝑔𝒽𝒾𝒿𝓀𝓁𝓂𝓃𝑜𝓅𝓆𝓇𝓈𝓉𝓊𝓋𝓌𝓍𝓎𝓏𝒜𝐵𝒞𝒟𝐸𝐹𝒢𝐻𝐼𝒥𝒦𝐿𝑀𝒩𝒪𝒫𝒬𝑅𝒮𝒯𝒰𝒱𝒲𝒳𝒴𝒵𝟣𝟤𝟥𝟦𝟧𝟨𝟩𝟪𝟫𝟢!@#$%^&*()-_=+[{]}\\|;:'\",<.>/?`~ "
      .asArray,
    superscript:
      "ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖqʳˢᵗᵘᵛʷˣʸᶻᴬᴮᶜᴰᴱᶠᴳᴴᴵᴶᴷᴸᴹᴺᴼᴾQᴿˢᵀᵁⱽᵂˣʸᶻ¹²³⁴⁵⁶⁷⁸⁹⁰!@#$%^&*⁽⁾⁻_⁼⁺[{]}\\|;:'\",<.>/?`~ "
      .asArray,
    boxed:
      "🄰🄱🄲🄳🄴🄵🄶🄷🄸🄹🄺🄻🄼🄽🄾🄿🅀🅁🅂🅃🅄🅅🅆🅇🅈🅉🄰🄱🄲🄳🄴🄵🄶🄷🄸🄹🄺🄻🄼🄽🄾🄿🅀🅁🅂🅃🅄🅅🅆🅇🅈🅉1234567890!@#$%^&*()-_=+[{]}\\|;:'\",<.>/?`~ "
      .asArray,
    inverseBoxed:
      "🅰🅱🅲🅳🅴🅵🅶🅷🅸🅹🅺🅻🅼🅽🅾🅿🆀🆁🆂🆃🆄🆅🆆🆇🆈🆉🅰🅱🅲🅳🅴🅵🅶🅷🅸🅹🅺🅻🅼🅽🅾🅿🆀🆁🆂🆃🆄🆅🆆🆇🆈🆉1234567890!@#$%^&*()-_=+[{]}\\|;:'\",<.>/?`~ "
      .asArray,
    circled:
      "ⓐⓑⓒⓓⓔⓕⓖⓗⓘⓙⓚⓛⓜⓝⓞⓟⓠⓡⓢⓣⓤⓥⓦⓧⓨⓩⒶⒷⒸⒹⒺⒻⒼⒽⒾⒿⓀⓁⓂⓃⓄⓅⓆⓇⓈⓉⓊⓋⓌⓍⓎⓏ①②③④⑤⑥⑦⑧⑨⓪!@#$%^&*()-_=+[{]}\\|;:'\",<.>/?`~ "
      .asArray,
    doubleStroke:
      "𝕒𝕓𝕔𝕕𝕖𝕗𝕘𝕙𝕚𝕛𝕜𝕝𝕞𝕟𝕠𝕡𝕢𝕣𝕤𝕥𝕦𝕧𝕨𝕩𝕪𝕫𝔸𝔹ℂ𝔻𝔼𝔽𝔾ℍ𝕀𝕁𝕂𝕃𝕄ℕ𝕆ℙℚℝ𝕊𝕋𝕌𝕍𝕎𝕏𝕐ℤ𝟙𝟚𝟛𝟜𝟝𝟞𝟟𝟠𝟡𝟘!@#$%^&*()-_=+[{]}\\|;:'\",<.>/?`~ "
      .asArray,
    zalgo:
      "à̶̭͍̔͛̏̕b̶̜̏ͅc̶͎̳̲̻̭͙͂̽̅͑͝͝d̴͇̘̱̙̰͓͊͝ḛ̶̟̠̲̰̍̂̓́͒f̵̯̖͇̻̩̓̈́͋̀͋̾͜ġ̶̯͋͠ͅh̵̡͍͉̿͂̔͝i̴̠͕͉̋̐j̷̺̪͉̝̫͓̀k̵̨̼̾̈́͂̾͝l̶͙̟̿̾͊̓̇̄͜m̴̨͍̫̼̈́͒̈́͝ņ̴̳̞̄͌͒͌o̶̧̭͚̩̎̇ͅp̷̤̞̝̰̝̀̈́͝q̵͕̥̻̳̈́̀̄ͅr̴̪͑͂̓̕s̴̬͈̑̑̀̑ț̶̤̪̲̖̌̾̀͑ù̷̫͖̲̙̈v̴̹̮̙̎̑͑̅́̾͜w̴̟̞̯̟̠̌͜x̸̢͖͓͉͖͒͗̈̎̇y̸̢̡͔̟͍͇̑̓͘͝͝z̶̭̻̓̿Ä̴̛̻͕́̀̀͋B̴̠̩̳͊Ć̵̨̨͚͘̕D̴̩̲͇̖͉̘̉͊̔E̴̯̺̾͊́̇́̾F̶͎̖̄͛͘̕G̶̨̩̭̞̦͑̿̀͗͘H̵̦̭̯̩̮̐͂̎̏͋̓I̵͐̈̿̂ͅJ̸̮̃K̶̢̬̭̝̖̻̎͝L̶̜͚͖̻̦̳̎͊̕͠M̶̧̦̼̩͎͙̿̎̃͘N̵̡͈̟̑ͅͅO̸̲͇̭͙̐̓̇̂͒P̷͓̓̈́̈̚Q̷̺͉̺̀̔͆̅̕͘ͅR̵̗͉̲̜̟̮͐S̷͓̭͕͎̘̘͋͐̆T̷̬͓̜̐͗̿̀̋Ū̸̼̰͕̘̞́̒͠V̷̤̘̇Ŵ̶͍͇͖͒X̵͚͖͑̔͑Y̶̨̛̍̈̊̿̐Z̷͕̈́1̶̱̠̲̻̂͗̐2̸̦̙͗͐͛3̷̺͙̬͌̈́̅4̷̩̓̌̋̈́̒͝5̴̜̼̔̀͑̈͊6̸̱̼̦̮̯͈̇̿͗̒̃͠7̴̡̡̟͕̦̮̆̋̀̾̇̚8̵̗̰̰͗̓̈́̍̐͜9̶̩̟̹̑̑̒0̴͍̲̣͙͒͂͗̎͗͝!̶̡͖̟̉̑@̶̙̙̰͐̐̅#̵̻̽̐̓̏̂̓$̷̨̺͓͊̊̿͝%̶̹̈́̿͛͐^̴̧̭̝͙̝̲̃͝&̷̛̣̩̮̽*̸̼́̌͘(̴̙̙́͌̅̋̾̚)̸͕͔̂̃̃͛͠͠-̴͇̯̳̠̄_̷̳̠̞̃̎͒͗̍͠≠̨͙̗̣̆+̵͈̣̣̆̈̒͛ͅ[̵̻̫̅͆{̶̯̤̥̽̐́̅͆͝]̶̺̮̤͎̦̐̔̒̕͝}̴̺̼͉̱̜̎͂̉̔̓͠\\̶̲̏̑|̵̘̱̝̱̌͛ͅ;̶̛͋͂̂́ͅ:̶͒̅̆̊͜'̵̡͖̣̃́̈͠\"̵͙̳͗̚͜,̷̭̣̆̇̊͘̚<̶̳̈́́͆̀̕.̴̧̠͕͙̉̽̂͒̊>̷̳̩͇̫̋̋̈́͋̏/̵̣̳̗͎͓̈́͘?̶͚̅`̵̧̨̟̦͒̈͂͒́~̷͕̱̹̠̇̃͜ ̷͉̬͋̌͛̈́͋"
      .asArray,
  ]

  fileprivate static let reverseMap: [String: String] = {
    var map = [String: String]()
    for i in 0..<stylables.count {
      let root = stylables[i]
      map[root] = root
      for style in TextStyle.allCases {
        guard style != .regular && style != .ransom && style != .spongeBob else {
          continue
        }
        map[stylableMaps[style]![i]] = root
      }
    }
    return map
  }()
}

extension String {

  public var styleErased: String {
    return TextStyle.regular.style(self)
  }

  public func styled(_ style: TextStyle) -> String {
    return style.style(self)
  }
}

extension String {
  fileprivate var asArray: [String] {
    var arr = [String]()
    for s in self {
      arr.append(String(s))
    }
    return arr
  }
}
