import ChrysaCore
import ChrysaApplication
import Foundation

package struct PEImportInfo: Sendable {
    package let is64Bit: Bool
    package let importsSteamAPI: Bool
    package let importsD3D12: Bool
    package let importsWinHTTP: Bool
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
            func containsCaseInsensitiveASCII(_ lowerNeedle: [UInt8]) -> Bool {
                let nLen = lowerNeedle.count
                guard nLen > 0, raw.count >= nLen else { return false }
                let firstB = lowerNeedle[0]
                let firstUpper = (firstB >= 97 && firstB <= 122) ? (firstB - 32) : firstB
                let endIdx = raw.count - nLen
                var i = 0
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
            if !hasSteam {
                hasSteam = containsCaseInsensitiveASCII(Array("steam_api64.dll".utf8))
                    || containsCaseInsensitiveASCII(Array("steam_api.dll".utf8))
            }
            if !hasD3D12 {
                hasD3D12 = containsCaseInsensitiveASCII(Array("d3d12.dll".utf8))
                    || containsCaseInsensitiveASCII(Array("d3d12core.dll".utf8))
            }
            if !hasWinHTTP {
                hasWinHTTP = containsCaseInsensitiveASCII(Array("winhttp.dll".utf8))
            }

            return PEImportInfo(
                is64Bit: is64,
                importsSteamAPI: hasSteam,
                importsD3D12: hasD3D12,
                importsWinHTTP: hasWinHTTP
            )
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
