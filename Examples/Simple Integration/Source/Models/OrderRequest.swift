//
//  OrderRequest.swift
//  Simple Integration
//
//  Created by Johnny Peter on 23/08/19.
//  Copyright © 2019 Network International. All rights reserved.
//

import Foundation
import NISdk

// This is just a sample order request class
// Check docs for all possible fields available
struct OrderRequest: Encodable {
    let action: String
    let amount: OrderAmount
    let language: String
    let merchantAttributes: [String: String]?
    var savedCard: SavedCard?
    var type: String?
    var frequency: String?
    var installmentDetails: InstallmentDetails?
    var recurringDetails: RecurringDetails?
    
    private enum  OrderRequestCodingKeys: String, CodingKey {
        case action
        case amount
        case language
        case merchantAttributes
        case savedCard
        case type
        case frequency
        case installmentDetails
        case recurringDetails
    }
}
