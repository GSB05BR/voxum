// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One model or library Voxum uses, with its license (an SPDX identifier, never translated).
public struct ThirdPartyComponent: Equatable, Sendable {
    public enum Kind: Sendable { case model, library }

    public let kind: Kind
    public let name: String
    public let url: String
    public let license: String
    public let copyright: String
    /// False for packages SwiftPM resolves but the app does not contain (build tools, unused products).
    public let shipped: Bool
    /// Extra detail for THIRD_PARTY_NOTICES.md only (English; not shown in the app).
    public let note: String?
    /// The license file of a library, relative to the repository root (in the SwiftPM checkout or
    /// artifact). THIRD_PARTY_NOTICES.md reproduces it verbatim (the Apache-2.0 text once).
    public let licenseFile: String?
    /// For code vendored inside a package with its license only in a header comment: the lines of
    /// `licenseFile` (1-based) that hold the copyright lines and license text.
    public let licenseLines: ClosedRange<Int>?
    /// NOTICE files reproduced verbatim (Apache-2.0 §4(d)), relative to the repository root.
    public let notices: [String]

    init(_ kind: Kind, _ name: String, _ url: String, _ license: String, _ copyright: String,
         shipped: Bool = true, note: String? = nil, licenseFile: String? = nil, licenseLines: ClosedRange<Int>? = nil,
         notices: [String] = []) {
        self.kind = kind
        self.name = name
        self.url = url
        self.license = license
        self.copyright = copyright
        self.shipped = shipped
        self.note = note
        self.licenseFile = licenseFile
        self.licenseLines = licenseLines
        self.notices = notices
    }
}

/// The single source of the third-party credits: the app's Credits window shows `components`, and
/// THIRD_PARTY_NOTICES.md is `markdown(reading:)` with every license and NOTICE text
/// (`tcli notices > THIRD_PARTY_NOTICES.md`; a test checks the file matches; build-app.sh bundles it). Versions and copyright lines come from Package.resolved and the packages' own
/// LICENSE/NOTICE files; model licenses from their Hugging Face model cards.
public enum ThirdPartyNotices {
    public static let projectLicense = "GPL-3.0-or-later"
    public static let repositoryURL = "https://github.com/GSB05BR/voxum"

    public static let components: [ThirdPartyComponent] = models + libraries

    public static let models: [ThirdPartyComponent] = [
        .init(.model, "Whisper large-v3-turbo", "https://huggingface.co/openai/whisper-large-v3-turbo", "MIT",
              "Copyright (c) 2022 OpenAI",
              note: "Speech recognition model. Voxum runs it through the Core ML conversion below."),
        .init(.model, "WhisperKit Core ML models (argmaxinc/whisperkit-coreml)",
              "https://huggingface.co/argmaxinc/whisperkit-coreml", "MIT", "argmax, inc.",
              note: "Variant `openai_whisper-large-v3-v20240930_turbo_632MB`, the Core ML conversion of Whisper large-v3-turbo. License as stated on the model card."),
        .init(.model, "Whisper large-v3 tokenizer", "https://huggingface.co/openai/whisper-large-v3", "Apache-2.0",
              "OpenAI",
              note: "Tokenizer files WhisperKit downloads for the model above. License as stated on the model card."),
        .init(.model, "Qwen3-4B-Instruct-2507", "https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507", "Apache-2.0",
              "Copyright 2024 Alibaba Cloud",
              note: "Text model that organizes the dictation and answers questions (optional: \"No AI\" never downloads it)."),
        .init(.model, "Qwen3-4B-Instruct-2507 4-bit (MLX)", "https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit",
              "Apache-2.0", "Copyright 2024 Alibaba Cloud; MLX conversion by mlx-community",
              note: "The 4-bit MLX conversion of Qwen3-4B-Instruct-2507 that Voxum downloads."),
    ]

