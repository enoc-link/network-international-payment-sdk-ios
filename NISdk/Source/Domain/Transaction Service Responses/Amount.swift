//
//  Amount.swift
//  NISdk
//
//  Created by Johnny Peter on 15/08/19.
//  Copyright © 2019 Network International. All rights reserved.
//

import Foundation

public struct Amount: Codable {
    public let currencyCode: String?
    public let value: Double?
    
    private enum AmountCodingKeys: String, CodingKey {
        case currencyCode
        case value
    }
    
    public init(currencyCode: String?, value: Double?) {
        self.currencyCode = currencyCode
        self.value = value
    }
    
    func getMinorUnit() -> Int {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: NISdk.sharedInstance.sdkLanguage)
        formatter.currencyCode = self.currencyCode
        formatter.numberStyle = .currency
        let minorUnit = formatter.maximumFractionDigits
        return minorUnit
    }
    
    func getFormattedAmount() -> String {
        var orderAmountValue = ""
        if let value = value {
            let minorUnit = self.getMinorUnit()
            let exponent: Decimal = pow(10.00, minorUnit)
            let roundedValue = Decimal(value) / exponent
            orderAmountValue = "\(roundedValue)";
        }
        
        let language = NISdk.sharedInstance.sdkLanguage
        let direction = Locale.characterDirection(forLanguage: language)
        if (direction == .rightToLeft) {
            return "\(currencyCode ?? "") \(orderAmountValue)"
        } else {
            return "\(orderAmountValue) \(currencyCode ?? "")"
        }
    }
    
    func getFormattedAmount2Decimal() -> String {
        var orderAmountValue = ""
        if let value = value {
            let minorUnit = self.getMinorUnit()
            let exponent: Decimal = pow(10.00, minorUnit)
            let roundedValue = Decimal(value) / exponent
            let doubleValue = NSDecimalNumber(decimal: roundedValue).doubleValue
            orderAmountValue = String(format: "%.2f", doubleValue);
        }
        
        let language = NISdk.sharedInstance.sdkLanguage
        let direction = Locale.characterDirection(forLanguage: language)
        if (direction == .rightToLeft) {
            return "\(currencyCode ?? "") \(orderAmountValue)"
        } else {
            return "\(orderAmountValue) \(currencyCode ?? "")"
        }
    }
    
    func getFormattedAmountValue() -> String {
        var orderAmountValue = ""
        if let value = value {
            let minorUnit = self.getMinorUnit()
            let exponent: Decimal = pow(10.00, minorUnit)
            let roundedValue = Decimal(value) / exponent
            orderAmountValue = "\(roundedValue)";
        }

        return orderAmountValue
    }
    
    public init(from decoder: Decoder) throws {
        let AmountContainer = try decoder.container(keyedBy: AmountCodingKeys.self)
        currencyCode = try AmountContainer.decodeIfPresent(String.self, forKey: .currencyCode)
        value = try AmountContainer.decodeIfPresent(Double.self, forKey: .value)
    }
}
