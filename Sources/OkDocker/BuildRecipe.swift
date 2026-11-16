import Foundation

// The official builder has no per-project script hook. Generate only a Dockerfile
// instruction, never a host-shell process. Keep the original build context/ignores.
enum BuildRecipe {
    static let marker = "# okdocker:build-script"
    static func render(_ build: BuildSpec, context: URL, dockerfile: URL) throws -> Data? {
        guard let script = build.script else { return nil }
        let file = try contained(script, root: context, directory: false)
        let relative = String(file.path.dropFirst(context.path.count + 1))
        guard !relative.isEmpty, !relative.contains(where: { $0 == "\r" || $0 == "\n" }), relative.utf8.count <= 4096 else { throw Problem("build.script 必须是构建目录内的普通脚本文件路径") }
        let source = try String(contentsOf: dockerfile, encoding: .utf8)
        var lines = source.components(separatedBy: "\n")
        let positions = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == marker }
        guard positions.count == 1, let index = positions.first else { throw Problem("使用 build.script 时，Dockerfile 必须且只能包含一行 \(marker)，放在 COPY 和 WORKDIR 之后的构建阶段") }
        if index > 0, lines[index - 1].trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("\\") { throw Problem("构建脚本标记不能位于 Dockerfile 续行指令内") }
        // Respect Linux shebang semantics (interpreter + one optional argument).
        // Without a shebang use /bin/sh; no executable bit or Mac interpreter needed.
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 512) ?? Data()
        var command = ["/bin/sh"]
        if prefix.starts(with: [0x23, 0x21]) {
            let header = prefix.prefix { $0 != 0x0a }
            guard header.count <= 255, let line = String(data: header.dropFirst(2), encoding: .utf8) else { throw Problem("build.script 的 Linux shebang 过长或不是 UTF-8") }
            let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" }).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let interpreter = parts.first, interpreter.hasPrefix("/"), !line.contains("\0") else { throw Problem("build.script 的 shebang 必须使用 Linux 解释器绝对路径") }
            command = parts
        }
        // JSON exec form: no expansion or option injection from the supplied path.
        let arguments = try JSONSerialization.data(withJSONObject: command + ["./" + relative], options: [.withoutEscapingSlashes])
        lines[index] = "RUN " + String(decoding: arguments, as: UTF8.self)
        return Data(lines.joined(separator: "\n").utf8)
    }
    static func withDockerfile<T>(_ build: BuildSpec, context: URL, dockerfile: URL, scratch: URL, body: (URL) throws -> T) throws -> T {
        guard let data = try render(build, context: context, dockerfile: dockerfile) else { return try body(dockerfile) }
        let directory = scratch.appendingPathComponent("build-recipes/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let generated = directory.appendingPathComponent("Dockerfile")
        try Runtime.write(data, to: generated)
        let specificIgnore = URL(fileURLWithPath: dockerfile.path + ".dockerignore")
        // A renamed Dockerfile must NOT lose its Dockerfile-specific secret exclusions.
        if FileManager.default.fileExists(atPath: specificIgnore.path) {
            let relative = String(specificIgnore.path.dropFirst(context.path.count + 1))
            let approved = try contained(relative, root: context, directory: false)
            try Runtime.write(Data(contentsOf: approved), to: URL(fileURLWithPath: generated.path + ".dockerignore"))
        }
        return try body(generated)
    }
}
