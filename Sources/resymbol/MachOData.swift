//
//  File.swift
//  
//
//  Created by paradiseduo on 2021/12/30.
//

import Foundation

class MachOData {
    static let shared = MachOData()
    var objcCategories = [ObjcCategory]()
    var objcClasses = [Int: String]()
    var dylbMap = [String: String]()
    
    private init() {}
    
    func dylbMap(_ address: UInt64, _ name: String) {
        let add = address - 0x100000000
        self.dylbMap[String(add, radix: 16, uppercase: false)] = name
    }
    
    func classNameFrom(address: String) -> String {
        let index = address.int16Replace()
        return self.objcClasses[index] ?? ""
    }
}