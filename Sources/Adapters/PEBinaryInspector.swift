import ChrysaCore
import ChrysaApplication
import CryptoKit
import Foundation

package struct PEImportInfo: Sendable {
    package let isValidPE: Bool
    package let is64Bit: Bool
    package let importsSteamAPI: Bool
    package let importsD3D12: Bool
    package let importsWinHTTP: Bool

    package init(
        isValidPE: Bool = false,
        is64Bit: Bool,
        importsSteamAPI: Bool,
        importsD3D12: Bool,
        importsWinHTTP: Bool
    ) {
        self.isValidPE = isValidPE
        self.is64Bit = is64Bit
        self.importsSteamAPI = importsSteamAPI
        self.importsD3D12 = importsD3D12
        self.importsWinHTTP = importsWinHTTP
    }
}

package enum SteamDLLDisposition: Equatable, Sendable {
    /// Genuine unmodified Valve Steamworks SDK DLL (verified via PE Authenticode Valve signature + intact image digest),
    /// or a non-PE synthetic test fixture below the Goldberg threshold.
    case officialValve
    /// Already patched with Goldberg / `gbe_fork`.
    case goldberg
    /// Pre-cracked third-party Steam emulator DLL (e.g. RUNE, CODEX, TENOKE, FLT, Online-Fix, CreamAPI):
    /// valid PE binary without an intact Valve Authenticode signature and not Goldberg.
    case thirdPartyEmulator
}

