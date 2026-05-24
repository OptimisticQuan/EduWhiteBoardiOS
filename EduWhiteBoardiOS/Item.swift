//
//  Item.swift
//  EduWhiteBoardiOS
//
//  Created by Wayne Quan on 2026/5/24.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
