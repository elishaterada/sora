import Darwin
import Foundation

enum ForegroundWorkingDirectory {
    static func url(pid: pid_t) -> URL? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let requested = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let got = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, requested)
        guard got == requested else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cString in
                String(cString: cString)
            }
        }
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
