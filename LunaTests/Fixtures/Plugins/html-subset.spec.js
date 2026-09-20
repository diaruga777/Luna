/*
 * html-subset.spec.js — the specification for `luna.html` and `luna.text`
 * (§6.3). `luna.text` rides on the `html` capability, has no state and no
 * I/O, and the same three backings answer it, so it is specified here rather
 * than in a file of its own. `luna.html.article` is the one member NOT here:
 * it is native everywhere (relayed to native from Safari), so there is no
 * page-side backing to compare.
 *
 * Three backings must agree on this file: SwiftSoup behind JavaScriptCore in
 * the app and the extensions, `DOMParser` in the Safari content world, and
 * `linkedom` in the node dev harness. A disagreement fails the suite; the fix
 * is narrowing the subset or the backing, never a per-backing expectation.
 *
 * Each case is `{ name, html, script, expected }`. `script` is the BODY of a
 * function called with `(doc, luna)`, where `doc` is `luna.html.parse(html,
 * baseURL)` and `luna` carries `html` and `text`. Its answer is compared to
 * `expected` by deep JSON equality, so every expectation is a plain value.
 *
 * `baseURL` defaults to "https://example.com/dir/page.html"; a case may set its
 * own.
 *
 * The file evaluates to the case list, so a runner reads it with one
 * evaluation and no module system.
 */