    public static let libraries: [ThirdPartyComponent] = [
        .init(.library, "WhisperKit", "https://github.com/argmaxinc/WhisperKit", "MIT", "Copyright (c) 2024 argmax, inc.",
              note: "Its NOTICES file: portions are derived from swift-transformers (Apache-2.0, Copyright 2022 Hugging Face SAS).",
              licenseFile: ".build/checkouts/WhisperKit/LICENSE", notices: [".build/checkouts/WhisperKit/NOTICES"]),
        .init(.library, "MLX Swift (mlx-swift)", "https://github.com/ml-explore/mlx-swift", "MIT", "Copyright (c) 2023 ml-explore",
              licenseFile: ".build/checkouts/mlx-swift/LICENSE"),
        .init(.library, "MLX", "https://github.com/ml-explore/mlx", "MIT", "Copyright © 2023 Apple Inc.",
              note: "Bundled in mlx-swift (Cmlx).",
              licenseFile: ".build/checkouts/mlx-swift/Source/Cmlx/mlx/LICENSE"),
        .init(.library, "MLX C (mlx-c)", "https://github.com/ml-explore/mlx-c", "MIT", "Copyright (c) 2023 ml-explore",
              note: "Bundled in mlx-swift (Cmlx).",
              licenseFile: ".build/checkouts/mlx-swift/Source/Cmlx/mlx-c/LICENSE"),
        .init(.library, "metal-cpp", "https://developer.apple.com/metal/cpp/", "Apache-2.0", "Copyright 2020-2025 Apple Inc.",
              note: "Bundled in mlx-swift (Cmlx).",
              licenseFile: ".build/checkouts/mlx-swift/Source/Cmlx/metal-cpp/LICENSE.txt"),
        .init(.library, "{fmt}", "https://github.com/fmtlib/fmt", "MIT",
              "Copyright (c) 2012 - present, Victor Zverovich and {fmt} contributors",
              note: "Bundled in mlx-swift (Cmlx).",
              licenseFile: ".build/checkouts/mlx-swift/Source/Cmlx/fmt/LICENSE"),
        .init(.library, "JSON for Modern C++", "https://github.com/nlohmann/json", "MIT", "Copyright (c) 2013-2022 Niels Lohmann",
              note: "Bundled in mlx-swift (Cmlx). Its json.hpp also contains code, marked MIT in it, by Florian Loitsch (Grisu2, Copyright (c) 2009 Florian Loitsch), Björn Hoehrmann (UTF-8 decoder, Copyright (c) 2008-2009 Bjoern Hoehrmann), Evan Nemerson (Hedley, Copyright 2016-2021 Evan Nemerson) and The Abseil Authors (Copyright 2018 The Abseil Authors).",
              licenseFile: ".build/checkouts/mlx-swift/Source/Cmlx/json/LICENSE.MIT"),
        .init(.library, "PocketFFT", "https://gitlab.mpcdf.mpg.de/mtr/pocketfft", "BSD-3-Clause",
              "Copyright (C) 2010-2022 Max-Planck-Society, (C) 2019-2020 Peter Bell; DCT-IV parts (C) 2003, 2007-14 Matteo Frigo and Massachusetts Institute of Technology",
              note: "Bundled in MLX (`mlx/3rdparty/pocketfft.h`).",
              licenseFile: ".build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/3rdparty/pocketfft.h", licenseLines: 1...37),
        .init(.library, "V8 SmallVector", "https://github.com/v8/v8", "BSD-3-Clause", "Copyright 2018 the V8 project authors",
              note: "Bundled in MLX (`mlx/small_vector.h`, adapted from V8).",
              licenseFile: ".build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/small_vector.h", licenseLines: 1...28),
        .init(.library, "ThreadPool", "https://github.com/progschj/ThreadPool", "Zlib",
              "Copyright (c) 2012 Jakob Progsch, Václav Zeman",
              note: "Bundled in MLX (`mlx/threadpool.h`, modified).",
              licenseFile: ".build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/threadpool.h", licenseLines: 1...22),
        .init(.library, "expm1f", "https://github.com/ml-explore/mlx/blob/main/mlx/backend/metal/kernels/expm1f.h",
              "BSD-2-Clause", "Copyright (c) 2015-2023 Norbert Juffa",
              note: "Bundled in MLX's Metal kernels (`expm1f.h`).",
              licenseFile: ".build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/kernels/expm1f.h", licenseLines: 7...32),
        .init(.library, "cexpf (NVIDIA CCCL)", "https://github.com/NVIDIA/cccl", "Apache-2.0",
              "Copyright 2008-2013 NVIDIA Corporation, Copyright 2013 Filipe RNC Maia",
              note: "Bundled in MLX's Metal kernels (`cexpf.h`, forked from Thrust).",
              licenseFile: ".build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/kernels/cexpf.h", licenseLines: 1...15),
        .init(.library, "MLX Swift LM (mlx-swift-lm)", "https://github.com/ml-explore/mlx-swift-lm", "MIT",
              "Copyright (c) 2024 ml-explore",
              licenseFile: ".build/checkouts/mlx-swift-lm/LICENSE"),
        .init(.library, "XGrammar", "https://github.com/mlc-ai/xgrammar", "Apache-2.0",
              "Copyright (c) 2024 by XGrammar Contributors",
              note: "Bundled in mlx-swift-lm (MLXCXGrammar).",
              licenseFile: ".build/checkouts/mlx-swift-lm/Libraries/MLXCXGrammar/xgrammar/LICENSE", notices: [".build/checkouts/mlx-swift-lm/Libraries/MLXCXGrammar/xgrammar/NOTICE"]),
        .init(.library, "picojson", "https://github.com/kazuho/picojson", "BSD-2-Clause",
              "Copyright 2009-2010 Cybozu Labs, Inc., Copyright 2011-2014 Kazuho Oku",
              note: "Bundled in XGrammar (`3rdparty/picojson/picojson.h`).",
              licenseFile: ".build/checkouts/mlx-swift-lm/Libraries/MLXCXGrammar/xgrammar/3rdparty/picojson/picojson.h", licenseLines: 1...27),
        .init(.library, "DLPack", "https://github.com/dmlc/dlpack", "Apache-2.0", "Copyright (c) 2017 by Contributors",
              note: "Bundled in XGrammar (`3rdparty/dlpack`, a header). Its header carries only the copyright line; the DLPack project is Apache-2.0.",
              licenseFile: ".build/checkouts/mlx-swift-lm/Libraries/MLXCXGrammar/xgrammar/3rdparty/dlpack/include/dlpack/dlpack.h", licenseLines: 1...5),
        .init(.library, "Sparkle", "https://github.com/sparkle-project/Sparkle", "MIT",
              "Copyright (c) 2006-2013 Andy Matuschak and the other authors in its LICENSE",
              note: "Its LICENSE also covers bundled code under other permissive licenses: bsdiff/bspatch (BSD-2-Clause, Copyright 2003-2005 Colin Percival), sais-lite (MIT, Copyright (c) 2008-2010 Yuta Mori), ed25519 (Zlib, Copyright (c) 2015 Orson Peters) and SUSignatureVerifier (BSD-2-Clause, Copyright (c) 2011 Mark Hamlin).",
              licenseFile: ".build/artifacts/sparkle/Sparkle/LICENSE"),
        .init(.library, "swift-transformers", "https://github.com/huggingface/swift-transformers", "Apache-2.0",
              "Copyright 2022 Hugging Face SAS",
              licenseFile: ".build/checkouts/swift-transformers/LICENSE"),
        .init(.library, "swift-huggingface", "https://github.com/huggingface/swift-huggingface", "Apache-2.0",
              "Copyright 2025 Hugging Face SAS",
              licenseFile: ".build/checkouts/swift-huggingface/LICENSE"),
        .init(.library, "swift-jinja", "https://github.com/huggingface/swift-jinja", "Apache-2.0",
              "Copyright 2022 Hugging Face SAS",
              licenseFile: ".build/checkouts/swift-jinja/LICENSE"),
        .init(.library, "Swift Collections", "https://github.com/apple/swift-collections",
              "Apache-2.0 WITH Swift-exception", "Copyright (c) Apple Inc. and the Swift project authors",
              licenseFile: ".build/checkouts/swift-collections/LICENSE.txt"),
        .init(.library, "Swift Numerics", "https://github.com/apple/swift-numerics",
              "Apache-2.0 WITH Swift-exception", "Copyright (c) Apple Inc. and the Swift Numerics project authors",
              licenseFile: ".build/checkouts/swift-numerics/LICENSE.txt"),
        .init(.library, "Swift Crypto", "https://github.com/apple/swift-crypto", "Apache-2.0",
              "Copyright (c) Apple Inc. and the SwiftCrypto project authors",
              note: "Its NOTICE file: Copyright 2019 The SwiftCrypto Project.",
              licenseFile: ".build/checkouts/swift-crypto/LICENSE.txt", notices: [".build/checkouts/swift-crypto/NOTICE.txt"]),
        .init(.library, "EventSource", "https://github.com/mattt/EventSource", "MIT", "Copyright 2025 Mattt (https://mat.tt)",
              licenseFile: ".build/checkouts/EventSource/LICENSE.md"),
        .init(.library, "yyjson", "https://github.com/ibireme/yyjson", "MIT", "Copyright (c) 2020 YaoYuan",
              licenseFile: ".build/checkouts/yyjson/LICENSE"),
        .init(.library, "Swift ASN.1", "https://github.com/apple/swift-asn1", "Apache-2.0",
              "Copyright (c) Apple Inc. and the SwiftASN1 project authors", shipped: false,
              note: "Resolved by SwiftPM as a dependency of a dependency; not linked into the app.",
              licenseFile: ".build/checkouts/swift-asn1/LICENSE.txt", notices: [".build/checkouts/swift-asn1/NOTICE.txt"]),
        .init(.library, "Swift Argument Parser", "https://github.com/apple/swift-argument-parser",
              "Apache-2.0 WITH Swift-exception", "Copyright (c) Apple Inc. and the Swift project authors", shipped: false,
              note: "Resolved by SwiftPM as a dependency of a dependency; not linked into the app.",
              licenseFile: ".build/checkouts/swift-argument-parser/LICENSE.txt"),
        .init(.library, "SwiftSyntax", "https://github.com/swiftlang/swift-syntax", "Apache-2.0 WITH Swift-exception",
              "Copyright (c) Apple Inc. and the Swift project authors", shipped: false,
              note: "Used only at build time, for the Swift macros of mlx-swift-lm; not part of the app.",
              licenseFile: ".build/checkouts/swift-syntax/LICENSE.txt"),
    ]

