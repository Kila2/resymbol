//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/9/10.
//

import Foundation
import MachO

let byteSwappedOrder = NXByteOrder(rawValue: 0)

struct Section {
    
    static func readSection(type:BitType, isByteSwapped: Bool, handle: (Bool)->()) {
        if type == .x64_fat || type == .x86_fat || type == .none {
            handle(false)
            return
        }
        let binary = MachOData.shared.binary
                
        if type == .x86 {
            print("Not Support x86")
            handle(false)
            return
        } else {
            let header = binary.extract(mach_header_64.self)
            var offset_machO = MemoryLayout.size(ofValue: header)
            var vmAddress = [UInt64]()
            for _ in 0..<header.ncmds {
                let loadCommand = binary.extract(load_command.self, offset: offset_machO)
                if loadCommand.cmd == LC_SEGMENT_64 {
                    var segment = binary.extract(segment_command_64.self, offset: offset_machO)
                    if isByteSwapped {
                        swap_segment_command_64(&segment, byteSwappedOrder)
                    }
                    let segmentSegname = String(rawCChar: segment.segname)
                    vmAddress.append(segment.vmaddr)
                    if segmentSegname == "__DATA_CONST" {
                        var offset_segment = offset_machO + 0x48
                        for _ in 0..<segment.nsects {
                            let section = binary.extract(section_64.self, offset: offset_segment)
                            let sectionSegname = String(rawCChar: section.segname)
                            if sectionSegname.hasPrefix("__DATA") {
                                let sectname = String(rawCChar: section.sectname)
                                if sectname == "__objc_classlist__objc_classlist" || sectname == "__objc_nlclslist" {
//                                    handle__objc_classlist(binary, section: section)
                                } else if sectname == "__objc_catlist" {
//                                    handle__objc_catlist(binary, section: section)
                                } else if sectname == "__objc_protolist__objc_protolist" {
//                                    handle__objc_protolist(binary, section: section)
                                }
                            }
                            offset_segment += 0x50
                        }
                    }
                } else if loadCommand.cmd == LC_DYLD_INFO || loadCommand.cmd == LC_DYLD_INFO_ONLY {
                    var dylib = binary.extract(dyld_info_command.self, offset: offset_machO)
                    if isByteSwapped {
                        swap_dyld_info_command(&dylib, byteSwappedOrder)
                    }
                    print(dylib.bind_off, dylib.bind_size)
                    bindingDyld(binary, vmAddress: vmAddress, start: Int(dylib.bind_off), end: Int(dylib.bind_size+dylib.bind_off))
                } else if loadCommand.cmd == LC_SYMTAB {
                    var symtab = binary.extract(symtab_command.self, offset: offset_machO)
                    if isByteSwapped {
                        swap_symtab_command(&symtab, byteSwappedOrder)
                    }
                    let symbolTable = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(symtab.symoff), length: Int(symtab.nsyms*16)))!)
                    print(symbolTable)
                    let stringTable = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(symtab.stroff), length: Int(symtab.strsize)))!)
                    print(stringTable)
                } else if loadCommand.cmd == LC_DYSYMTAB {
                    var dysymtab = binary.extract(dysymtab_command.self, offset: offset_machO)
                    if isByteSwapped {
                        swap_dysymtab_command(&dysymtab, byteSwappedOrder)
                    }
                    let indirectSymbolTable = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(dysymtab.indirectsymoff), length: Int(dysymtab.nindirectsyms*4)))!)
                    print(indirectSymbolTable)
                }
                offset_machO += Int(loadCommand.cmdsize)
            }
        }
        handle(true)
    }
    
    private static func handle__objc_classlist(_ binary: Data, section: section_64) {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>3
        for i in 0..<count {
            let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
            
            var offsetS = sub.rawValueBig().int16Replace()
            if offsetS % 4 != 0 {
                offsetS -= offsetS%4
            }
            var oc = ObjcClass.OC(binary, offset: offsetS)
            
            let isa = DataStruct.data(binary, offset: offsetS, length: 8)
            var metaClassOffset = isa.value.int16Replace()
            if metaClassOffset % 4 != 0 {
                metaClassOffset -= metaClassOffset%4
            }
            oc.classMethods = ObjcClass.OC(binary, offset: metaClassOffset).classRO.baseMethod
            oc.write()
        }
    }
    
    private static func handle__objc_catlist(_ binary: Data, section: section_64) {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>3
        for i in 0..<count {
            let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
            
            var offsetS = sub.rawValueBig().int16Replace()
            if offsetS % 4 != 0 {
                offsetS -= offsetS%4
            }
            
            ObjcCategory.OCCG(binary, offset: offsetS).write()
        }
    }
    
    private static func handle__objc_protolist(_ binary: Data, section: section_64) {
        let d = binary.subdata(in: Range<Data.Index>(NSRange(location: Int(section.offset), length: Int(section.size)))!)
        let count = d.count>>3
        for i in 0..<count {
            let sub = d.subdata(in: Range<Data.Index>(NSRange(location: i<<3, length: 8))!)
            
            var offsetS = sub.rawValueBig().int16Replace()
            if offsetS % 4 != 0 {
                offsetS -= offsetS%4
            }
            
            ObjcProtocol.OCPT(binary, offset: offsetS).write()
        }
    }
    
    private static func bindingDyld(_ binary: Data, vmAddress:[UInt64], start: Int, end: Int, isLazy: Bool = false) {
        var done = false
        var symbolName = ""
        var libraryOrdinal: Int32 = 0
        var symbolFlags: Int32 = 0
        var type: Int32 = 0
        var addend: UInt64 = 0
        var segmentIndex: Int32 = 0
        let ptrSize = UInt64(MemoryLayout<UInt64>.size)
        
        var index = start
        var address = vmAddress[0]
        while index < end && !done {
            let item = Int32(binary[index])
            let immediate = item & BIND_IMMEDIATE_MASK
            let opcode = item & BIND_OPCODE_MASK
            index += 1
            switch opcode {
            case BIND_OPCODE_DONE:
                if !isLazy {
                    done = true
                }
                break
            case BIND_OPCODE_SET_DYLIB_ORDINAL_IMM:
                libraryOrdinal = immediate
                break
            case BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB:
                let r = binary.ulieb128(index: index, end: end)
                libraryOrdinal = Int32(r.1)
                index = r.0
                break
            case BIND_OPCODE_SET_DYLIB_SPECIAL_IMM:
                if immediate == 0 {
                    libraryOrdinal = 0
                } else {
                    libraryOrdinal = immediate | BIND_OPCODE_MASK
                }
                break
            case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM:
                var strData = Data()
                while binary[index] != 0 {
                    strData.append(contentsOf: [binary[index]])
                    index += 1
                }
                index += 1
                symbolName = String(data: strData, encoding: String.Encoding.utf8) ?? ""
                symbolFlags = immediate
                break
            case BIND_OPCODE_SET_TYPE_IMM:
                type = immediate
                break
            case BIND_OPCODE_SET_ADDEND_SLEB:
                let r = binary.ulieb128(index: index, end: end)
                index = r.0
                addend = r.1
                break
            case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
                segmentIndex = immediate
                let r = binary.ulieb128(index: index, end: end)
                index = r.0
                address = vmAddress[Int(segmentIndex)]+r.1
                break
            case BIND_OPCODE_ADD_ADDR_ULEB:
                let r = binary.ulieb128(index: index, end: end)
                index = r.0
                address &+= r.1
                break
            case BIND_OPCODE_DO_BIND:
                MachOData.shared.dylbMap[String(address)] = symbolName
                address &+= ptrSize
                break
            case BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB:
                let r = binary.ulieb128(index: index, end: end)
                index = r.0
                MachOData.shared.dylbMap[String(address)] = symbolName
                address &+= (ptrSize &+ r.1)
                break
            case BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED:
                MachOData.shared.dylbMap[String(address)] = symbolName
                address &+= ptrSize + ptrSize * UInt64(immediate)
                break
            case BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB:
                let r = binary.ulieb128(index: index, end: end)
                index = r.0
                let count = r.1
                let r1 = binary.ulieb128(index: index, end: end)
                index = r1.0
                for _ in 0 ..< count {
                    MachOData.shared.dylbMap[String(address)] = symbolName
                    address &+= (ptrSize &+ r1.1)
                }
                break
            default:
                break
            }
        }
        print(end-index)
        print(MachOData.shared.dylbMap.keys.count)
    }
}
