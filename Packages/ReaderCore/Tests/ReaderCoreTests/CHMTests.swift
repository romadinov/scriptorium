import Foundation
import Testing
@testable import ReaderCore

@Test func siteMapParsesTagSoup() {
    // Typical .hhc: upper-case tags, unclosed <LI>, nested lists, Windows paths, anchors.
    let hhc = """
    <HTML><BODY><OBJECT type="text/site properties"><param name="Window Styles" value="0x800025"></OBJECT>
    <UL>
      <LI> <OBJECT type="text/sitemap"><param name="Name" value="Introduction"><param name="Local" value="intro.htm"></OBJECT>
      <LI> <OBJECT type="text/sitemap"><param name="Name" value="Part 1 &amp; 2"></OBJECT>
      <UL>
        <LI> <OBJECT type="text/sitemap"><param name="Name" value="Chapter 1"><param name="Local" value="part1\\ch1.htm#top"></OBJECT>
        <LI> <OBJECT type="text/sitemap"><param name="Name" value="Chapter 2"><param name="Local" value="part1/ch2.htm"></OBJECT>
      </UL>
      <LI> <OBJECT type="text/sitemap"><param name="Name" value="Index"><param name="Local" value="index.htm"></OBJECT>
    </UL></BODY></HTML>
    """
    let tree = SiteMap.parse(hhc)
    #expect(tree.map(\.name) == ["Introduction", "Part 1 & 2", "Index"])
    #expect(tree[1].local == nil)
    #expect(tree[1].children.map(\.name) == ["Chapter 1", "Chapter 2"])
    #expect(tree[1].children[0].local == "part1\\ch1.htm#top")
}

@Test func legacyEncodingsBecomeUTF8() {
    let cyrillic = "<html><head><meta http-equiv=Content-Type content=\"text/html; charset=windows-1251\"></head><body>Энтропия</body></html>"
    let converted = CHMSource.utf8HTML(cyrillic.data(using: .windowsCP1251)!)
    #expect(converted.contains("Энтропия") && converted.contains("charset=utf-8"))
    // No declaration: mostly C0–FF bytes → guessed as Windows-1251.
    #expect(CHMSource.decode("Тепловой двигатель".data(using: .windowsCP1251)!, charset: nil) == "Тепловой двигатель")
    #expect(CHMSource.decode("Café crème".data(using: .windowsCP1252)!, charset: nil) == "Café crème")
}
