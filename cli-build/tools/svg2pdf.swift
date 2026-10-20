// Build helper for build-cli.sh: render an SVG asset to PDF (catalog vector images need actool otherwise).
import AppKit
let u = URL(fileURLWithPath: CommandLine.arguments[1])
guard let img = NSImage(contentsOf: u) else { print("nil"); exit(1) }
print(img.size, img.representations)
let data = NSMutableData(); var box = CGRect(origin: .zero, size: img.size)
let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
ctx.beginPDFPage(nil); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
img.draw(in: box); ctx.endPDFPage(); ctx.closePDF()
try! (data as Data).write(to: URL(fileURLWithPath: CommandLine.arguments[2])); print("ok")