    /// The canonical Apache-2.0 text, printed once for every Apache-licensed library (each library's own
    /// LICENSE is the same text; `ThirdPartyNoticesTests` checks that).
    public static let apacheLicenseFile = ".build/checkouts/swift-transformers/LICENSE"
    /// Where the Runtime Library Exception of the Swift projects' Apache-2.0 LICENSE starts.
    static let swiftExceptionMarker = "## Runtime Library Exception"

    public struct MissingText: Error, CustomStringConvertible {
        public let description: String
    }

    /// THIRD_PARTY_NOTICES.md, byte for byte. `read` returns a file of the repository by its relative
    /// path (the license and NOTICE files of the SwiftPM checkouts and artifacts).
    public static func markdown(reading read: (String) throws -> String) throws -> String {
        var out = """
        # Third-party notices

        Voxum is free software, licensed under the GNU General Public License, version 3 or any later version \
        (\(projectLicense)); see [LICENSE](LICENSE). Source code: \(repositoryURL)

        Voxum uses the models and libraries below, each under its own license. All of these licenses \
        (MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, Zlib) are compatible with \(projectLicense). Voxum uses Whisper and Qwen; \
        it is not affiliated with or endorsed by OpenAI, Alibaba Cloud, Argmax, Apple, Hugging Face or any other \
        author listed here.

        The app shows the same list in its Credits window, and this file (with the GPL text) is in the app \
        bundle. It is generated from `Sources/TranscricaoCore/App/ThirdPartyNotices.swift` and the license \
        files and headers of the SwiftPM checkouts (`swift run --disable-keychain tcli notices > THIRD_PARTY_NOTICES.md`).

        ## Models

        The model weights are not part of this repository or of the app download. On first run, Voxum downloads \
        them from Hugging Face into `~/Library/Application Support/Voxum`, where their model cards state \
        their licenses.


        """
        out += section(models)
        out += """
        ## Libraries

        Swift packages pinned in `Package.resolved`, and the code they bundle. Their license texts and NOTICE \
        files follow the list.


        """
        out += section(libraries)

        out += "## License texts\n\n"
        let apache = libraries.filter { $0.license.hasPrefix("Apache-2.0") }
        out += "### Apache License 2.0\n\nApplies to: \(names(apache)).\n\n"
        out += fenced(try read(apacheLicenseFile))
        let swift = libraries.filter { $0.license.contains("Swift-exception") }
        if let file = swift.first?.licenseFile {
            let text = try read(file)
            guard let start = text.range(of: swiftExceptionMarker)?.lowerBound else {
                throw MissingText(description: "\(file) has no \"\(swiftExceptionMarker)\"")
            }
            out += "### Runtime Library Exception to the Apache 2.0 License\n\nApplies to: \(names(swift)).\n\n"
            out += fenced(String(text[start...]))
        }
        // Every other license verbatim; identical files (same text and copyright) are printed once.
        var groups: [(text: String, components: [ThirdPartyComponent])] = []
        for c in libraries where !c.license.hasPrefix("Apache-2.0") {
            let text = try licenseText(of: c, reading: read)
            if let i = groups.firstIndex(where: { $0.text == text }) { groups[i].components.append(c) }
            else { groups.append((text, [c])) }
        }
        for group in groups {
            out += "### \(names(group.components)) (\(group.components[0].license))\n\n" + fenced(group.text)
        }

        out += "## NOTICE files\n\n"
        for c in libraries {
            for file in c.notices {
                out += "### \(c.name): \((file as NSString).lastPathComponent)\n\n" + fenced(try read(file))
            }
        }
        return out.trimmingCharacters(in: .newlines) + "\n"
    }

    /// A library's license text: its license file, or the given lines of a vendored header.
    public static func licenseText(of c: ThirdPartyComponent, reading read: (String) throws -> String) throws -> String {
        guard let file = c.licenseFile else { throw MissingText(description: "\(c.name) has no license file") }
        let text = try read(file)
        guard let range = c.licenseLines else { return text }
        let lines = text.components(separatedBy: "\n")
        guard range.upperBound <= lines.count else { throw MissingText(description: "\(file) is shorter than \(range)") }
        return lines[(range.lowerBound - 1)..<range.upperBound].joined(separator: "\n")
    }

    private static func names(_ items: [ThirdPartyComponent]) -> String {
        items.map(\.name).joined(separator: ", ")
    }

    private static func fenced(_ text: String) -> String {
        "```text\n" + text.trimmingCharacters(in: .newlines) + "\n```\n\n"
    }

    private static func section(_ items: [ThirdPartyComponent]) -> String {
        items.map { c in
            var lines = ["### \(c.name)", "", "- URL: \(c.url)", "- License: \(c.license)", "- \(c.copyright)"]
            if let note = c.note { lines.append("- \(note)") }
            return lines.joined(separator: "\n") + "\n\n"
        }.joined()
    }
}