[
  // ---------------------------------------------------------------- selectors
  {
    name: "querySelector finds by type",
    html: "<p>one</p><p>two</p>",
    script: "return doc.querySelector('p').textContent;",
    expected: "one"
  },
  {
    name: "querySelector answers null when nothing matches",
    html: "<p>one</p>",
    script: "return doc.querySelector('article');",
    expected: null
  },
  {
    name: "querySelectorAll answers an Array, not a NodeList",
    html: "<p>a</p><p>b</p>",
    script: "const found = doc.querySelectorAll('p'); return Array.isArray(found);",
    expected: true
  },
  {
    name: "querySelectorAll keeps document order",
    html: "<ul><li>a</li><li>b</li><li>c</li></ul>",
    script: "return doc.querySelectorAll('li').map(n => n.textContent);",
    expected: ["a", "b", "c"]
  },
  {
    name: "querySelectorAll answers an empty Array when nothing matches",
    html: "<p>a</p>",
    script: "return doc.querySelectorAll('.missing').length;",
    expected: 0
  },
  {
    name: "class selector",
    html: "<div class='card lead'>x</div><div class='card'>y</div>",
    script: "return doc.querySelectorAll('.card').map(n => n.textContent);",
    expected: ["x", "y"]
  },
  {
    name: "two class selectors combine",
    html: "<div class='card lead'>x</div><div class='card'>y</div>",
    script: "return doc.querySelectorAll('.card.lead').map(n => n.textContent);",
    expected: ["x"]
  },
  {
    name: "id selector",
    html: "<div id='main'>x</div><div id='other'>y</div>",
    script: "return doc.querySelector('#main').textContent;",
    expected: "x"
  },
  {
    name: "attribute presence selector",
    html: "<a href='/a'>a</a><a>b</a>",
    script: "return doc.querySelectorAll('a[href]').map(n => n.textContent);",
    expected: ["a"]
  },
  {
    name: "attribute equals selector with a quoted value",
    html: "<meta property='og:title' content='T'>",
    script: "return doc.querySelector(\"meta[property='og:title']\").getAttribute('content');",
    expected: "T"
  },
  {
    name: "attribute prefix selector",
    html: "<a href='https://a.test/1'>a</a><a href='/rel'>b</a>",
    script: "return doc.querySelectorAll(\"a[href^=https]\").map(n => n.textContent);",
    expected: ["a"]
  },
  {
    name: "attribute suffix selector",
    html: "<a href='/a.mp4'>a</a><a href='/b.jpg'>b</a>",
    script: "return doc.querySelectorAll(\"a[href$='.mp4']\").map(n => n.textContent);",
    expected: ["a"]
  },
  {
    name: "attribute contains selector",
    html: "<a href='/watch?v=1'>a</a><a href='/about'>b</a>",
    script: "return doc.querySelectorAll(\"a[href*=watch]\").map(n => n.textContent);",
    expected: ["a"]
  },
  {
    name: "descendant combinator",
    html: "<article><p>in</p></article><p>out</p>",
    script: "return doc.querySelectorAll('article p').map(n => n.textContent);",
    expected: ["in"]
  },
  {
    name: "child combinator",
    html: "<div><p>direct</p><section><p>deep</p></section></div>",
    script: "return doc.querySelectorAll('div > p').map(n => n.textContent);",
    expected: ["direct"]
  },
  {
    name: "comma groups two selectors",
    html: "<h1>a</h1><h2>b</h2><h3>c</h3>",
    script: "return doc.querySelectorAll('h1, h2').map(n => n.textContent);",
    expected: ["a", "b"]
  },
  {
    name: "not() excludes a class",
    html: "<p class='ad'>x</p><p>y</p>",
    script: "return doc.querySelectorAll('p:not(.ad)').map(n => n.textContent);",
    expected: ["y"]
  },
  {
    name: "first-child",
    html: "<ul><li>a</li><li>b</li></ul>",
    script: "return doc.querySelectorAll('li:first-child').map(n => n.textContent);",
    expected: ["a"]
  },
  {
    name: "nth-child picks the nth",
    html: "<ul><li>a</li><li>b</li><li>c</li></ul>",
    script: "return doc.querySelector('li:nth-child(2)').textContent;",
    expected: "b"
  },
  {
    name: "a selector scoped to an element searches only its subtree",
    html: "<div id='a'><p>in</p></div><p>out</p>",
    script: "return doc.querySelector('#a').querySelectorAll('p').map(n => n.textContent);",
    expected: ["in"]
  },

  // --------------------------------------------------------------- attributes
  {
    name: "getAttribute reads a value",
    html: "<a href='/x' data-id='7'>a</a>",
    script: "return doc.querySelector('a').getAttribute('data-id');",
    expected: "7"
  },
  {
    name: "getAttribute answers null for an absent attribute",
    html: "<a>a</a>",
    script: "return doc.querySelector('a').getAttribute('href');",
    expected: null
  },
  {
    name: "an empty attribute reads as an empty string, not null",
    html: "<a href=''>a</a>",
    script: "return doc.querySelector('a').getAttribute('href');",
    expected: ""
  },
  {
    name: "hasAttribute tells an empty attribute from an absent one",
    html: "<input disabled><input>",
    script: "return doc.querySelectorAll('input').map(n => n.hasAttribute('disabled'));",
    expected: [true, false]
  },
  {
    name: "attribute names are lower case",
    html: "<img SRC='/a.png' ALT='x'>",
    script: "return Object.keys(doc.querySelector('img').attributes).sort();",
    expected: ["alt", "src"]
  },
  {
    name: "attributes reads every value",
    html: "<a href='/x' rel='next'>a</a>",
    script: "const a = doc.querySelector('a').attributes; return [a.href, a.rel];",
    expected: ["/x", "next"]
  },
  {
    name: "an entity in an attribute is decoded",
    html: "<a title='a &amp; b'>x</a>",
    script: "return doc.querySelector('a').getAttribute('title');",
    expected: "a & b"
  },

  // ---------------------------------------------------------------- traversal
  {
    name: "tagName is upper case",
    html: "<div><span>x</span></div>",
    script: "return doc.querySelector('span').tagName;",
    expected: "SPAN"
  },
  {
    name: "children lists elements only",
    html: "<div>text<p>a</p><!-- c --><p>b</p></div>",
    script: "return doc.querySelector('div').children.map(n => n.tagName);",
    expected: ["P", "P"]
  },
  {
    name: "parentElement walks up",
    html: "<article><p>x</p></article>",
    script: "return doc.querySelector('p').parentElement.tagName;",
    expected: "ARTICLE"
  },
  {
    name: "matches tests the element itself",
    html: "<p class='ad'>x</p>",
    script: "const p = doc.querySelector('p'); return [p.matches('.ad'), p.matches('.no')];",
    expected: [true, false]
  },
  {
    name: "closest finds the nearest matching ancestor",
    html: "<article id='a'><div><p>x</p></div></article>",
    script: "return doc.querySelector('p').closest('article').getAttribute('id');",
    expected: "a"
  },
  {
    name: "closest matches the element itself first",
    html: "<article><p class='body'>x</p></article>",
    script: "return doc.querySelector('p').closest('.body').tagName;",
    expected: "P"
  },
  {
    name: "closest answers null when no ancestor matches",
    html: "<div><p>x</p></div>",
    script: "return doc.querySelector('p').closest('article');",
    expected: null
  },

  // ------------------------------------------------------------------ content
  {
    name: "textContent joins descendant text",
    html: "<div>a <b>b</b> c</div>",
    script: "return doc.querySelector('div').textContent;",
    expected: "a b c"
  },
  {
    name: "textContent decodes entities",
    html: "<p>caf&eacute; &amp; cr&egrave;me</p>",
    script: "return doc.querySelector('p').textContent;",
    expected: "café & crème"
  },
  {
    name: "textContent of an empty element is an empty string",
    html: "<p></p>",
    script: "return doc.querySelector('p').textContent;",
    expected: ""
  },
  {
    name: "innerHTML is the element's markup without its own tag",
    html: "<div><b>x</b></div>",
    script: "return doc.querySelector('div').innerHTML;",
    expected: "<b>x</b>"
  },
  {
    name: "outerHTML includes the element's own tag",
    html: "<div><b>x</b></div>",
    script: "return doc.querySelector('b').outerHTML;",
    expected: "<b>x</b>"
  },

  // --------------------------------------------------------------- document
  {
    name: "title reads the head's title",
    html: "<html><head><title>A Page</title></head><body><p>x</p></body></html>",
    script: "return doc.title;",
    expected: "A Page"
  },
  {
    name: "title is an empty string when the page has none",
    html: "<p>x</p>",
    script: "return doc.title;",
    expected: ""
  },
  {
    name: "documentElement is the html element",
    html: "<html><body><p>x</p></body></html>",
    script: "return doc.documentElement.tagName;",
    expected: "HTML"
  },
  {
    name: "body and head are found even when the markup omits them",
    html: "<p>x</p>",
    script: "return [doc.body.tagName, doc.head.tagName];",
    expected: ["BODY", "HEAD"]
  },
  {
    name: "the document can be queried like any node",
    html: "<html><body><p>x</p></body></html>",
    script: "return doc.querySelector('p').textContent;",
    expected: "x"
  },

  // ------------------------------------------------------------- absoluteURL
  {
    name: "absoluteURL resolves a root-relative href",
    html: "<a href='/x/y'>a</a>",
    script: "return doc.querySelector('a').absoluteURL('href');",
    expected: "https://example.com/x/y"
  },
  {
    name: "absoluteURL resolves a document-relative src",
    html: "<img src='pic.png'>",
    script: "return doc.querySelector('img').absoluteURL('src');",
    expected: "https://example.com/dir/pic.png"
  },
  {
    name: "absoluteURL leaves an absolute URL alone",
    html: "<a href='https://other.test/z'>a</a>",
    script: "return doc.querySelector('a').absoluteURL('href');",
    expected: "https://other.test/z"
  },
  {
    name: "absoluteURL answers null for an absent attribute",
    html: "<a>a</a>",
    script: "return doc.querySelector('a').absoluteURL('href');",
    expected: null
  },
  {
    name: "baseURI is the URL the document was parsed against",
    html: "<p>x</p>",
    script: "return doc.baseURI;",
    expected: "https://example.com/dir/page.html"
  },

  // ------------------------------------------------------------- luna.html.*
  {
    name: "luna.html.text strips tags and decodes entities",
    html: "<p>ignored</p>",
    script: "return luna.html.text('<b>a</b> &amp; <i>b</i>');",
    expected: "a & b"
  },
  {
    name: "luna.html.text of plain text is that text",
    html: "<p>ignored</p>",
    script: "return luna.html.text('just words');",
    expected: "just words"
  },
  {
    name: "jsonScripts parses ld+json bodies",
    html: "<script type='application/ld+json'>{\"@type\":\"Article\",\"headline\":\"H\"}</script>",
    script: "return luna.html.jsonScripts(doc).map(j => j.headline);",
    expected: ["H"]
  },
  {
    name: "jsonScripts skips a malformed block and keeps the rest",
    html: "<script type='application/ld+json'>{ not json </script>" +
      "<script type='application/ld+json'>{\"ok\":1}</script>",
    script: "return luna.html.jsonScripts(doc).map(j => j.ok);",
    expected: [1]
  },
  {
    name: "jsonScripts reads application/json too",
    html: "<script type='application/json'>{\"a\":2}</script>",
    script: "return luna.html.jsonScripts(doc).map(j => j.a);",
    expected: [2]
  },
  {
    name: "jsonScripts can be narrowed to one type",
    html: "<script type='application/ld+json'>{\"a\":1}</script>" +
      "<script type='application/json'>{\"a\":2}</script>",
    script: "return luna.html.jsonScripts(doc, 'application/json').map(j => j.a);",
    expected: [2]
  },
  {
    name: "jsonScripts ignores a plain script tag",
    html: "<script>var a = {\"a\": 3};</script>",
    script: "return luna.html.jsonScripts(doc).length;",
    expected: 0
  },
  {
    name: "jsonScripts answers an empty list when the page has none",
    html: "<p>x</p>",
    script: "return luna.html.jsonScripts(doc).length;",
    expected: 0
  },

  // --------------------------------------------------------------- resilience
  {
    name: "an unclosed tag still parses",
    html: "<div><p>one<p>two</div>",
    script: "return doc.querySelectorAll('p').map(n => n.textContent);",
    expected: ["one", "two"]
  },
  {
    name: "a script body is not read as text content of the page",
    html: "<body><script>var hidden = 'secret';</script><p>shown</p></body>",
    script: "return doc.body.textContent.indexOf('secret');",
    expected: -1
  },
  {
    name: "an empty document answers empty rather than throwing",
    html: "",
    script: "return [doc.querySelectorAll('p').length, doc.title];",
    expected: [0, ""]
  },
  // ------------------------------------------------------------ luna.html.jsonLD
  {
    name: "jsonLD parses ld+json and ignores application/json",
    html: "<script type='application/ld+json'>{\"@type\":\"Article\",\"headline\":\"H\"}</script>" +
      "<script type='application/json'>{\"@type\":\"Other\"}</script>",
    script: "return luna.html.jsonLD(doc).map(o => o['@type']);",
    expected: ["Article"]
  },
  {
    name: "jsonLD flattens a top-level array",
    html: "<script type='application/ld+json'>[{\"@type\":\"A\"},{\"@type\":\"B\"}]</script>",
    script: "return luna.html.jsonLD(doc).map(o => o['@type']);",
    expected: ["A", "B"]
  },
  {
    name: "jsonLD flattens a @graph one level",
    html: "<script type='application/ld+json'>" +
      "{\"@context\":\"x\",\"@graph\":[{\"@type\":\"WebSite\"},{\"@type\":\"Article\"}]}</script>",
    script: "return luna.html.jsonLD(doc).map(o => o['@type']);",
    expected: ["WebSite", "Article"]
  },
  {
    name: "jsonLD skips a malformed block and keeps the rest",
    html: "<script type='application/ld+json'>{ not json </script>" +
      "<script type='application/ld+json'>{\"@type\":\"Article\"}</script>",
    script: "return luna.html.jsonLD(doc).map(o => o['@type']);",
    expected: ["Article"]
  },
  {
    name: "jsonLD is always an array",
    html: "<p>x</p>",
    script: "const ld = luna.html.jsonLD(doc); return [Array.isArray(ld), ld.length];",
    expected: [true, 0]
  },

  // -------------------------------------------------------------- luna.html.meta
  {
    name: "meta reads OpenGraph first",
    html: "<html><head><title>Tag title</title>" +
      "<meta property='og:title' content='OG title'></head><body><p>x</p></body></html>",
    script: "return luna.html.meta(doc).title;",
    expected: "OG title"
  },
  {
    name: "meta falls back to a twitter card, then to the title tag",
    html: "<html><head><title>Tag title</title>" +
      "<meta name='twitter:title' content='Card title'></head><body><p>x</p></body></html>",
    script: "return luna.html.meta(doc).title;",
    expected: "Card title"
  },
  {
    name: "meta falls back to the title tag",
    html: "<html><head><title>Tag title</title></head><body><p>x</p></body></html>",
    script: "return luna.html.meta(doc).title;",
    expected: "Tag title"
  },
  {
    name: "meta omits a key the page never states",
    html: "<p>x</p>",
    script: "return Object.keys(luna.html.meta(doc));",
    expected: []
  },
  {
    name: "meta resolves a relative image against the document base",
    html: "<meta property='og:image' content='/img/lead.png'>",
    script: "return luna.html.meta(doc).image;",
    expected: "https://example.com/img/lead.png"
  },
  {
    name: "meta resolves a relative canonical link",
    html: "<link rel='canonical' href='other.html'>",
    script: "return luna.html.meta(doc).canonical;",
    expected: "https://example.com/dir/other.html"
  },
  {
    name: "meta prefers og:url over link rel=canonical",
    html: "<meta property='og:url' content='https://example.com/og'>" +
      "<link rel='canonical' href='https://example.com/link'>",
    script: "return luna.html.meta(doc).canonical;",
    expected: "https://example.com/og"
  },
  {
    name: "meta reads the author, the date and the site name",
    html: "<meta name='author' content='A. Writer'>" +
      "<meta property='article:published_time' content='2024-03-04T09:30:00Z'>" +
      "<meta property='og:site_name' content='Example'>",
    script: "const m = luna.html.meta(doc); return [m.author, m.published, m.siteName];",
    expected: ["A. Writer", "2024-03-04T09:30:00Z", "Example"]
  },
  {
    name: "meta reads the html lang attribute",
    html: "<html lang='pt-BR'><head></head><body><p>x</p></body></html>",
    script: "return luna.html.meta(doc).language;",
    expected: "pt-BR"
  },
  {
    name: "meta reads og:type",
    html: "<meta property='og:type' content='article'>",
    script: "return luna.html.meta(doc).type;",
    expected: "article"
  },
  {
    name: "meta collapses whitespace in a value",
    html: "<meta property='og:title' content='  A   long\n  title '>",
    script: "return luna.html.meta(doc).title;",
    expected: "A long title"
  },
  {
    name: "meta fills gaps from a JSON-LD Article",
    html: "<script type='application/ld+json'>{\"@type\":\"NewsArticle\"," +
      "\"headline\":\"LD headline\",\"author\":{\"name\":\"LD Author\"}," +
      "\"datePublished\":\"2024-03-04\",\"inLanguage\":\"fr\"}</script>",
    script: "const m = luna.html.meta(doc); " +
      "return [m.title, m.author, m.published, m.language];",
    expected: ["LD headline", "LD Author", "2024-03-04", "fr"]
  },
  {
    name: "a JSON-LD author may be a bare string",
    html: "<script type='application/ld+json'>" +
      "{\"@type\":\"BlogPosting\",\"author\":\"Plain Name\"}</script>",
    script: "return luna.html.meta(doc).author;",
    expected: "Plain Name"
  },
  {
    name: "a JSON-LD image may be a list, and the first entry wins",
    html: "<script type='application/ld+json'>{\"@type\":\"Product\",\"name\":\"P\"," +
      "\"image\":[\"https://cdn.test/1.jpg\",\"https://cdn.test/2.jpg\"]}</script>",
    script: "const m = luna.html.meta(doc); return [m.title, m.image];",
    expected: ["P", "https://cdn.test/1.jpg"]
  },
  {
    name: "a JSON-LD type Luna does not read answers for nothing",
    html: "<script type='application/ld+json'>" +
      "{\"@type\":\"BreadcrumbList\",\"name\":\"Crumbs\"}</script>",
    script: "return luna.html.meta(doc).title;",
    expected: null
  },
  {
    name: "a page meta always outranks JSON-LD",
    html: "<meta property='og:title' content='OG'>" +
      "<script type='application/ld+json'>{\"@type\":\"Article\",\"headline\":\"LD\"}</script>",
    script: "return luna.html.meta(doc).title;",
    expected: "OG"
  },

  // ------------------------------------------------------------- luna.text.price
  {
    name: "price reads a dollar amount with a thousands comma",
    html: "<p>x</p>",
    script: "return luna.text.price('$1,299.00');",
    expected: { amount: "1299.00", currency: "USD" }
  },
  {
    name: "price reads a European amount with a trailing euro sign",
    html: "<p>x</p>",
    script: "return luna.text.price('1.299,00 €');",
    expected: { amount: "1299.00", currency: "EUR" }
  },
  {
    name: "price reads a comma decimal separator",
    html: "<p>x</p>",
    script: "return luna.text.price('23,50 €');",
    expected: { amount: "23.50", currency: "EUR" }
  },
  {
    name: "a lone comma before three digits is a thousands separator",
    html: "<p>x</p>",
    script: "return luna.text.price('1,234');",
    expected: { amount: "1234" }
  },
  {
    name: "price reads an ISO code before the amount",
    html: "<p>x</p>",
    script: "return luna.text.price('USD 49.99');",
    expected: { amount: "49.99", currency: "USD" }
  },
  {
    name: "price reads an ISO code after the amount",
    html: "<p>x</p>",
    script: "return luna.text.price('89.00 AUD');",
    expected: { amount: "89.00", currency: "AUD" }
  },
  {
    name: "price omits a currency the string never names",
    html: "<p>x</p>",
    script: "return luna.text.price('1299.00');",
    expected: { amount: "1299.00" }
  },
  {
    name: "a lower-case word beside the amount is not a currency",
    html: "<p>x</p>",
    script: "return luna.text.price('now 19.99');",
    expected: { amount: "19.99" }
  },
  {
    name: "price keeps the fraction digits the page wrote",
    html: "<p>x</p>",
    script: "return [luna.text.price('$5.00').amount, luna.text.price('$5').amount];",
    expected: ["5.00", "5"]
  },
  {
    name: "price ignores a trailing separator",
    html: "<p>x</p>",
    script: "return luna.text.price('Was $40. Now less');",
    expected: { amount: "40", currency: "USD" }
  },
  {
    name: "price answers null when the string holds no number",
    html: "<p>x</p>",
    script: "return luna.text.price('Sold out');",
    expected: null
  },

  // -------------------------------------------------------------- luna.text.date
  {
    name: "date passes an ISO instant through as UTC",
    html: "<p>x</p>",
    script: "return luna.text.date('2024-03-04T09:30:00Z');",
    expected: "2024-03-04T09:30:00Z"
  },
  {
    name: "date converts an offset to UTC",
    html: "<p>x</p>",
    script: "return luna.text.date('2024-03-04T09:30:00+02:00');",
    expected: "2024-03-04T07:30:00Z"
  },
  {
    name: "date drops fractional seconds",
    html: "<p>x</p>",
    script: "return luna.text.date('2024-03-04T09:30:00.123Z');",
    expected: "2024-03-04T09:30:00Z"
  },
  {
    name: "a date with no time answers the day the page named",
    html: "<p>x</p>",
    script: "return luna.text.date('2024-03-04');",
    expected: "2024-03-04"
  },
  {
    name: "a space instead of a T is read as a naive UTC time",
    html: "<p>x</p>",
    script: "return luna.text.date('2024-03-04 09:30');",
    expected: "2024-03-04T09:30:00Z"
  },
  {
    name: "date reads Month D, YYYY",
    html: "<p>x</p>",
    script: "return luna.text.date('March 4, 2024');",
    expected: "2024-03-04"
  },
  {
    name: "date reads an abbreviated month",
    html: "<p>x</p>",
    script: "return luna.text.date('Mar 4, 2024');",
    expected: "2024-03-04"
  },
  {
    name: "date reads D Month YYYY",
    html: "<p>x</p>",
    script: "return luna.text.date('4 March 2024');",
    expected: "2024-03-04"
  },
  {
    name: "date reads RFC 2822",
    html: "<p>x</p>",
    script: "return luna.text.date('Mon, 04 Mar 2024 09:30:00 GMT');",
    expected: "2024-03-04T09:30:00Z"
  },
  {
    name: "date answers null for a relative phrase",
    html: "<p>x</p>",
    script: "return [luna.text.date('2 hours ago'), luna.text.date('yesterday')];",
    expected: [null, null]
  },
  {
    name: "date answers null for a day that does not exist",
    html: "<p>x</p>",
    script: "return luna.text.date('2023-02-29');",
    expected: null
  },
  {
    name: "date answers null for an empty string",
    html: "<p>x</p>",
    script: "return luna.text.date('');",
    expected: null
  },

  // ------------------------------------------------------------- luna.text.clean
  {
    name: "clean decodes entities",
    html: "<p>x</p>",
    script: "return luna.text.clean('caf&eacute; &amp; cr&egrave;me');",
    expected: "café & crème"
  },
  {
    name: "clean collapses whitespace and no-break spaces",
    html: "<p>x</p>",
    script: "return luna.text.clean('  a &nbsp;&nbsp; b \\n  c  ');",
    expected: "a b c"
  },
  {
    name: "clean drops tags, as luna.html.text does",
    html: "<p>x</p>",
    script: "return luna.text.clean('<b>Bold</b> label');",
    expected: "Bold label"
  },
  {
    name: "clean of an empty string is an empty string",
    html: "<p>x</p>",
    script: "return luna.text.clean('');",
    expected: ""
  }
]
