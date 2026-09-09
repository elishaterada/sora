import AppKit
func bench(_ name: String, count: Int = 100, _ body: () -> Void) {
    var times: [Double] = []
    for _ in 0..<count {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    times.sort()
    print("\(name): median=\(times[count/2])ms p95=\(times[Int(Double(count)*0.95)])ms max=\(times.last!)ms")
}
let font = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
_ = ("Warm up text shaping" as NSString).size(withAttributes: [.font: font])
for length in [40, 200, 2000, 10000] {
    let line = String(repeating: "echo hello world ", count: length/17 + 1)
    bench("wrap-\(length)", count: 30) {
        _ = StickyPromptBarModel.wrap(line, cursorOffset: line.count, width: 700) { ($0 as NSString).size(withAttributes: [.font: font]).width }
    }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for i in 0..<10000 { FileManager.default.createFile(atPath: root.appendingPathComponent("file-\(i)").path, contents: Data()) }
bench("path-10000-no-match", count: 30) { _ = PathCompleter.matches(token: "zz", cwd: root) }
bench("path-10000-matches", count: 10) { _ = PathCompleter.matches(token: "fi", cwd: root) }
