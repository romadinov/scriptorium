#!/usr/bin/env swift
// Writes Linked.pdf for the back-navigation UI tests: three pages; page 1 has a link (top left) to page 3,
// and page 3 one back to page 2. Usage: swift scripts/make-linked-pdf.swift <output.pdf>
import AppKit
import PDFKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Linked.pdf")
let size = CGSize(width: 612, height: 792)
let document = PDFDocument()
let body = "Entropy measures the number of microstates compatible with a macrostate. " +
    "The second law says it never decreases in an isolated system. "

for index in 0..<3 {
    let image = NSImage(size: size, flipped: true) { _ in
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 28)]
        let link: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.systemBlue]
        let text: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16)]
        ("Section \(index + 1)" as NSString).draw(at: CGPoint(x: 60, y: 40), withAttributes: title)
        if index == 0 { ("Go to section 3" as NSString).draw(at: CGPoint(x: 60, y: 90), withAttributes: link) }
        if index == 2 { ("Go to section 2" as NSString).draw(at: CGPoint(x: 60, y: 90), withAttributes: link) }
        (String(repeating: body, count: 12) as NSString).draw(in: CGRect(x: 60, y: 140, width: 492, height: 600), withAttributes: text)
        return true
    }
    // A text page (so PDFKit opens it as a PDF with text, not a scan).
    let data = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    _ = image.representations.first.map { _ in image.draw(in: NSRect(origin: .zero, size: size)) }
    context.endPDFPage(); context.closePDF()
    document.insert(PDFDocument(data: data as Data)!.page(at: 0)!, at: index)
}

func link(on from: Int, to target: Int) {
    guard let page = document.page(at: from), let destinationPage = document.page(at: target) else { return }
    // PDF coordinates: origin bottom left; the link text sits 90pt from the top.
    let annotation = PDFAnnotation(bounds: CGRect(x: 56, y: size.height - 122, width: 200, height: 34), forType: .link, withProperties: nil)
    annotation.action = PDFActionGoTo(destination: PDFDestination(page: destinationPage, at: CGPoint(x: 0, y: size.height)))
    page.addAnnotation(annotation)
}
link(on: 0, to: 2)
link(on: 2, to: 1)
guard document.write(to: out) else { fatalError("couldn't write \(out.path)") }
print("wrote \(out.path)")