package enum PEBinaryInspector {
    /// Parses standard Windows PE32 / PE32+ headers and `IMAGE_DIRECTORY_ENTRY_IMPORT` RVA tables directly
    /// without converting multi-hundred-MB binaries to UTF-8 Strings, with a bounded fallback if packed.
    package static func inspect(exePath: String) -> PEImportInfo {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: exePath), options: .mappedIfSafe),
              data.count > 0x200 else {
            return PEImportInfo(is64Bit: true, importsSteamAPI: false, importsD3D12: false, importsWinHTTP: false)
        }

        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> PEImportInfo in
            func readU16(_ off: Int) -> UInt16? {
                guard off >= 0, off + 2 <= raw.count else { return nil }
                return UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))
            }
            func readU32(_ off: Int) -> UInt32? {
                guard off >= 0, off + 4 <= raw.count else { return nil }
                return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self))
            }
            func readCString(_ off: Int, maxLen: Int = 128) -> String? {
                guard off >= 0, off < raw.count else { return nil }
                let limit = min(raw.count, off + maxLen)
                var bytes: [UInt8] = []
                for idx in off..<limit {
                    let b = raw[idx]
                    if b == 0 { break }
                    bytes.append(b)
                }
                guard !bytes.isEmpty else { return nil }
                return String(bytes: bytes, encoding: .ascii)
            }

            // Verify MZ magic (0x5A4D)
            guard readU16(0) == 0x5A4D,
                  let peOffU32 = readU32(0x3C) else {
                return PEImportInfo(is64Bit: true, importsSteamAPI: false, importsD3D12: false, importsWinHTTP: false)
            }
            let peOff = Int(peOffU32)
            // Verify "PE\0\0" signature (0x00004550)
            guard readU32(peOff) == 0x00004550,
                  let numSections = readU16(peOff + 6),
                  let sizeOfOptionalHeader = readU16(peOff + 20),
                  let optMagic = readU16(peOff + 24) else {
                return PEImportInfo(is64Bit: true, importsSteamAPI: false, importsD3D12: false, importsWinHTTP: false)
            }

            guard optMagic == 0x10B || optMagic == 0x20B else {
                return PEImportInfo(is64Bit: true, importsSteamAPI: false, importsD3D12: false, importsWinHTTP: false)
            }
            let is64 = (optMagic == 0x20B)
            let optHeaderStart = peOff + 24
            // DataDirectory starts at offset +96 in PE32 (0x10B) and +112 in PE32+ (0x20B).
            // Entry #1 (Import Table) is 8 bytes after DataDirectory[0].
            let importDirOffset = optHeaderStart + (is64 ? 112 : 96) + 8
            let importTableRVA = readU32(importDirOffset) ?? 0

            // Parse Section Headers to translate RVA -> File Offset
            struct PESection {
                let virtualAddress: UInt32
                let virtualSpan: UInt32
                let rawDataPtr: UInt32
                let rawDataSize: UInt32
            }

            let sectionTableStart = optHeaderStart + Int(sizeOfOptionalHeader)
            var sections: [PESection] = []
            for sIdx in 0..<Int(numSections) {
                let sOff = sectionTableStart + sIdx * 40
                guard let vSize = readU32(sOff + 8),
                      let vAddr = readU32(sOff + 12),
                      let rSize = readU32(sOff + 16),
                      let rPtr  = readU32(sOff + 20) else { break }
                sections.append(PESection(
                    virtualAddress: vAddr,
                    virtualSpan: max(vSize, rSize),
                    rawDataPtr: rPtr,
                    rawDataSize: rSize
                ))
            }

            func rvaToFileOffset(_ rva: UInt32) -> Int? {
                guard rva > 0 else { return nil }
                for sec in sections {
                    if rva >= sec.virtualAddress && rva < sec.virtualAddress &+ sec.virtualSpan {
                        let delta = rva - sec.virtualAddress
                        if delta < sec.rawDataSize {
                            let fileOff = Int(sec.rawDataPtr) + Int(delta)
                            return fileOff < raw.count ? fileOff : nil
                        }
                    }
                }
                return Int(rva) < raw.count ? Int(rva) : nil
            }

            var importedDLLs: [String] = []
            if importTableRVA > 0, let importOff = rvaToFileOffset(importTableRVA) {
                var descOff = importOff
                // IMAGE_IMPORT_DESCRIPTOR is 20 bytes; Name RVA is at +12
                for _ in 0..<512 {
                    guard let origThunk = readU32(descOff),
                          let nameRVA = readU32(descOff + 12),
                          let firstThunk = readU32(descOff + 16) else { break }
                    if origThunk == 0 && nameRVA == 0 && firstThunk == 0 {
                        break
                    }
                    if let nameFileOff = rvaToFileOffset(nameRVA),
                       let dllName = readCString(nameFileOff)?.lowercased() {
                        importedDLLs.append(dllName)
                    }
                    descOff += 20
                }
            }

            var hasSteam = importedDLLs.contains { $0 == "steam_api64.dll" || $0 == "steam_api.dll" }
            var hasD3D12 = importedDLLs.contains { $0 == "d3d12.dll" || $0 == "d3d12core.dll" }
            var hasWinHTTP = importedDLLs.contains { $0 == "winhttp.dll" }

            // Dynamic LoadLibrary fallback scan on raw mapped bytes if not statically imported
            let fullRange = 0 ..< raw.count
            if !hasSteam {
                hasSteam = Self.sliceContainsASCII(raw, fullRange, Array("steam_api64.dll".utf8))
                    || Self.sliceContainsASCII(raw, fullRange, Array("steam_api.dll".utf8))
            }
            if !hasD3D12 {
                hasD3D12 = Self.sliceContainsASCII(raw, fullRange, Array("d3d12.dll".utf8))
                    || Self.sliceContainsASCII(raw, fullRange, Array("d3d12core.dll".utf8))
            }
            if !hasWinHTTP {
                hasWinHTTP = Self.sliceContainsASCII(raw, fullRange, Array("winhttp.dll".utf8))
            }

            return PEImportInfo(
                isValidPE: true,
                is64Bit: is64,
                importsSteamAPI: hasSteam,
                importsD3D12: hasD3D12,
                importsWinHTTP: hasWinHTTP
            )
        }
    }

    private struct PEAuthenticodeResult {
        let isValidPE: Bool
        let certRange: Range<Int>?
        let hasIntactSignature: Bool
    }

    package static let proxyHookDLLWhitelist: Set<String> = [
        "winhttp.dll", "version.dll", "dinput8.dll", "dwmapi.dll", "dsound.dll", "winmm.dll"
    ]

    /// Scans the main executable's sibling directory (and game root) for non-Microsoft proxy hook DLLs in the safe whitelist.
    /// Returns lowercased DLL stems (e.g. `["dinput8", "winhttp"]`), excluding DirectX graphics DLLs (`dxgi`/`d3d11`/`d3d12`).
    package static func detectProxyHookDLLs(nearExecutable exePath: String?, gameDirectory: String? = nil) -> [String] {
        var dirs: [String] = []
        if let exePath, !exePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dirs.append((exePath as NSString).deletingLastPathComponent)
        }
        if let gameDirectory, !gameDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dirs.append(gameDirectory)
        }
        var seenDirs = Set<String>()
        var detectedStems = Set<String>()
        let fm = FileManager.default

        for dir in dirs {
            let standardizedDir = URL(fileURLWithPath: dir).standardizedFileURL.path
            guard seenDirs.insert(standardizedDir).inserted,
                  let entries = try? fm.contentsOfDirectory(atPath: standardizedDir) else {
                continue
            }
            for entry in entries {
                let lower = entry.lowercased()
                guard proxyHookDLLWhitelist.contains(lower) else { continue }
                let fullPath = (standardizedDir as NSString).appendingPathComponent(entry)
                let vals = try? URL(fileURLWithPath: fullPath).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard vals?.isRegularFile == true, vals?.isSymbolicLink != true else { continue }
                if isProxyHookDLL(atPath: fullPath) {
                    detectedStems.insert(String(lower.dropLast(4)))
                }
            }
        }
        return detectedStems.sorted()
    }

    package static func isProxyHookDLL(atPath path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
            return false
        }
        return isProxyHookDLL(data: data)
    }

    package static func isProxyHookDLL(data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let msPublishers: [[UInt8]] = [Array("microsoft".utf8)]
            let msCAs: [[UInt8]] = [
                Array("microsoft".utf8),
                Array("digicert".utf8),
                Array("symantec".utf8),
                Array("verisign".utf8),
                Array("globalsign".utf8),
                Array("sectigo".utf8)
            ]
            let auth = verifyPEAuthenticode(
                in: raw,
                publisherNeedles: msPublishers,
                excludedNeedles: [],
                trustedCANeedles: msCAs
            )
            return auth.isValidPE && !auth.hasIntactSignature
        }
    }

    private static func sliceContainsASCII(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ lowerNeedle: [UInt8]) -> Bool {
        let nLen = lowerNeedle.count
        guard nLen > 0, range.lowerBound >= 0, range.upperBound <= raw.count, range.count >= nLen else {
            return false
        }
        let firstB = lowerNeedle[0]
        let firstUpper = (firstB >= 97 && firstB <= 122) ? (firstB - 32) : firstB
        let endIdx = range.upperBound - nLen
        var i = range.lowerBound
        while i <= endIdx {
            let b0 = raw[i]
            if b0 == firstB || b0 == firstUpper {
                var match = true
                for j in 1..<nLen {
                    var bj = raw[i + j]
                    if bj >= 65 && bj <= 90 { bj += 32 }
                    if bj != lowerNeedle[j] {
                        match = false
                        break
                    }
                }
                if match { return true }
            }
            i += 1
        }
        return false
    }

    private static func sliceContainsBytes(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ needle: [UInt8]) -> Bool {
        let nLen = needle.count
        guard nLen > 0, range.lowerBound >= 0, range.upperBound <= raw.count, range.count >= nLen else {
            return false
        }
        let endIdx = range.upperBound - nLen
        var i = range.lowerBound
        while i <= endIdx {
            if raw[i] == needle[0] {
                var match = true
                for j in 1..<nLen where raw[i + j] != needle[j] {
                    match = false
                    break
                }
                if match { return true }
            }
            i += 1
        }
        return false
    }

    private static func verifyPEAuthenticode(
        in raw: UnsafeRawBufferPointer,
        publisherNeedles: [[UInt8]],
        excludedNeedles: [[UInt8]],
        trustedCANeedles: [[UInt8]]
    ) -> PEAuthenticodeResult {
        func readU16(_ off: Int) -> UInt16? {
            guard off >= 0, off + 2 <= raw.count else { return nil }
            return UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))
        }
        func readU32(_ off: Int) -> UInt32? {
            guard off >= 0, off + 4 <= raw.count else { return nil }
            return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self))
        }

        guard raw.count >= 0x80,
              readU16(0) == 0x5A4D,
              let peOffU32 = readU32(0x3C) else {
            return PEAuthenticodeResult(isValidPE: false, certRange: nil, hasIntactSignature: false)
        }
        let peOff = Int(peOffU32)
        guard peOff >= 0x40,
              peOff <= raw.count - 0x40,
              readU32(peOff) == 0x00004550,
              let sizeOfOptionalHeaderU16 = readU16(peOff + 20),
              let optMagic = readU16(peOff + 24),
              optMagic == 0x10B || optMagic == 0x20B else {
            return PEAuthenticodeResult(isValidPE: false, certRange: nil, hasIntactSignature: false)
        }

        let is64 = (optMagic == 0x20B)
        let optHeaderStart = peOff + 24
        let sizeOfOptionalHeader = Int(sizeOfOptionalHeaderU16)
        guard optHeaderStart + sizeOfOptionalHeader <= raw.count else {
            return PEAuthenticodeResult(isValidPE: false, certRange: nil, hasIntactSignature: false)
        }

        let minOptSizeForSecurity = is64 ? 152 : 136
        let numRvaAndSizes = readU32(optHeaderStart + (is64 ? 108 : 92)) ?? 0
        let checksumOff = optHeaderStart + 64
        let certDirOff = optHeaderStart + (is64 ? 112 : 96) + 32

        var certRange: Range<Int>? = nil
        var hasIntactSignature = false
        if sizeOfOptionalHeader >= minOptSizeForSecurity,
           numRvaAndSizes >= 5,
           let certOffU32 = readU32(certDirOff),
           let certSizeU32 = readU32(certDirOff + 4) {
            let certOff = Int(certOffU32)
            let certSize = Int(certSizeU32)
            if certOff > certDirOff + 8,
               certSize > 8,
               certOff <= raw.count - certSize {
                let cRange = (certOff + 8) ..< (certOff + certSize)
                certRange = cRange

                if certOff + certSize == raw.count,
                   readU16(certOff + 6) == 0x0002,
                   publisherNeedles.contains(where: { sliceContainsASCII(raw, cRange, $0) }),
                   !excludedNeedles.contains(where: { sliceContainsASCII(raw, cRange, $0) }),
                   trustedCANeedles.contains(where: { sliceContainsASCII(raw, cRange, $0) }) {
                    var sha1 = Insecure.SHA1()
                    var sha256 = SHA256()
                    let r1 = UnsafeRawBufferPointer(rebasing: raw[0 ..< checksumOff])
                    let r2 = UnsafeRawBufferPointer(rebasing: raw[(checksumOff + 4) ..< certDirOff])
                    let r3 = UnsafeRawBufferPointer(rebasing: raw[(certDirOff + 8) ..< certOff])
                    for region in [r1, r2, r3] {
                        sha1.update(bufferPointer: region)
                        sha256.update(bufferPointer: region)
                    }
                    let sha1Bytes = Array(sha1.finalize())
                    let sha256Bytes = Array(sha256.finalize())
                    if sliceContainsBytes(raw, cRange, sha256Bytes) || sliceContainsBytes(raw, cRange, sha1Bytes) {
                        hasIntactSignature = true
                    }
                }
            }
        }

        return PEAuthenticodeResult(isValidPE: true, certRange: certRange, hasIntactSignature: hasIntactSignature)
    }

    /// Classifies a `steam_api(64).dll` using a whitelist check on Valve's PE Authenticode digital signature
    /// and cryptographic image digest rather than maintaining exhaustive crack-group regex lists.
    package static func classifySteamDLL(atPath path: String, hasOriginalBackup: Bool = false) -> SteamDLLDisposition {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
            return hasOriginalBackup ? .goldberg : .officialValve
        }
        return classifySteamDLL(data: data, hasOriginalBackup: hasOriginalBackup)
    }

    package static func classifySteamDLL(data: Data, hasOriginalBackup: Bool = false) -> SteamDLLDisposition {
        let fallbackDisposition: SteamDLLDisposition = (hasOriginalBackup || data.count > 2_000_000)
            ? .goldberg
            : .officialValve

        guard data.count >= 0x200 else { return fallbackDisposition }

        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> SteamDLLDisposition in
            let trustedCAs: [[UInt8]] = [
                Array("digicert".utf8),
                Array("symantec".utf8),
                Array("verisign".utf8),
                Array("thawte".utf8),
                Array("entrust".utf8),
                Array("globalsign".utf8),
                Array("sectigo".utf8),
                Array("comodo".utf8)
            ]
            let auth = verifyPEAuthenticode(
                in: raw,
                publisherNeedles: [Array("valve".utf8)],
                excludedNeedles: [Array("gse1".utf8), Array("gse0".utf8)],
                trustedCANeedles: trustedCAs
            )
            guard auth.isValidPE else { return fallbackDisposition }
            if auth.hasIntactSignature { return .officialValve }

            // Valid PE without an intact Valve signature: distinguish Goldberg (`gbe_fork`) from third-party cracks.
            if raw.count > 2_000_000 {
                return .goldberg
            }
            if let cRange = auth.certRange,
               (sliceContainsASCII(raw, cRange, Array("gse1".utf8)) || sliceContainsASCII(raw, cRange, Array("gse0".utf8))) {
                return .goldberg
            }
            let fullRange = 0 ..< raw.count
            if sliceContainsASCII(raw, fullRange, Array("gbe_fork".utf8))
                || sliceContainsASCII(raw, fullRange, Array("steam_settings".utf8)) {
                return .goldberg
            }

            return .thirdPartyEmulator
        }
    }

    /// Extracts the best icon image (`PNG` or single-entry `.ico`) from a PE32/PE32+ `.exe` resource section.
    package static func extractIconData(exePath: String) -> Data? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: exePath), options: .mappedIfSafe),
              data.count > 0x200 else {
            return nil
        }
        return extractIconData(from: data)
    }

    package static func extractIconData(from data: Data) -> Data? {
        guard data.count > 0x200 else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            func readU8(_ off: Int) -> UInt8? {
                guard off >= 0, off < raw.count else { return nil }
                return raw[off]
            }
            func readU16(_ off: Int) -> UInt16? {
                guard off >= 0, off + 2 <= raw.count else { return nil }
                return UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))
            }
            func readU32(_ off: Int) -> UInt32? {
                guard off >= 0, off + 4 <= raw.count else { return nil }
                return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self))
            }

            guard readU16(0) == 0x5A4D,
                  let peOffU32 = readU32(0x3C) else { return nil }
            let peOff = Int(peOffU32)
            guard readU32(peOff) == 0x00004550,
                  let numSections = readU16(peOff + 6),
                  let sizeOfOptionalHeader = readU16(peOff + 20),
                  let optMagic = readU16(peOff + 24) else { return nil }

            let is64 = (optMagic == 0x20B)
            guard optMagic == 0x10B || is64 else { return nil }
            let optHeaderStart = peOff + 24
            let dataDirStart = optHeaderStart + (is64 ? 112 : 96)
            // Entry #2 is IMAGE_DIRECTORY_ENTRY_RESOURCE (offset +16)
            guard let resTableRVA = readU32(dataDirStart + 16), resTableRVA > 0 else { return nil }

            struct PESection {
                let virtualAddress: UInt32
                let virtualSpan: UInt32
                let rawDataPtr: UInt32
                let rawDataSize: UInt32
            }

            let sectionTableStart = optHeaderStart + Int(sizeOfOptionalHeader)
            var sections: [PESection] = []
            for sIdx in 0..<Int(numSections) {
                let sOff = sectionTableStart + sIdx * 40
                guard let vSize = readU32(sOff + 8),
                      let vAddr = readU32(sOff + 12),
                      let rSize = readU32(sOff + 16),
                      let rPtr  = readU32(sOff + 20) else { break }
                sections.append(PESection(
                    virtualAddress: vAddr,
                    virtualSpan: max(vSize, rSize),
                    rawDataPtr: rPtr,
                    rawDataSize: rSize
                ))
            }

            func rvaToFileOffset(_ rva: UInt32) -> Int? {
                guard rva > 0 else { return nil }
                for sec in sections {
                    if rva >= sec.virtualAddress && rva < sec.virtualAddress &+ sec.virtualSpan {
                        let delta = rva - sec.virtualAddress
                        if delta < sec.rawDataSize {
                            let fileOff = Int(sec.rawDataPtr) + Int(delta)
                            return fileOff < raw.count ? fileOff : nil
                        }
                    }
                }
                return Int(rva) < raw.count ? Int(rva) : nil
            }

            guard let resRootOff = rvaToFileOffset(resTableRVA) else { return nil }

            func directoryEntries(at dirOff: Int) -> [(id: UInt32, offsetVal: UInt32)] {
                guard let namedCount = readU16(dirOff + 12),
                      let idCount = readU16(dirOff + 14) else { return [] }
                let total = min(Int(namedCount) + Int(idCount), 512)
                var entries: [(UInt32, UInt32)] = []
                entries.reserveCapacity(total)
                for idx in 0..<total {
                    let entryOff = dirOff + 16 + idx * 8
                    guard let nameOrId = readU32(entryOff),
                          let offsetVal = readU32(entryOff + 4) else { break }
                    entries.append((nameOrId, offsetVal))
                }
                return entries
            }

            func subdirOffset(_ offsetVal: UInt32) -> Int? {
                guard (offsetVal & 0x8000_0000) != 0 else { return nil }
                let rel = Int(offsetVal & 0x7FFF_FFFF)
                let off = resRootOff + rel
                return (off >= 0 && off + 16 <= raw.count) ? off : nil
            }

            func firstResourcePayload(in langDirOff: Int) -> Data? {
                for (_, offsetVal) in directoryEntries(at: langDirOff) {
                    if (offsetVal & 0x8000_0000) == 0 {
                        let dataEntryOff = resRootOff + Int(offsetVal)
                        guard let dataRVA = readU32(dataEntryOff),
                              let dataSize = readU32(dataEntryOff + 4),
                              dataSize > 0, dataSize <= 8_000_000,
                              let fileOff = rvaToFileOffset(dataRVA),
                              fileOff + Int(dataSize) <= raw.count else { continue }
                        let startPtr = raw.baseAddress!.advanced(by: fileOff)
                        return Data(bytes: startPtr, count: Int(dataSize))
                    }
                }
                return nil
            }

            let rootEntries = directoryEntries(at: resRootOff)
            guard let groupTypeEntry = rootEntries.first(where: { $0.id == 14 }),
                  let groupTypeDir = subdirOffset(groupTypeEntry.offsetVal),
                  let iconTypeEntry = rootEntries.first(where: { $0.id == 3 }),
                  let iconTypeDir = subdirOffset(iconTypeEntry.offsetVal) else {
                return nil
            }

            let iconEntries = directoryEntries(at: iconTypeDir)
            for groupEntry in directoryEntries(at: groupTypeDir) {
                guard let groupLangDir = subdirOffset(groupEntry.offsetVal),
                      let groupData = firstResourcePayload(in: groupLangDir),
                      groupData.count >= 6 else {
                    continue
                }

                let idType = UInt16(groupData[2]) | (UInt16(groupData[3]) << 8)
                let idCount = Int(UInt16(groupData[4]) | (UInt16(groupData[5]) << 8))
                guard idType == 1, idCount > 0 else { continue }

                struct GroupEntry {
                    let header12: Data
                    let width: Int
                    let bitCount: Int
                    let iconID: UInt16
                }

                var candidates: [GroupEntry] = []
                for idx in 0..<min(idCount, 64) {
                    let off = 6 + idx * 14
                    guard off + 14 <= groupData.count else { break }
                    let wByte = Int(groupData[off])
                    let width = wByte == 0 ? 256 : wByte
                    let bitCount = Int(UInt16(groupData[off + 6]) | (UInt16(groupData[off + 7]) << 8))
                    let iconID = UInt16(groupData[off + 12]) | (UInt16(groupData[off + 13]) << 8)
                    candidates.append(GroupEntry(
                        header12: Data(groupData[off ..< (off + 8)]),
                        width: width,
                        bitCount: bitCount,
                        iconID: iconID
                    ))
                }
                guard !candidates.isEmpty else { continue }

                // Prefer 32..128px frames (high bitCount), then 256px, then smaller frames
                let sortedCandidates = candidates.sorted { a, b in
                    let aSweet = (a.width >= 32 && a.width <= 128)
                    let bSweet = (b.width >= 32 && b.width <= 128)
                    if aSweet != bSweet { return aSweet }
                    if a.bitCount != b.bitCount { return a.bitCount > b.bitCount }
                    return a.width > b.width
                }

                for cand in sortedCandidates {
                    guard let iconEntry = iconEntries.first(where: { ($0.id & 0x7FFF_FFFF) == UInt32(cand.iconID) }),
                          let iconLangDir = subdirOffset(iconEntry.offsetVal),
                          let iconBytes = firstResourcePayload(in: iconLangDir),
                          iconBytes.count >= 8 else { continue }

                    // Direct PNG payload inside PE resource
                    let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
                    if Array(iconBytes.prefix(8)) == pngMagic {
                        return iconBytes
                    }

                    // Wrap raw BMP DIB inside a 1-entry .ico container
                    var ico = Data(capacity: 22 + iconBytes.count)
                    ico.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01, 0x00]) // ICONDIR
                    ico.append(cand.header12) // bWidth, bHeight, bColorCount, bReserved, wPlanes, wBitCount (8 bytes)
                    var lenLE = UInt32(iconBytes.count).littleEndian
                    ico.append(Data(bytes: &lenLE, count: 4))
                    var offsetLE = UInt32(22).littleEndian
                    ico.append(Data(bytes: &offsetLE, count: 4))
                    ico.append(iconBytes)
                    return ico
                }
            }
            return nil
        }
    }
}
